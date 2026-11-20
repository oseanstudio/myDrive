#!/usr/bin/env python3
"""Native GTK desktop shell for myDrive on Linux."""

import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk

from services import DATA, ROOT, Blip, Sync, core, read_settings, save_settings
from smb_sharing import add_private_share
from storage_view import StorageView
from tray import Tray
from transfer_view import TransferView
from ui_widgets import button, clear, label, menu, row


APP_ID = "net.oseanstudio.myDrive"
VERSION_FILE = Path(__file__).with_name("version.txt")
VERSION = VERSION_FILE.read_text(encoding="utf-8").strip() if VERSION_FILE.is_file() else "0.4.17"


class MyDrive(Gtk.Application):
    def __init__(self, fixture=False):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE if fixture else 0)
        self.fixture = fixture
        self.sync = Sync()
        self.blip = Blip()
        self.preferences = read_settings("preferences.json", {})
        self.sync.config_path = self.preferences.get("syncthing_config", "")
        self.activity = read_settings("activity.json", [])
        self.snapshot = {}
        self.lanes = {key: ThreadPoolExecutor(max_workers=1) for key in ("sync", "blip", "storage", "updates", "settings")}
        self.pending = {key: 0 for key in self.lanes}
        self.window = None
        self.browse = None
        self.stopping = False
        self.show_update_result = False
        self.available_update = None
        self.read_update_error = True
        self.startup = {"enabled": True, "configured": False}

    def do_activate(self):
        if self.window:
            self.window.present()
            return
        self.window = Gtk.ApplicationWindow(application=self, title="myDrive")
        self.window.set_default_size(344, 420)
        self.window.set_icon_name(APP_ID)
        header = Gtk.HeaderBar()
        self.window.set_titlebar(header)
        self.settings = Gtk.Settings.get_default()
        schema_source = Gio.SettingsSchemaSource.get_default()
        schema = schema_source.lookup("org.gnome.desktop.interface", True) if schema_source else None
        self.desktop_appearance = Gio.Settings.new_full(schema, None, None) if schema and schema.has_key("color-scheme") else None
        if self.desktop_appearance:
            self.desktop_appearance.connect("changed::color-scheme", lambda *_: self.apply_appearance())
        self.apply_appearance()
        titles = ["Sync", "SMB Storage", "Send & Receive", "Activity", "Settings"]
        view = Gtk.DropDown.new_from_strings(titles)
        header_content = Gtk.Box(spacing=7)
        header_content.append(label(f"myDrive {VERSION}", "heading"))
        header_content.append(view)
        header.set_title_widget(header_content)
        header.pack_end(menu([("Sync a folder…", self.share_folder), ("Quit myDrive", self.quit)]))
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        self.window.set_child(content)
        drop = Gtk.DropTarget.new(Gdk.FileList.__gtype__, Gdk.DragAction.COPY)
        drop.connect("drop", self.dropped)
        self.window.add_controller(drop)
        self.status = label("")
        self.status.set_margin_start(8)
        self.status.set_margin_end(8)
        self.status.set_visible(False)
        content.append(self.status)
        self.update_offer = button("", self.install_update)
        self.update_offer.set_halign(Gtk.Align.START)
        self.update_offer.set_margin_start(8)
        self.update_offer.set_visible(False)
        content.append(self.update_offer)
        self.stack = Gtk.Stack(vhomogeneous=False, vexpand=True)
        content.append(self.stack)
        self.pages = {}
        for title in titles:
            page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_bottom=8, margin_start=8, margin_end=8)
            scroll = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, child=page)
            self.pages[title] = page
            self.stack.add_named(scroll, title)
        expand = button("Open full window", self.resize)
        expand.set_halign(Gtk.Align.END)
        expand.set_margin_end(8)
        expand.set_margin_bottom(6)
        content.append(expand)
        self.window.connect("notify::maximized", lambda *_: expand.set_label(
            "Open compact window" if self.window.is_maximized() else "Open full window"))
        def show_view(dropdown, *_):
            title = titles[dropdown.get_selected()]
            self.stack.set_visible_child_name(title)
            if title == "SMB Storage" and not self.fixture:
                self.storage_view.load()
            if title == "Settings" and not self.fixture:
                self.change_startup("startup.status")
        view.connect("notify::selected", show_view)
        self.storage_view = StorageView(self, self.pages["SMB Storage"])
        self.transfer_view = TransferView(self, self.pages["Send & Receive"], self.blip)
        self.render_activity()
        self.render_settings()
        self.window.present()
        if self.fixture:
            self.run_fixture()
            return
        self.tray = Tray(self.window, ROOT / f"{APP_ID}.png")
        self.refresh_sync()
        self.storage_view.load()
        self.transfer_view.refresh()
        self.tick_updates()
        GLib.timeout_add_seconds(6 * 60 * 60, self.tick_updates)
        GLib.timeout_add_seconds(8, self.tick_sync)
        GLib.timeout_add_seconds(2, self.tick_blip)
        GLib.timeout_add_seconds(15, self.tick_storage)

    def do_shutdown(self):
        self.stopping = True
        self.lanes["blip"].submit(self.blip.stop)
        for worker in self.lanes.values():
            worker.shutdown(wait=False)
        Gtk.Application.do_shutdown(self)

    def tick_sync(self):
        if not self.browse:
            self.refresh_sync(quiet=True)
        return not self.stopping

    def tick_blip(self):
        self.transfer_view.refresh(quiet=True)
        return not self.stopping

    def tick_storage(self):
        if self.stack.get_visible_child_name() == "SMB Storage" and self.storage_view.current is None:
            self.storage_view.load()
        return not self.stopping

    def tick_updates(self):
        self.check_for_updates()
        return not self.stopping

    def check_for_updates(self, show_result=False):
        if self.fixture or self.stopping:
            return
        self.show_update_result |= show_result
        if self.pending["updates"]:
            return

        def check():
            error = core("update.error") if self.read_update_error else None
            try:
                return error, core("update.check", payload={"version": VERSION}), None
            except (OSError, RuntimeError, subprocess.SubprocessError) as failure:
                return error, None, str(failure)

        def complete(result):
            self.read_update_error = False
            error, update, check_error = result
            if error:
                self.announce(error)
            if check_error:
                failed(check_error)
                return
            self.available_update = update["version"] if update else None
            self.update_offer.set_visible(bool(update))
            if update:
                self.update_offer.set_label(f"Update to myDrive {self.available_update}")
            elif self.show_update_result:
                self.announce(f"myDrive {VERSION} is up to date.")
            self.show_update_result = False

        def failed(_message):
            if self.show_update_result:
                self.announce("Could not check for updates. Try again when GitHub is available.")
            self.show_update_result = False

        self.work("updates", "", check, complete, quiet=True, on_error=failed)

    def install_update(self):
        if not self.available_update or self.pending["updates"]:
            return
        if self.pending["storage"]:
            self.announce("Finish the current file operation before updating myDrive.")
            return
        appimage = os.environ.get("APPIMAGE")
        if not appimage:
            self.announce("Open myDrive from its AppImage before updating.")
            return
        target = self.available_update
        self.update_offer.set_sensitive(False)
        self.update_offer.set_label(f"Downloading myDrive {target}…")

        def failed(message):
            self.announce(message)
            self.update_offer.set_sensitive(True)
            self.update_offer.set_label(f"Update to myDrive {target}")

        self.work("updates", "", lambda: core("update.install", payload={
            "version": VERSION, "target_version": target, "app_path": appimage, "pid": os.getpid(),
        }), lambda _: self.quit(), quiet=True, on_error=failed)

    def resize(self):
        if self.window.is_maximized():
            self.window.unmaximize()
        else:
            self.window.maximize()

    def apply_appearance(self):
        theme = self.preferences.get("appearance", "System")
        if theme == "System":
            self.settings.reset_property("gtk-theme-name")
            self.settings.reset_property("gtk-application-prefer-dark-theme")
            if self.desktop_appearance and self.desktop_appearance.get_string("color-scheme") == "prefer-dark":
                self.settings.set_property("gtk-application-prefer-dark-theme", True)
        else:
            self.settings.set_property("gtk-theme-name", "Adwaita")
            self.settings.set_property("gtk-application-prefer-dark-theme", theme == "Dark")

    def announce(self, message):
        self.status.set_text(message or "")
        self.status.set_tooltip_text(message or "")
        self.status.set_visible(bool(message))

    def work(self, lane, title, operation, complete, *, quiet=False, on_error=None):
        if self.stopping or (quiet and self.pending[lane]):
            return
        self.pending[lane] += 1
        if not quiet:
            self.announce(title + "…")
        future = self.lanes[lane].submit(operation)
        def finish():
            self.pending[lane] -= 1
            if self.stopping:
                return GLib.SOURCE_REMOVE
            try:
                complete(future.result())
                if not quiet and title:
                    self.announce("")
                    self.record(title, True)
            except Exception as error:
                if on_error:
                    on_error(str(error))
                if not quiet:
                    self.announce(str(error))
                    self.record(title, False)
            return GLib.SOURCE_REMOVE
        future.add_done_callback(lambda *_: GLib.idle_add(finish))

    def record(self, title, success):
        self.activity = [{"time": datetime.now().isoformat(timespec="minutes"), "name": title, "success": success}, *self.activity][:200]
        with_error = False
        try:
            save_settings("activity.json", self.activity)
        except OSError:
            with_error = True
        self.render_activity()
        if with_error:
            self.announce("Activity could not be saved.")

    def dialog(self, title, apply, fields, accepted, parent=None):
        dialog = Gtk.Dialog(title=title, transient_for=parent or self.window, modal=True)
        dialog.set_default_size(344, -1)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button(apply, Gtk.ResponseType.OK)
        content = dialog.get_content_area()
        content.set_spacing(6)
        for widget in fields:
            content.append(widget)
        def response(dialog, result):
            if result == Gtk.ResponseType.OK:
                try:
                    accepted()
                except (OSError, ValueError, RuntimeError) as error:
                    self.announce(str(error))
                    return
            dialog.close()
        dialog.connect("response", response)
        dialog.present()
        return dialog

    def confirm(self, title, message, action, accepted):
        detail = Gtk.Label(label=message, xalign=0, wrap=True, max_width_chars=40)
        self.dialog(title, action, [detail], accepted)

    def entry(self, title, initial, accepted):
        text = Gtk.Entry(text=initial, activates_default=True)
        dialog = self.dialog(title, "Save", [text], lambda: accepted(text.get_text().strip()))
        dialog.set_default_response(Gtk.ResponseType.OK)
        text.grab_focus()

    def files(self, title, action, accepted, multiple=False, suggested_name=None):
        chooser = Gtk.FileChooserNative.new(title, self.window, action, "Choose", "Cancel")
        chooser.set_select_multiple(multiple)
        if suggested_name:
            chooser.set_current_name(suggested_name)
        def response(chooser, result):
            if result == Gtk.ResponseType.ACCEPT:
                files = chooser.get_files()
                paths = [files.get_item(i).get_path() for i in range(files.get_n_items())]
                if paths and all(paths):
                    accepted(paths)
            chooser.destroy()
        chooser.connect("response", response)
        chooser.show()

    def open_uri(self, uri):
        try:
            Gio.AppInfo.launch_default_for_uri(uri, None)
        except GLib.Error as error:
            self.announce(error.message)

    def open_path(self, path):
        if path:
            self.open_uri(Gio.File.new_for_path(str(Path(path).expanduser())).get_uri())

    def dropped(self, controller, value, x, y):
        paths = [file.get_path() for file in value.get_files()]
        if not paths or not all(path and (Path(path).is_file() or Path(path).is_dir()) for path in paths):
            return False
        self.handle_drop(paths)
        return True

    def handle_drop(self, paths):
        if len(paths) != 1 or not Path(paths[0]).is_dir():
            self.transfer_view.send_dropped(paths)
            return
        folder = paths[0]
        dialog = Gtk.Dialog(title=Path(folder).name, transient_for=self.window, modal=True)
        for response, title in enumerate(("Send with Blip", "Sync folder", "Share over SMB"), 1):
            dialog.add_button(title, response)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        actions = {
            1: lambda: self.transfer_view.send_dropped(paths),
            2: lambda: self.share_folder(folder),
            3: lambda: self.smb_share_folder(folder),
        }
        def chosen(dialog, response):
            dialog.close()
            if response in actions:
                actions[response]()
        dialog.connect("response", chosen)
        dialog.present()

    def smb_share_folder(self, folder):
        field = Gtk.Entry(text=Path(folder).name, placeholder_text="SMB share name")
        account = Gtk.Entry(placeholder_text="Samba account")
        detail = Gtk.Label(label="Share read-only over encrypted SMB on Tailscale.",
                           wrap=True, max_width_chars=42, xalign=0)

        def submit():
            name = field.get_text().strip()
            username = account.get_text().strip()
            def shared(_):
                self.storage_view.load()
            self.work("storage", "Share folder over SMB", lambda: add_private_share(name, folder, username),
                      shared)

        self.dialog("Share over SMB", "Share", [field, account, detail], submit)

    def refresh_sync(self, quiet=False):
        def updated(snapshot):
            self.snapshot = snapshot
            if not self.browse:
                self.render_sync()
        def failed(message):
            if not self.browse:
                self.render_sync(error=message)
        self.work("sync", "Refresh Syncthing", lambda: self.sync.request("snapshot"), updated,
                  quiet=quiet, on_error=failed)

    def render_sync(self, error=None):
        page = self.pages["Sync"]
        clear(page)
        version = self.snapshot.get("version", "")
        page.append(row("Syncthing", version, button("Refresh", self.refresh_sync)))
        if error:
            page.append(Gtk.Label(label=error, xalign=0, wrap=True, max_width_chars=42))
        folders = self.snapshot.get("folders", [])
        devices = {d["deviceID"]: d for d in self.snapshot.get("devices", []) if not d.get("is_local")}
        for folder in folders:
            identifier = folder["id"]
            name = folder.get("label") or identifier
            status = folder.get("status") or {}
            state = "Paused" if folder.get("paused") else (status.get("state") or "Unavailable").capitalize()
            need = status.get("needFiles", 0)
            peers = [devices[key].get("name") or key for key in folder.get("device_ids", []) if key in devices]
            detail = " · ".join([state] + ([f"{need} pending"] if need else []) + peers)
            actions = menu([
                ("Pause" if not folder.get("paused") else "Resume",
                 lambda f=folder: self.sync_action(f, "pause", paused=not f.get("paused"))),
                ("Rescan", lambda f=folder: self.sync_action(f, "scan")),
                ("Pending files", lambda f=folder: self.sync_details(f, "need")),
                ("Show errors", lambda f=folder: self.sync_details(f, "errors")),
                ("Saved versions", lambda f=folder: self.sync_details(f, "versions")),
                ("Protect version history", lambda f=folder: self.sync_action(f, "protect")),
                ("Stop syncing folder…", lambda f=folder: self.stop_folder(f)),
            ])
            page.append(row(name, detail, button("Browse", lambda f=folder: self.browse_folder(f, "")),
                            button("Open", lambda f=folder: self.open_path(f.get("path"))), actions))
        if not folders and not error:
            page.append(label("No synced folders."))
        if devices:
            peers = Gtk.Expander(label="Devices")
            items = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            for identifier, device in devices.items():
                online = (device.get("connection") or {}).get("connected")
                items.append(row(device.get("name") or identifier, "Connected" if online else "Disconnected"))
            peers.set_child(items)
            page.append(peers)

    def sync_action(self, folder, action, **fields):
        self.work("sync", action.capitalize(), lambda: self.sync.request(action, folder_id=folder["id"], **fields),
                  lambda _: self.refresh_sync(quiet=True))

    def stop_folder(self, folder):
        self.confirm("Stop syncing folder?", "Files and saved versions stay on your devices.", "Stop syncing",
                     lambda: self.sync_action(folder, "stop", expected_path=folder.get("path", "")))

    def share_folder(self, path=None):
        devices = [d for d in self.snapshot.get("devices", []) if not d.get("is_local")]
        if not devices:
            self.announce("Add a device in Syncthing first, then refresh Sync.")
            return
        if path is None:
            self.files("Choose a folder to sync", Gtk.FileChooserAction.SELECT_FOLDER,
                       lambda paths: self.share_folder(paths[0]))
            return
        peers = Gtk.ListBox()
        for device in devices:
            peers.append(label(device.get("name") or device["deviceID"]))
        def selected():
            active = peers.get_selected_row()
            if active is None:
                raise ValueError("Choose a device.")
            payload = {"local_path": str(path), "device_id": devices[active.get_index()]["deviceID"]}
            def preview(result):
                detail = f"Share {Path(path).name} with {devices[active.get_index()].get('name') or 'this device'}?"
                self.confirm("Sync this folder?", detail, "Start syncing",
                             lambda: self.work("sync", "Share folder", lambda: self.sync.request("share", **payload),
                                               lambda _: self.refresh_sync(quiet=True)))
            self.work("sync", "Check folder", lambda: self.sync.request("share.preview", **payload), preview)
        self.dialog("Choose a sync device", "Continue", [self.scrolled_list(peers)], selected)

    @staticmethod
    def scrolled_list(child, height=200):
        return Gtk.ScrolledWindow(child=child, min_content_height=height, max_content_height=height,
                                  propagate_natural_height=True, hscrollbar_policy=Gtk.PolicyType.NEVER)

    def browse_folder(self, folder, path):
        self.browse = (folder["id"], path)
        page = self.pages["Sync"]
        clear(page)
        def back():
            if path:
                self.browse_folder(folder, path.rpartition("/")[0])
            else:
                self.browse = None
                self.render_sync()
        page.append(row(path or folder.get("label") or folder["id"], "", button("Back", back),
                        button("Refresh", lambda: self.browse_folder(folder, path))))
        def loaded(result):
            if self.browse != (folder["id"], path):
                return
            for entry in result.get("entries", []):
                relative = entry["path"]
                if entry.get("is_dir"):
                    open_item = lambda p=relative: self.browse_folder(folder, p)
                else:
                    open_item = lambda p=relative: self.work(
                        "sync", "Open synced file", lambda: self.sync.request("local_file", folder_id=folder["id"], path=p),
                        lambda item: self.open_path(item.get("path")))
                entries = [("Sync", lambda e=entry: self.rule(folder, path, e, "sync")),
                           ("Stop", lambda e=entry: self.rule(folder, path, e, "ignore"))]
                if entry.get("is_dir"):
                    entries.append(("Sync with another device…", lambda p=relative: self.share_folder(Path(folder["path"]) / p)))
                page.append(row(entry["name"], "Folder" if entry.get("is_dir") else "",
                                button("Open", open_item), menu(entries)))
            if not result.get("entries"):
                page.append(label("This folder has no visible entries."))
        self.work("sync", "Browse synced folder", lambda: self.sync.request("browse", folder_id=folder["id"], path=path), loaded)

    def rule(self, folder, path, entry, mode):
        def apply():
            identifier = folder["id"]
            current = self.sync.request("ignores", folder_id=identifier)["ignore"]
            selection = self.sync.request("browse", folder_id=identifier, path=path).get("rules", [])
            changed = [rule for rule in selection if rule["path"] != entry["path"]]
            changed.append({"path": entry["path"], "is_dir": bool(entry.get("is_dir")), "sync": mode == "sync"})
            return self.sync.request("selection.apply", folder_id=identifier, expected_ignore=current, rules=changed)
        self.work("sync", "Change file selection", apply, lambda _: self.browse_folder(folder, path))

    def sync_details(self, folder, action):
        def loaded(result):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            if action == "versions":
                for path, versions in result.items():
                    for version in versions:
                        time = version.get("versionTime")
                        box.append(row(path, time or "", button("Restore…", lambda p=path, t=time: self.confirm(
                            "Restore this version?", "myDrive backs up the current local copy first.", "Restore",
                            lambda: self.sync_action(folder, "restore", path=p, version_time=t)))))
            else:
                items = result.get("errors", []) if action == "errors" else [
                    item for key in ("progress", "queued", "rest") for item in (result.get(key) or [])]
                for item in items:
                    box.append(row(item.get("path") or item.get("name") or "File", item.get("error", "")))
            if not box.get_first_child():
                box.append(label("No items."))
            dialog = self.dialog({"errors": "Sync errors", "versions": "Saved versions", "need": "Pending files"}[action],
                                 "Done", [self.scrolled_list(box)], lambda: None)
            dialog.get_widget_for_response(Gtk.ResponseType.CANCEL).set_visible(False)
        self.work("sync", "Read folder details", lambda: self.sync.request(action, folder_id=folder["id"]), loaded)

    def render_activity(self):
        page = self.pages["Activity"]
        clear(page)
        if not self.activity:
            page.append(label("No activity yet."))
        for item in self.activity:
            page.append(row(item["name"], f"{item['time']} · {'Done' if item['success'] else 'Needs attention'}"))

    def render_settings(self):
        page = self.pages["Settings"]
        clear(page)
        themes = ["System", "Light", "Dark"]
        appearance = Gtk.DropDown.new_from_strings(themes)
        saved_theme = self.preferences.get("appearance", "System")
        appearance.set_selected(themes.index(saved_theme) if saved_theme in themes else 0)
        def change_theme(dropdown, *_):
            self.change_preference("appearance", themes[dropdown.get_selected()])
            self.apply_appearance()
        appearance.connect("notify::selected", change_theme)
        page.append(row("Appearance", "", appearance))
        startup = Gtk.Switch(active=self.startup["enabled"], valign=Gtk.Align.CENTER)
        startup.connect("notify::active", lambda switch, _: self.change_startup(
            "startup.enable" if switch.get_active() else "startup.disable"))
        page.append(row("Start at boot", "", startup))
        if self.startup["enabled"] and not self.startup["configured"]:
            page.append(button("Set up before-sign-in startup…", lambda: self.change_startup("startup.setup")))
        for key, title in [("blip_background", "Blip background service"), ("blip_open", "Open approved links")]:
            switch = Gtk.Switch(active=self.preferences.get(key, True), valign=Gtk.Align.CENTER)
            switch.connect("notify::active", lambda s, _, key=key: self.change_preference(key, s.get_active()))
            page.append(row(title, "", switch))
        page.append(button("Check for updates", lambda: self.check_for_updates(show_result=True)))
        page.append(row("Advanced", "", menu([
            ("Syncthing settings…", lambda: self.files("Choose Syncthing config.xml", Gtk.FileChooserAction.OPEN,
                                                      lambda files: self.set_config(files[0]))),
            ("Open app data folder", lambda: self.open_path(DATA)),
        ])))

    def change_startup(self, action):
        def loaded(state):
            self.startup = state
            self.render_settings()

        self.work("settings", "Set up startup", lambda: core(action), loaded, quiet=True,
                  on_error=None if action == "startup.status" else self.announce)

    def change_preference(self, key, value):
        try:
            updated = {**self.preferences, key: value}
            save_settings("preferences.json", updated)
            self.preferences = updated
        except OSError as error:
            self.announce(str(error))

    def set_config(self, path):
        self.change_preference("syncthing_config", path)
        def connect():
            self.sync.config_path = self.preferences.get("syncthing_config", "")
            self.sync.connection = None
            return self.sync.request("snapshot")
        self.work("sync", "Connect Syncthing", connect, lambda data: (setattr(self, "snapshot", data), self.render_sync()))

    def run_fixture(self):
        self.snapshot = {"version": "v2 fixture", "folders": [
            {"id": "folder", "label": "A long studio folder label to verify truncation", "path": "/tmp/mydrive-fixture",
             "device_ids": ["device"], "status": {"state": "idle", "needFiles": 2}}
        ], "devices": [{"deviceID": "device", "name": "Studio laptop", "connection": {"connected": True}}]}
        self.render_sync()
        self.storage_view.render_bookmarks()
        self.transfer_view.render()
        self.stack.set_visible_child_name("Send & Receive")
        chosen = []
        recipients = self.transfer_view.choose_recipient({f"{n}": f"Fixture device {n}" for n in range(10)},
                                                         chosen.append, files_ready=True)
        initial_size = self.window.get_default_size()

        class FixtureBlip:
            def monitor(self, background):
                assert background
                return {"status": {"authenticated": True, "user_id": "00000000-0000-4000-8000-000000000001",
                                   "device_id": "00000000-0000-4000-8000-000000000002"},
                        "devices": [{"peer": "00000000-0000-4000-8000-000000000001:00000000-0000-4000-8000-000000000003",
                                     "name": "Fixture laptop", "name_known": True}]}

        def verify_cold_send():
            assert list(self.transfer_view.recipients().values()) == ["Fixture laptop"]
            assert self.window.get_default_size() == initial_size == (344, 420)
            print("Linux GTK fixed popup, cold Blip connection and one-click recipient passed", flush=True)
            self.quit()

        def verify():
            target = recipients.get_row_at_index(3)
            send = target.get_child().get_first_child()
            edit = target.get_child().get_last_child()
            assert not chosen and not target.get_activatable()
            edit.emit("clicked")
            assert not chosen
            send.emit("clicked")
            send.emit("clicked")
            assert chosen == ["3"]
            self.transfer_view.blip = FixtureBlip()
            self.transfer_view.with_send_connection(verify_cold_send)
            return GLib.SOURCE_REMOVE
        GLib.timeout_add(300, verify)


if __name__ == "__main__":
    if sys.argv[1:] == ["--version"]:
        print(VERSION)
        sys.exit(0)
    fixture = sys.argv[1:] == ["--smoke-test"]
    sys.exit(MyDrive(fixture).run([sys.argv[0], *([] if fixture else sys.argv[1:])]))
