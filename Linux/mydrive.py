#!/usr/bin/env python3
"""Native GTK desktop shell for myDrive on Linux."""

import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event
from time import monotonic

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk

from file_manager import install_actions
from services import DATA, ROOT, Blip, Sync, core, read_settings, save_settings
from smb_sharing import add_private_share
from storage_view import StorageView
from tray import Tray
from transfer_view import TransferView, clipboard_text
from ui_widgets import button, clear, label, menu, row


APP_ID = "net.oseanstudio.myDrive"
VERSION_FILE = Path(__file__).with_name("version.txt")
VERSION = VERSION_FILE.read_text(encoding="utf-8").strip() if VERSION_FILE.is_file() else "0.4.17"


def folders_needing_attention(snapshot):
    def has_error(folder):
        status = folder.get("status") or {}
        return not folder.get("paused") and (
            folder.get("error") or (status.get("pullErrors") or 0) > 0 or (status.get("errors") or 0) > 0
        )
    return sorted((folder for folder in snapshot.get("folders", []) if has_error(folder)),
                  key=lambda folder: (folder.get("label") or folder["id"]).casefold())


class MyDrive(Gtk.Application):
    def __init__(self, fixture=False):
        flags = Gio.ApplicationFlags.HANDLES_OPEN
        if fixture:
            flags |= Gio.ApplicationFlags.NON_UNIQUE
        super().__init__(application_id=APP_ID, flags=flags)
        self.fixture = fixture
        self.sync = Sync()
        self.blip = Blip()
        self.preferences = read_settings("preferences.json", {})
        self.sync.config_path = self.preferences.get("syncthing_config", "")
        self.activity = read_settings("activity.json", [])
        self.send_activity = []
        self.send_activity_owner = ""
        self.send_activity_error = ""
        self.snapshot = {}
        self.lanes = {key: ThreadPoolExecutor(max_workers=1)
                      for key in ("sync", "blip", "blip-recipients", "storage", "smb-health", "updates", "settings")}
        self.pending = {key: 0 for key in self.lanes}
        self.window = None
        self.browse = None
        self.sync_attention = False
        self.sync_issue_folder = None
        self.sync_rescanning = False
        self.last_sync_refresh = float("-inf")
        self.stopping = False
        self.show_update_result = False
        self.checking_for_update = False
        self.available_update = None
        self.read_update_error = True
        self.prepared_update = None
        self.manual_update_requested = False
        self.auto_update_timer = 0
        self.auto_update_after = 0
        self.file_picker_depth = 0
        self.popup_dismiss_timer = 0
        self.startup = {"enabled": True, "configured": False}

    def do_activate(self):
        if self.window:
            was_visible = self.window.get_visible()
            if not was_visible and not self.file_picker_depth:
                self.stack.set_visible_child_name("Send")
            self.window.present()
            if was_visible:
                self.check_for_updates()
            return
        self.window = Gtk.ApplicationWindow(application=self, title="myDrive")
        self.window.set_default_size(344, 420)
        self.window.set_icon_name(APP_ID)
        header = Gtk.HeaderBar()
        header.set_decoration_layout(":close")
        self.window.set_titlebar(header)
        self.settings = Gtk.Settings.get_default()
        schema_source = Gio.SettingsSchemaSource.get_default()
        schema = schema_source.lookup("org.gnome.desktop.interface", True) if schema_source else None
        self.desktop_appearance = Gio.Settings.new_full(schema, None, None) if schema and schema.has_key("color-scheme") else None
        if self.desktop_appearance:
            self.desktop_appearance.connect("changed::color-scheme", lambda *_: self.apply_appearance())
        self.apply_appearance()
        titles = {"Send": "Blip", "Sync": "Syncthing", "SMB Drives": "SMB Drives",
                  "Activity": "Activity", "Settings": "Settings"}
        header_content = Gtk.Box(spacing=7)
        header_content.append(label(f"myDrive {VERSION}", "heading"))
        header.set_title_widget(header_content)
        controls = Gtk.Box(spacing=4)
        controls.append(menu([("Sync a folder…", self.share_folder), ("Quit myDrive", self.quit)]))
        expand = Gtk.Button()
        expand.connect("clicked", lambda *_: self.resize())

        def update_window_mode(*_):
            full = self.window.is_maximized()
            title = "Open compact window" if full else "Open full window"
            expand.set_icon_name("window-restore-symbolic" if full else "view-fullscreen-symbolic")
            expand.set_tooltip_text(title)
            expand.update_property([Gtk.AccessibleProperty.LABEL], [title])

        update_window_mode()
        self.window.connect("notify::maximized", update_window_mode)
        controls.append(expand)
        header.pack_end(controls)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        self.window.set_child(content)
        tabs = Gtk.StackSwitcher(halign=Gtk.Align.CENTER, margin_top=6, margin_start=6, margin_end=6)
        content.append(tabs)
        drop = Gtk.DropTarget.new(Gdk.FileList.__gtype__, Gdk.DragAction.COPY)
        drop.connect("drop", self.dropped)
        self.file_drop = drop
        self.window.add_controller(drop)
        self.window.connect("notify::is-active", self.popup_focus_changed)
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
        for title, caption in titles.items():
            page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_bottom=8, margin_start=8, margin_end=8)
            scroll = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, child=page)
            self.pages[title] = page
            tab = self.stack.add_titled(scroll, title, caption)
            if title in ("Activity", "Settings"):
                tab.set_icon_name("document-open-recent-symbolic" if title == "Activity" else "emblem-system-symbolic")
        self.stack.set_visible_child_name("Send")
        tabs.set_stack(self.stack)
        def show_view(stack, *_):
            title = stack.get_visible_child_name()
            if title == "Sync" and not self.fixture:
                self.refresh_background_sync(force=True)
            if title == "SMB Drives" and not self.fixture:
                self.storage_view.check_now("view")
            if title == "Settings" and not self.fixture:
                self.change_startup("startup.status")
            if title == "Activity" and not self.fixture:
                self.refresh_send_activity()
        self.stack.connect("notify::visible-child-name", show_view)
        self.storage_view = StorageView(self, self.pages["SMB Drives"])
        if not self.fixture:
            def check_visible_storage(window, _property):
                if window.get_visible() and self.stack.get_visible_child_name() == "SMB Drives":
                    self.storage_view.check_now("view")
            self.window.connect("notify::visible", check_visible_storage)
        self.transfer_view = TransferView(self, self.pages["Send"], self.blip)
        self.render_activity()
        self.render_settings()
        self.window.present()
        if self.fixture:
            assert header.get_decoration_layout() == ":close" and controls.get_last_child() == expand
            assert expand.get_icon_name() == "view-fullscreen-symbolic" and content.get_last_child() == self.stack
            assert self.stack.get_visible_child_name() == "Send" and tabs.get_stack() == self.stack
            assert self.stack.get_pages().get_item(0).get_title() == "Blip"
            assert self.stack.get_pages().get_item(1).get_title() == "Syncthing"
            self.run_fixture()
            return
        self.tray = Tray(self.window, ROOT / f"{APP_ID}.png")
        self.window.connect("notify::visible", lambda window, _: self.check_for_updates()
                            if window.get_visible() else None)
        self.window.connect("notify::visible", lambda window, _: self.refresh_background_sync(force=True)
                            if window.get_visible() and self.stack.get_visible_child_name() == "Sync" else None)
        self.refresh_sync()
        self.storage_view.load()
        self.storage_view.start_monitor()
        self.transfer_view.refresh()
        self.tick_updates()
        GLib.timeout_add_seconds(6 * 60 * 60, self.tick_updates)
        GLib.timeout_add_seconds(8, self.tick_sync)
        GLib.timeout_add_seconds(2, self.tick_blip)

    def do_open(self, files, _count, _hint):
        self.activate()
        if self.fixture or not 0 < len(files) <= 256:
            return
        paths = list(dict.fromkeys(file.get_path() for file in files if file.is_native()))
        paths = [path for path in paths if path and (Path(path).is_file() or Path(path).is_dir())]
        if not paths:
            self.announce("Choose an available file or folder.")
            return
        self.stack.set_visible_child_name("Send")
        self.transfer_view.send_dropped(paths)

    def do_shutdown(self):
        self.stopping = True
        if not self.fixture:
            self.sync.stop()
        self.sync_auto_install_timer()
        self.discard_prepared_update()
        if self.window:
            self.storage_view.stop_monitor()
        self.lanes["blip"].submit(self.blip.stop)
        for worker in self.lanes.values():
            worker.shutdown(wait=False)
        Gtk.Application.do_shutdown(self)

    def tick_sync(self):
        self.refresh_background_sync()
        return not self.stopping

    def refresh_background_sync(self, force=False):
        if self.pending["sync"]:
            return
        visible = self.main_window_visible() and self.stack.get_visible_child_name() == "Sync"
        now = datetime.now().timestamp()
        due = any(0 < (folder.get("paused_until") or 0) <= now
                  for folder in self.snapshot.get("folders", []))
        if self.browse and not due:
            return
        if force or monotonic() - self.last_sync_refresh >= (8 if visible or due else 120):
            self.refresh_sync(quiet=True)

    def tick_blip(self):
        self.transfer_view.refresh(quiet=True)
        return not self.stopping

    def tick_updates(self):
        self.check_for_updates()
        return not self.stopping

    def check_for_updates(self, show_result=False):
        if self.fixture or self.stopping:
            return
        if self.pending["updates"]:
            if self.checking_for_update:
                self.show_update_result |= show_result
            return
        self.checking_for_update = True
        self.show_update_result = show_result

        def check():
            error = core("update.error") if self.read_update_error else None
            try:
                update = core("update.check", payload={"version": VERSION})
                return error, update, None
            except (OSError, RuntimeError, subprocess.SubprocessError) as failure:
                return error, None, str(failure)

        def complete(result):
            self.read_update_error = False
            error, update, check_error = result
            if error:
                self.auto_update_after = monotonic() + 60 * 60
                self.announce(error)
            if check_error:
                failed(check_error)
                return
            self.checking_for_update = False
            target = update["version"] if update else None
            if target != self.available_update:
                self.manual_update_requested = False
                if self.prepared_update:
                    path, self.prepared_update = self.prepared_update, None
                    self.work("updates", "", lambda: self.use_prepared_update("update.discard", path),
                              lambda _: self.install_update(automatic=True), quiet=True)
            self.available_update = target
            self.update_offer.set_visible(bool(update))
            self.update_offer_label()
            self.sync_auto_install_timer()
            if not update and self.show_update_result:
                self.announce(f"myDrive {VERSION} is up to date.")
            self.show_update_result = False
            self.install_update(automatic=True)

        def failed(_message):
            if self.show_update_result:
                self.announce("Could not check for updates. Try again when GitHub is available.")
            self.show_update_result = False
            self.checking_for_update = False

        self.work("updates", "", check, complete, quiet=True, on_error=failed)

    def sync_auto_install_timer(self):
        enabled = self.available_update and not self.stopping and (
            self.manual_update_requested or self.preferences.get("auto_install_updates", False)
        )
        if enabled and not self.auto_update_timer:
            self.auto_update_timer = GLib.timeout_add_seconds(30, self.tick_auto_install)
        elif not enabled and self.auto_update_timer:
            GLib.source_remove(self.auto_update_timer)
            self.auto_update_timer = 0

    def tick_auto_install(self):
        if not self.manual_update_requested or self.update_idle():
            self.install_update(automatic=not self.manual_update_requested)
        return GLib.SOURCE_CONTINUE

    def can_auto_install(self):
        if not self.preferences.get("auto_install_updates", False) or monotonic() < self.auto_update_after:
            return False
        return not self.main_window_visible()

    def main_window_visible(self):
        surface = self.window.get_surface()
        return self.window.get_visible() and not (
            isinstance(surface, Gdk.Toplevel) and surface.get_state() & Gdk.ToplevelState.MINIMIZED
        )

    def update_idle(self):
        if self.file_picker_depth or any(self.pending[key] for key in ("storage", "blip", "sync", "settings")):
            return False
        if any(window.get_transient_for() is self.window and window.get_visible()
               for window in Gtk.Window.list_toplevels()):
            return False
        return not any(
            transfer.get("status") in {"Created", "Pending", "Active", "ResumeRequested"}
            and not transfer.get("dismissed") and not transfer.get("has_error")
            for transfer in self.transfer_view.snapshot.get("transfers", [])
        )

    def update_offer_label(self):
        self.update_offer.set_sensitive(True)
        if self.available_update:
            action = "Install myDrive" if self.prepared_update else "Update to myDrive"
            self.update_offer.set_label(f"{action} {self.available_update}")

    def install_update(self, automatic=False):
        if self.stopping or not self.available_update or self.pending["updates"]:
            return
        if automatic and not self.can_auto_install():
            return
        if not self.update_idle():
            if not automatic:
                self.announce("Finish the current operation before updating myDrive.")
            return
        appimage = os.environ.get("APPIMAGE")
        if not appimage:
            self.auto_update_after = monotonic() + 60 * 60
            if not automatic:
                self.announce("Open myDrive from its AppImage before updating.")
            return
        self.update_offer.set_sensitive(False)
        self.manual_update_requested |= not automatic

        def failed(message):
            self.manual_update_requested = False
            self.auto_update_after = monotonic() + 60 * 60
            self.announce(message)
            self.update_offer_label()
            self.sync_auto_install_timer()

        if self.prepared_update:
            self.update_offer.set_label("Installing update…")
            path = self.prepared_update

            def applied(_):
                self.prepared_update = None
                self.quit()

            self.work("updates", "", lambda: self.use_prepared_update("update.apply", path), applied,
                      quiet=True, on_error=failed)
            return

        target = self.available_update
        self.update_offer.set_label(f"Downloading myDrive {target}…")

        def download():
            result = core("update.stage", payload={
                "version": VERSION, "target_version": target, "app_path": appimage, "pid": os.getpid(),
            })
            path = result["plan_path"]
            if self.stopping:
                self.use_prepared_update("update.discard", path)
            return path

        def downloaded(path):
            self.prepared_update = path
            self.update_offer_label()
            self.sync_auto_install_timer()
            if self.update_idle():
                self.install_update(automatic=automatic)

        self.work("updates", "", download, downloaded, quiet=True, on_error=failed)

    @staticmethod
    def use_prepared_update(action, path):
        return core(action, payload={"plan_path": path, "app_path": os.environ.get("APPIMAGE"), "pid": os.getpid()})

    def discard_prepared_update(self):
        if not self.prepared_update:
            return
        path, self.prepared_update = self.prepared_update, None
        try:
            self.use_prepared_update("update.discard", path)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass

    def resize(self):
        if self.window.is_maximized():
            self.window.unmaximize()
        else:
            self.window.maximize()

    def dismiss_compact(self):
        if not self.window.is_maximized():
            self.window.set_visible(False)

    def popup_focus_changed(self, window, _):
        if self.popup_dismiss_timer:
            GLib.source_remove(self.popup_dismiss_timer)
            self.popup_dismiss_timer = 0
        if window.get_visible() and not window.is_active() and not window.is_maximized():
            self.popup_dismiss_timer = GLib.timeout_add(350, self.dismiss_after_click)

    def dismiss_after_click(self):
        if self.window.get_visible() and not self.window.is_active() and not self.window.is_maximized():
            if self.file_drop.get_current_drop() is None:
                surface = self.window.get_surface()
                seat = self.window.get_display().get_default_seat()
                pointer = seat.get_pointer() if seat else None
                if surface and pointer:
                    _, _, _, state = surface.get_device_position(pointer)
                    if state & (Gdk.ModifierType.BUTTON1_MASK | Gdk.ModifierType.BUTTON2_MASK |
                                Gdk.ModifierType.BUTTON3_MASK):
                        return GLib.SOURCE_CONTINUE
                self.dismiss_compact()
        self.popup_dismiss_timer = 0
        return GLib.SOURCE_REMOVE

    def present_dialog(self, dialog):
        if not self.window.is_maximized() and dialog.get_transient_for() == self.window:
            dialog.set_transient_for(None)
            dialog.set_application(self)
        dialog.present()
        self.dismiss_compact()

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

    def work(self, lane, title, operation, complete, *, quiet=False, queue=False, on_error=None):
        if self.stopping or (quiet and not queue and self.pending[lane]):
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
        self.present_dialog(dialog)
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
        parent = self.window if self.window.is_maximized() else None
        chooser = Gtk.FileChooserNative.new(title, parent, action, "Choose", "Cancel")
        chooser.set_select_multiple(multiple)
        if suggested_name:
            chooser.set_current_name(suggested_name)
        def response(chooser, result):
            try:
                if result == Gtk.ResponseType.ACCEPT:
                    files = chooser.get_files()
                    paths = [files.get_item(i).get_path() for i in range(files.get_n_items())]
                    if paths and all(paths):
                        accepted(paths)
            finally:
                self.file_picker_depth -= 1
                chooser.destroy()
        chooser.connect("response", response)
        self.file_picker_depth += 1
        chooser.show()
        self.dismiss_compact()

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
        self.present_dialog(dialog)

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
        self.last_sync_refresh = monotonic()
        def showing_folders():
            return not self.browse and not self.sync_attention and self.sync_issue_folder is None
        def updated(snapshot):
            self.snapshot = snapshot
            if showing_folders():
                self.render_sync()
        def failed(message):
            if showing_folders():
                self.render_sync(error=message)
        self.work("sync", "Refresh Syncthing", lambda: self.sync.request("snapshot"), updated,
                  quiet=quiet, on_error=failed)

    def render_sync(self, error=None):
        page = self.pages["Sync"]
        clear(page)
        version = self.snapshot.get("version", "")
        page.append(row("Syncthing", version, button("Refresh", self.refresh_sync)))
        if warning := error or self.snapshot.get("scheduled_pause_error"):
            page.append(Gtk.Label(label=warning, xalign=0, wrap=True, max_width_chars=42))
        folders = self.snapshot.get("folders", [])
        attention_count = len(folders_needing_attention(self.snapshot))
        if attention_count and not error:
            title = "1 folder needs attention" if attention_count == 1 else f"{attention_count} folders need attention"
            attention = button(title + " ›", self.show_sync_attention)
            attention.set_tooltip_text("Open sync errors and fixes")
            attention.set_halign(Gtk.Align.START)
            attention.add_css_class("flat")
            page.append(attention)
        devices = {d["deviceID"]: d for d in self.snapshot.get("devices", []) if not d.get("is_local")}
        for folder in folders:
            identifier = folder["id"]
            name = folder.get("label") or identifier
            status = folder.get("status") or {}
            state = "Paused" if folder.get("paused") else (status.get("state") or "Unavailable").capitalize()
            if folder.get("paused") and folder.get("paused_until"):
                state = "Paused until " + datetime.fromtimestamp(folder["paused_until"]).strftime("%b %d %H:%M")
            need = status.get("needFiles", 0)
            peers = [devices[key].get("name") or key for key in folder.get("device_ids", []) if key in devices]
            detail = " · ".join([state] + ([f"{need} pending"] if need else []) + peers)
            actions = menu([
                ("Pause" if not folder.get("paused") else "Resume",
                 lambda f=folder: self.sync_action(f, "pause", paused=not f.get("paused"))),
                ("Pause until…", lambda f=folder: self.choose_sync_pause(f)),
                ("Device progress", lambda f=folder: self.show_device_progress(f)),
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

    def choose_sync_pause(self, folder):
        start = datetime.now() + timedelta(hours=1)
        calendar = Gtk.Calendar()
        calendar.select_day(GLib.DateTime.new_now_local().add_hours(1))
        hour = Gtk.SpinButton.new_with_range(0, 23, 1)
        minute = Gtk.SpinButton.new_with_range(0, 59, 1)
        hour.set_value(start.hour)
        minute.set_value(start.minute)
        clock = Gtk.Box(spacing=6)
        for control in [label("Hour"), hour, label("Minute"), minute]:
            clock.append(control)

        def schedule():
            date = calendar.get_date()
            resume = datetime(date.get_year(), date.get_month(), date.get_day_of_month(),
                              hour.get_value_as_int(), minute.get_value_as_int())
            until = int(resume.timestamp())
            if datetime.fromtimestamp(until) != resume:
                raise ValueError("Choose another time. The clock skips that time.")
            self.sync_action(folder, "pause_until", until=until, expected_path=folder.get("path", ""))

        self.dialog("Pause until", "Pause", [calendar, clock], schedule)

    def show_device_progress(self, folder):
        identifier = folder["id"]
        self.sync_issue_folder = identifier
        page = self.sync_issues_header("Device progress", self.leave_sync_attention,
                                       lambda: self.show_device_progress(folder))
        loading = label("Loading…")
        page.append(loading)

        def loaded(result=None, error=None):
            if loading.get_parent() != page:
                return
            self.sync_issues_header("Device progress", self.leave_sync_attention,
                                    lambda: self.show_device_progress(folder))
            if error:
                page.append(label(error))
                return
            devices = result.get("devices", [])
            if not devices:
                page.append(label("This folder has no other devices."))
            for device in devices:
                parts = [device.get("state", "Progress unavailable")]
                if (remaining := device.get("remaining_bytes")) is not None:
                    parts.append(GLib.format_size(remaining) + " remaining")
                if (percent := device.get("percent")) is not None:
                    parts.append(f"{percent:.1f}%")
                page.append(row(device.get("name", "Device"), " · ".join(parts)))
        self.work("sync", "Read device progress", lambda: self.sync.request("device_progress", folder_id=identifier),
                  loaded, quiet=True, queue=True, on_error=lambda error: loaded(error=error))

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
        if action == "errors":
            self.show_sync_issue(folder)
            return
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
                items = [item for key in ("progress", "queued", "rest") for item in (result.get(key) or [])]
                for item in items:
                    box.append(row(item.get("path") or item.get("name") or "File", item.get("error", "")))
            if not box.get_first_child():
                box.append(label("No items."))
            dialog = self.dialog({"versions": "Saved versions", "need": "Pending files"}[action],
                                 "Done", [self.scrolled_list(box)], lambda: None)
            dialog.get_widget_for_response(Gtk.ResponseType.CANCEL).set_visible(False)
        self.work("sync", "Read folder details", lambda: self.sync.request(action, folder_id=folder["id"]), loaded)

    def leave_sync_attention(self):
        self.sync_attention = False
        self.sync_issue_folder = None
        self.render_sync()

    def sync_issues_header(self, title, back, refresh):
        page = self.pages["Sync"]
        clear(page)
        page.append(row(title, "", button("Back", back), button("Refresh", refresh)))
        return page

    @staticmethod
    def issue_rows(details):
        return (details.get("errors") or []) if isinstance(details, dict) else details

    @staticmethod
    def add_issue_text(container, message):
        if message:
            text = Gtk.Label(label=message, xalign=0, wrap=True, max_width_chars=44, selectable=True)
            text.set_tooltip_text(message)
            container.append(text)

    def show_sync_attention(self, refresh=False):
        self.sync_attention = True
        self.sync_issue_folder = None
        page = self.sync_issues_header("Sync errors", self.leave_sync_attention,
                                       lambda: self.show_sync_attention(refresh=True))
        loading = label("Loading folder errors…")
        page.append(loading)

        def load():
            snapshot = self.sync.request("snapshot") if refresh else self.snapshot
            folders = folders_needing_attention(snapshot)
            issues = self.sync.request("attention", folder_ids=[folder["id"] for folder in folders]) if folders else {}
            return snapshot, folders, issues

        def done(result):
            if loading.get_parent() is not page:
                return
            page.remove(loading)
            self.snapshot, folders, issues = result
            if not folders:
                page.append(label("No folders need attention."))
            for folder in folders:
                report = issues.get(folder["id"], {})
                first = next(iter(self.issue_rows(report)), {})
                box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin_top=4, margin_bottom=5)
                box.append(label(folder.get("label") or folder["id"], "heading"))
                if first.get("path"):
                    box.append(label(first["path"], "dim-label"))
                self.add_issue_text(box, first.get("error") or first.get("message") or folder.get("error") or
                                    report.get("failure") or "Syncthing reported a sync problem.")
                self.add_issue_text(box, first.get("advice") or folder.get("error_advice"))
                actions = Gtk.Box(spacing=6)
                if folder.get("path"):
                    actions.append(button("Choose new location…", lambda f=folder: self.relocate_sync_folder(f)))
                actions.append(button("Rescan", lambda f=folder: self.rescan_issue(f)))
                actions.append(button("View errors", lambda f=folder: self.show_sync_issue(f)))
                box.append(actions)
                page.append(box)

        self.work("sync", "Check sync errors", load, done,
                  on_error=lambda message: loading.set_label(message) if loading.get_parent() is page else None)

    def show_sync_issue(self, folder):
        self.sync_issue_folder = folder["id"]
        back = self.show_sync_attention if self.sync_attention else self.leave_sync_attention
        page = self.sync_issues_header("Folder errors", back, lambda: self.show_sync_issue(folder))
        actions = []
        if folder.get("path"):
            actions.append(button("Choose new location…", lambda: self.relocate_sync_folder(folder)))
        actions.append(button("Rescan folder", lambda: self.rescan_issue(folder)))
        page.append(row(folder.get("label") or folder["id"], "", *actions))
        loading = label("Loading folder errors…")
        page.append(loading)

        def done(result):
            if loading.get_parent() is not page:
                return
            page.remove(loading)
            errors = self.issue_rows(result)
            if not errors:
                fresh = next((item for item in self.snapshot.get("folders", [])
                              if item["id"] == folder["id"]), {})
                self.add_issue_text(page, fresh.get("error") or "No file errors.")
            for issue in errors:
                page.append(label(issue.get("path") or issue.get("file") or "File", "heading"))
                self.add_issue_text(page, issue.get("error") or issue.get("message"))
                self.add_issue_text(page, issue.get("advice"))

        self.work("sync", "Read folder errors", lambda: self.sync.request("errors", folder_id=folder["id"]), done,
                  on_error=lambda message: loading.set_label(message) if loading.get_parent() is page else None)

    def relocate_sync_folder(self, folder):
        def chosen(paths):
            def relocate():
                self.sync.request("relocate", folder_id=folder["id"], expected_path=folder["path"], local_path=paths[0])
                return self.sync.request("snapshot")

            def done(snapshot):
                self.snapshot = snapshot
                if self.sync_issue_folder == folder["id"]:
                    self.sync_issue_folder = None
                if self.sync_attention and self.sync_issue_folder is None:
                    self.show_sync_attention()
                elif self.sync_issue_folder is None:
                    self.render_sync()

            self.work("sync", "Update sync location", relocate, done)

        self.files("Choose the moved sync folder", Gtk.FileChooserAction.SELECT_FOLDER, chosen)

    def rescan_issue(self, folder):
        if self.sync_rescanning:
            return
        self.sync_rescanning = True
        identifier = folder["id"]
        def scan():
            self.sync.request("scan", folder_id=identifier)
            return self.sync.request("snapshot")
        def done(snapshot):
            self.sync_rescanning = False
            self.snapshot = snapshot
            if self.sync_issue_folder == identifier:
                self.show_sync_issue(folder)
            elif self.sync_attention and self.sync_issue_folder is None:
                self.show_sync_attention()
        def failed(_message):
            self.sync_rescanning = False
        self.work("sync", "Rescan folder", scan, done, on_error=failed)

    def render_activity(self):
        page = self.pages["Activity"]
        clear(page)
        owner = self.transfer_view.owner(self.transfer_view.snapshot)
        if owner:
            page.append(row("Send activity", "", button("Refresh", self.refresh_send_activity)))
            if owner == self.send_activity_owner:
                names = self.transfer_view.peer_captions()
                if self.send_activity_error:
                    page.append(label(self.send_activity_error))
                for entry in self.send_activity:
                    title = f"{entry.get('kind', 'File')} · {entry.get('name', '')}"
                    peer = entry.get("peer", "")
                    recipient = names.get(peer.lower(), self.transfer_view.fallback_name(peer))
                    detail = " · ".join(filter(None, (recipient, entry.get("status"), entry.get("detail"))))
                    actions = [button("Retry", lambda id=entry["id"]: self.refresh_send_activity(id))] if entry.get("can_retry") else []
                    page.append(row(title, detail, *actions))
                if not self.send_activity and not self.send_activity_error:
                    page.append(label("No sends recorded yet."))
        if not self.activity:
            return
        for item in self.activity:
            page.append(row(item["name"], f"{item['time']} · {'Done' if item['success'] else 'Needs attention'}"))

    def refresh_send_activity(self, retry=None):
        owner = self.transfer_view.owner(self.transfer_view.snapshot)
        if not owner:
            self.render_activity()
            return
        def load():
            if retry:
                self.blip.request("retry", owner, retry)
            return self.blip.request("activity", owner)
        def finish(result=None, error=""):
            if owner != self.transfer_view.owner(self.transfer_view.snapshot):
                return
            self.send_activity_owner = owner
            self.send_activity = result.get("entries", []) if result else []
            self.send_activity_error = error
            self.render_activity()
        self.work("blip", "Read Send activity", load, finish, quiet=True, queue=True,
                  on_error=lambda error: finish(error=error))

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
        page.append(button("Sender permissions…", self.transfer_view.permissions))
        automatic = Gtk.Switch(active=self.preferences.get("auto_install_updates", False), valign=Gtk.Align.CENTER)
        automatic.set_tooltip_text("Updates install when myDrive is in the background and idle.")
        def toggle_automatic(switch, _property):
            self.change_preference("auto_install_updates", switch.get_active())
            self.sync_auto_install_timer()
            if self.preferences.get("auto_install_updates"):
                self.check_for_updates()
        automatic.connect("notify::active", toggle_automatic)
        page.append(row("Install updates automatically", "", automatic))
        page.append(button("Check for updates", lambda: self.check_for_updates(show_result=True)))
        if os.environ.get("APPIMAGE"):
            page.append(button("Add file manager actions", self.add_file_manager_actions))
        page.append(row("Advanced", "", menu([
            ("Syncthing settings…", lambda: self.files("Choose Syncthing config.xml", Gtk.FileChooserAction.OPEN,
                                                      lambda files: self.set_config(files[0]))),
            ("Open app data folder", lambda: self.open_path(DATA)),
        ])))

    def add_file_manager_actions(self):
        target = Path(GLib.get_user_data_dir())
        try:
            install_actions(os.environ.get("APPIMAGE", ""), target)
            self.announce("Send with myDrive is available in Files → Scripts and in Dolphin’s context menu.")
        except (OSError, ValueError) as error:
            self.announce(str(error))

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
        with TemporaryDirectory() as directory:
            text_file = Path(directory, "clipboard.txt")
            text = "  Received café 雪\r\n\r\n2\n3\n4\n5\n6\n7\n "
            for encoding in ("utf-8", "utf-8-sig", "utf-16", "utf-32"):
                text_file.write_bytes(text.encode(encoding))
                assert clipboard_text(text_file) == text
            text_file.write_bytes(b"binary\x00data")
            assert clipboard_text(text_file) is None
        self.snapshot = {"version": "v2 fixture", "folders": [
            {"id": "folder", "label": "A long studio folder label to verify truncation", "path": "/tmp/mydrive-fixture",
             "device_ids": ["device"], "status": {"state": "idle", "needFiles": 2, "pullErrors": 1}}
        ], "devices": [{"deviceID": "device", "name": "Studio laptop", "connection": {"connected": True}}]}
        snapshot = self.snapshot

        class FixtureSync:
            def request(self, action, **fields):
                issue = {"path": "Projects/Scene.blend", "error": "sharing violation",
                         "advice": "Close the app using the file, then rescan."}
                if action == "attention":
                    assert fields == {"folder_ids": ["folder"]}
                    return {"folder": {"errors": [issue]}}
                assert action == "errors" and fields == {"folder_id": "folder"}
                return {"errors": [issue]}

        self.sync = FixtureSync()
        self.render_sync()
        sync_page = self.pages["Sync"]
        warning = sync_page.get_first_child().get_next_sibling()
        assert warning.get_label() == "1 folder needs attention ›"

        def verify_attention():
            if self.pending["sync"]:
                return GLib.SOURCE_CONTINUE
            assert self.sync_attention and self.sync_issue_folder is None
            folder = sync_page.get_last_child()
            actions = folder.get_last_child()
            assert actions.get_first_child().get_label() == "Choose new location…"
            assert actions.get_first_child().get_next_sibling().get_label() == "Rescan"
            actions.get_last_child().emit("clicked")
            GLib.timeout_add(25, verify_detail)
            return GLib.SOURCE_REMOVE

        def verify_detail():
            if self.pending["sync"]:
                return GLib.SOURCE_CONTINUE
            assert self.sync_attention and self.sync_issue_folder == "folder"
            assert sync_page.get_last_child().get_label() == "Close the app using the file, then rescan."
            self.snapshot = snapshot
            self.leave_sync_attention()
            print("Linux GTK sync attention and folder error navigation passed", flush=True)
            self.quit()
            return GLib.SOURCE_REMOVE

        self.storage_view.tail_devices = [{"name": "Fixture device", "address": "100.64.0.1", "online": True}]
        self.storage_view.render_bookmarks()
        tailnet = self.pages["SMB Drives"].get_last_child()
        assert tailnet.get_label() == "Tailnet devices" and not tailnet.get_expanded()
        self.transfer_view.render()
        self.stack.set_visible_child_name("Send")
        chosen = []
        recipients = self.transfer_view.choose_recipient({f"{n}": f"Fixture device {n}" for n in range(10)},
                                                         chosen.append)
        assert not self.window.get_visible(), "The recipient picker should replace the compact menu."
        initial_size = self.window.get_default_size()

        class FixtureBlip:
            searches = []
            release_old_search = Event()

            def monitor(self, background):
                assert background
                return {"status": {"authenticated": True, "user_id": "00000000-0000-4000-8000-000000000001",
                                   "device_id": "00000000-0000-4000-8000-000000000002"},
                        "devices": [{"peer": "00000000-0000-4000-8000-000000000001:00000000-0000-4000-8000-000000000003",
                                     "name": "Fixture laptop", "name_known": True, "user_name": "Fixture owner"}]}

            def request(self, action, query):
                assert action == "search"
                self.searches.append(query)
                if query == "Older query":
                    assert self.release_old_search.wait(3)
                    return {"devices": [{"peer": "00000000-0000-4000-8000-000000000004:00000000-0000-4000-8000-000000000005",
                                         "user_name": "Stale result", "name": "Remote desktop", "name_known": True}]}
                if query == "Fixture@Example.test":
                    return {"people": [{"peer": "00000000-0000-4000-8000-000000000004:",
                                        "user_name": "Email match", "contact": "fixture@example.test"}]}
                return {"devices": [{"peer": "00000000-0000-4000-8000-000000000004:00000000-0000-4000-8000-000000000005",
                                     "user_name": "Remote person", "contact": "fixture@example.test",
                                     "name": "Remote desktop", "name_known": True}]}

        def verify_cold_send():
            view = self.transfer_view
            assert list(view.recipients().values()) == ["Fixture laptop"]
            size = self.window.get_default_size()
            assert size == initial_size and size[0] >= 344 and size[1] >= 420, (initial_size, size)
            print("Linux GTK fixed popup, cold Blip connection and one-click recipient passed", flush=True)
            peer = next(iter(view.recipients()))
            second = peer.partition(":")[0] + ":00000000-0000-4000-8000-000000000006"
            view.snapshot["devices"].extend([
                {"peer": second, "name": "Fixture studio", "name_known": True, "online": False},
                {"peer": view.recipient_owner, "name": "This fixture device", "name_known": True},
                {"peer": "00000000-0000-4000-8000-000000000009:00000000-0000-4000-8000-000000000008",
                 "name": "Fixture external", "name_known": True},
            ])
            view.recent_recipients = [{"peer": peer, "label": "Fixture laptop", "nickname": "Fixture laptop"}]
            view.render_recipient_rows()
            heading = view.recipient_rows.get_first_child()
            recipient = heading.get_next_sibling()
            other_owned = recipient.get_next_sibling()
            other_heading = other_owned.get_next_sibling()
            assert heading.get_label() == "My devices"
            assert other_owned.get_first_child().get_child().get_first_child().get_label() == "Fixture studio"
            assert other_heading.get_label() == "Other devices"
            assert other_heading.get_next_sibling() == view.recipient_rows.get_last_child()
            external = view.recipient_rows.get_last_child()
            archive = external.get_last_child()
            assert archive.get_icon_name() == "emblem-system-symbolic"
            external_peer = view.snapshot["devices"][-1]["peer"]
            requests = []
            update_recents = view.update_recents
            view.update_recents = lambda action, owner, **kwargs: requests.append((action, kwargs["target"]))
            remove_item = archive.get_popover().get_child().get_last_child()
            assert remove_item.get_label() == "Remove"
            remove_item.emit("clicked")
            view.recent_recipients.append({"peer": external_peer, "label": "Fixture external", "archived": "other"})
            view.render_recipient_rows()
            assert external_peer not in view.visible_recipients()
            section = view.recipient_rows.get_last_child()
            assert section.get_label() == "Archived"
            section.set_expanded(True)
            section.get_child().get_first_child().get_last_child().emit("clicked")
            assert requests == [("archive", external_peer), ("restore", external_peer)]
            view.recent_recipients.pop()
            view.update_recents = update_recents
            view.recent_recipients.append({"peer": external_peer, "label": "Fixture external"})
            view.render_recipient_rows()
            assert view.recipient_rows.get_first_child().get_label() == "Recent recipients"
            assert view.recipient_rows.get_first_child().get_next_sibling().get_next_sibling().get_label() == "My devices"
            view.recent_recipients.pop()
            view.render_recipient_rows()
            recipient = view.recipient_rows.get_first_child().get_next_sibling()
            calls = []
            view.choose_files = lambda **options: calls.append(options)
            view.paste = lambda selected, owner: calls.append(("paste", selected, owner))
            view.rename_recent = lambda *args: calls.append(("rename", *args))
            recipient.get_first_child().emit("clicked")
            edit = recipient.get_last_child()
            paste = edit.get_prev_sibling()
            assert edit.get_icon_name() == "emblem-system-symbolic"
            paste.emit("clicked")
            edit_item = edit.get_popover().get_child().get_last_child()
            assert edit_item.get_label() == "Edit name…"
            edit_item.emit("clicked")
            assert calls == [{"peer": peer, "owner": view.recipient_owner},
                             ("paste", peer, view.recipient_owner),
                             ("rename", view.recipient_owner, peer, "Fixture laptop", "Fixture laptop", False)]
            abandoned = []
            paste_picker = view.choose_recipient({peer: "Fixture laptop"}, chosen.append,
                                                  lambda: abandoned.append(True))
            actions = paste_picker.get_row_at_index(0).get_child()
            paste_action = actions.get_first_child().get_next_sibling()
            assert paste_action.get_icon_name() == "edit-paste-symbolic"
            assert actions.get_last_child().get_icon_name() == "document-edit-symbolic"
            paste_action.emit("clicked")
            paste_action.emit("clicked")
            assert abandoned == [True] and chosen == ["3"]
            assert calls[3:] == [("paste", peer, view.recipient_owner)]
            view.recipient_entry.set_text("Remote")
            view.recipient_entry.set_text("Remote person")
            GLib.timeout_add(25, verify_directory)

        def verify_directory():
            view = self.transfer_view
            if view.active_search is not None or view.search_lookup is not None:
                return GLib.SOURCE_CONTINUE
            heading = view.recipient_rows.get_first_child()
            assert heading.get_label() == "Suggestions"
            result = heading.get_next_sibling().get_first_child()
            assert result.get_child().get_first_child().get_label() == "Remote person"
            assert view.blip.searches == ["Remote person"]
            first = view.directory_recipients[0]
            account = first["peer"].partition(":")[0]
            second = {"peer": account + ":00000000-0000-4000-8000-000000000007",
                      "name": "Remote phone", "name_known": True}
            view.directory_recipients.append(second)
            labels = view.names(view.directory_recipients, view.catalog(view.recipient_owner))
            assert labels == {first["peer"]: "Remote person · Remote desktop", second["peer"]: "Remote person · Remote phone"}
            view.recipient_entry.set_text("Older query")
            GLib.timeout_add(25, replace_directory_query)
            return GLib.SOURCE_REMOVE

        def replace_directory_query():
            view = self.transfer_view
            if not view.blip.searches or view.blip.searches[-1] != "Older query":
                return GLib.SOURCE_CONTINUE
            view.recipient_entry.set_text(" Fixture@Example.test ")
            view.blip.release_old_search.set()
            GLib.timeout_add(25, verify_email_directory)
            return GLib.SOURCE_REMOVE

        def verify_email_directory():
            view = self.transfer_view
            assert not any(device.get("user_name") == "Stale result" for device in view.directory_recipients)
            if view.active_search is not None or view.search_lookup is not None:
                return GLib.SOURCE_CONTINUE
            heading = view.recipient_rows.get_first_child()
            assert heading.get_label() == "Suggestions"
            result = heading.get_next_sibling().get_first_child()
            assert result.get_child().get_first_child().get_label() == "Email match"
            assert result.get_child().get_last_child().get_label().startswith("fixture@example.test")
            assert view.blip.searches == ["Remote person", "Older query", "Fixture@Example.test"]
            print("Linux GTK type-ahead, email lookup, and stale result checks passed", flush=True)
            self.stack.set_visible_child_name("Sync")
            warning.emit("clicked")
            GLib.timeout_add(25, verify_attention)
            return GLib.SOURCE_REMOVE

        def verify():
            target = recipients.get_row_at_index(3)
            send = target.get_child().get_first_child()
            edit = target.get_child().get_last_child()
            assert edit.get_prev_sibling().get_icon_name() == "edit-paste-symbolic"
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
    selection = sys.argv[2:] if sys.argv[1:2] == ["--send-files"] else []
    paths = [os.path.abspath(path) for path in selection]
    sys.exit(MyDrive(fixture).run([sys.argv[0], *paths]))
