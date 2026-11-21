"""Blip recipient selection, receive actions and durable relay for GTK."""

import hashlib
import os
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from time import monotonic
from urllib.parse import unquote, urlsplit
from uuid import UUID

from gi.repository import Gdk, Gio, GLib, Gtk

from services import DATA, core, exact_peer, link_url, read_settings, save_settings
from ui_widgets import button, clear, label, menu, row


def completed(transfer):
    return transfer.get("direction") == "Incoming" and transfer.get("completed") and not transfer.get("has_error")


def packet(transfer):
    names = transfer.get("item_names", [])
    return len(names) == 1 and names[0].startswith("mydrive-relay-v1.")


def received_path(item):
    location = item.get("path", "")
    try:
        uri = urlsplit(location)
        if uri.scheme and (uri.scheme != "file" or uri.netloc not in ("", "localhost")):
            return None
        path = Path(unquote(uri.path) if uri.scheme else location)
        if not path.is_absolute() or any(p.is_symlink() for p in (path, *path.parents)):
            return None
        return path if (path.is_dir() if item.get("is_directory") else path.is_file()) else None
    except (OSError, ValueError):
        return None


class TransferView:
    LIVE = {"Created", "InviteRequested", "Invited", "Pending", "Active", "Paused", "ResumeRequested"}

    def __init__(self, app, page, blip):
        self.app, self.page, self.blip = app, page, blip
        self.snapshot = {}
        self.identity = ""
        self.history = set()
        self.notice_states = {}
        self.relay_states = ()
        self.relay_waiting = 0
        self.next_relay_discovery = 0
        self.next_poll = 0
        self.delivery = None
        self.error = ""
        self.connecting_to_send = False
        self.downloads = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD) or str(Path.home() / "Downloads")
        self.render()

    @staticmethod
    def owner(snapshot):
        status = snapshot.get("status", {})
        peer = f"{status.get('user_id', '')}:{status.get('device_id', '')}"
        return peer.lower() if status.get("authenticated") and exact_peer(peer) else ""

    @staticmethod
    def names(devices, catalog):
        raw = {}
        for device in devices:
            peer = device.get("peer")
            if not exact_peer(peer):
                continue
            peer = peer.lower()
            contact = device.get("user_name") or device.get("contact") or ""
            if nickname := catalog.get(peer, {}).get("name"):
                title = nickname
            elif device.get("name_known"):
                title = device["name"]
            else:
                title = device.get("kind") or "Device"
            raw[peer] = " · ".join(part for part in (contact, title) if part)
        counts, ordinal = Counter(raw.values()), defaultdict(int)
        names = {}
        for peer, title in sorted(raw.items(), key=lambda item: (item[1].casefold(), item[0])):
            ordinal[title] += 1
            names[peer] = title if counts[title] == 1 else f"{title} {ordinal[title]}"
        return names

    def catalog(self, identity):
        return read_settings("blip-permissions.json", {}).get(identity.partition(":")[0], {})

    def refresh(self, quiet=True):
        if quiet and monotonic() < self.next_poll:
            return
        preferences = self.app.preferences.copy()
        def poll():
            snapshot = self.blip.monitor(preferences.get("blip_background", True))
            identity = self.owner(snapshot)
            if not identity:
                self.identity = ""
                return snapshot, [], []
            incoming = [t for t in snapshot.get("transfers", []) if t.get("direction") == "Incoming"]
            baseline = self.identity != identity
            if baseline:
                self.identity = identity
                self.history = {str(UUID(t["transfer_id"])) for t in incoming if completed(t)}
                self.notice_states = {}
                self.relay_states = ()
                self.relay_waiting = 0
                self.next_relay_discovery = 0
            permissions = self.catalog(identity)
            receipts = set(read_settings("blip-receipts.json", []))
            urls, notices = [], []
            account = identity.partition(":")[0]
            transfers = snapshot.get("transfers", [])
            transports = [t for t in transfers if packet(t) and (t.get("peer") or "").lower().startswith(account + ":")]
            states = tuple(sorted((
                t["transfer_id"], t.get("status", ""), bool(t.get("completed")), bool(t.get("has_error"))
            ) for t in transports))
            relay = {}
            if (self.relay_waiting or monotonic() >= self.next_relay_discovery or states != self.relay_states
                    or any(t.get("status") in self.LIVE and not t.get("dismissed") and not t.get("completed")
                           for t in transports)):
                command = core("relay.tick", payload={
                    "self": identity, "inbox": str(self.blip.inbox), "downloads": self.downloads,
                    "devices": snapshot.get("devices", []), "transfers": transfers,
                })
                self.relay_states = states
                self.next_relay_discovery = monotonic() + 30
                self.relay_waiting = command.get("waiting", 0)
                relay = command.get("command") or {}
            snapshot["relays"] = self.relay_waiting
            if relay.get("action") == "send":
                self.blip.send(relay["peer"], relay["paths"], relay["id"])
            elif relay.get("action") == "accept":
                self.blip.request("accept", relay["id"])

            def claim(operation, transfer_id, value=""):
                token = hashlib.sha256(f"{identity}:{operation}:{transfer_id}:{value}".encode()).hexdigest()
                if token in receipts:
                    return False
                receipts.add(token)
                save_settings("blip-receipts.json", sorted(receipts))
                return True

            for transfer in incoming:
                if not exact_peer(transfer.get("peer")) or transfer.get("dismissed"):
                    continue
                transfer_id = str(UUID(transfer["transfer_id"]))
                peer = transfer["peer"].lower()
                permission = permissions.get(peer, {})
                links = preferences.get("blip_open", True) and permission.get("links")
                state = transfer.get("status")
                locations = transfer.get("link_files", [])
                if packet(transfer):
                    if relay.get("action") != "deliver" or relay.get("id") != transfer_id:
                        continue
                    locations = relay["paths"]
                    transfer = {**transfer, "received_items": [
                        {"path": filename, "name": Path(filename).name, "is_directory": Path(filename).is_dir()}
                        for filename in locations]}
                if self.notice_states.get(transfer_id) != state and (
                    state == "Invited" or completed(transfer) and transfer_id not in self.history
                ):
                    notices.append(transfer)
                self.notice_states[transfer_id] = state
                if state == "Invited" and not transfer.get("has_error") and (
                    permission.get("files") or links and transfer.get("link_only")
                ) and claim("accept", transfer_id):
                    self.blip.request("accept", transfer["transfer_id"])
                if completed(transfer) and transfer_id not in self.history and links:
                    for path in locations[:256]:
                        if (url := link_url(path)) and claim("open", transfer_id, url):
                            urls.append(url)
            return snapshot, urls, notices

        def arrived(result):
            snapshot, urls, notices = result
            self.next_poll = 0 if self.owner(snapshot) else monotonic() + 10
            if snapshot != self.snapshot or self.error:
                self.snapshot, self.error = snapshot, ""
                self.render()
            for uri in urls:
                if self.app.preferences.get("blip_open", True):
                    self.app.open_uri(uri)
            for transfer in notices:
                if completed(transfer):
                    self.delivery = transfer
                    self.render()
                notification = Gio.Notification.new("myDrive")
                notification.set_body("File received" if completed(transfer) else "Incoming Blip transfer")
                self.app.send_notification(transfer["transfer_id"], notification)

        def failed(message):
            self.next_poll = monotonic() + 10
            if self.error != message:
                self.error = message
                self.render()
        self.app.work("blip", "Refresh Blip", poll, arrived, quiet=quiet, on_error=failed)

    def render(self):
        clear(self.page)
        identity = self.owner(self.snapshot)
        self.page.append(row("Blip", "Ready" if identity and not self.error else "Connection needed",
                             button("Refresh", lambda: self.refresh(quiet=False))))
        if self.error:
            self.page.append(Gtk.Label(label=self.error, xalign=0, wrap=True, max_width_chars=38))
        if self.error and getattr(self.blip, "arguments", None) is None:
            self.page.append(button("Set up Blip…", self.set_up_blip))
        status = self.snapshot.get("status", {})
        if status and not identity and not status.get("desktop_session"):
            verifying = status.get("registration") == "CODE_SENT"
            self.page.append(button("Enter code…" if verifying else "Sign in to Blip…",
                                    lambda: self.sign_in(verifying)))
        actions = Gtk.Box(spacing=6)
        actions.append(button("Send…", self.choose_files))
        actions.append(button("Paste and send", self.paste))
        actions.append(menu([("Send folder…", lambda: self.choose_files(folder=True)),
                             ("Sender permissions…", self.permissions),
                             ("Received files", lambda: self.app.open_path(self.blip.inbox))]))
        self.page.append(actions)
        if waiting := self.snapshot.get("relays"):
            self.page.append(label(f"{waiting} waiting for relay or delivery"))
        names = self.names(self.snapshot.get("devices", []), self.catalog(identity))
        for transfer in self.snapshot.get("transfers", []):
            if transfer.get("dismissed") or packet(transfer) or transfer.get("status") not in self.LIVE:
                continue
            state = transfer.get("status", "")
            title = names.get(transfer.get("peer", "").lower(), "Previous device")
            if state == "Invited" and transfer.get("direction") == "Incoming" and not transfer.get("has_error"):
                self.page.append(row(title, "Waiting for you", button("Receive", lambda t=transfer: self.accept(t))))
            else:
                self.page.append(row(title, state))
        if self.delivery:
            name = names.get(self.delivery.get("peer", "").lower(), "Previous device")
            self.page.append(row(name, "Received", button("View files", lambda: self.show_received(self.delivery))))

    def accept(self, transfer):
        self.app.work("blip", "Receive transfer", lambda: self.blip.request("accept", transfer["transfer_id"]),
                      lambda _: self.refresh())

    def show_received(self, transfer):
        if not completed(transfer):
            return
        items = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        for item in transfer.get("received_items", []):
            path = received_path(item)
            if path is None:
                items.append(row(item.get("name", "File"), "Unavailable"))
                continue
            if path.is_file() and path.stat().st_size <= 4 * 1024 * 1024:
                if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".gif"}:
                    picture = Gtk.Picture.new_for_filename(str(path))
                    picture.set_size_request(-1, 150)
                    picture.set_can_shrink(True)
                    items.append(picture)
                elif path.suffix.lower() in {".txt", ".log", ".md", ".csv"}:
                    with path.open("rb") as file:
                        preview = file.read(2048).decode(errors="replace")
                    items.append(label("\n".join(preview.splitlines()[:5])))
            actions = menu([("Copy path", lambda p=path: self.app.window.get_clipboard().set_text(str(p))),
                            ("Open folder", lambda p=path: self.app.open_path(p if p.is_dir() else p.parent))])
            items.append(row(item.get("name") or path.name, "", button("Open", lambda p=path: self.app.open_path(p)),
                             button("Copy", lambda p=path: self.copy_path(p)), actions))
        self.app.dialog("Received files", "Done", [self.app.scrolled_list(items, height=270)], lambda: None)

    def copy_path(self, path):
        uri = Gio.File.new_for_path(str(path)).get_uri()
        provider = Gdk.ContentProvider.new_for_bytes("text/uri-list", GLib.Bytes.new((uri + "\r\n").encode()))
        self.app.window.get_clipboard().set_content(provider)

    def choose_recipient(self, devices, selected, cancelled=lambda: None, *, files_ready=False):
        box = Gtk.ListBox()
        box.set_selection_mode(Gtk.SelectionMode.NONE)
        entries = list(devices.items())
        if not entries:
            self.app.announce("No Blip recipient devices are available.")
            cancelled()
            return
        dialog = Gtk.Dialog(title="Send with Blip", transient_for=self.app.window, modal=True)
        dialog.set_default_size(344, -1)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        content = dialog.get_content_area()
        content.set_spacing(6)
        content.append(label("Click a device to send." if files_ready else "Click a device to choose what to send."))
        content.append(self.app.scrolled_list(box))
        finished = False

        def activate(peer):
            nonlocal finished
            if finished:
                return
            finished = True
            dialog.close()
            selected(peer)

        def close(_):
            nonlocal finished
            if not finished:
                finished = True
                cancelled()
            return False

        owner = self.owner(self.snapshot)
        for peer, name in entries:
            controls = Gtk.Box(spacing=4, margin_top=2, margin_bottom=2)
            send = button(name, lambda peer=peer: activate(peer))
            send.set_child(label(name))
            send.set_hexpand(True)
            edit = self.rename_button(name, lambda peer=peer, name=name, send=send: self.rename_device(
                owner, peer, name, dialog, lambda updated: send.set_child(label(updated))))
            controls.append(send)
            controls.append(edit)
            item = Gtk.ListBoxRow(activatable=False, selectable=False, child=controls)
            box.append(item)
        dialog.connect("close-request", close)
        dialog.connect("response", lambda dialog, _: dialog.close())
        dialog.present()
        return box

    @staticmethod
    def rename_button(name, action):
        pencil = Gtk.Button(icon_name="document-edit-symbolic", tooltip_text="Rename " + name)
        pencil.connect("clicked", lambda *_: action())
        return pencil

    def rename_device(self, owner, peer, label_text, parent, updated):
        if not owner or self.owner(self.snapshot) != owner or not exact_peer(peer):
            return
        account = owner.partition(":")[0]
        previous = self.catalog(owner).get(peer, {})
        name = Gtk.Entry(text=previous.get("name", ""), placeholder_text=label_text, max_length=80)
        def save():
            if self.owner(self.snapshot) != owner:
                return
            all_rules = read_settings("blip-permissions.json", {})
            device_rules = all_rules.setdefault(account, {}).setdefault(peer, {})
            nickname = "".join(c for c in name.get_text().strip() if c.isprintable())[:80]
            device_rules["name"] = nickname
            save_settings("blip-permissions.json", all_rules)
            names = self.names(self.snapshot.get("devices", []), all_rules[account])
            updated(names.get(peer, nickname or label_text))
            self.render()
        self.app.dialog("Device name", "Save", [name], save, parent=parent)

    def recipients(self):
        identity = self.owner(self.snapshot)
        if not identity or self.error:
            return {}
        devices = [d for d in self.snapshot.get("devices", [])
                   if not d.get("history") and str(d.get("peer", "")).lower() != identity]
        return self.names(devices, self.catalog(identity))

    def set_up_blip(self):
        def setup():
            return self.blip.monitor(setup=True)

        def done(snapshot):
            self.snapshot, self.error = snapshot, ""
            self.next_poll = 0
            self.render()

        self.app.work("blip", "Set up Blip", setup, done)

    def sign_in(self, verifying):
        entry = Gtk.Entry(placeholder_text="Sign-in code" if verifying else "Email address",
                          visibility=not verifying, activates_default=True)

        def accepted():
            value = entry.get_text().strip()
            def register():
                self.blip.sign_in(value, verifying)
                return self.blip.request("poll")

            def done(snapshot):
                self.snapshot, self.error = snapshot, ""
                self.next_poll = 0
                self.render()

            self.app.work("blip", "Sign in to Blip" if verifying else "Send Blip sign-in code", register, done)

        dialog = self.app.dialog("Sign in to Blip", "Sign in" if verifying else "Send code", [entry], accepted)
        dialog.set_default_response(Gtk.ResponseType.OK)
        entry.grab_focus()

    def with_send_connection(self, ready, cancelled=lambda: None):
        if self.owner(self.snapshot) and not self.error:
            ready()
            return
        if self.connecting_to_send:
            cancelled()
            return
        self.connecting_to_send = True

        def connected(snapshot):
            self.connecting_to_send = False
            self.snapshot, self.error = snapshot, ""
            self.render()
            if self.owner(snapshot):
                def ready_after_status():
                    ready()
                    return GLib.SOURCE_REMOVE
                GLib.idle_add(ready_after_status)
            else:
                cancelled()
                GLib.idle_add(self.app.announce, "Sign in to Blip once to send files.")

        def failed(_message):
            self.connecting_to_send = False
            cancelled()

        background = self.app.preferences.get("blip_background", True)
        self.app.work("blip", "Connect to Blip", lambda: self.blip.monitor(background), connected, on_error=failed)

    def choose_files(self, folder=False):
        action = Gtk.FileChooserAction.SELECT_FOLDER if folder else Gtk.FileChooserAction.OPEN
        def picked(peer):
            self.app.files("Choose a folder" if folder else "Choose files", action,
                           lambda paths: self.send(peer, paths), multiple=not folder)
        self.with_send_connection(lambda: self.choose_recipient(self.recipients(), picked))

    def send_dropped(self, paths, cancelled=lambda: None):
        self.with_send_connection(
            lambda: self.choose_recipient(
                self.recipients(), lambda peer: self.send(peer, paths), cancelled, files_ready=True
            ),
            cancelled,
        )

    def send(self, peer, paths):
        sender = self.owner(self.snapshot)
        if not sender or peer not in self.recipients():
            self.app.announce("Refresh Blip and choose the device again.")
            return
        def dispatch():
            fresh = self.blip.request("poll")
            identity = self.owner(fresh)
            own = identity.partition(":")[0]
            devices = [d for d in fresh.get("devices", []) if not d.get("history")]
            target = next((d for d in devices if d.get("peer", "").lower() == peer), None)
            if identity != sender or not target:
                raise RuntimeError("The selected Blip device is unavailable.")
            if target.get("online") is False and target.get("can_relay") and peer.startswith(own + ":"):
                relays = [d["peer"] for d in devices if d.get("can_relay") and d.get("online") is True
                          and d["peer"].startswith(own + ":") and d["peer"] not in {identity, peer}]
                if relays:
                    result = core("relay.stage", payload={"self": identity, "target": peer, "relay": relays[0],
                                                         "alternatives": relays[1:], "paths": paths})
                    self.next_relay_discovery = 0
                    return result
            return self.blip.send(peer, paths)
        self.app.work("blip", "Send with Blip", dispatch, lambda _: self.refresh())

    def paste(self):
        def got_text(clipboard, result):
            try:
                text = clipboard.read_text_finish(result)
            except GLib.Error:
                text = None
            if not text:
                self.app.announce("Copy text or a web link, then try Paste and send again.")
                return
            if len(text.encode()) > 1024 * 1024:
                self.app.announce("Copy a smaller text selection or send it as a file.")
                return
            staging = DATA / "Blip" / "outbox"
            staging.mkdir(parents=True, mode=0o700, exist_ok=True)
            folder = Path(tempfile.mkdtemp(prefix="clipboard-", dir=staging))
            lines = [line.strip() for line in text.splitlines() if line.strip()]
            paths = []
            if 0 < len(lines) <= 16 and all(urlsplit(line).scheme in ("https", "http") and
                                           not any(c.isspace() or ord(c) < 32 for c in line) for line in lines):
                for index, line in enumerate(lines, 1):
                    path = folder / f"Clipboard link {index}.url"
                    path.write_text(f"[InternetShortcut]\nURL={line}\n", encoding="utf-8")
                    paths.append(str(path))
            else:
                path = folder / "Clipboard text.txt"
                path.write_text(text, encoding="utf-8")
                paths.append(str(path))
            def cleanup():
                for path in paths:
                    Path(path).unlink(missing_ok=True)
                folder.rmdir()
            self.send_dropped(paths, cleanup)
        self.app.window.get_clipboard().read_text_async(None, got_text)

    def permissions(self):
        identity = self.owner(self.snapshot)
        if not identity:
            self.app.announce("Connect Blip before choosing sender permissions.")
            return
        names = self.names(self.snapshot.get("devices", []), self.catalog(identity))
        saved = self.catalog(identity)
        group = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        fields = {}
        for peer, title in names.items():
            if peer == identity:
                continue
            previous = saved.get(peer, {})
            name = Gtk.Entry(text=previous.get("name", ""), placeholder_text=title, visible=False, max_length=80)
            name.set_tooltip_text("Local label for " + title)
            files = Gtk.CheckButton(label="Auto-receive files", active=bool(previous.get("files")))
            links = Gtk.CheckButton(label="Auto-open links", active=bool(previous.get("links")))
            checks = Gtk.Box(spacing=8)
            checks.append(files)
            checks.append(links)
            heading = Gtk.Box(spacing=4)
            heading.append(label(title, "heading"))
            def edit_name(field=name):
                field.set_visible(True)
                field.grab_focus()
            heading.append(self.rename_button(title, edit_name))
            group.append(heading)
            group.append(name)
            group.append(checks)
            fields[peer] = (name, files, links)
        def save():
            all_rules = read_settings("blip-permissions.json", {})
            account = identity.partition(":")[0]
            rules = all_rules.setdefault(account, {})
            for peer, (name, files, links) in fields.items():
                rules[peer] = {"name": name.get_text()[:80].strip(), "files": files.get_active(), "links": links.get_active()}
            save_settings("blip-permissions.json", all_rules)
            self.render()
        self.app.dialog("Sender permissions", "Save", [self.app.scrolled_list(group, height=260)], save)
