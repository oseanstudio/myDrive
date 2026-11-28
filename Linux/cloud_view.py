"""Cloud account browsing and backup controls for the compact and expanded windows."""

from pathlib import Path
from time import monotonic

from gi.repository import Gtk

from services import DATA, core
from ui_widgets import button, clear, label, menu, row


class CloudView:
    def __init__(self, app, page):
        self.app = app
        self.page = page
        self.accounts = []
        self.jobs = []
        self.entries = []
        self.account = self.path = self.message = ""
        self.truncated = self.busy = False
        self.has_profile = False
        self.next_schedule = self.last_status = 0
        self.render()

    @property
    def active(self):
        return any(item["report"]["phase"] in ("queued", "running") for item in self.jobs)

    def start(self):
        self.has_profile = (DATA / "cloud" / "state.json").is_file()
        self.tick()

    def tick(self):
        if not self.has_profile or self.app.pending["cloud"]:
            return
        now = monotonic()
        scheduled = any(item["job"]["interval"] and not item["job"]["paused"] for item in self.jobs)
        visible = self.app.main_window_visible() and self.app.stack.get_visible_child_name() == "Cloud Drives"
        if now >= self.next_schedule and (scheduled or self.next_schedule == 0):
            self.next_schedule = now + 60
            self.refresh(check_schedule=True)
        elif self.active and (visible or now - self.last_status >= 30):
            self.refresh()

    def refresh(self, check_schedule=False):
        def read():
            if check_schedule:
                core("cloud.tick")
            return core("cloud.status")

        self.app.work("cloud", "", read, self.update, quiet=True, on_error=self.failed)

    def update(self, snapshot):
        self.last_status = monotonic()
        self.accounts, self.jobs = snapshot["accounts"], snapshot["jobs"]
        self.render()

    def failed(self, error):
        self.busy = False
        self.message = error
        self.render()

    def change(self, title, action, payload, accepted=None, timeout=120):
        if self.busy:
            return
        self.busy = True
        self.message = title
        self.render()

        def changed(reply):
            self.message = ""
            self.busy = False
            if accepted:
                accepted(reply)
            self.render()
            self.refresh()

        self.app.work("cloud", "", lambda: core("cloud." + action, timeout=timeout, payload=payload),
                      changed, quiet=True, on_error=self.failed)

    def browse(self, account, path=""):
        def opened(reply):
            self.account, self.path = account, path
            self.entries, self.truncated = reply["entries"], reply["truncated"]

        self.change("Opening cloud folder…", "browse", {"account": account, "path": path}, opened)

    def back(self):
        self.account = self.path = self.message = ""
        self.entries = []
        self.render()

    def connect(self):
        providers = {"dropbox": "Dropbox", "onedrive": "OneDrive", "drive": "Google Drive"}
        provider = Gtk.ComboBoxText()
        for key, name in providers.items():
            provider.append(key, name)
        provider.set_active(0)
        name = Gtk.Entry(placeholder_text="Account name (optional)")
        identity = Gtk.Entry(placeholder_text="Google Drive client ID", max_length=512)
        secret = Gtk.Entry(placeholder_text="Google Drive client secret", max_length=512, visibility=False)
        help_link = Gtk.LinkButton(uri="https://rclone.org/drive/#making-your-own-client-id",
                                   label="Create a Google Drive desktop client")
        google_fields = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, visible=False)
        for field in (help_link, identity, secret):
            google_fields.append(field)
        provider.connect("changed", lambda item: google_fields.set_visible(item.get_active_id() == "drive"))

        def save():
            key = provider.get_active_id()
            caption = name.get_text().strip() or providers[key]
            def connected(_):
                self.has_profile = True
            self.change("Preparing Cloud Drives. Complete sign-in in your browser…", "connect",
                        {"provider": key, "name": caption, "client_id": identity.get_text() if key == "drive" else "",
                         "client_secret": secret.get_text() if key == "drive" else ""}, connected, timeout=None)
            secret.set_text("")

        self.app.dialog("Connect cloud account", "Connect", [label("Provider"), provider, name, google_fields], save)

    def reconnect(self, account):
        self.change("Complete sign-in in your browser…", "connect", {"account": account}, timeout=None)

    def add_backup(self):
        account, path = self.account, self.path

        def picked(paths):
            source = paths[0]
            destination = Gtk.Entry(text=path or "Backups/" + Path(source).name)
            schedule = Gtk.ComboBoxText()
            for value, title in ((0, "Run manually"), (60, "Hourly"), (1440, "Daily")):
                schedule.append(str(value), title)
            schedule.set_active(0)

            def save():
                interval = int(schedule.get_active_id())
                def added(_):
                    self.back()
                    if interval:
                        self.next_schedule = 0
                        self.tick()
                self.change("Saving backup…", "add", {
                    "account": account, "source": source, "path": destination.get_text().strip(),
                    "interval": interval,
                }, added)

            self.app.dialog("Back up a folder", "Save backup", [
                label(source), label("Cloud destination"), destination, label("Schedule"), schedule,
            ], save)

        self.app.files("Choose a local folder to back up", Gtk.FileChooserAction.SELECT_FOLDER, picked)

    def download(self, item):
        account = self.account
        self.app.files("Choose where to save " + item["name"], Gtk.FileChooserAction.SELECT_FOLDER,
                       lambda paths: self.change("Downloading…", "download", {
                           "account": account, "path": item["path"], "destination": str(Path(paths[0]) / item["name"]),
                       }, timeout=None))

    def pause(self, job, paused):
        def applied(_):
            if not paused:
                self.next_schedule = 0
        self.change("Updating schedule…", "pause", {"job": job, "paused": paused}, applied)

    def confirm(self, title, detail, caption, action, payload):
        self.app.confirm(title, detail, caption, lambda: self.change(caption + "…", action, payload))

    def entry_row(self, caption, action, options=None):
        line = Gtk.Box(spacing=5)
        select = button(caption, action)
        select.set_child(label(caption))
        select.update_property([Gtk.AccessibleProperty.LABEL], [caption])
        select.set_hexpand(True)
        line.append(select)
        if options:
            line.append(menu(options, title="Options"))
        return line

    def render(self):
        clear(self.page)
        if self.message:
            message = label(self.message)
            message.set_wrap(True)
            self.page.append(message)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        body.set_sensitive(not self.busy)
        self.page.append(body)
        if self.account:
            self.render_folder(body)
            return
        body.append(button("Connect account…", self.connect))
        captions = {account["id"]: account["name"] for account in self.accounts}
        for account in self.accounts:
            key, name = account["id"], account["name"]
            body.append(self.entry_row(name, lambda key=key: self.browse(key), [
                ("Sign in again…", lambda key=key: self.reconnect(key)),
                ("Disconnect…", lambda key=key, name=name: self.confirm(
                    "Disconnect " + name + "?", "The cloud files will stay in your account.",
                    "Disconnect", "disconnect", {"account": key})),
            ]))
        if self.jobs:
            body.append(label("Backups", "heading"))
        for item in self.jobs:
            body.append(self.backup_row(item, captions))

    def render_folder(self, body):
        header = Gtk.Box(spacing=5)
        header.append(button("Accounts", self.back))
        if self.path:
            header.append(button("Up", lambda: self.browse(self.account, self.path.rpartition("/")[0])))
        header.append(Gtk.Box(hexpand=True))
        header.append(button("Back up a folder…", self.add_backup))
        body.append(header)
        caption = next((account["name"] for account in self.accounts if account["id"] == self.account), "Cloud Drives")
        body.append(label(self.path or caption, "heading"))
        for item in self.entries:
            body.append(self.entry_row(item["name"] + ("  ›" if item["folder"] else ""),
                        lambda item=item: self.browse(self.account, item["path"])
                        if item["folder"] else self.download(item)))
        if not self.entries:
            body.append(label("Empty folder", "dim-label"))
        if self.truncated:
            body.append(label("Showing the first 4,000 entries.", "dim-label"))

    def backup_row(self, item, captions):
        job, report = item["job"], item["report"]
        key, account, path, paused = job["id"], job["account"], job["folder"], job["paused"]
        detail = {
            "queued": "Queued", "running": f"Backing up · {report['files']} files copied",
            "complete": "Backup complete", "failed": report["message"],
        }.get(report["phase"], "Ready to back up")
        running = report["phase"] in ("queued", "running")
        if paused and not running:
            detail = "Schedule paused · " + detail
        actions = []
        if job["interval"]:
            actions.append(("Resume schedule" if paused else "Pause schedule", lambda: self.pause(key, not paused)))
        actions.extend([
            ("Browse backup", lambda: self.browse(account, path)),
            ("Browse previous versions", lambda: self.browse(account, "myDrive Versions/" + key)),
            ("Remove backup…", lambda: self.confirm("Remove backup schedule?", "The cloud files will stay in your account.",
                                                    "Remove", "remove", {"job": key})),
        ])
        run = button("Run now", lambda: self.change("Starting backup…", "run", {"job": key}))
        run.set_sensitive(not running)
        return row(captions.get(account, "Cloud") + " · " + path, detail, run, menu(actions, title="Backup options"))
