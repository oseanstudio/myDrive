"""Storage bookmarks and the native GNOME virtual file system SMB adapter."""

import json
import subprocess
import tempfile
from pathlib import Path
from time import monotonic
from urllib.parse import quote, urlsplit
from uuid import uuid4

from gi.repository import Gio, GLib, Gtk

from services import DATA, core, credentials, save_credentials
from smb_sharing import list_private_shares, stop_private_share
from ui_widgets import button, clear, label, menu, row


def single_name(value):
    if not value or value in {".", ".."} or any(c in "/\\:" or ord(c) < 32 for c in value):
        raise ValueError("Enter a single valid filename.")
    return value


def smb_file(bookmark, relative=""):
    host = urlsplit("smb://" + bookmark["host"])
    if not host.hostname or host.path or host.query or host.fragment or host.username is not None:
        raise ValueError("Enter an SMB server address without credentials or a share path.")
    parts = [p for p in bookmark["path"].split("/") if p]
    if not parts:
        raise ValueError("Enter the SMB share name.")
    uri = f"smb://{host.netloc}/" + "/".join(quote(single_name(part), safe="") for part in parts)
    file = Gio.File.new_for_uri(uri)
    return file.resolve_relative_path(relative) if relative else file


def cifs_mounts():
    # Read the kernel mount table without resolving a possibly stalled network path.
    try:
        result = subprocess.run(
            ["findmnt", "--json", "--list", "--types", "cifs,smb3", "--output", "SOURCE,TARGET"],
            capture_output=True, text=True, timeout=2,
        )
        return json.loads(result.stdout).get("filesystems", []) if result.returncode == 0 else []
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def health_targets(bookmarks):
    mounts = cifs_mounts() if any(bookmark.get("mount_path") for bookmark in bookmarks) else []
    for bookmark in bookmarks:
        probe = {"kind": "host", "value": bookmark["host"]}
        if mount_path := bookmark.get("mount_path"):
            path = Path(mount_path)
            expected = f"//{bookmark['host']}/{bookmark['path'].strip('/')}".casefold()
            if path.is_absolute() and any(
                mount["source"].casefold() == expected
                and (path == Path(mount["target"]) or Path(mount["target"]) in path.parents)
                for mount in mounts
            ):
                probe = {"kind": "path", "value": mount_path}
        yield {"id": bookmark["id"], "probe": probe}


class StorageView:
    def __init__(self, app, page):
        self.app = app
        self.page = page
        self.bookmarks = []
        self.shared_here = []
        self.tail_devices = []
        self.current = None
        self.path = ""
        self.health = {}
        self.health_labels = {}
        self.health_timer = 0
        self.trigger = "periodic"
        self.next_inventory = 0
        self.monitor_handlers = []
        self.wake_bus = None
        self.wake_subscription = 0

    def start_monitor(self):
        network = Gio.NetworkMonitor.get_default()
        self.monitor_handlers.append((network, network.connect(
            "network-changed", lambda *_: self.check_now("network"))))
        volumes = Gio.VolumeMonitor.get()
        for signal in ("mount-added", "mount-removed"):
            self.monitor_handlers.append((volumes, volumes.connect(signal, lambda *_: self.check_now("mount"))))
        Gio.bus_get(Gio.BusType.SYSTEM, None, self.watch_wake, None)
        self.check_now("periodic")

    def watch_wake(self, _source, result, _data):
        try:
            bus = Gio.bus_get_finish(result)
        except GLib.Error:
            return
        if self.app.stopping:
            return
        self.wake_bus = bus
        self.wake_subscription = bus.signal_subscribe(
            "org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
            "/org/freedesktop/login1", None, Gio.DBusSignalFlags.NONE, self.wake_received,
        )

    def wake_received(self, _connection, _sender, _path, _interface, _signal, parameters, *_):
        if parameters.unpack() == (False,):
            self.check_now("wake")

    def stop_monitor(self):
        if self.health_timer:
            GLib.source_remove(self.health_timer)
            self.health_timer = 0
        for monitor, handler in self.monitor_handlers:
            monitor.disconnect(handler)
        if self.wake_subscription:
            self.wake_bus.signal_unsubscribe(self.wake_subscription)

    def check_now(self, trigger):
        if self.app.stopping:
            return
        if trigger != "periodic":
            self.trigger = trigger
        if not self.app.pending["smb-health"]:
            self.schedule_health(2 if trigger in {"wake", "network"} else 1)

    def schedule_health(self, seconds):
        if self.health_timer:
            GLib.source_remove(self.health_timer)
        self.health_timer = GLib.timeout_add_seconds(seconds, self.check_health)

    def check_health(self):
        self.health_timer = 0
        trigger, self.trigger = self.trigger, "periodic"
        if self.app.stack.get_visible_child_name() == "SMB Storage" and (
            trigger != "periodic" or monotonic() >= self.next_inventory
        ):
            self.load()
        bookmarks = [bookmark for bookmark in self.bookmarks if bookmark["protocol"] == "smb"]
        if not bookmarks:
            self.health = {}
            self.schedule_health(90)
            return GLib.SOURCE_REMOVE

        def check():
            return core("smb.health", payload={
                "trigger": trigger, "targets": list(health_targets(bookmarks)), "previous": self.health,
            })

        def done(result):
            self.health = result["states"]
            if self.current is None:
                for bookmark in bookmarks:
                    if label := self.health_labels.get(bookmark["id"]):
                        self.set_health_label(label, bookmark)
            self.schedule_health(result["next_seconds"] if self.trigger == "periodic" else 2)

        self.app.work("smb-health", "Check SMB shares", check, done, quiet=True,
                      on_error=lambda _: self.schedule_health(90 if self.trigger == "periodic" else 2))
        return GLib.SOURCE_REMOVE

    def set_health_label(self, widget, bookmark):
        status = self.health.get(bookmark["id"], {}).get("status")
        title = {
            "connected": "Connected", "server_reachable": "Server reachable",
            "access_denied": "Access denied", "unavailable": "Unavailable",
        }.get(status, "Checking…")
        text = f"{bookmark['host']} · {title}"
        widget.set_label(text)
        widget.set_tooltip_text(text)

    def load(self):
        def inventory():
            try:
                devices = core("smb.devices") or []
            except (OSError, RuntimeError, subprocess.SubprocessError):
                devices = []
            return core("bookmarks.load"), list_private_shares(), devices

        def done(inventory):
            bookmarks_changed = self.bookmarks != inventory[0]
            self.next_inventory = monotonic() + 90
            if (self.bookmarks, self.shared_here, self.tail_devices) != inventory or not self.page.get_first_child():
                self.bookmarks, self.shared_here, self.tail_devices = inventory
                if self.current is None:
                    self.render_bookmarks()
            if bookmarks_changed:
                self.check_now("mount")

        self.app.work("storage", "Read SMB shares", inventory, done, quiet=True,
                      on_error=self.app.announce)

    def render_bookmarks(self):
        self.current = None
        self.path = ""
        clear(self.page)
        self.health_labels.clear()
        self.page.append(row("Shared from this computer", "", button("Share folder…", lambda: self.app.files(
            "Choose a folder to share", Gtk.FileChooserAction.SELECT_FOLDER, lambda paths: self.app.smb_share_folder(paths[0])))))
        for share in self.shared_here:
            self.page.append(row(share["name"], "Read-only", menu([("Stop sharing…", lambda s=share: self.stop_share(s))])))
        if not self.shared_here:
            self.page.append(label("No folders shared from this computer."))
        if self.tail_devices:
            self.page.append(label("Tailscale devices", "heading"))
        for device in self.tail_devices:
            address = device["address"]
            host = f"[{address}]" if ":" in address else address
            browse = button("Browse", lambda h=host: self.app.open_uri(f"smb://{h}/"))
            browse.set_sensitive(device["online"])
            self.page.append(row(device["name"], "Tailscale" if device["online"] else "Offline", browse))
        shares = [bookmark for bookmark in self.bookmarks if bookmark["protocol"] == "smb"]
        self.page.append(label("Saved SMB shares", "heading"))
        if not shares:
            self.page.append(label("No saved SMB shares."))
        for bookmark in shares:
            choices = [("Connect share…", lambda b=bookmark: self.mount(b)),
                       ("Remove…", lambda b=bookmark: self.remove(b))]
            share_row = row(bookmark["nickname"], bookmark["host"],
                            button("Browse", lambda b=bookmark: self.browse(b, "")), menu(choices))
            detail = share_row.get_first_child().get_last_child()
            self.health_labels[bookmark["id"]] = detail
            self.set_health_label(detail, bookmark)
            self.page.append(share_row)

    def stop_share(self, share):
        name = share["name"]
        self.app.confirm("Stop sharing?", name, "Stop sharing", lambda: self.app.work(
            "storage", "Stop sharing folder", lambda: stop_private_share(name), lambda _: self.load()))

    def mount(self, bookmark):
        if bookmark.get("mount_path"):
            self.browse(bookmark, "")
            return
        try:
            file = smb_file(bookmark)
        except ValueError as error:
            self.app.announce(str(error))
            return
        def mounted(file, result):
            try:
                file.mount_enclosing_volume_finish(result)
            except GLib.Error as error:
                if not error.matches(Gio.io_error_quark(), Gio.IOErrorEnum.ALREADY_MOUNTED):
                    self.app.announce(error.message)
                    return
            self.browse(bookmark, "")
        try:
            file.mount_enclosing_volume(Gio.MountMountFlags.NONE, Gtk.MountOperation.new(self.app.window),
                                        None, mounted)
        except GLib.Error as error:
            self.app.announce(error.message)

    def edit(self, bookmark=None):
        original = bookmark or {}
        protocols = ["local", "smb", "sftp", "webdav", "s3"]
        protocol = Gtk.DropDown.new_from_strings(["Local folder", "SMB", "SFTP", "WebDAV", "S3"])
        protocol.set_selected(protocols.index(original.get("protocol", "local")))
        fields = {}
        caption = {
            "nickname": "Name", "host": "Server or local folder", "path": "Share or base path",
            "mount_path": "Existing CIFS mount path (optional)",
            "port": "Port (optional)", "username": "Username or S3 access key", "password": "Password or S3 secret key",
            "private_key": "SFTP private key path (optional)", "passphrase": "Private key passphrase (optional)",
            "session_token": "S3 session token (optional)", "bucket": "S3 bucket", "region": "S3 region",
        }
        form = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        form.append(protocol)
        for name, title in caption.items():
            value = original.get(name) or original.get("options", {}).get(name) or ""
            secret = name in ("password", "passphrase", "session_token")
            entry = Gtk.PasswordEntry(show_peek_icon=True) if secret else Gtk.Entry(text=str(value))
            entry.set_property("placeholder-text", title)
            fields[name] = entry
            form.append(entry)

        def show_fields(*_):
            value = protocols[protocol.get_selected()]
            visible = {"nickname", "host", "path"}
            if value == "smb":
                visible.add("mount_path")
            if value not in ("local", "smb"):
                visible.update({"port", "username", "password"})
            if value == "sftp":
                visible.update({"private_key", "passphrase"})
            if value == "s3":
                visible.update({"session_token", "bucket", "region"})
            for name, field in fields.items():
                field.set_visible(name in visible)
        protocol.connect("notify::selected", show_fields)
        show_fields()

        def save():
            value = {name: field.get_text() for name, field in fields.items()}
            server = value["host"].strip()
            name = value["nickname"].strip()
            selected = protocols[protocol.get_selected()]
            if not name or not server:
                raise ValueError("Enter a connection name and server or folder.")
            if selected == "local" and not Path(server).expanduser().is_absolute():
                raise ValueError("Enter an absolute local folder path.")
            if selected == "local":
                server = str(Path(server).expanduser())
            port = int(value["port"] or 0)
            if not 0 <= port <= 65535:
                raise ValueError("Enter a port between 1 and 65535.")
            item = {"id": original.get("id", str(uuid4())), "nickname": name, "host": server,
                    "path": value["path"], "port": port, "username": value["username"],
                    "protocol": selected, "options": {k: value[k] for k in ("bucket", "region") if value[k]}}
            if selected == "smb":
                smb_file(item)
                if value["mount_path"].strip():
                    item["mount_path"] = str(Path(value["mount_path"].strip()).expanduser())
            secrets = {key: value[key] for key in ("password", "private_key", "passphrase", "session_token")}
            def persist():
                if selected not in ("local", "smb"):
                    save_credentials(item, secrets)
                saved = core("bookmarks.load")
                updated = [entry for entry in saved if entry["id"] != item["id"]] + [item]
                core("bookmarks.save", bookmarks=updated)
                return updated
            self.app.work("storage", "Save connection", persist, self.replace)
        self.app.dialog("Edit connection" if bookmark else "Add connection", "Save",
                        [self.app.scrolled_list(form, height=265)], save)

    def replace(self, items):
        self.bookmarks = items
        self.render_bookmarks()
        self.check_now("mount")

    def remove(self, bookmark):
        def remove():
            remaining = [item for item in core("bookmarks.load") if item["id"] != bookmark["id"]]
            core("bookmarks.save", bookmarks=remaining)
            return remaining
        self.app.confirm("Remove connection?", "Files on the server and local files stay in place.", "Remove",
                         lambda: self.app.work("storage", "Remove connection", remove, self.replace))

    def list(self, bookmark, path):
        if bookmark["protocol"] != "smb" or bookmark.get("mount_path"):
            return self.request(bookmark, "list", path)
        folder = smb_file(bookmark, path)
        children = folder.enumerate_children("standard::name,standard::type,standard::size",
                                             Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, None)
        items = []
        try:
            while info := children.next_file(None):
                name = info.get_name()
                items.append({"name": name, "path": f"{path}/{name}".lstrip("/"),
                              "is_dir": info.get_file_type() == Gio.FileType.DIRECTORY, "size": info.get_size()})
        finally:
            children.close(None)
        return sorted(items, key=lambda item: (not item["is_dir"], item["name"].casefold()))

    def request(self, bookmark, action, path, **payload):
        if bookmark["protocol"] != "smb":
            return core(action, bookmark=bookmark, credentials=credentials(bookmark), path=path, **payload)
        if mount := bookmark.get("mount_path"):
            mounted = subprocess.run(
                ["findmnt", "--noheadings", "--output", "FSTYPE,SOURCE", "--target", mount],
                capture_output=True, text=True, timeout=10,
            )
            parts = mounted.stdout.strip().split(maxsplit=1)
            expected = f"//{bookmark['host']}/{bookmark['path'].strip('/')}"
            if (not Path(mount).is_absolute() or mounted.returncode or len(parts) != 2
                    or parts[0] not in {"cifs", "smb3"} or parts[1].casefold() != expected.casefold()):
                raise RuntimeError("Mount the configured SMB share at this CIFS path before using it.")
            return core(action, bookmark=bookmark, path=path, **payload)
        file = smb_file(bookmark, path)
        if action == "download":
            file.copy(Gio.File.new_for_path(payload["local_path"]), Gio.FileCopyFlags.NONE, None, None)
        elif action == "upload":
            Gio.File.new_for_path(payload["local_path"]).copy(file, Gio.FileCopyFlags.NONE, None, None)
        elif action == "mkdir":
            file.make_directory(None)
        elif action == "rename":
            file.move(smb_file(bookmark, payload["destination"]), Gio.FileCopyFlags.NONE, None, None)
        elif action == "delete":
            file.delete(None)

    def browse(self, bookmark, path):
        self.current, self.path = bookmark, path
        clear(self.page)
        back = lambda: self.browse(bookmark, path.rpartition("/")[0]) if path else self.render_bookmarks()
        actions = [("New folder…", lambda: self.app.entry("New folder", "",
                    lambda name: self.change(bookmark, "mkdir", self.child(path, name)))),
                   ("Upload…", lambda: self.app.files("Upload a file", Gtk.FileChooserAction.OPEN,
                    lambda files: self.change(bookmark, "upload", self.child(path, Path(files[0]).name), local_path=files[0])))]
        if bookmark["protocol"] == "smb":
            actions.append(("Connect share…", lambda: self.mount(bookmark)))
        self.page.append(row(path or bookmark["nickname"], "", button("Back", back), menu(actions)))
        def loaded(items):
            if self.current != bookmark or self.path != path:
                return
            for item in items:
                self.page.append(self.file_row(bookmark, path, item))
            if not items:
                self.page.append(label("This folder is empty."))
        self.app.work("storage", "Browse storage", lambda: self.list(bookmark, path), loaded)

    @staticmethod
    def child(base, name):
        return f"{base}/{single_name(name)}".lstrip("/")

    def change(self, bookmark, action, path, **payload):
        active = self.path
        self.app.work("storage", action.capitalize(), lambda: self.request(bookmark, action, path, **payload),
                      lambda _: self.browse(bookmark, active) if self.current == bookmark and self.path == active else None)

    def file_row(self, bookmark, path, item):
        name, location = item["name"], item["path"]
        if item["is_dir"]:
            open_item = lambda: self.browse(bookmark, location)
        elif bookmark["protocol"] == "local":
            open_item = lambda: self.app.open_path(Path(bookmark["host"]) / bookmark["path"].lstrip("/") / location)
        elif bookmark["protocol"] == "smb":
            open_item = lambda: self.app.open_uri(smb_file(bookmark, location).get_uri())
        else:
            open_item = lambda: self.download(bookmark, item, open_after=True)
        choices = [("Rename…", lambda: self.app.entry("Rename", name,
                    lambda value: self.change(bookmark, "rename", location, destination=self.child(path, value)))),
                   ("Delete…", lambda: self.app.confirm("Delete this item?", name, "Delete",
                    lambda: self.change(bookmark, "delete", location, is_dir=item["is_dir"])))]
        if not item["is_dir"]:
            choices.insert(0, ("Download…", lambda: self.download(bookmark, item)))
        detail = "Folder" if item["is_dir"] else GLib.format_size(item.get("size", 0))
        return row(name, detail, button("Open", open_item), menu(choices))

    def download(self, bookmark, item, open_after=False):
        def run(path):
            self.app.work("storage", "Download file", lambda: self.request(bookmark, "download", item["path"], local_path=path),
                          lambda _: self.app.open_path(path) if open_after else None)
        if open_after:
            DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
            folder = Path(tempfile.mkdtemp(prefix="opened-", dir=DATA))
            run(str(folder / single_name(item["name"])))
        else:
            self.app.files("Download file", Gtk.FileChooserAction.SAVE, lambda files: run(files[0]), suggested_name=item["name"])
