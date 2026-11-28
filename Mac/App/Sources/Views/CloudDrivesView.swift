import AppKit
import SwiftUI

@MainActor
final class CloudDrivesState: NSObject, ObservableObject {
    @Published private(set) var accounts: [JSON] = []
    @Published private(set) var jobs: [JSON] = []
    @Published private(set) var entries: [JSON] = []
    @Published private(set) var account = ""
    @Published private(set) var path = ""
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    @Published private(set) var truncated = false
    private var refreshing = false
    private var hasProfile = false
    private var lastSchedule = Date.distantPast
    private var lastStatus = Date.distantPast

    var active: Bool {
        jobs.contains { ["queued", "running"].contains($0.dict("report").str("phase")) }
    }
    private var scheduled: Bool {
        jobs.contains { $0.dict("job").int64("interval") > 0 && !$0.dict("job").bool("paused") }
    }
    private var accountName: String { accounts.first { $0.str("id") == account }?.str("name") ?? "Cloud Drives" }
    var title: String { path.isEmpty ? accountName : path }

    private func call(_ action: String, _ payload: JSON = [:], timeout: TimeInterval? = 100) async throws -> JSON {
        let reply = try await CoreBridge.shared.call(action: "cloud." + action, request: [
            "data_dir": Paths.dataDir.path, "payload": payload
        ], timeout: timeout)
        return reply as? JSON ?? [:]
    }

    func start() {
        hasProfile = FileManager.default.fileExists(atPath: Paths.appSupport.appendingPathComponent("cloud/state.json").path)
        if hasProfile { tick(viewing: false) }
    }

    func tick(viewing: Bool) {
        guard hasProfile, !refreshing else { return }
        let due = Date().timeIntervalSince(lastSchedule) >= 60
        if due && (scheduled || lastSchedule == .distantPast) {
            Task { await refresh(checkSchedule: true) }
        } else if active && (viewing || Date().timeIntervalSince(lastStatus) >= 30) {
            Task { await refresh() }
        }
    }

    func refresh(checkSchedule: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            if checkSchedule {
                lastSchedule = Date()
                _ = try await call("tick")
            }
            let snapshot = try await call("status")
            lastStatus = Date()
            accounts = snapshot.array("accounts").compactMap { $0 as? JSON }
            jobs = snapshot.array("jobs").compactMap { $0 as? JSON }
        } catch {
            if !busy { message = error.localizedDescription }
        }
    }

    private func perform(_ label: String, work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = label
        Task {
            do {
                try await work()
                message = ""
            } catch {
                message = error.localizedDescription
            }
            await refresh()
            busy = false
        }
    }

    func back() {
        account = ""
        path = ""
        entries = []
        message = ""
    }

    func browse(_ id: String, _ folder: String = "") {
        perform("Opening cloud folder…") {
            let reply = try await self.call("browse", ["account": id, "path": folder])
            self.account = id
            self.path = folder
            self.entries = reply.array("entries").compactMap { $0 as? JSON }
            self.truncated = reply.bool("truncated")
        }
    }

    func browseParent() {
        browse(account, path.split(separator: "/").dropLast().joined(separator: "/"))
    }

    func connect(_ provider: String, name: String) {
        let alert = NSAlert()
        alert.messageText = "Connect \(name)"
        let google = provider == "drive"
        alert.informativeText = google ? "Enter your Google desktop client credentials, then sign in in your browser."
            : "Sign in to your cloud account in your browser."
        let field = NSTextField()
        field.placeholderString = "Account name (optional)"
        let identity = NSTextField()
        identity.placeholderString = "Google Drive client ID"
        let secret = NSSecureTextField()
        secret.placeholderString = "Google Drive client secret"
        let help = NSButton(title: "Create a Google Drive desktop client", target: self, action: #selector(googleClientHelp))
        let fields = NSStackView(views: google ? [field, identity, secret, help] : [field])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 5
        for input in [field, identity, secret] {
            input.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        fields.setFrameSize(fields.fittingSize)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: JSON = ["provider": provider, "name": entered.isEmpty ? name : entered,
                             "client_id": identity.stringValue, "client_secret": secret.stringValue]
        secret.stringValue = ""
        perform("Preparing Cloud Drives. Complete sign-in in your browser…") {
            _ = try await self.call("connect", payload, timeout: nil)
            self.hasProfile = true
        }
    }

    @objc private func googleClientHelp() {
        if let url = URL(string: "https://rclone.org/drive/#making-your-own-client-id") {
            NSWorkspace.shared.open(url)
        }
    }

    func reconnect(_ id: String) {
        perform("Complete sign-in in your browser…") {
            _ = try await self.call("connect", ["account": id], timeout: nil)
        }
    }

    func addBackup() {
        let selectedAccount = account
        let picker = NSOpenPanel()
        picker.title = "Choose a local folder to back up"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        guard picker.runMyDrivePicker() == .OK, let folder = picker.url else { return }

        let alert = NSAlert()
        alert.messageText = "Back up a folder"
        alert.informativeText = folder.path
        let destination = NSTextField(string: path.isEmpty ? "Backups/" + folder.lastPathComponent : path)
        destination.placeholderString = "Cloud destination"
        destination.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let schedule = NSPopUpButton()
        schedule.addItems(withTitles: ["Run manually", "Hourly", "Daily"])
        let fields = NSStackView(views: [NSTextField(labelWithString: "Cloud destination"), destination,
                                          NSTextField(labelWithString: "Schedule"), schedule])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 5
        fields.setFrameSize(fields.fittingSize)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Save backup")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let interval = [0, 60, 1440][schedule.indexOfSelectedItem]
        perform("Saving backup…") {
            _ = try await self.call("add", ["account": selectedAccount, "source": folder.path,
                    "path": destination.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), "interval": interval])
            self.back()
            if interval > 0 { _ = try await self.call("tick"); self.lastSchedule = Date() }
        }
    }

    func download(_ item: JSON) {
        let selectedAccount = account
        let picker = NSOpenPanel()
        picker.title = "Choose where to save " + item.str("name")
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard picker.runMyDrivePicker() == .OK, let folder = picker.url else { return }
        let destination = folder.appendingPathComponent(item.str("name")).path
        perform("Downloading…") {
            _ = try await self.call("download", ["account": selectedAccount, "path": item.str("path"),
                                                  "destination": destination], timeout: nil)
        }
    }

    func run(_ id: String) {
        perform("Starting backup…") { _ = try await self.call("run", ["job": id]) }
    }

    func pause(_ id: String, _ paused: Bool) {
        perform("Updating schedule…") {
            _ = try await self.call("pause", ["job": id, "paused": paused])
            if !paused { self.lastSchedule = .distantPast }
        }
    }

    func confirm(_ title: String, button: String, action: String, payload: JSON) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(button + "…") { _ = try await self.call(action, payload) }
    }
}

struct CloudDrivesView: View {
    @ObservedObject var model: CloudDrivesState

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if !model.message.isEmpty {
                HStack(spacing: 5) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.message).font(.caption)
                }
            }
            Group {
                if model.account.isEmpty { accounts } else { folder }
            }
            .disabled(model.busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.refresh() }
    }

    private var accounts: some View {
        Group {
            Menu("Connect account…") {
                Button("Dropbox") { model.connect("dropbox", name: "Dropbox") }
                Button("OneDrive") { model.connect("onedrive", name: "OneDrive") }
                Button("Google Drive") { model.connect("drive", name: "Google Drive") }
            }
            ForEach(model.accounts, id: \.cloudID) { account in
                let id = account.str("id")
                HStack {
                    entry(account.str("name"), icon: "cloud") { model.browse(id) }
                    menu("Account options") {
                        Button("Sign in again…") { model.reconnect(id) }
                        Button("Disconnect…") {
                            model.confirm("Disconnect \(account.str("name"))?", button: "Disconnect",
                                          action: "disconnect", payload: ["account": id])
                        }
                    }
                }
            }
            if !model.jobs.isEmpty { Text("Backups").font(.headline) }
            ForEach(model.jobs, id: \.cloudJobID) { backup($0) }
        }
    }

    private var folder: some View {
        Group {
            HStack(spacing: 5) {
                Button("Accounts") { model.back() }
                if !model.path.isEmpty { Button("Up") { model.browseParent() } }
                Spacer()
                Button("Back up a folder…") { model.addBackup() }
            }
            Text(model.title).font(.headline).lineLimit(1).help(model.title)
            ForEach(model.entries, id: \.cloudPath) { item in
                let isFolder = item.bool("folder")
                entry(item.str("name"), icon: isFolder ? "folder" : "doc") {
                    if isFolder { model.browse(model.account, item.str("path")) } else { model.download(item) }
                }
            }
            if model.entries.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
            if model.truncated { Text("Showing the first 4,000 entries.").font(.caption) }
        }
    }

    private func backup(_ entry: JSON) -> some View {
        let job = entry.dict("job"), report = entry.dict("report")
        let id = job.str("id"), account = job.str("account"), paused = job.bool("paused")
        let phase = report.str("phase"), running = ["queued", "running"].contains(phase)
        let name = model.accounts.first { $0.str("id") == account }?.str("name") ?? "Cloud"
        let detail: String
        switch phase {
        case "queued": detail = "Queued"
        case "running": detail = "Backing up · \(report.int64("files")) files copied"
        case "complete": detail = "Backup complete"
        case "failed": detail = report.str("message")
        default: detail = "Ready to back up"
        }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name + " · " + job.str("folder")).lineLimit(1).help(job.str("source"))
                Text(paused && !running ? "Schedule paused · " + detail : detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Run now") { model.run(id) }.disabled(running)
            menu("Backup options") {
                if job.int64("interval") > 0 {
                    Button(paused ? "Resume schedule" : "Pause schedule") { model.pause(id, !paused) }
                }
                Button("Browse backup") { model.browse(account, job.str("folder")) }
                Button("Browse previous versions") { model.browse(account, "myDrive Versions/" + id) }
                Button("Remove backup…") {
                    model.confirm("Remove backup schedule?", button: "Remove", action: "remove", payload: ["job": id])
                }
            }
        }
    }

    private func entry(_ name: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: icon)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private func menu<Items: View>(_ title: String, @ViewBuilder content: () -> Items) -> some View {
        Menu(content: content) { Image(systemName: "ellipsis.circle").accessibilityLabel(title) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(title)
    }
}

private extension Dictionary where Key == String, Value == Any {
    var cloudID: String { str("id") }
    var cloudJobID: String { dict("job").str("id") }
    var cloudPath: String { str("path") }
}
