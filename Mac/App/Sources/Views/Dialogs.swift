// Dialogs shown inside the popup (or full window). Setup forms live here per
// docs/NATIVE-UI.md; every dialog returns to the underlying view on close.
import AppKit
import SwiftUI

struct DialogContainer: View {
    @EnvironmentObject var app: AppState
    let dialog: DialogKind
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                content
                    .padding(10)
            }
            .frame(maxHeight: 350)
        }
    }

    private var title: String {
        switch dialog {
        case .share: return "Sync a folder"
        case .devices: return "Devices"
        case .pending(_, let label): return "Pending files · \(label)"
        case .errors(_, let label): return "Folder errors · \(label)"
        case .versions(_, let label): return "Saved versions · \(label)"
        case .alternatives(_, let label): return "Saved edits · \(label)"
        case .requestFix(_, let label): return "Request a fix · \(label)"
        case .bookmarkEditor(let bookmark):
            return bookmark == nil ? "Add storage connection" : "Edit connection"
        case .smbAddress: return "Open shared folder"
        case .syncSettings: return "Sync connection"
        case .selectionHelp: return "Selection help"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch dialog {
        case .share: ShareDialog(close: close)
        case .devices: DevicesDialog()
        case .pending: PendingDialog()
        case .errors: ErrorsDialog()
        case .versions: VersionsDialog(close: close)
        case .alternatives: AlternativesDialog()
        case .requestFix(let folderId, _): RequestFixDialog(folderId: folderId, close: close)
        case .bookmarkEditor(let bookmark): BookmarkEditorDialog(bookmark: bookmark, close: close)
        case .smbAddress: SmbAddressDialog(close: close)
        case .syncSettings: SyncSettingsDialog(close: close)
        case .selectionHelp: SelectionHelpDialog(close: close)
        }
    }
}

// MARK: - Share

struct ShareDialog: View {
    @EnvironmentObject var app: AppState
    let close: () -> Void
    @State private var path = PrefStore.shared.preferences.lastSyncFolder
    @State private var deviceId = PrefStore.shared.preferences.lastSyncDevice
    @State private var skipBuild = true

    private var devices: [SyncthingDevice] {
        (app.snapshot?.devices ?? []).filter { !$0.isLocal && !$0.paused }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Folder", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .disabled(app.busy != nil)
            HStack(spacing: 6) {
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runMyDrivePicker() == .OK, let url = panel.url {
                        path = url.path
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
                Button("This project") { path = Paths.projectFolder() }
                    .font(.system(size: 11))
                    .controlSize(.small)
                Spacer()
            }
            Picker("Share with", selection: $deviceId) {
                ForEach(devices) { device in
                    Text(device.displayName).tag(device.deviceID)
                }
            }
            .font(.system(size: 12))
            Toggle("Skip build, SDK and cache folders", isOn: $skipBuild)
                .font(.system(size: 11))
            Text("Subfolders can sync with different devices from their parent. New shares skip generated build/cache folders when selected; existing rules are preserved. Accept new shares on the other device.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .font(.system(size: 12))
                Button("Start syncing") {
                    app.shareFolder(path: path, deviceId: deviceId, skipBuild: skipBuild)
                    close()
                }
                .font(.system(size: 12, weight: .semibold))
                .disabled(path.isEmpty || deviceId.isEmpty || app.busy != nil)
            }
        }
        .onAppear {
            if !app.shareFolderPath.isEmpty {path=app.shareFolderPath;app.shareFolderPath=""}
            if !devices.contains(where: { $0.deviceID == deviceId }) {
                deviceId = devices.first(where: { $0.connected })?.deviceID
                    ?? devices.first?.deviceID ?? ""
            }
        }
    }
}

// MARK: - Devices

struct DevicesDialog: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let devices = app.snapshot?.devices, !devices.isEmpty {
                ForEach(devices) { device in
                    DeviceRow(device: device)
                }
            } else {
                Text("No other devices configured.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Syncthing \(app.snapshot?.version ?? "—") · Status refreshes while this view is open")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }
}

// MARK: - Pending / Errors

struct PendingDialog: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if app.pendingItems.isEmpty {
                Text("No pending files on this computer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.pendingItems) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(item.path)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.path)
                        Spacer(minLength: 0)
                    }
                }
                Text("Showing up to 50 pending files. Files resume automatically when a device with the content is connected.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }
}

struct ErrorsDialog: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if app.errorItems.isEmpty {
                Text(app.snapshot?.folders.first { $0.id == app.syncInfo?.folderId }?.error ?? "No file errors.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.errorItems) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.path)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.path)
                        Text(item.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .help(item.message)
                        if !item.advice.isEmpty {
                            Text(item.advice).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Versions

struct VersionsDialog: View {
    @EnvironmentObject var app: AppState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Restoring replaces the current file and syncs that change to other devices. myDrive backs up the current local file before restoring. History here covers changes received from other devices.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if app.versionRows.isEmpty {
                Text("No saved versions yet. Versions appear after files are replaced or deleted by another device.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.versionRows) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.path)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(group.path)
                        ForEach(group.versions) { version in
                            HStack(spacing: 6) {
                                Text("\(Format.modified(version.versionTime)) · \(Format.bytes(version.size))")
                                    .font(.system(size: 10))
                                Spacer(minLength: 4)
                                Button("Restore this version") {
                                    app.restoreVersion(group, version)
                                    close()
                                }
                                .font(.system(size: 10))
                                .controlSize(.small)
                                .disabled(app.busy != nil)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

// MARK: - Saved alternative edits

struct AlternativesDialog: View {
    @EnvironmentObject var app: AppState

    private var alternatives: [BrowseEntry] {
        (app.syncBrowse?.result.entries ?? []).filter(\.isAlternative)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Two different offline edits to the same file are preserved as alternatives instead of being discarded. Open the copy you want to keep; the others stay in the folder until you delete them.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if alternatives.isEmpty {
                Text("No saved edits right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(alternatives) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(entry.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.name)
                        Spacer(minLength: 4)
                        Button("Open") { app.openSyncedFile(entry) }
                            .font(.system(size: 10))
                            .controlSize(.small)
                            .disabled(app.busy != nil)
                    }
                }
            }
        }
    }
}

// MARK: - SMB address

struct SmbAddressDialog: View {
    @EnvironmentObject var app: AppState
    let close: () -> Void
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("smb://computer/share", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Text("This opens the network copy with your saved macOS credentials. Syncing to a network copy needs a Syncthing folder instead.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .font(.system(size: 12))
                Button("Connect and open") {
                    app.openSmbAddress(address)
                    close()
                }
                .font(.system(size: 12, weight: .semibold))
                .disabled(address.isEmpty || app.busy != nil)
            }
        }
    }
}

// MARK: - Syncthing connection

struct SyncSettingsDialog: View {
    @EnvironmentObject var app: AppState
    let close: () -> Void
    @State private var manual = PrefStore.shared.preferences.syncthingManual
    @State private var endpoint = PrefStore.shared.preferences.syncthingEndpoint
    @State private var configPath = PrefStore.shared.preferences.syncthingConfigPath
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use a manually entered local API address", isOn: $manual)
                .font(.system(size: 12))
            if manual {
                Text("API address")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("http://127.0.0.1:8384/", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("API key (blank keeps the saved key)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            } else {
                Text("config.xml")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("", text: $configPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.directoryURL = URL(fileURLWithPath: SyncthingService.findConfig()
                            ?? (configPath as NSString).deletingLastPathComponent)
                        if panel.runMyDrivePicker() == .OK, let url = panel.url {
                            configPath = url.path
                        }
                    }
                    .font(.system(size: 11))
                    .controlSize(.small)
                }
            }
            Text("myDrive reuses your Syncthing configuration and starts its engine in the background. If missing, it installs the engine automatically. Manual connections use only the entered address.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .font(.system(size: 12))
                Button("Save") {
                    PrefStore.shared.update {
                        $0.syncthingManual = manual
                        $0.syncthingEndpoint = endpoint
                        $0.syncthingConfigPath = configPath
                    }
                    if !apiKey.isEmpty {
                        try? Keychain.saveSyncthingAPIKey(apiKey)
                    }
                    app.settingsPref = PrefStore.shared.preferences
                    app.syncthing.rediscover()
                    Task { await app.refreshSnapshot() }
                    close()
                }
                .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

// MARK: - Storage bookmark editor

struct BookmarkEditorDialog: View {
    @EnvironmentObject var app: AppState
    let bookmark: Bookmark?
    let close: () -> Void

    @State private var protocolKind: String
    @State private var nickname: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password = ""
    @State private var keyPath = ""
    @State private var passphrase = ""
    @State private var sessionToken = ""
    @State private var bucket = ""
    @State private var region = "us-east-1"
    @State private var testResult = ""

    private let protocols: [(String, String)] = [
        ("local", "Local folder · This Mac"),
        ("sftp", "SFTP · SSH file transfer"),
        ("webdav", "WebDAV · Nextcloud and servers"),
        ("s3", "S3 · AWS, B2, Wasabi, MinIO"),
    ]

    init(bookmark: Bookmark?, close: @escaping () -> Void) {
        self.bookmark = bookmark
        self.close = close
        let existing = bookmark ?? Bookmark()
        _protocolKind = State(initialValue: existing.protocolKind == "smb" ? "local" : existing.protocolKind)
        _nickname = State(initialValue: existing.nickname)
        _host = State(initialValue: existing.host)
        _port = State(initialValue: existing.port > 0 ? String(existing.port) : "22")
        _username = State(initialValue: existing.username)
        _bucket = State(initialValue: existing.options["bucket"] ?? "")
        _region = State(initialValue: existing.options["region"] ?? "us-east-1")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Type", selection: $protocolKind) {
                ForEach(protocols, id: \.0) { kind in
                    Text(kind.1).tag(kind.0)
                }
            }
            .font(.system(size: 12))
            .pickerStyle(.menu)
            TextField("Name", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            if protocolKind == "local" {
                HStack(spacing: 6) {
                    TextField("Folder", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runMyDrivePicker() == .OK, let url = panel.url { host = url.path }
                    }
                    .font(.system(size: 11))
                    .controlSize(.small)
                }
            } else {
                TextField(protocolKind == "webdav" || protocolKind == "s3"
                          ? "Server URL (https://…)" : "Host", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if protocolKind == "sftp" {
                    HStack(spacing: 6) {
                        TextField("Port", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 70)
                        TextField("User", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    SecureField("Password (blank keeps saved)", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    HStack(spacing: 6) {
                        TextField("Private key file (optional)", text: $keyPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .truncationMode(.middle)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            if panel.runMyDrivePicker() == .OK, let url = panel.url { keyPath = url.path }
                        }
                        .font(.system(size: 11))
                        .controlSize(.small)
                    }
                    SecureField("Key passphrase (blank keeps saved)", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                } else {
                    TextField("User", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    SecureField(protocolKind == "s3" ? "Secret access key" : "Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    if protocolKind == "s3" {
                        TextField("Bucket", text: $bucket)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        TextField("Region", text: $region)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        SecureField("Session token (optional)", text: $sessionToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                }
            }
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.system(size: 10))
                    .foregroundStyle(testResult.hasPrefix("Connection successful") ? Color.green : Color.red)
            }
            HStack {
                Button("Test") { runTest() }
                    .font(.system(size: 12))
                    .disabled(!canSave || app.busy != nil)
                Spacer()
                Button("Cancel") { close() }
                    .font(.system(size: 12))
                Button("Save") { save() }
                    .font(.system(size: 12, weight: .semibold))
                    .disabled(!canSave || app.busy != nil)
            }
        }
    }

    private var canSave: Bool {
        if nickname.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if protocolKind == "local" { return !host.isEmpty }
        if host.isEmpty { return false }
        if protocolKind == "s3" && bucket.isEmpty { return false }
        return true
    }

    private func buildBookmark() -> Bookmark {
        var updated = bookmark ?? Bookmark()
        updated.nickname = nickname
        updated.protocolKind = protocolKind
        updated.host = host
        updated.port = Int(port) ?? (protocolKind == "sftp" ? 22 : 0)
        updated.username = username
        updated.credentialsRef = "myDrive/\(updated.id)"
        if protocolKind == "s3" {
            updated.options["bucket"] = bucket
            updated.options["region"] = region
        }
        return updated
    }

    private func buildCredentials() throws -> Credentials {
        let existing = Keychain.readCredentials(id: (bookmark?.id ?? Bookmark().id))
        var credentials = Credentials()
        credentials.password = password.isEmpty ? existing.password : password
        credentials.passphrase = passphrase.isEmpty ? existing.passphrase : passphrase
        credentials.sessionToken = sessionToken.isEmpty ? existing.sessionToken : sessionToken
        if !keyPath.isEmpty {
            credentials.privateKey = try String(contentsOf: URL(fileURLWithPath: keyPath), encoding: .utf8)
        } else {
            credentials.privateKey = existing.privateKey
        }
        return credentials
    }

    private func runTest() {
        let candidate = buildBookmark()
        let credentials = (try? buildCredentials()) ?? Credentials()
        testResult = "Testing…"
        app.testBookmark(candidate, credentials: credentials) { result in
            testResult = result
        }
    }

    private func save() {
        let candidate = buildBookmark()
        guard let credentials = try? buildCredentials() else {
            testResult = "Cannot read the private key file."
            return
        }
        app.saveBookmark(candidate, credentials: credentials)
        close()
    }
}

// MARK: - Selection help

/// Sends a whitelisted fix request to a peer over the shared folder.
struct RequestFixDialog: View {
    @EnvironmentObject var app: AppState
    let folderId: String
    let close: () -> Void

    @State private var fix: FixKindRemote = .rescan
    @State private var deviceId = FixRequestStore.anyDevice

    private var peers: [SyncthingDevice] {
        (app.snapshot?.devices ?? []).filter { !$0.isLocal && !$0.paused }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Asks the other computer's myDrive to run a safe fix on its copy of this folder. The request travels inside the synced folder and runs only when the peer accepts it.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Picker("Fix", selection: $fix) {
                ForEach(FixKindRemote.allCases, id: \.rawValue) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .font(.system(size: 12))
            .pickerStyle(.menu)
            Text(fix.effect)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Picker("Device", selection: $deviceId) {
                Text("Any device sharing the folder").tag(FixRequestStore.anyDevice)
                ForEach(peers) { peer in
                    Text("\(peer.displayName)\(peer.connected ? " · connected" : " · offline")")
                        .tag(peer.deviceID)
                }
            }
            .font(.system(size: 12))
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .font(.system(size: 12))
                Button("Send request") {
                    app.sendFixRequest(folderId: folderId, deviceId: deviceId, fix: fix)
                    close()
                }
                .font(.system(size: 12, weight: .semibold))
                .disabled(app.busy != nil || peers.isEmpty)
            }
        }
        .onAppear {
            if !peers.contains(where: { $0.deviceID == deviceId }) {
                deviceId = peers.first(where: { $0.connected })?.deviceID
                    ?? peers.first?.deviceID ?? FixRequestStore.anyDevice
            }
        }
    }
}

struct SelectionHelpDialog: View {
    @EnvironmentObject var app: AppState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync and Stop apply immediately on this computer, for all devices sharing this Syncthing folder. Stop keeps existing copies. A specific file selection overrides a containing folder. Default rules retain your existing Syncthing selection.")
                .font(.system(size: 11))
            HStack {
                Spacer()
                Button("Got it") { close() }
                    .font(.system(size: 12, weight: .semibold))
            }
        }
    }
}
