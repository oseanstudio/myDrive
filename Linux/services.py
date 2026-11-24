"""Use the shared myDrive core and the verified local Blip engine."""

import configparser
import hashlib
import json
import os
import plistlib
import re
import select
import shutil
import subprocess
import tarfile
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.request import urlopen
from uuid import UUID, uuid4

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "myDrive"


def read_settings(name, default):
    path = DATA / name
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    except (OSError, ValueError) as error:
        raise RuntimeError(f"Cannot read {name}. The existing file was kept.") from error


def save_settings(name, value):
    DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=DATA, delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(value, file, ensure_ascii=False)
            file.flush()
            os.fsync(file.fileno())
            temporary.replace(DATA / name)
        finally:
            temporary.unlink(missing_ok=True)


def core(action, **fields):
    binary = os.environ.get("MYDRIVE_CORE", str(ROOT / "mydrive-core"))
    resumable = action in {"upload", "download"} and fields.get("bookmark", {}).get("protocol") == "smb"
    if action in {"update.install", "update.stage"}:
        timeout = 11 * 60
    elif action in {"update.apply", "update.discard", "update.error"}:
        timeout = 5
    elif action == "update.check":
        timeout = 12
    else:
        timeout = 8 if action == "smb.health" else None if resumable else 180
    process = subprocess.run(
        [binary], input=json.dumps({"action": action, "data_dir": str(DATA), **fields}),
        capture_output=True, encoding="utf-8", timeout=timeout,
    )
    if process.returncode:
        raise RuntimeError("The myDrive core stopped unexpectedly.")
    result = json.loads(process.stdout)
    if not result.get("ok"):
        raise RuntimeError(result.get("error", "The operation could not be completed."))
    return result.get("data")


class Sync:
    def __init__(self):
        self.connection = None
        self.config_path = ""
        self.owner = None
        self.owner_lock = threading.Lock()
        self.stopping = False

    def stop(self):
        with self.owner_lock:
            self.stopping = True
            if self.owner is not None:
                self.owner.stdin.close()

    def ensure(self):
        with self.owner_lock:
            if self.stopping:
                raise RuntimeError("myDrive is closing.")
            if self.owner is None or self.owner.poll() is not None:
                if self.owner is not None:
                    self.owner.stdin.close()
                    self.owner.stdout.close()
                binary = os.environ.get("MYDRIVE_CORE", str(ROOT / "mydrive-core"))
                self.owner = subprocess.Popen([binary, "--syncthing-owner"],
                                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                              encoding="utf-8")
            owner = self.owner
            owner.stdin.write(json.dumps({"data_dir": str(DATA), "payload": {"config_path": self.config_path}}) + "\n")
            owner.stdin.flush()
        line = owner.stdout.readline()
        if not line:
            raise RuntimeError("The myDrive Syncthing service stopped. Refresh Sync to reconnect.")
        result = json.loads(line)
        if not result.get("ok"):
            raise RuntimeError(result["error"])
        self.connection = result["data"]["connection"]

    def request(self, action, **payload):
        try:
            if self.connection is None:
                self.ensure()
            return core(f"syncthing.{action}", syncthing=self.connection, payload=payload)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            self.connection = None
            raise


def credentials(bookmark):
    if bookmark["protocol"] in {"local", "smb"}:
        return {}
    key = bookmark["id"]
    tool = shutil.which("secret-tool")
    if not tool:
        raise RuntimeError("Install the Secret Service command-line client to use saved credentials.")
    result = subprocess.run([tool, "lookup", "application", "myDrive", "bookmark", key],
                            capture_output=True, encoding="utf-8", timeout=15)
    if result.returncode and result.stderr.strip():
        raise RuntimeError("Linux Secret Service is unavailable. Unlock your keyring and try again.")
    return json.loads(result.stdout) if result.stdout.strip() else {}


def save_credentials(bookmark, value):
    if not any(value.values()):
        return
    tool = shutil.which("secret-tool")
    if not tool:
        raise RuntimeError("Install the Secret Service command-line client to save credentials.")
    result = subprocess.run(
        [tool, "store", "--label=myDrive connection", "application", "myDrive", "bookmark", bookmark["id"]],
        input=json.dumps(value), capture_output=True, encoding="utf-8", timeout=30,
    )
    if result.returncode:
        raise RuntimeError("Linux Secret Service could not save the connection credentials.")


def exact_peer(value):
    try:
        account, device = value.split(":")
        return str(UUID(account)) == account.lower() and str(UUID(device)) == device.lower()
    except (AttributeError, TypeError, ValueError):
        return False


def link_url(location):
    try:
        uri = urlsplit(location)
        if uri.scheme and (uri.scheme != "file" or uri.netloc not in ("", "localhost")):
            return None
        path = Path(unquote(uri.path) if uri.scheme else location)
        if not path.is_absolute() or not path.is_file() or any(p.is_symlink() for p in (path, *path.parents)):
            return None
        with path.open("rb") as file:
            data = file.read(65537)
        if not 0 < len(data) <= 65536:
            return None
        if path.suffix.lower() == ".webloc":
            url = plistlib.loads(data).get("URL")
        elif path.suffix.lower() == ".url":
            parser = configparser.ConfigParser(interpolation=None, strict=True)
            encoding = "utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig"
            parser.read_string(data.decode(encoding))
            url = parser["InternetShortcut"].get("URL")
        else:
            return None
        if not isinstance(url, str) or len(url) > 8192 or any(c.isspace() or ord(c) < 32 for c in url) or "\\" in url:
            return None
        target = urlsplit(url)
        if target.scheme in ("https", "http") and target.hostname and target.username is None and target.password is None:
            return url
    except (OSError, ValueError, KeyError, AttributeError, TypeError, configparser.Error, plistlib.InvalidFileException):
        return None
    return None


class Blip:
    ARCHIVE = "https://static.blip.net/linux/blip-1.2.8-linux-amd64.tar.gz"
    ARCHIVE_HASH = "59fd1020f7f193aae4373f45f39bf39e9e3337bf0af6ede91bdb1c8e4c1ac463"
    ENGINE_MEMBER = "blip-1.2.8/lib/runtime/lib/libblip-jni.so"
    ENGINE_ERRORS = {
        "native_engine_missing": "Choose Set up Blip to get the background engine.",
        "native_engine_unsupported": "This Blip engine does not match the supported release.",
        "native_connection_unavailable": "The Blip background receiver is unavailable.",
        "sign_in_required": "Sign in to Blip to send or receive files.",
        "activity_unavailable": "myDrive could not read saved Send activity.",
        "activity_retry_unavailable": "This transfer can no longer be retried safely. Select the files again to send them.",
        "cancel_not_active": "This send is no longer active. Refresh to check its status.",
        "cancel_unconfirmed": "Blip hasn’t confirmed the cancellation. Refresh to check the send.",
        "search_unavailable": "Blip search is unavailable. Try again in a moment.",
        "invalid_search": "Enter a name or email address.",
        "accept_not_waiting": "This transfer is no longer waiting. Refresh to check its status.",
        "registration_failed": "Blip could not confirm sign-in. Check the email or code and try again.",
        "invalid_sign_in_input": "Check the Blip email address or sign-in code.",
    }

    def __init__(self):
        state_home = Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/mydrive-{os.getuid()}"))
        self.run_dir = state_home / "mydrive-blip"
        self.standalone = DATA / "Blip" / "profile"
        self.desktop_state = DATA.parent / "net.blip.desktop" / "state.dat"
        self.desktop = self.desktop_state.is_file() and not (self.standalone / "state/state.dat").is_file()
        self.profile = self.run_dir if self.desktop else self.standalone
        self.inbox = DATA / "Blip" / "downloads"
        self.host = None
        self.host_buffer = b""
        self.host_can_poll = None
        self.next_start = 0
        self.arguments = None
        self.environment = {key: value for key, value in os.environ.items() if key != "LD_PRELOAD"}
        self.executable = os.environ.get("MYDRIVE_CORE", str(ROOT / "mydrive-core"))

    def install_engine(self):
        self.inbox.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".blip-", dir=self.inbox.parent) as work:
            package = Path(work) / "blip.tar.gz"
            digest = hashlib.sha256()
            length = 0
            with urlopen(self.ARCHIVE, timeout=15) as response, package.open("wb") as output:
                location = urlsplit(response.url)
                if location.scheme != "https" or location.hostname != "static.blip.net":
                    raise RuntimeError("The Blip download redirected to an unexpected server.")
                deadline = time.monotonic() + 120
                while data := response.read(256 * 1024):
                    length += len(data)
                    if length > 160 * 1024 * 1024 or time.monotonic() >= deadline:
                        raise RuntimeError("The Blip download did not finish within its limits.")
                    output.write(data)
                    digest.update(data)
            if digest.hexdigest() != self.ARCHIVE_HASH:
                raise RuntimeError("The downloaded Blip archive failed its checksum.")
            engine = Path(work) / "libblip-jni.so"
            with tarfile.open(package, "r:gz") as archive:
                member = archive.getmember(self.ENGINE_MEMBER)
                if not member.isfile() or not 0 < member.size <= 64 * 1024 * 1024:
                    raise RuntimeError("The downloaded archive does not contain the supported Blip engine.")
                with archive.extractfile(member) as source, engine.open("wb") as output:
                    shutil.copyfileobj(source, output)
            self.invoke("import-engine", "--", str(engine))

    def prepare(self, download=False):
        if self.arguments is not None:
            return
        try:
            self.invoke("doctor")
        except RuntimeError:
            known = [Path("/opt/blip"), Path("/usr/local/lib/blip"), Path.home() / ".local/opt/blip"]
            if configured := os.environ.get("MYDRIVE_BLIP_DIR"):
                known.insert(0, Path(configured))
            for folder in known:
                library = folder / "lib/runtime/lib/libblip-jni.so"
                if library.is_file():
                    try:
                        self.invoke("import-engine", "--", str(library))
                        break
                    except RuntimeError:
                        continue
            else:
                if not download:
                    raise
                self.install_engine()
        if not self.desktop:
            self.invoke("init", "--name", "myDrive on Linux")
        self.arguments = True

    def command(self, action, *options):
        mode = ["--desktop"] if self.desktop and action in {
            "poll", "send", "accept", "search", "activity", "retry", "cancel", "publish-name"
        } else []
        return [self.executable, "--blip-engine", action, "--profile", str(self.profile), *mode, *options]

    def invoke(self, action, *options, input_text=""):
        process = subprocess.run(self.command(action, *options), input=input_text,
                                 capture_output=True, encoding="utf-8", env=self.environment, timeout=30)
        try:
            result = json.loads(process.stdout)
        except ValueError as error:
            raise RuntimeError("Could not read the background Blip session.") from error
        return self.checked(result)

    def checked(self, result):
        if not result.get("ok"):
            error = self.ENGINE_ERRORS.get(result.get("error"), "Blip could not confirm this request.")
            raise RuntimeError(error)
        return result

    def request(self, command, *values):
        self.prepare()
        if command in {"accept", "accept-manual"}:
            return self.invoke(command, "--id", values[0], "--execute")
        if command == "activity":
            return self.invoke(command, input_text=values[0])
        if command in {"retry", "cancel"}:
            return self.invoke(command, "--id", values[1], "--execute", input_text=values[0])
        if command == "publish-name":
            return self.invoke(command, "--name", os.uname().nodename, input_text=values[0])
        if command == "send":
            peer, request_id, *paths = values
            return self.invoke(command, "--peer", peer, "--id", request_id, "--execute", "--", *paths)
        if command == "search":
            return self.invoke(command, input_text=values[0] + "\n")
        return self.invoke(command)

    def monitor(self, background=True, setup=False):
        self.prepare(download=setup)
        if background and (self.host is None or self.host.poll() is not None) and time.monotonic() >= self.next_start:
            self.next_start = time.monotonic() + 30
            self.host = subprocess.Popen(
                self.command("desktop-serve" if self.desktop else "serve"),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=self.environment,
            )
            self.host_buffer = b""
            self.host_can_poll = None
        if not background:
            self.stop()
        if self.host is not None and self.host.poll() is None:
            try:
                return self.poll_host()
            except (OSError, RuntimeError):
                if self.host.poll() is None:
                    raise
        return self.request("poll")

    def sign_in(self, value, verifying=False):
        if self.desktop:
            raise RuntimeError("Sign in from a myDrive-managed profile.")
        if verifying:
            if not re.fullmatch(r"[A-Za-z0-9-]{4,16}", value):
                raise RuntimeError("Enter the Blip sign-in code.")
            return self.invoke("verify", input_text=value + "\n")
        if len(value.encode()) > 254 or not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value):
            raise RuntimeError("Enter a valid Blip email address.")
        return self.invoke("login", input_text=value + "\n")

    def poll_host(self):
        identifier = None
        deadline = time.monotonic() + 12
        while True:
            if self.host_can_poll is False:
                return self.request("poll")
            if self.host_can_poll and identifier is None:
                identifier = uuid4().hex
                self.host.stdin.write(f"POLL {identifier}\n".encode("ascii"))
                self.host.stdin.flush()
            line, split, remaining = self.host_buffer.partition(b"\n")
            if split:
                self.host_buffer = remaining
                payload = json.loads(line)
                if payload.get("event") == "host_ready":
                    self.host_can_poll = bool(payload.get("poll_pipe"))
                if payload.get("event") == "poll_result" and payload.get("request_id") == identifier:
                    payload.pop("event")
                    payload.pop("request_id")
                    return self.checked(payload)
                if not payload.get("ok") and not payload.get("event"):
                    self.checked(payload)
                continue
            remaining_time = deadline - time.monotonic()
            if remaining_time <= 0 or not select.select([self.host.stdout], [], [], remaining_time)[0]:
                raise RuntimeError("Blip's background receiver did not respond.")
            part = os.read(self.host.stdout.fileno(), 65536)
            if not part or len(self.host_buffer) + len(part) > 1_048_576:
                raise RuntimeError("Blip's background receiver could not return its status.")
            self.host_buffer += part

    def stop(self):
        if self.host is not None:
            self.host.stdin.close()
            self.host.stdout.close()
            if self.host.poll() is None:
                try:
                    self.host.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    self.host.terminate()
        self.host = None
        self.host_buffer = b""
        self.host_can_poll = None

    def send(self, peer, paths, request_id=None):
        if not exact_peer(peer):
            raise RuntimeError("Choose one exact Blip device.")
        return self.request("send", peer, request_id or str(uuid4()), *paths)
