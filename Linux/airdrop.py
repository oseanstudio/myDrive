"""Optional nearby sharing through the system-installed Owly CLI and radio service."""

import json
import os
import re
import select
import shutil
import subprocess
import threading
from pathlib import Path
from time import monotonic

from gi.repository import GLib, Gtk

from ui_widgets import button, clear


OWLY = "https://github.com/t4t5/owly#install"
LEASE_SECONDS = 600
DEVICE = re.compile(r'^([0-9a-fA-F]{12}|(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})\s+("(?:[^"\\]|\\.)*")\s+\(')
OFFER = re.compile(rb'^("(?:[^"\\\r\n]|\\.)*") \("(?:[^"\\\r\n]|\\.)*"\) wants to send:\r?$', re.M)
PROMPT = b"accept? [y/N] "


def nearby_devices(output):
    devices = {}
    for line in output.splitlines():
        match = DEVICE.match(line)
        if not match:
            continue
        identifier, quoted = match.groups()
        try:
            caption = "".join(char for char in json.loads(quoted) if char.isprintable())[:100].strip()
        except ValueError:
            continue
        if caption:
            devices[identifier] = caption
    return devices


class NearbyAirDrop:
    def __init__(self, app):
        self.app = app
        self.dialog = None
        self.session = None

    @staticmethod
    def executable():
        # Owly is installed and updated through the system package, alongside owlyd.
        return shutil.which("owly", path="/usr/local/bin:/usr/bin:/bin:/run/current-system/sw/bin")

    @property
    def active(self):
        return self.session is not None

    def show(self, paths=None):
        if self.dialog:
            self.dialog.present()
            return
        executable = self.executable()
        self.dialog = Gtk.Dialog(title="Nearby AirDrop", transient_for=self.app.window, modal=True)
        self.dialog.set_default_size(344, -1)
        self.dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        self.dialog.connect("response", lambda *_: self.stop())
        self.dialog.connect("close-request", self.window_closed)
        self.status = Gtk.Label(xalign=0, wrap=True, max_width_chars=42)
        self.actions = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        content = self.dialog.get_content_area()
        content.set_spacing(6)
        content.append(self.status)
        content.append(self.actions)
        if not executable:
            self.status.set_text("Install Owly and its radio service to use nearby AirDrop.")
            self.actions.append(Gtk.LinkButton(uri=OWLY, label="Owly setup and supported Wi-Fi adapters"))
        elif paths:
            self.status.set_text("Choose a nearby device. On the iPhone, unlock it and turn on AirDrop.")
            self.actions.append(button("Find devices", lambda: self.begin(executable, paths)))
        else:
            self.status.set_text("AirDrop uses a temporary session with a nearby device.")
            self.actions.append(button("Send files…", lambda: self.pick(Gtk.FileChooserAction.OPEN, True)))
            self.actions.append(button("Send a folder…", lambda: self.pick(Gtk.FileChooserAction.SELECT_FOLDER, False)))
            self.actions.append(button("Receive", lambda: self.begin(executable, None)))
        self.app.present_dialog(self.dialog)

    def pick(self, action, multiple):
        self.stop()
        self.app.files("Send via AirDrop", action, self.show, multiple=multiple)

    def window_closed(self, *_):
        self.stop()
        return True

    def stop(self):
        if self.session:
            self.session.close()
            self.session = None
        if self.dialog:
            dialog, self.dialog = self.dialog, None
            dialog.destroy()

    def begin(self, executable, paths):
        clear(self.actions)
        self.status.set_text("Checking Wi-Fi and the AirDrop helper…")
        downloads = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD) or str(Path.home() / "Downloads")
        session = self.session = AirDropSession(self, executable, paths, downloads)
        session.background(session.check)

    def update(self, session, status, choices=()):
        if self.session is not session or not self.dialog:
            return GLib.SOURCE_REMOVE
        clear(self.actions)
        self.status.set_text(status)
        for name, action in choices:
            self.actions.append(button(name, action))
        return GLib.SOURCE_REMOVE


class AirDropSession:
    def __init__(self, owner, executable, paths, downloads):
        self.owner, self.executable, self.paths, self.downloads = owner, executable, paths, downloads
        self.closed = False
        self.lock = threading.Lock()
        self.children = set()

    def background(self, operation):
        def work():
            try:
                operation()
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                self.finish(str(error))
        threading.Thread(target=work, daemon=True).start()

    def launch(self, operation):
        clear(self.owner.actions)
        self.background(operation)

    def show(self, text, choices=()):
        GLib.idle_add(self.owner.update, self, text, choices)

    def start(self, args, **options):
        with self.lock:
            if self.closed:
                raise RuntimeError("AirDrop session ended.")
            process = subprocess.Popen([self.executable, *args], **options)
            self.children.add(process)
            return process

    def finish(self, text, choices=()):
        self.close()
        self.show(text, choices)

    def close(self):
        with self.lock:
            self.closed = True
            children = tuple(self.children)
            self.children.clear()
            for process in children:
                if process.poll() is None:
                    try:
                        process.terminate()
                    except ProcessLookupError:
                        pass
        def reap():
            for process in children:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        if children:
            threading.Thread(target=reap, daemon=True).start()

    def check(self):
        version = self.command(["--version"], 5).strip()
        match = re.fullmatch(r"owly 0\.4\.(\d+)", version)
        if not match or int(match.group(1)) < 3:
            raise RuntimeError("Nearby AirDrop needs Owly 0.4.3 or a newer 0.4 release.")
        report = json.loads(self.command(["doctor", "--json"], 8, check=False))
        blockers = report.get("missing") if isinstance(report, dict) else None
        if blockers != []:
            messages = blockers if isinstance(blockers, list) else []
            message = next((str(item.get("say", "")) for item in messages if isinstance(item, dict)), "")
            raise RuntimeError(message[:240] or "Owly could not confirm that this Wi-Fi adapter is ready.")
        if report.get("mode") in ("shared", "concurrent"):
            self.radio()
        else:
            self.show("Owly may disconnect Wi-Fi during this session. This can interrupt Parsec and other transfers.",
                      [("Start AirDrop", lambda: self.launch(self.radio))])

    def command(self, args, timeout, check=True):
        process = self.start(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise RuntimeError("The AirDrop operation timed out.") from None
        finally:
            with self.lock:
                self.children.discard(process)
        if check and process.returncode:
            raise RuntimeError("Owly could not complete the AirDrop request.")
        return output.decode("utf-8", errors="replace")

    def radio(self):
        self.show("Starting the AirDrop radio…")
        self.radio_process = self.start(["radio", "up", "--for", str(LEASE_SECONDS)],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        buffer = b""
        deadline = monotonic() + 18
        while monotonic() < deadline:
            if self.radio_process.poll() is not None:
                raise RuntimeError("Owly could not start its radio. Check the radio service and its permissions.")
            if not select.select([self.radio_process.stderr], [], [], 0.4)[0]:
                continue
            buffer = (buffer + os.read(self.radio_process.stderr.fileno(), 4096))[-8192:]
            if re.search(rb"(?m)^awdl0 is up:", buffer):
                break
        else:
            raise RuntimeError("The AirDrop radio did not become ready.")
        self.background(self.watch_radio)
        if self.paths:
            self.browse()
        else:
            self.receive()

    def watch_radio(self):
        # Drain Owly's peer diagnostics while the radio is leased.
        while self.radio_process.stderr.read(4096):
            pass
        self.radio_process.wait()
        if not self.closed:
            self.finish("The AirDrop session ended.")

    def browse(self):
        self.show("Looking for nearby AirDrop devices…")
        devices = nearby_devices(self.command(["browse", "--seconds", "10"], 20))
        choices = []
        for identifier, name in list(devices.items())[:12]:
            caption = name if list(devices.values()).count(name) == 1 else f"{name} ({identifier[-4:]})"
            choices.append((caption, lambda target=identifier, caption=name:
                            self.launch(lambda: self.send(target, caption))))
        choices.append(("Scan again", lambda: self.launch(self.browse)))
        self.show("Choose a device" if devices else "No AirDrop devices found. Unlock the device and check AirDrop.", choices)

    def send(self, target, caption):
        self.show("Sending to " + caption + "…")
        selector = "--mac" if ":" in target else "--to"
        output = self.command(["send", selector, target, "--", *self.paths], LEASE_SECONDS, check=False).strip()
        if output == "delivered":
            self.finish("Sent to " + caption)
        else:
            self.finish("The recipient declined the transfer." if output == "declined" else "The AirDrop transfer did not finish.")

    def receive(self):
        Path(self.downloads).mkdir(parents=True, exist_ok=True)
        process = self.start(["receive", "--dir", self.downloads], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.show("Waiting for an AirDrop. Choose this computer in the sender’s AirDrop picker.")
        stream = b""
        sender = ""
        awaiting = 0
        accepted = False

        def allow():
            nonlocal accepted
            if self.closed or accepted or monotonic() >= awaiting or process.poll() is not None:
                return
            try:
                process.stdin.write(b"y\n")
                process.stdin.flush()
            except OSError:
                self.finish("This AirDrop offer has ended.")
                return
            accepted = True
            clear(self.owner.actions)
            self.show("Receiving from " + sender + "…")

        while not self.closed:
            if self.closed or process.poll() is not None:
                break
            ready, _, _ = select.select([process.stdout, process.stderr], [], [], 0.4)
            if awaiting and not accepted and monotonic() >= awaiting:
                self.finish("The AirDrop offer timed out.")
                return
            for channel in ready:
                chunk = os.read(channel.fileno(), 4096)
                if not chunk:
                    continue
                if channel == process.stdout and accepted:
                    text = chunk.decode("utf-8", errors="replace").strip()
                    heading = "AirDrop received."
                    if text.startswith('"http') and text.endswith('"'):
                        try:
                            received = json.loads(text)
                            if isinstance(received, str) and received.startswith(("https://", "http://")):
                                heading = "Received a link\n" + received[:300]
                        except ValueError:
                            pass
                    self.finish(heading, [("Open Downloads", lambda: self.owner.app.open_path(self.downloads))])
                    return
                if channel == process.stderr:
                    stream = (stream + chunk)[-8192:]
                    offers = list(OFFER.finditer(stream))
                    if not awaiting and offers and stream.endswith(PROMPT):
                        quoted = offers[0].group(1).decode("utf-8", errors="replace")
                        try:
                            sender = "".join(char for char in json.loads(quoted) if char.isprintable())[:80]
                        except ValueError:
                            sender = "Nearby device"
                        sender = sender or "Nearby device"
                        awaiting = monotonic() + 11
                        self.show(sender + " wants to share over AirDrop.",
                                  [("Receive", allow), ("Decline", lambda: self.finish("AirDrop declined."))])
                    elif accepted and (len(offers) > 1 or b"transfer failed:" in chunk):
                        self.finish("The AirDrop transfer did not finish.")
                        return
        if not self.closed:
            self.finish("Owly stopped receiving. Check AirDrop visibility and your firewall.")
