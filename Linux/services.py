"""Use the shared myDrive core and an installed Blip runtime from the Linux shell."""

import base64
import configparser
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import unquote, urlsplit
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
    timeout = 11 * 60 if action == "update.install" else None if resumable else 180
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

    def request(self, action, **payload):
        try:
            if self.connection is None:
                details = core("engine.ensure", payload={"config_path": self.config_path})
                self.connection = details["connection"]
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
    LOCK = {
        "lib/app/desktopApp-desktop-1.2.8.jar": "d30b5172b1a7a6216e0de33e195cf248fc06ef3524ee45de0918a0742a941c51",
        "lib/app/libblip-jvm.jar": "0632dae7615951811a63788b6f37cfb041474a177f46244a8dd3bc3337734572",
        "lib/runtime/lib/libblip-jni.so": "4125334ab2cef75a056b7bd542f736374c3f036be4c04ef12818ed4492476335",
    }

    def __init__(self):
        state_home = Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/mydrive-{os.getuid()}"))
        self.profile = state_home / "mydrive-blip"
        self.inbox = DATA / "Blip" / "downloads"
        self.host = None
        self.next_start = 0
        self.arguments = None
        self.environment = None

    def prepare(self):
        if self.arguments is not None:
            return
        locations = [Path(os.environ["MYDRIVE_BLIP_DIR"])] if os.environ.get("MYDRIVE_BLIP_DIR") else [
            Path("/opt/blip"), Path("/usr/local/lib/blip"), Path.home() / ".local/opt/blip"
        ]
        if not os.environ.get("MYDRIVE_BLIP_DIR"):
            for name in ("blip", "Blip"):
                if launcher := shutil.which(name):
                    locations.extend(Path(launcher).resolve().parents[:2])
        folder = next((path for path in locations if (path / "lib/app/libblip-jvm.jar").is_file()), None)
        if not folder:
            raise RuntimeError("Install Blip 1.2.8 from its Linux archive and set MYDRIVE_BLIP_DIR to its folder.")
        for name, expected in self.LOCK.items():
            path = folder / name
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise RuntimeError("This Linux Blip build differs from the supported 1.2.8 release.")
        bundled_java = folder / "lib/runtime/bin/java"
        java = os.environ.get("MYDRIVE_JAVA") or (
            str(bundled_java) if os.access(bundled_java, os.X_OK) else shutil.which("java")
        )
        if not java:
            raise RuntimeError("Java 25 is required for Blip. Install it or set MYDRIVE_JAVA.")
        native = folder / "lib/runtime/lib"
        classes = os.environ.get("MYDRIVE_BLIP_CLASSES", str(ROOT / "blip-classes"))
        self.profile.mkdir(mode=0o700, parents=True, exist_ok=True)
        for path in (self.profile.parent, self.profile):
            stat = path.lstat()
            if path.is_symlink() or stat.st_uid != os.getuid() or stat.st_mode & 0o022:
                raise RuntimeError("Blip requires a private per-user runtime directory.")
        (self.profile / "cache").mkdir(mode=0o700, exist_ok=True)
        self.inbox.mkdir(mode=0o700, parents=True, exist_ok=True)
        (self.profile / "mydrive-profile.json").touch(mode=0o600, exist_ok=True)
        self.environment = {k: v for k, v in os.environ.items()
                            if k not in ("JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "LD_PRELOAD")}
        self.arguments = [java, "-Djava.awt.headless=true", "--enable-native-access=ALL-UNNAMED",
                          f"-Dmydrive.inbox={self.inbox.resolve()}",
                          f"-Djava.library.path={native}", "-cp", f"{classes}:{folder / 'lib/app/*'}", "BlipBridge"]

    def request(self, command, *values):
        self.prepare()
        payload = "".join(base64.b64encode(str(value).encode()).decode() + "\n" for value in values)
        process = subprocess.run(
            self.arguments + ["desktop-request", str(self.profile), command],
            input=payload, capture_output=True, encoding="utf-8", env=self.environment, timeout=15,
        )
        replies = [row.removeprefix("MYDRIVE_JSON ") for row in process.stdout.splitlines()
                   if row.startswith("MYDRIVE_JSON ")]
        if len(replies) != 1:
            raise RuntimeError("Could not read the Blip session. Check Java 25 and open Blip once.")
        result = json.loads(replies[0])
        if process.returncode or not result.get("ok"):
            raise RuntimeError("Blip could not confirm the request. Check the existing Blip session before retrying.")
        return result

    def monitor(self, background=True):
        self.prepare()
        if background and (self.host is None or self.host.poll() is not None) and time.monotonic() >= self.next_start:
            self.next_start = time.monotonic() + 30
            self.host = subprocess.Popen(
                self.arguments + ["desktop-host", str(self.profile), "serve"],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.environment,
            )
        if not background:
            self.stop()
        deadline = time.monotonic() + 12
        while True:
            try:
                return self.request("poll")
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                if (not background or self.host is None or self.host.poll() is not None
                        or time.monotonic() >= deadline):
                    raise RuntimeError("Blip did not connect. Check that you have signed in to the installed Blip app.") from error
                time.sleep(0.5)

    def stop(self):
        if self.host is not None and self.host.poll() is None:
            self.host.stdin.close()
            try:
                self.host.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.host.terminate()
        self.host = None

    def send(self, peer, paths, request_id=None):
        if not exact_peer(peer):
            raise RuntimeError("Choose one exact Blip device.")
        return self.request("send", peer, request_id or str(uuid4()), *paths)
