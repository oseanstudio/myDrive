"""Blip recipient selection, receive actions and durable relay for GTK."""

import hashlib
import os
import tempfile
from collections import defaultdict
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
        self.relay_queued = []
        self.next_relay_discovery = 0
        self.next_poll = 0
        self.delivery = None
        self.error = ""
        self.connecting_to_send = False
        self.cancelling_sends = set()
        self.next_name_publish = 0
        self.recipient_owner = ""
        self.recent_recipients = []
        self.archives_expanded = False
        self.directory_recipients = []
        self.searched_query = ""
        self.search_status = ""
        self.searching = False
        self.recipient_entry = Gtk.Entry(placeholder_text="Find people & devices", max_length=254, hexpand=True)
        self.recipient_entry.set_tooltip_text("Find people & devices")
        self.recipient_entry.connect("changed", lambda *_: self.render_recipient_rows())
        self.recipient_entry.connect("activate", lambda *_: self.search_recipients())
        self.recipient_rows = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.downloads = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD) or str(Path.home() / "Downloads")
        self.render()

    @staticmethod
    def owner(snapshot):
        status = snapshot.get("status", {})
        peer = f"{status.get('user_id', '')}:{status.get('device_id', '')}"
        return peer.lower() if status.get("authenticated") and exact_peer(peer) else ""

    @staticmethod
    def fallback_name(peer, kind="Device"):
        if kind not in {"Desktop", "Laptop", "Phone", "Tablet"}:
            kind = "Device"
        return f"{kind} {peer[-6:].upper()}" if exact_peer(peer) else "Previous device"

    def base_device_name(self, device, catalog):
        peer = device["peer"].lower()
        recent = {}
        if self.recipient_owner == self.owner(self.snapshot):
            recent = next((r for r in self.recent_recipients if r["peer"] == peer), {})
        kind = device.get("kind")
        kind = kind if kind in {"Desktop", "Laptop", "Phone", "Tablet"} else "Device"
        saved = recent.get("device")
        if saved == self.fallback_name(peer, kind):
            saved = None
        return (recent.get("nickname") or catalog.get(peer, {}).get("name")
                or (device.get("name") if device.get("name_known") else None)
                or saved or kind)

    def device_name(self, device, catalog):
        name = self.base_device_name(device, catalog)
        peer = device["peer"].lower()
        account = peer.partition(":")[0] + ":"
        devices = self.snapshot.get("devices", []) + self.directory_recipients
        duplicate = any(other["peer"].lower() != peer and other["peer"].lower().startswith(account)
                        and not other.get("history")
                        and self.base_device_name(other, catalog).casefold() == name.casefold()
                        for other in devices if exact_peer(other.get("peer")))
        return name + " " + peer[-6:].upper() if duplicate else name

    def person_name(self, device):
        prefix = device["peer"].lower().partition(":")[0] + ":"
        saved = [entry for entry in self.recent_recipients if entry["peer"].startswith(prefix)]
        known = [other for other in self.snapshot.get("devices", []) + self.directory_recipients
                 if str(other.get("peer", "")).lower().startswith(prefix)]
        candidates = ([entry.get("person_nickname") for entry in saved] + [device.get("user_name")]
                      + [other.get("user_name") for other in known] + [entry.get("person") for entry in saved]
                      + [device.get("contact")] + [other.get("contact") for other in known])
        return next((name for name in candidates if name), "")

    def recipient_name(self, device, catalog, show_device=False):
        peer = device["peer"].lower()
        device_name = self.device_name(device, catalog)
        owner = self.owner(self.snapshot).partition(":")[0]
        prefix = peer.partition(":")[0] + ":"
        if owner and prefix == owner + ":":
            return device_name
        person = self.person_name(device)
        if not person:
            return device_name
        nickname = catalog.get(peer, {}).get("name") or next(
            (entry.get("nickname") for entry in self.recent_recipients if entry["peer"] == peer), None)
        other_device = any(other["peer"].lower() != peer and other["peer"].lower().startswith(prefix)
                           and not other.get("history") and not self.is_archived(other["peer"].lower())
                           for other in self.snapshot.get("devices", []) + self.directory_recipients
                           if exact_peer(other.get("peer")))
        return (person + " · " + device_name
                if (show_device or nickname or other_device) and person.casefold() != device_name.casefold() else person)

    def names(self, devices, catalog, show_device=False):
        names = {}
        for device in devices:
            peer = device.get("peer")
            if not exact_peer(peer):
                continue
            peer = peer.lower()
            names[peer] = self.recipient_name(device, catalog, show_device)
        return dict(sorted(names.items(), key=lambda item: (item[1].casefold(), item[0])))

    def peer_captions(self):
        owner = self.owner(self.snapshot)
        recents = [{"peer": item["peer"], "user_name": item.get("person")}
                   for item in self.recent_recipients] if owner == self.recipient_owner else []
        return self.names(recents + self.directory_recipients + self.snapshot.get("devices", []), self.catalog(owner))

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
                self.next_name_publish = 0
                self.history = {str(UUID(t["transfer_id"])) for t in incoming if completed(t)}
                self.notice_states = {}
                self.relay_states = ()
                self.relay_waiting = 0
                self.relay_queued = []
                self.next_relay_discovery = 0
            named = snapshot.get("status", {}).get("current_device_named")
            if not self.app.fixture and named is not True and monotonic() >= self.next_name_publish:
                self.next_name_publish = monotonic() + 300
                try:
                    self.blip.request("publish-name", identity)
                    if named is None:
                        self.next_name_publish = float("inf")
                except (OSError, RuntimeError):
                    pass
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
                self.relay_queued = command.get("queued", [])
                relay = command.get("command") or {}
            snapshot["relays"] = self.relay_waiting
            snapshot["queued"] = self.relay_queued
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
        focused = self.recipient_entry.is_focus()
        if self.recipient_entry.get_parent() is not None:
            self.recipient_entry.get_parent().remove(self.recipient_entry)
        if self.recipient_rows.get_parent() is self.page:
            self.page.remove(self.recipient_rows)
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
        names = self.names(self.snapshot.get("devices", []), self.catalog(identity))
        for transfer in self.snapshot.get("transfers", []):
            if (transfer.get("direction") == "Outgoing" and not transfer.get("dismissed")
                    and not transfer.get("completed") and not packet(transfer) and transfer.get("status") in self.LIVE):
                identifier = transfer["transfer_id"]
                waiting = identifier in self.cancelling_sends
                stop = button("Cancelling…" if waiting else "Cancel", lambda t=transfer: self.cancel_send(t))
                stop.set_sensitive(not waiting and bool(identity))
                title = next(iter(transfer.get("item_names", [])), "Outgoing transfer")
                stop.set_tooltip_text("Cancel send of " + title)
                peer = transfer.get("peer", "").lower()
                self.page.append(row(title, f"{names.get(peer, self.fallback_name(peer))} · {transfer['status']}", stop))
        if identity:
            for item in self.snapshot.get("queued", []):
                waiting = item["id"] in self.cancelling_sends
                stop = button("Cancelling…" if waiting else "Cancel", lambda q=item: self.cancel_send(q, relay=True))
                stop.set_sensitive(not waiting)
                peer = item["peer"].lower()
                self.page.append(row(item["label"], f"{names.get(peer, self.fallback_name(peer))} · Queued for relay", stop))
        if self.recipient_owner != identity:
            self.recipient_owner = identity
            self.archives_expanded = False
            self.recent_recipients = []
            self.directory_recipients = []
            self.searched_query = self.search_status = ""
            self.recipient_entry.set_text("")
            if identity and not self.app.fixture:
                self.update_recents("list", identity)
        search = Gtk.Box(spacing=4)
        search.append(self.recipient_entry)
        find = Gtk.Button(icon_name="system-search-symbolic", tooltip_text="Search Blip for a person")
        find.connect("clicked", lambda *_: self.search_recipients())
        search.append(find)
        search.set_sensitive(bool(identity))
        self.page.append(search)
        self.page.append(self.recipient_rows)
        self.render_recipient_rows()
        if focused and identity:
            self.recipient_entry.grab_focus()
        if waiting := self.snapshot.get("relays"):
            self.page.append(label(f"{waiting} waiting for relay or delivery"))
        for transfer in self.snapshot.get("transfers", []):
            if (transfer.get("direction") != "Incoming" or transfer.get("dismissed") or packet(transfer)
                    or transfer.get("status") not in self.LIVE):
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

    def update_recents(self, action, identity, peer=None, title=None, target=None, name=None):
        if not identity or self.app.fixture:
            return
        names = self.recipients()
        transfers = sorted(self.snapshot.get("transfers", []), key=lambda t: t.get("updated_at", 0), reverse=True)
        prior = dict.fromkeys(t["peer"].lower() for t in transfers
                              if t.get("direction") == "Outgoing" and t.get("completed") and not t.get("has_error")
                              and not packet(t) and str(t.get("peer", "")).lower() in names)
        details = self.recent_details(identity)
        def saved(key, display):
            person, device = details.get(key, ("", ""))
            return {"peer": key, "label": display, "person": person, "device": device}
        seed = [saved(key, names[key]) for key in list(prior)[:24]]
        payload = {"owner": identity, "seed": seed, "recipient": saved(peer, title), "target": target, "name": name}
        def loaded(result):
            if identity == self.recipient_owner:
                self.recent_recipients = result
                self.render_recipient_rows()
        self.app.work("blip-recipients", "", lambda: core("blip.recents." + action, payload=payload),
                      loaded, quiet=True, queue=True, on_error=self.app.announce)

    def search_recipients(self):
        term = self.recipient_entry.get_text().strip()
        owner = self.owner(self.snapshot)
        if not owner or not term or self.searching:
            return
        self.searching = True
        self.searched_query = term
        self.directory_recipients = []
        self.search_status = "Searching Blip…"
        self.render_recipient_rows()
        def finish(devices, status):
            self.searching = False
            if owner == self.recipient_owner:
                self.directory_recipients = devices
                self.search_status = status
                self.render_recipient_rows()
        self.app.work("blip-recipients", "", lambda: self.blip.request("search", term),
                      lambda result: finish(result.get("devices", []), ""), quiet=True, queue=True,
                      on_error=lambda error: finish([], error))

    def render_recipient_rows(self):
        clear(self.recipient_rows)
        owner = self.recipient_owner
        if not owner:
            return
        known = self.visible_recipients()
        query = self.recipient_entry.get_text().strip()
        if query:
            term = query.casefold()
            matched = {peer: name for peer, name in known.items() if term in name.casefold()}
            for device in self.snapshot.get("devices", []):
                peer = str(device.get("peer", "")).lower()
                if peer in known and any(term in str(device.get(field) or "").casefold()
                                         for field in ("contact", "user_name", "name")):
                    matched[peer] = known[peer]
            searched = query == self.searched_query
            if searched:
                for peer, name in self.names(self.directory_recipients, self.catalog(owner)).items():
                    if peer != owner and not self.is_archived(peer):
                        matched.setdefault(peer, name)
            for peer, name in sorted(matched.items(), key=lambda item: item[1].casefold())[:30]:
                self.add_recipient_row(owner, name, peer)
            if searched and self.search_status:
                self.recipient_rows.append(label(self.search_status))
            elif not matched:
                self.recipient_rows.append(label("No matching Blip devices." if searched else "Press Enter to search Blip."))
            return
        details = self.recent_details(owner)
        catalog = self.catalog(owner)
        account_prefix = owner.partition(":")[0] + ":"
        my_devices = {peer for peer in known if peer.startswith(account_prefix)}
        aliases = {entry["peer"]: entry.get("nickname") for entry in self.recent_recipients}
        if my_devices:
            self.recipient_rows.append(label("My devices", "heading"))
            for peer, name in known.items():
                if peer in my_devices:
                    nickname = aliases.get(peer)
                    self.add_recipient_row(owner, name, peer, nickname=nickname, device_shortcut=True)
        recents = [entry for entry in self.recent_recipients
                   if not entry.get("archived") and entry["peer"] not in my_devices]
        if recents:
            self.recipient_rows.append(label("Recent recipients", "heading"))
        groups = defaultdict(list)
        for entry in recents:
            groups[entry["peer"].partition(":")[0]].append(entry)
        for account, entries in groups.items():
            first = entries[0]
            grouped = len(entries) > 1
            own = owner.startswith(account + ":")
            live_person = next((details[entry["peer"]][0] for entry in entries
                                if details.get(entry["peer"], ("", ""))[0]), "")
            alias = first.get("person_nickname")
            person = alias or ("Your devices" if own else live_person) or first.get("person") or self.recent_fallback(first)
            if grouped:
                self.add_recipient_row(owner, person, remove=account, nickname=alias, person=True)
            for entry in entries:
                peer = entry["peer"]
                device_name = details.get(peer, ("", ""))[1] or self.device_name({"peer": peer}, catalog)
                name = device_name if grouped else known.get(peer) or self.recipient_name({"peer": peer}, catalog)
                self.add_recipient_row(owner, name, peer if peer in known else None, peer,
                                       nickname=entry.get("nickname"), nested=grouped)
        listed = my_devices | {entry["peer"] for entry in recents}
        others = [(peer, name) for peer, name in known.items() if peer not in listed]
        if others:
            self.recipient_rows.append(label("Other devices", "heading"))
        for peer, name in others:
            self.add_recipient_row(owner, name, peer, remove=peer)
        archived = [entry for entry in self.recent_recipients if entry.get("archived")]
        if archived:
            entries = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            captions = self.peer_captions()
            for entry in archived:
                peer = entry["peer"]
                name = captions.get(peer, entry["label"])
                actions = Gtk.Box(spacing=4)
                name_label = label(name)
                name_label.set_hexpand(True)
                actions.append(name_label)
                restore = button("Restore", lambda peer=peer: self.update_recents("restore", owner, target=peer))
                restore.set_tooltip_text("Restore " + name)
                actions.append(restore)
                entries.append(actions)
            section = Gtk.Expander(label="Archived", expanded=self.archives_expanded, child=entries)
            section.connect("notify::expanded", lambda current, _: setattr(self, "archives_expanded", current.get_expanded()))
            self.recipient_rows.append(section)

    def recent_details(self, owner):
        catalog = self.catalog(owner)
        rows = self.snapshot.get("devices", []) + self.directory_recipients
        result = {}
        for device in rows:
            peer = str(device.get("peer", "")).lower()
            if not exact_peer(peer):
                continue
            person = device.get("user_name") or device.get("contact") or ""
            result[peer] = person, self.device_name(device, catalog)
        return result

    @staticmethod
    def recent_fallback(entry):
        def is_type(value):
            kind, _, suffix = value.partition(" ")
            return kind in {"Desktop", "Laptop", "Tablet", "Phone"} and (not suffix or suffix.isdecimal())
        name, separator, kind = entry["label"].partition(" · ")
        if separator and is_type(kind):
            return name
        return "Device" if is_type(entry["label"]) else entry["label"]

    def rename_recent(self, owner, target, displayed, nickname, person):
        if self.owner(self.snapshot) != owner:
            return
        if not person:
            self.rename_device(owner, target, displayed, None, lambda _: None)
            return
        name = Gtk.Entry(text=nickname or "", placeholder_text=displayed, max_length=80, activates_default=True)
        self.app.dialog("Person name" if person else "Device name", "Save", [name],
                        lambda: self.update_recents("rename", owner, target=target, name=name.get_text()))

    def add_recipient_row(self, owner, name, peer=None, remove=None, nickname=None, person=False, nested=False,
                          device_shortcut=False):
        controls = Gtk.Box(spacing=4, margin_start=12 if nested else 0)
        if peer:
            select = button(name, lambda: self.choose_files(peer=peer, owner=owner))
            select.set_child(label(name))
            select.set_tooltip_text("Send files to " + name)
            select.set_hexpand(True)
            controls.append(select)
            actions = [("Send folder…", lambda: self.choose_files(folder=True, peer=peer, owner=owner))]
            if not (remove or device_shortcut):
                actions.append(("Paste and send", lambda: self.paste(peer, owner)))
            controls.append(menu(actions))
        else:
            name_label = label(name, "heading" if person else None)
            name_label.set_hexpand(True)
            controls.append(name_label)
        if peer and (remove or device_shortcut):
            paste = Gtk.Button(icon_name="edit-paste-symbolic", tooltip_text="Paste and send to " + name)
            paste.connect("clicked", lambda *_: self.paste(peer, owner))
            controls.append(paste)
        if device_shortcut:
            def rename():
                if nickname:
                    self.rename_recent(owner, peer, name, nickname, False)
                else:
                    self.rename_device(owner, peer, name, None, lambda _: None)
            controls.append(self.rename_button(name, rename))
        if remove:
            controls.append(self.rename_button(name, lambda: self.rename_recent(owner, remove, name, nickname, person)))
            cross = Gtk.Button(icon_name="window-close-symbolic", tooltip_text="Archive " + name)
            cross.connect("clicked", lambda *_: self.update_recents("archive", owner, peer=peer, title=name, target=remove))
            controls.append(cross)
        self.recipient_rows.append(controls)

    def accept(self, transfer):
        self.app.work("blip", "Receive transfer", lambda: self.blip.request("accept", transfer["transfer_id"]),
                      lambda _: self.refresh())

    def cancel_send(self, transfer, relay=False):
        owner = self.owner(self.snapshot)
        identifier = transfer["id" if relay else "transfer_id"]
        if not owner or identifier in self.cancelling_sends:
            return
        self.cancelling_sends.add(identifier)
        self.render()
        def refresh():
            self.cancelling_sends.discard(identifier)
            self.render()
            self.refresh(quiet=False)
        def cancel():
            if relay:
                result = core("relay.cancel", payload={"self": owner, "id": identifier})
                self.next_relay_discovery = 0
                return result
            return self.blip.request("cancel", owner, identifier)
        self.app.work("blip", "Cancel send", cancel,
                      lambda _: refresh(), on_error=lambda _: refresh())

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

    def choose_recipient(self, devices, selected, cancelled=lambda: None):
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
        content.set_spacing(4)
        content.append(self.app.scrolled_list(box, height=min(len(entries), 6) * 36 + 2))
        finished = False

        def activate(peer, paste=False):
            nonlocal finished
            if finished:
                return
            finished = True
            dialog.close()
            if paste:
                cancelled()
                self.paste(peer, owner)
            else:
                selected(peer)

        def close(_):
            nonlocal finished
            if not finished:
                finished = True
                cancelled()
            return False

        owner = self.owner(self.snapshot)
        for peer, name in entries:
            controls = Gtk.Box(spacing=4, margin_top=1, margin_bottom=1)
            send = button(name, lambda peer=peer: activate(peer))
            send.set_child(label(name))
            send.set_hexpand(True)
            paste = Gtk.Button(icon_name="edit-paste-symbolic", tooltip_text="Paste and send to " + name)
            paste.connect("clicked", lambda _, peer=peer: activate(peer, paste=True))
            def update_name(updated, send=send, paste=paste):
                send.set_child(label(updated))
                paste.set_tooltip_text("Paste and send to " + updated)
            edit = self.rename_button(name, lambda peer=peer, name=name, updated=update_name: self.rename_device(
                owner, peer, name, dialog, updated))
            controls.append(send)
            controls.append(paste)
            controls.append(edit)
            item = Gtk.ListBoxRow(activatable=False, selectable=False, child=controls)
            box.append(item)
        dialog.connect("close-request", close)
        dialog.connect("response", lambda dialog, _: dialog.close())
        self.app.present_dialog(dialog)
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
        recent = next((r for r in self.recent_recipients if r["peer"] == peer), None)
        name = Gtk.Entry(text=(recent or {}).get("nickname") or previous.get("name", ""),
                         placeholder_text=label_text, max_length=80)
        def save():
            if self.owner(self.snapshot) != owner:
                return
            all_rules = read_settings("blip-permissions.json", {})
            device_rules = all_rules.setdefault(account, {}).setdefault(peer, {})
            nickname = "".join(c for c in name.get_text().strip() if c.isprintable())[:80]
            device_rules["name"] = nickname
            save_settings("blip-permissions.json", all_rules)
            self.update_recent_nickname(owner, peer, nickname)
            names = self.names(self.snapshot.get("devices", []), all_rules[account])
            updated(names.get(peer, nickname or label_text))
            self.render()
        self.app.dialog("Device name", "Save", [name], save, parent=parent)

    def update_recent_nickname(self, owner, peer, nickname):
        recent = next((r for r in self.recent_recipients if r["peer"] == peer), None)
        if recent is not None:
            recent["nickname"] = nickname
            self.update_recents("rename", owner, target=peer, name=nickname)

    def recipients(self):
        identity = self.owner(self.snapshot)
        if not identity or self.error:
            return {}
        devices = [d for d in self.snapshot.get("devices", [])
                   if not d.get("history") and str(d.get("peer", "")).lower() != identity]
        return self.names(devices, self.catalog(identity))

    def is_archived(self, peer):
        return any(entry.get("archived") and entry["peer"] == peer for entry in self.recent_recipients)

    def visible_recipients(self):
        return {peer: name for peer, name in self.recipients().items() if not self.is_archived(peer)}

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

    def choose_files(self, folder=False, peer=None, owner=None):
        action = Gtk.FileChooserAction.SELECT_FOLDER if folder else Gtk.FileChooserAction.OPEN
        def picked(peer):
            expected_owner = owner or self.owner(self.snapshot)
            self.app.files("Choose a folder" if folder else "Choose files", action,
                           lambda paths: self.send(peer, paths, expected_owner), multiple=not folder)
        if peer is not None:
            if owner == self.owner(self.snapshot):
                picked(peer)
        else:
            self.with_send_connection(lambda: self.choose_recipient(self.visible_recipients(), picked))

    def send_dropped(self, paths, cancelled=lambda: None):
        self.with_send_connection(
            lambda: self.choose_recipient(
                self.visible_recipients(), lambda peer: self.send(peer, paths), cancelled
            ),
            cancelled,
        )

    def send(self, peer, paths, expected_owner=None, cancelled=lambda: None):
        sender = self.owner(self.snapshot)
        current = {**self.names(self.directory_recipients, self.catalog(sender)), **self.recipients()}
        if not sender or (expected_owner is not None and sender != expected_owner) or peer not in current:
            cancelled()
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
        def sent(_):
            self.update_recents("remember", sender, peer=peer, title=current[peer])
            self.refresh()
        self.app.work("blip", "Send with Blip", dispatch, sent)

    def paste(self, peer=None, owner=None):
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
            if peer:
                self.send(peer, paths, owner, cleanup)
            else:
                self.send_dropped(paths, cleanup)
        self.app.window.get_clipboard().read_text_async(None, got_text)

    def permissions(self):
        identity = self.owner(self.snapshot)
        if not identity:
            self.app.announce("Connect Blip before choosing sender permissions.")
            return
        names = self.names(self.snapshot.get("devices", []), self.catalog(identity), show_device=True)
        saved = self.catalog(identity)
        group = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        fields = {}
        for peer, title in names.items():
            if peer == identity:
                continue
            previous = saved.get(peer, {})
            recent = next((r for r in self.recent_recipients if r["peer"] == peer), None)
            existing = (recent or {}).get("nickname") or previous.get("name", "")
            name = Gtk.Entry(text=existing, placeholder_text=title, visible=False, max_length=80)
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
            fields[peer] = (name, files, links, existing)
        def save():
            if self.owner(self.snapshot) != identity:
                return
            all_rules = read_settings("blip-permissions.json", {})
            account = identity.partition(":")[0]
            rules = all_rules.setdefault(account, {})
            changed = []
            for peer, (name, files, links, existing) in fields.items():
                text = "".join(c for c in name.get_text().strip() if c.isprintable())[:80]
                rules[peer] = {"name": text, "files": files.get_active(), "links": links.get_active()}
                if text != existing:
                    changed.append((peer, text))
            save_settings("blip-permissions.json", all_rules)
            for peer, name in changed:
                self.update_recent_nickname(identity, peer, name)
            self.render()
        self.app.dialog("Sender permissions", "Save", [self.app.scrolled_list(group, height=260)], save)
