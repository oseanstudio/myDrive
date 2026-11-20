"""Storage bookmarks and the native GNOME virtual file system SMB adapter."""

import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote, urlsplit
from uuid import uuid4

from gi.repository import Gio, GLib, Gtk

from services import DATA, core, credentials, save_credentials
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


class StorageView:
    def __init__(self, app, page):
        self.app = app
        self.page = page
        self.bookmarks = []
        self.current = None
        self.path = ""

    def load(self):
        def done(items):
            self.bookmarks = items
            self.render_bookmarks()
        self.app.work("storage", "Read storage connections", lambda: core("bookmarks.load"), done, quiet=True,
                      on_error=self.app.announce)

    def render_bookmarks(self):
        self.current = None
        self.path = ""
        clear(self.page)
        self.page.append(row("SMB Storage", "", button("Add connection…", self.edit)))
        if not self.bookmarks:
            self.page.append(label("No saved storage connections."))
        for bookmark in self.bookmarks:
            choices = [("Edit…", lambda b=bookmark: self.edit(b)),
                       ("Remove…", lambda b=bookmark: self.remove(b))]
            if bookmark["protocol"] == "smb":
                choices.insert(0, ("Connect share…", lambda b=bookmark: self.mount(b)))
            self.page.append(row(bookmark["nickname"], bookmark["host"],
                                 button("Browse", lambda b=bookmark: self.browse(b, "")), menu(choices)))

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
