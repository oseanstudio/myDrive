// Central observable state shared by the popover and the full window.
// All Syncthing/file work runs through the Rust core; UI actions run as
// cancellable tasks that append to the activity log.
import AppKit
import Combine
import Foundation

enum PopupViewKind: String, CaseIterable, Identifiable {
    case sync, syncFiles, syncInfo, syncAttention, connections, activity, transfers, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sync: return "Syncthing"
        case .syncFiles: return "Sync files"
        case .syncInfo, .syncAttention: return "Syncthing"
        case .connections: return "SMB Drives"
        case .activity: return "Activity"
        case .transfers: return "Blip"
        case .settings: return "Settings"
        }
    }
    var tab: PopupViewKind {
        switch self {
        case .syncFiles, .syncInfo, .syncAttention: return .sync
        default: return self
        }
    }
    static var tabs: [PopupViewKind] { [.transfers, .sync, .connections, .activity, .settings] }
}

enum StatusTint {
    case green, orange, red, gray
}

struct BusyState {
    let label: String
    let task: Task<Void, Never>
}

struct Banner: Identifiable {
    enum Kind { case error, info }
    let kind: Kind
    let title: String
    let message: String
    var id = UUID()
}

struct SyncBrowseState {
    let folderId: String
    let label: String
    var path: String
    var result: BrowseResult
}

struct StorageBrowseState {
    let bookmark: Bookmark
    var path: String
    var files: [RemoteFile]
}

struct SyncInfoState {
    let folderId: String
    let label: String
    let action: String
    let title: String
    var errors: Bool { action == "errors" }
}

struct VersionGroup: Identifiable {
    let path: String
    let versions: [SavedVersion]
    var id: String { path }
}

enum DialogKind: Identifiable {
    case share
    case devices
    case pending(String, String)      // folderId, label
    case errors(String, String)
    case versions(String, String)
    case alternatives(String, String)
    case requestFix(String, String)   // folderId, label
    case bookmarkEditor(Bookmark?)
    case smbAddress
    case syncSettings
    case selectionHelp
    var id: String {
        switch self {
        case .share: return "share"
        case .devices: return "devices"
        case .pending: return "pending"
        case .errors: return "errors"
        case .versions: return "versions"
        case .alternatives: return "alternatives"
        case .requestFix: return "request-fix"
        case .bookmarkEditor: return "editor"
        case .smbAddress: return "smb"
        case .syncSettings: return "sync-settings"
        case .selectionHelp: return "help"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var view: PopupViewKind = .transfers
    @Published var bookmarks: [Bookmark] = [] {
        didSet {
            SmbMonitor.shared.bookmarks = bookmarks
            SmbMonitor.shared.checkNow()
        }
    }
    @Published private(set) var smbBookmarkHealth: [String: String] = [:]
    @Published var snapshot: Snapshot?
    @Published var snapshotError: String?
    @Published var mounts: [SmbMount] = []
    @Published var hostedSmbShares: [HostedSmbShare] = []
    @Published var smbTailDevices: [SmbTailDevice] = []
    @Published var activity: [ActivityEntry] = []
    @Published var updates: [UpdateEntry] = []
    @Published var attention: [AttentionItem] = []
    @Published var busy: BusyState?
    @Published var banner: Banner?
    @Published var availableAppUpdate: String?
    @Published var installingAppUpdate = false
    @Published private var preparedUpdatePath: String?
    @Published private var applyingAppUpdate = false
    @Published var dialog: DialogKind?
    @Published var syncBrowse: SyncBrowseState?
    @Published var storageBrowse: StorageBrowseState?
    @Published var syncInfo: SyncInfoState?
    @Published var syncDeviceProgress: [JSON] = []
    @Published private(set) var syncAttentionReport: JSON = [:]
    @Published private(set) var syncAttentionLoading = false
    @Published private(set) var syncAttentionFailure: String?
    private var syncInfoBack: PopupViewKind = .sync
    @Published var syncInfoLoading = false
    @Published var syncInfoFailure: String?
    @Published var pendingItems: [IssueItem] = []
    @Published var errorItems: [IssueItem] = []
    @Published var versionRows: [VersionGroup] = []
    @Published var folderErrors: [String: [IssueItem]] = [:]
    @Published var incomingFixRequests: [IncomingFixRequest] = []
    @Published var popoverVisible = false
    @Published var settingsPref = PrefStore.shared.preferences
    private var announcedResponses = Set<String>()

    let syncthing = SyncthingService()
    lazy var blip = BlipReceiver()
    let smbHosting = SmbSharingHost()
    @Published var shareFolderPath = ""
    private let log = ActivityLog.shared
    private var lastSnapshotAt = Date.distantPast
    private var lastEventsAt = Date.distantPast
    private var lastAppUpdateCheck = Date.distantPast
    private var autoUpdateAfter = Date.distantPast
    private var updateChecksStarted = false
    @Published private(set) var checkingForAppUpdate = false
    private var showAppUpdateResult = false
    private var downloadCheckedUpdate = false
    private var manualUpdateRequested = false
    var stoppingUpdateChecks = false
    var updateWindowIsVisible = { true }
    var hasPreparedUpdate: Bool { preparedUpdatePath != nil }
    private var snapshotTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var snapshotRefreshPending = false

    // MARK: - Lifecycle

    func startup() {
        Task {
            if let error = (try? await CoreBridge.shared.call(action: "update.error", request: ["data_dir": Paths.dataDir.path], timeout: 5)) as? String {
                autoUpdateAfter = Date().addingTimeInterval(60 * 60)
                showBanner(.error, "Could not update myDrive", error)
            }
            updateChecksStarted = true
            checkForAppUpdate()
        }
        blip.start()
        activity = log.activity
        updates = log.updates
        applyFinderFolderCacheFix()
        SmbMonitor.shared.onMountsChanged = { [weak self] mounts, labels in
            self?.applyMountUpdate(mounts)
            if self?.smbBookmarkHealth != labels { self?.smbBookmarkHealth = labels }
        }
        Task {
            await loadBookmarks()
            SmbMonitor.shared.checkNow()
            async let snapshotTask: Void = refreshSnapshot(afterChange: false)
            async let eventsTask: Void = pollEvents()
            _ = await (snapshotTask, eventsTask)
        }
    }

    /// OpenDrive parity: turn off the SMB client's directory enumeration cache
    /// once, at launch, so Finder never serves stale, partial, or empty folder
    /// listings (support.apple.com/en-us/101918). Existing mounts pick the
    /// setting up the next time they remount.
    private func applyFinderFolderCacheFix() {
        guard !SmbMonitor.cacheFixApplied() else { return }
        if SmbMonitor.applyDirCacheFix() {
            log.append(ActivityEntry(operation: "Fix Finder folder listing", connection: "macOS",
                                     detail: "Disabled SMB folder caching in ~/Library/Preferences/nsmb.conf",
                                     success: true))
        } else {
            log.append(ActivityEntry(operation: "Fix Finder folder listing", connection: "macOS",
                                     detail: "Could not write ~/Library/Preferences/nsmb.conf", success: false))
            showBanner(.error, "Could not apply the Finder folder fix",
                       "myDrive could not write ~/Library/Preferences/nsmb.conf. Apply it from Settings → Network drives.")
        }
        activity = log.activity
    }

    func loadBookmarks() async {
        do {
            bookmarks = try await CoreBridge.shared.loadBookmarks(dataDir: Paths.dataDir)
        } catch {
            showBanner(.error, "Could not load connections",
                       "\(Self.errorText(error)) The saved file has been preserved.")
        }
    }

    // MARK: - Derived status

    var attentionCount: Int {
        attention.filter { $0.severity != .info }.count
    }

    var statusTint: StatusTint {
        // Red is for anything actually broken: Syncthing unavailable, a folder
        // that can't finish syncing, or an unavailable mount. Warnings
        // (pending files, paused sync) stay orange.
        if attention.contains(where: { $0.severity == .error }) { return .red }
        if attentionCount > 0 { return .orange }
        if snapshot == nil { return .gray }
        return .green
    }

    var statusTitle: String {
        if let snapshotError { return "Syncthing unavailable" }
        guard let snapshot else { return "Checking changes…" }
        let count = foldersNeedingAttention.count
        if count > 0 {
            return count == 1 ? "1 folder needs attention" : "\(count) folders need attention"
        }
        if snapshot.folders.contains(where: \.paused) && !snapshot.folders.contains(where: { !$0.paused && $0.status.state == "syncing" }) {
            return "Sync paused"
        }
        let pending = snapshot.folders.reduce(0) { $0 + ($1.paused ? 0 : $1.status.needFiles) }
        if pending > 0 { return "\(pending) files pending" }
        let remote = snapshot.devices.filter { !$0.isLocal && !$0.paused }
        if !remote.isEmpty && !remote.contains(where: \.connected) { return "Working offline" }
        let states = snapshot.folders.filter { !$0.paused }.map(\.status.state)
        if states.contains("scanning") { return "Checking changes…" }
        if states.contains("syncing") { return "Syncing changes…" }
        return "Local files up to date"
    }

    var foldersNeedingAttention: [SyncthingFolder] {
        (snapshot?.folders ?? []).filter { !$0.paused && $0.hasError }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var statusDetail: String {
        guard let snapshot else { return "" }
        let remoteOnline = snapshot.devices.filter { !$0.isLocal && $0.connected }.count
        var detail = "\(snapshot.folders.count) folders · \(remoteOnline) \(remoteOnline == 1 ? "device" : "devices") online"
        let paused = snapshot.folders.filter(\.paused).count
        if paused > 0 { detail += " · \(paused) paused" }
        return detail
    }

    func recomputeAttention() {
        attention = AttentionCenter.derive(snapshot: snapshot, snapshotError: snapshotError,
                                           mounts: mounts,
                                           folderErrors: folderErrors,
                                           incoming: incomingFixRequests)
    }

    private func applyMountUpdate(_ updated: [SmbMount]) {
        guard mounts != updated else { return }
        mounts = updated
        recomputeAttention()
    }

    // MARK: - Timers

    func tick() {
        checkForAppUpdate()
        if !manualUpdateRequested || idleForUpdate {
            installAppUpdate(automatic: !manualUpdateRequested)
        }
        Task { await refreshIfStale() }
    }

    func fetchAppUpdate() {
        if preparedUpdatePath != nil {
            installAppUpdate()
        } else {
            checkForAppUpdate(showResult: true, downloadIfAvailable: true)
        }
    }

    func checkForAppUpdate(showResult: Bool = false, onOpen: Bool = false, downloadIfAvailable: Bool = false) {
        guard updateChecksStarted, !stoppingUpdateChecks, !installingAppUpdate else { return }
        if checkingForAppUpdate {
            showAppUpdateResult = showAppUpdateResult || showResult
            downloadCheckedUpdate = downloadCheckedUpdate || downloadIfAvailable
            return
        }
        let age = Date().timeIntervalSince(lastAppUpdateCheck)
        guard showResult || downloadIfAvailable || onOpen || age < 0 || age >= 6 * 60 * 60,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        showAppUpdateResult = showResult
        downloadCheckedUpdate = downloadIfAvailable
        checkingForAppUpdate = true
        lastAppUpdateCheck = Date()
        Task {
            var foundUpdate = false
            do {
                let reply = try await CoreBridge.shared.call(action: "update.check", request: ["payload": ["version": version]], timeout: 12)
                let target = (reply as? JSON)?["version"] as? String
                if target != availableAppUpdate {
                    manualUpdateRequested = false
                    await discardPreparedUpdate()
                }
                availableAppUpdate = target
                foundUpdate = target != nil
            } catch {
                if showAppUpdateResult { showBanner(.info, "Could not check for updates", "Try again when GitHub is available.") }
            }
            let download = foundUpdate && downloadCheckedUpdate
            checkingForAppUpdate = false
            showAppUpdateResult = false
            downloadCheckedUpdate = false
            if download { manualUpdateRequested = true }
            installAppUpdate(automatic: !download)
        }
    }

    func updateOfferTitle(_ version: String) -> String {
        if applyingAppUpdate { return "Installing update…" }
        if installingAppUpdate { return "Downloading myDrive \(version)…" }
        return preparedUpdatePath == nil ? "Update to myDrive \(version)" : "Install myDrive \(version)"
    }

    private var canAutomaticallyInstallUpdate: Bool {
        settingsPref.autoInstallUpdates == true && Date() >= autoUpdateAfter &&
            !updateWindowIsVisible() && hostedSmbShares.isEmpty
    }

    private var idleForUpdate: Bool {
        busy == nil && dialog == nil && NSApp.modalWindow == nil &&
            !blip.transfers.contains { $0.isLive && ["Created", "Pending", "Active", "ResumeRequested"].contains($0.status) }
    }

    func installAppUpdate(automatic: Bool = false) {
        guard !checkingForAppUpdate, !installingAppUpdate, !stoppingUpdateChecks, let target = availableAppUpdate,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        guard !automatic || canAutomaticallyInstallUpdate else { return }
        guard idleForUpdate else {
            if !automatic { showBanner(.info, "An operation is running", "Finish the current operation before updating myDrive.") }
            return
        }
        installingAppUpdate = true
        manualUpdateRequested = manualUpdateRequested || !automatic
        Task {
            defer { installingAppUpdate = false; applyingAppUpdate = false }
            do {
                if preparedUpdatePath == nil {
                    let response = try await CoreBridge.shared.call(action: "update.stage", request: [
                        "data_dir": Paths.dataDir.path,
                        "payload": ["version": version, "target_version": target,
                                    "app_path": Bundle.main.bundleURL.path, "pid": ProcessInfo.processInfo.processIdentifier] as JSON,
                    ], timeout: 11 * 60)
                    guard let path = (response as? JSON)?["plan_path"] as? String else {
                        throw CoreError(message: "Could not locate the prepared update.")
                    }
                    preparedUpdatePath = path
                }
                if stoppingUpdateChecks { await discardPreparedUpdate(); return }
                guard idleForUpdate, !automatic || canAutomaticallyInstallUpdate,
                      let path = preparedUpdatePath else { return }
                applyingAppUpdate = true
                try await usePreparedUpdate("update.apply", path: path)
                preparedUpdatePath = nil
                quit()
            } catch {
                manualUpdateRequested = false
                autoUpdateAfter = Date().addingTimeInterval(60 * 60)
                if !stoppingUpdateChecks { showBanner(.error, "Could not update myDrive", Self.errorText(error)) }
            }
        }
    }

    func discardPreparedUpdate() async {
        guard let path = preparedUpdatePath else { return }
        preparedUpdatePath = nil
        try? await usePreparedUpdate("update.discard", path: path)
    }

    private func usePreparedUpdate(_ action: String, path: String) async throws {
        _ = try await CoreBridge.shared.call(action: action, request: [
            "data_dir": Paths.dataDir.path,
            "payload": ["plan_path": path, "app_path": Bundle.main.bundleURL.path,
                        "pid": ProcessInfo.processInfo.processIdentifier] as JSON,
        ], timeout: 5)
    }

    func refreshIfStale() async {
        let age = Date().timeIntervalSince(lastSnapshotAt)
        let visibleSync = (popoverVisible || updateWindowIsVisible()) && view == .sync
        let now = Date()
        let due = snapshot?.folders.contains { ($0.pausedUntil ?? .distantFuture) <= now } ?? false
        let budget = visibleSync || due ? 20.0 : 120.0
        if (snapshot == nil && snapshotError == nil) || age > budget {
            // Status and events refresh concurrently; awaiting them in order
            // stacked every request's latency onto opening the popup.
            async let snapshotTask: Void = refreshSnapshot(afterChange: false)
            async let eventsTask: Void = pollEvents()
            _ = await (snapshotTask, eventsTask)
        } else if Date().timeIntervalSince(lastEventsAt) > budget {
            await pollEvents()
        }
    }

    // MARK: - Syncthing status

    func refreshSnapshot(afterChange: Bool = true) async {
        if let snapshotTask {
            if afterChange { snapshotRefreshPending = true }
            await snapshotTask.value
            return
        }
        let task = Task { [self] in
            defer { snapshotTask = nil }
            repeat {
                snapshotRefreshPending = false
                await loadSnapshot()
            } while snapshotRefreshPending && !Task.isCancelled
        }
        snapshotTask = task
        await task.value
    }

    private func loadSnapshot() async {
        do {
            let fresh = try await syncthing.snapshot()
            snapshot = fresh
            snapshotError = nil
            AttentionCenter.myDeviceId = fresh.devices.first(where: { $0.isLocal })?.deviceID ?? ""
            async let folderErrorTask: Void = loadFolderErrors(for: fresh)
            async let fixRequestTask: Void = scanFixRequests()
            _ = await (folderErrorTask, fixRequestTask)
        } catch {
            snapshotError = Self.errorText(error)
        }
        lastSnapshotAt = Date()
        recomputeAttention()
    }

    /// Fetches the real error text for erroring folders so the attention cards
    /// can say what is wrong. Bounded to the first four folders per refresh,
    /// fetched concurrently.
    func loadFolderErrors(for snapshot: Snapshot) async {
        let folders = snapshot.folders.filter(\.hasError).prefix(4)
        guard !folders.isEmpty else {
            folderErrors = [:]
            return
        }
        let service = syncthing
        let gathered: [String: [IssueItem]] = await withTaskGroup(
            of: (String, [IssueItem])?.self) { group in
            for folder in folders {
                let id = folder.id
                group.addTask {
                    guard let raw = try? await service.call("errors",
                                                            payload: ["folder_id": id],
                                                            timeout: 20) else { return nil }
                    return (id, IssueItem.rows(from: raw))
                }
            }
            var out: [String: [IssueItem]] = [:]
            for await result in group {
                if let (id, rows) = result { out[id] = rows }
            }
            return out
        }
        folderErrors = gathered
    }

    func pollEvents() async {
        if let eventsTask { await eventsTask.value; return }
        let task = Task { defer { self.eventsTask = nil }; await self.loadEvents() }
        eventsTask = task
        await task.value
    }

    private func loadEvents() async {
        guard snapshot != nil || snapshotError == nil else { return }
        lastEventsAt = Date()
        let since = settingsPref.lastEventId
        guard let raw = try? await syncthing.call("events",
                                                  payload: ["since": since, "timeout_s": 3],
                                                  timeout: 20) else { return }
        let result = EventsResult(from: raw)
        let folderLabels = Dictionary(uniqueKeysWithValues: (snapshot?.folders ?? []).map { ($0.id, $0.displayName) })
        let deviceNames = Dictionary(uniqueKeysWithValues: (snapshot?.devices ?? []).map { ($0.deviceID, $0.displayName) })
        var additions: [UpdateEntry] = []
        for event in result.events where event.id > since {
            if var entry = Self.updateEntry(for: event, folderLabels: folderLabels, deviceNames: deviceNames) {
                entry.eventID = event.id
                additions.append(entry)
            }
        }
        log.append(contentsOf: additions)
        updates = log.updates
        if result.lastId > since {
            PrefStore.shared.update { $0.lastEventId = max($0.lastEventId, result.lastId) }
            settingsPref = PrefStore.shared.preferences
        }
    }

    func shutdown() {
        smbHosting.stop()
        blip.stop()
        syncthing.stop()
        snapshotTask?.cancel(); eventsTask?.cancel(); busy?.task.cancel()
        log.flush()
    }

    static func updateEntry(for event: SyncEvent, folderLabels: [String: String],
                            deviceNames: [String: String]) -> UpdateEntry? {
        let folder = folderLabels[event.data.str("folder")] ?? event.data.str("folder")
        switch event.type {
        case "ItemFinished":
            let item = (event.data.str("item") as NSString).lastPathComponent
            return UpdateEntry(text: "Synced \(item) · \(folder)", kind: "file", folderId: event.data.str("folder"))
        case "DeviceConnected":
            let name = deviceNames[event.data.str("id")] ?? event.data.str("id")
            return UpdateEntry(text: "\(name) connected", kind: "device", folderId: "")
        case "DeviceDisconnected":
            let name = deviceNames[event.data.str("id")] ?? event.data.str("id")
            return UpdateEntry(text: "\(name) disconnected", kind: "device", folderId: "")
        case "StateChanged":
            let to = event.data.str("to")
            guard ["scanning", "syncing"].contains(to), event.data.str("from") != to else { return nil }
            return UpdateEntry(text: "\(folder) \(to == "scanning" ? "checking changes" : "syncing")",
                               kind: "folder", folderId: event.data.str("folder"))
        case "FolderErrors":
            let count = event.data.array("errors").count
            guard count > 0 else { return nil }
            return UpdateEntry(text: "\(folder): \(count == 1 ? "1 file error" : "\(count) file errors")",
                               kind: "error", folderId: event.data.str("folder"))
        default:
            return nil
        }
    }

    // MARK: - Operation runner

    func perform(_ label: String, connection: String = "myDrive",
                 _ operation: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            var success = true
            var detail = label
            do {
                try await operation()
            } catch is CancellationError {
                success = false
                detail = "Canceled"
                self.showBanner(.info, "Operation canceled", "The transfer stopped. To resume an SMB copy, retry with the same file and destination.")
            } catch {
                success = false
                detail = Self.errorText(error)
                self.showBanner(.error, "Something needs attention", detail)
            }
            self.busy = nil
            self.log.append(ActivityEntry(operation: label, connection: connection, detail: detail, success: success))
            self.activity = log.activity
        }
        busy = BusyState(label: label, task: task)
    }

    func cancelOperation() {
        busy?.task.cancel()
    }

    func showBanner(_ kind: Banner.Kind, _ title: String, _ message: String) {
        banner = Banner(kind: kind, title: title, message: message)
    }

    static func errorText(_ error: Error) -> String {
        (error as? CoreError)?.message ?? error.localizedDescription
    }

    // MARK: - Syncthing fixes

    func pauseFolder(_ folder: SyncthingFolder, paused: Bool) {
        perform(paused ? "Pause \(folder.displayName)" : "Resume \(folder.displayName)") {
            _ = try await self.syncthing.call("pause", payload: ["folder_id": folder.id, "paused": paused])
            await self.refreshSnapshot()
        }
    }

    func chooseSyncPause(_ folder: SyncthingFolder) {
        guard busy == nil else { return }
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 270, height: 25))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = Date().addingTimeInterval(3600)
        picker.minDate = Date()
        picker.maxDate = Date().addingTimeInterval(31 * 86400)
        let prompt = NSAlert()
        prompt.messageText = "Pause until"
        prompt.accessoryView = picker
        prompt.addButton(withTitle: "Pause")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        perform("Schedule sync pause") {
            _ = try await self.syncthing.call("pause_until", payload: [
                "folder_id": folder.id, "expected_path": folder.path,
                "until": Int64(picker.dateValue.timeIntervalSince1970)
            ])
            await self.refreshSnapshot()
        }
    }

    func stopFolder(_ folder: SyncthingFolder) {
        guard busy == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Stop syncing \(folder.displayName)?"
        alert.informativeText = "This removes the folder from this computer's sync list. Existing files and saved versions stay on every device. You can add the folder again later."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Stop syncing")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform("Stop syncing \(folder.displayName)") {
            _ = try await self.syncthing.call("stop", payload: ["folder_id": folder.id, "expected_path": folder.path])
            self.syncBrowse = nil
            self.view = .sync
            self.dialog = nil
            await self.refreshSnapshot()
            self.showBanner(.info, "Folder sync stopped", "Existing files were kept on every device.")
        }
    }

    func rescanFolder(_ id: String) {
        let label = snapshot?.folders.first { $0.id == id }?.displayName ?? id
        perform("Rescan \(label)") {
            _ = try await self.syncthing.call("scan", payload: ["folder_id": id])
            try? await Task.sleep(nanoseconds: 400_000_000)
            await self.refreshSnapshot()
            if self.view == .syncAttention { await self.loadSyncAttention() }
            if self.view == .syncInfo, self.syncInfo?.errors == true, self.syncInfo?.folderId == id {
                let raw = try await self.syncthing.call("errors", payload: ["folder_id": id], timeout: 25)
                self.errorItems = IssueItem.rows(from: raw)
                self.syncInfoFailure = nil
            }
        }
    }

    func relocateSyncFolder(_ folder: SyncthingFolder) {
        guard busy == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose new location"
        picker.message = "Select the sync folder you moved."
        picker.prompt = "Use this location"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        guard picker.runModal() == .OK, let destination = picker.url else { return }
        perform("Update sync location") {
            _ = try await self.syncthing.call("relocate", payload: [
                "folder_id": folder.id, "expected_path": folder.path, "local_path": destination.path
            ])
            if self.view == .syncInfo, self.syncInfo?.errors == true, self.syncInfo?.folderId == folder.id {
                self.closeSyncInfo()
            }
            await self.refreshSnapshot()
            if self.view == .syncAttention { await self.loadSyncAttention() }
        }
    }

    func protectHistory(_ folder: SyncthingFolder) {
        perform("Protect version history · \(folder.displayName)") {
            _ = try await self.syncthing.call("protect", payload: ["folder_id": folder.id])
            await self.refreshSnapshot()
        }
    }

    func openFolderFiles(_ folder: SyncthingFolder) {
        view = .syncFiles
        dialog = nil
        perform("Choose files · \(folder.displayName)") {
            let raw = try await self.syncthing.call("browse",
                                                    payload: ["folder_id": folder.id, "path": ""])
            let result = BrowseResult(from: raw ?? [:])
            self.syncBrowse = SyncBrowseState(folderId: folder.id, label: folder.displayName,
                                              path: "", result: result)
        }
    }

    func browseSyncPath(_ path: String) {
        guard var state = syncBrowse else { return }
        perform("Open folder") {
            let raw = try await self.syncthing.call("browse",
                                                    payload: ["folder_id": state.folderId, "path": path])
            let result = BrowseResult(from: raw ?? [:])
            state.path = path
            state.result = result
            self.syncBrowse = state
        }
    }

    func browseSyncUp() {
        guard let state = syncBrowse, state.path.contains("/") else { return }
        let parent = (state.path as NSString).deletingLastPathComponent
        browseSyncPath(parent.isEmpty ? "" : parent)
    }

    func setDownloadWhenNeeded(_ enabled: Bool) {
        guard var state = syncBrowse, busy == nil else { return }
        let title = enabled ? "Download files when needed" : "Resume default syncing"
        let prompt = NSAlert()
        prompt.messageText = title + "?"
        prompt.informativeText = enabled
            ? "Unselected files stay online. You can open or pin them from myDrive. Existing local copies are kept."
            : "The folder will use its usual sync rules again. Any existing file selections are kept."
        prompt.addButton(withTitle: enabled ? "Enable" : "Resume")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        perform(title, connection: state.label) {
            _ = try await self.syncthing.call("selection.mode",
                payload: ["folder_id": state.folderId, "expected_ignore": state.result.ignore, "on_demand": enabled])
            let raw = try await self.syncthing.call("browse", payload: ["folder_id": state.folderId, "path": state.path])
            state.result = BrowseResult(from: raw ?? [:])
            self.syncBrowse = state
        }
    }

    func setSelection(_ entry: BrowseEntry, sync enabled: Bool) {
        guard var state = syncBrowse else { return }
        var rules = state.result.rules
        rules.removeAll { $0.path == entry.path }
        rules.append(SyncRule(path: entry.path, sync: enabled, is_dir: entry.isDir))
        perform(enabled ? "Sync \(entry.name)" : "Stop \(entry.name)", connection: state.label) {
            let payload: JSON = [
                "folder_id": state.folderId,
                "expected_ignore": state.result.ignore,
                "rules": rules.map { ["path": $0.path, "sync": $0.sync, "is_dir": $0.is_dir] },
            ]
            _ = try await self.syncthing.call("selection.apply", payload: payload, timeout: 60)
            let raw = try await self.syncthing.call("browse",
                                                    payload: ["folder_id": state.folderId, "path": state.path])
            state.result = BrowseResult(from: raw ?? [:])
            self.syncBrowse = state
        }
    }

    func openSyncedFile(_ entry: BrowseEntry) {
        guard let state = syncBrowse else { return }
        perform("Open \(entry.name)", connection: state.label) {
            let raw = try await self.syncthing.call("local_file",
                                                    payload: ["folder_id": state.folderId, "path": entry.path, "wait_seconds": 6])
            let result = (raw as? JSON) ?? [:]
            if state.result.onDemand {
                if let browse = try? await self.syncthing.call("browse",
                    payload: ["folder_id": state.folderId, "path": state.path]) {
                    var updated = state
                    updated.result = BrowseResult(from: browse)
                    self.syncBrowse = updated
                }
            }
            if result.bool("pending") {
                self.showBanner(.info, "Download requested",
                                "Open the file again when Syncthing has downloaded it.")
            } else {
                let path = result.str("path")
                if !path.isEmpty {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
    }

    func openLocalFolder(_ path: String) {
        guard !path.isEmpty else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            showBanner(.error, "Folder unavailable",
                       "\(path) is missing. Reconnect its volume or device, then rescan.")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Dialog data

    func openSyncAttention() {
        guard busy == nil else { return }
        view = .syncAttention
        refreshSyncAttention(refreshSnapshot: false)
    }

    func refreshSyncAttention(refreshSnapshot: Bool = true) {
        guard busy == nil else { return }
        perform("Check sync errors") {
            if refreshSnapshot { await self.refreshSnapshot() }
            await self.loadSyncAttention()
        }
    }

    private func loadSyncAttention() async {
        syncAttentionLoading = true
        syncAttentionFailure = snapshotError
        defer { syncAttentionLoading = false }
        do {
            let ids = foldersNeedingAttention.map(\.id)
            let raw = try await syncthing.call("attention", payload: ["folder_ids": ids], timeout: 35)
            syncAttentionReport = raw as? JSON ?? [:]
        } catch {
            syncAttentionFailure = Self.errorText(error)
        }
    }

    func openPending(_ folder: SyncthingFolder) {
        openSyncInfo(folder, action: "need", title: "Pending files")
    }

    func openErrors(_ folder: SyncthingFolder) {
        openSyncInfo(folder, action: "errors", title: "Folder errors")
    }

    func openDeviceProgress(_ folder: SyncthingFolder) {
        openSyncInfo(folder, action: "device_progress", title: "Device progress")
    }

    private func openSyncInfo(_ folder: SyncthingFolder, action: String, title: String) {
        guard busy == nil else { return }
        syncInfoBack = view == .syncAttention ? .syncAttention : .sync
        syncInfo = SyncInfoState(folderId: folder.id, label: folder.displayName, action: action, title: title)
        errorItems = []; pendingItems = []; syncDeviceProgress = []
        dialog = nil; view = .syncInfo
        refreshSyncInfo()
    }

    func refreshSyncInfo() {
        guard busy == nil, let info = syncInfo else { return }
        syncInfoLoading = true
        syncInfoFailure = nil
        perform("Load " + info.title.lowercased()) {
            defer { self.syncInfoLoading = false }
            do {
                let raw = try await self.syncthing.call(info.action,
                    payload: ["folder_id": info.folderId], timeout: 25)
                if info.errors { self.errorItems = IssueItem.rows(from: raw) }
                else if info.action == "device_progress" {
                    self.syncDeviceProgress = (raw as? JSON ?? [:]).array("devices").compactMap { $0 as? JSON }
                }
                else {
                    let dict = raw as? JSON ?? [:]
                    self.pendingItems = ["progress", "queued", "rest"].flatMap { dict.array($0).map(IssueItem.init(from:)) }
                }
            } catch {
                self.syncInfoFailure = Self.errorText(error)
                throw error
            }
        }
    }

    func closeSyncInfo() {
        view = syncInfoBack
        syncInfo = nil
    }

    private var versionsFolderId = ""

    func openVersions(_ folder: SyncthingFolder) {
        dialog = .versions(folder.id, folder.displayName)
        versionRows = []
        versionsFolderId = folder.id
        perform("Saved versions · \(folder.displayName)") {
            let raw = try await self.syncthing.call("versions",
                                                    payload: ["folder_id": folder.id], timeout: 30)
            let dict = raw as? JSON ?? [:]
            let groups: [VersionGroup] = dict.keys.sorted().prefix(50).map { path in
                let versions = dict.array(path).map { SavedVersion(path: path, from: $0) }
                return VersionGroup(path: path, versions: versions)
            }
            self.versionRows = groups.filter { !$0.versions.isEmpty }
        }
    }

    func restoreVersion(_ group: VersionGroup, _ version: SavedVersion) {
        let alert = NSAlert()
        alert.messageText = "Restore this version?"
        alert.informativeText = "Restoring replaces the current file and syncs that change to other devices. myDrive backs up the current local file before restoring. History here covers changes received from other devices."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let folderLabel = syncBrowse?.label ?? group.path
        perform("Restore saved version", connection: folderLabel) {
            let raw = try await self.syncthing.call("restore",
                                                    payload: ["folder_id": self.versionsFolderId,
                                                              "path": group.path,
                                                              "version_time": version.versionTime],
                                                    timeout: 50)
            if let backup = (raw as? JSON)?.str("backup"), !backup.isEmpty {
                self.showBanner(.info, "Restored", "Your previous local copy was also saved: \(backup)")
            } else {
                self.showBanner(.info, "Restored", "The saved version is back in place.")
            }
            await self.refreshSnapshot()
        }
    }

    func shareFolder(path: String, deviceId: String, skipBuild: Bool) {
        perform("Sync a folder", connection: path) {
            let raw = try await self.syncthing.call("share",
                                                    payload: ["local_path": path,
                                                              "device_id": deviceId,
                                                              "skip_build": skipBuild],
                                                    timeout: 60)
            let result = (raw as? JSON) ?? [:]
            let device = result.str("device_name")
            self.showBanner(.info, "Folder offered to \(device)",
                            (result.bool("nested") ? "Only this folder was offered; the overlapping folders' devices and selections stay unchanged. " : "") + "If this is a new share, accept it in Syncthing on the other device.")
            PrefStore.shared.update {
                $0.lastSyncFolder = path
                $0.lastSyncDevice = deviceId
            }
            self.settingsPref = PrefStore.shared.preferences
            await self.refreshSnapshot()
        }
    }

    // MARK: - Storage bookmarks
    func shareBrowsedSubfolder() {
        guard let browse=syncBrowse,!browse.path.isEmpty,
              let folder=snapshot?.folders.first(where:{$0.id==browse.folderId}) else {return}
        shareFolderPath=URL(fileURLWithPath:folder.path).appendingPathComponent(browse.path).path
        dialog = .share
    }

    func saveBookmark(_ bookmark: Bookmark, credentials: Credentials) {
        perform("Save connection", connection: bookmark.nickname) {
            let previous = Keychain.readCredentials(id: bookmark.id)
            let hadSecrets = !previous.isEmpty
            if !credentials.isEmpty || hadSecrets {
                do { try Keychain.saveCredentials(credentials, id: bookmark.id) }
                catch { throw CoreError(message: "Keychain rejected the secret: \(Self.errorText(error))") }
            }
            var updated = self.bookmarks.filter { $0.id != bookmark.id }
            updated.append(bookmark)
            do {
                try await CoreBridge.shared.saveBookmarks(updated, dataDir: Paths.dataDir)
                self.bookmarks = updated
            } catch {
                // Roll the secret back so storage stays consistent.
                if hadSecrets { try? Keychain.saveCredentials(previous, id: bookmark.id) }
                else { Keychain.deleteCredentials(id: bookmark.id) }
                throw error
            }
        }
    }

    func deleteBookmark(_ bookmark: Bookmark) {
        perform("Remove connection", connection: bookmark.nickname) {
            var updated = self.bookmarks.filter { $0.id != bookmark.id }
            try await CoreBridge.shared.saveBookmarks(updated, dataDir: Paths.dataDir)
            Keychain.deleteCredentials(id: bookmark.id)
            self.bookmarks = updated
        }
    }

    func testBookmark(_ bookmark: Bookmark, credentials: Credentials,
                      completion: @escaping (String) -> Void) {
        perform("Test connection", connection: bookmark.nickname) {
            do {
                let raw = try await CoreBridge.shared.fileAction("test", bookmark: bookmark,
                                                                 credentials: credentials)
                let files = (raw as? [Any]) ?? []
                completion("Connection successful. Found \(files.count) items.")
            } catch {
                completion("Connection failed: \(Self.errorText(error))")
            }
        }
    }

    func browseBookmark(_ bookmark: Bookmark, path: String) {
        view = .connections
        dialog = nil
        perform("Browse \(bookmark.nickname)", connection: bookmark.nickname) {
            let raw = try await CoreBridge.shared.fileAction(
                "list", bookmark: bookmark,
                credentials: Keychain.readCredentials(id: bookmark.id),
                extra: ["path": path])
            let files = (raw as? [Any] ?? []).map(RemoteFile.init(from:))
            self.storageBrowse = StorageBrowseState(bookmark: bookmark, path: path, files: files)
        }
    }

    func browseSmbMount(_ mount: SmbMount) {
        var bookmark = Bookmark()
        bookmark.id = "mounted-smb:" + mount.remoteDescription
        bookmark.nickname = mount.displayName
        bookmark.protocolKind = "smb"
        bookmark.host = mount.host
        bookmark.mountPath = mount.path
        browseBookmark(bookmark, path: "")
    }

    func storagePathUp() {
        guard let state = storageBrowse, !state.path.isEmpty else { return }
        let parent = (state.path as NSString).deletingLastPathComponent
        browseBookmark(state.bookmark, path: parent)
    }

    func openStorageFile(_ file: RemoteFile) {
        guard let state = storageBrowse else { return }
        let bookmark = state.bookmark
        if bookmark.protocolKind == "local" || bookmark.protocolKind == "smb" {
            let full = (bookmark.coreHost as NSString).appendingPathComponent(file.path)
            NSWorkspace.shared.open(URL(fileURLWithPath: full))
            log.append(ActivityEntry(operation: "Open", connection: bookmark.nickname,
                                     detail: file.name, success: true))
            activity = log.activity
            return
        }
        perform("Open \(file.name)", connection: bookmark.nickname) {
            let cache = Paths.dataDir.appendingPathComponent("opened")
                .appendingPathComponent(SHA256.hex(bookmark.id + "/" + file.path + file.modified),
                                        isDirectory: false)
            let directory = cache.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: cache.path) {
                try await CoreBridge.shared.fileAction(
                    "download", bookmark: bookmark,
                    credentials: Keychain.readCredentials(id: bookmark.id),
                    extra: ["path": file.path, "local_path": cache.path], timeout: 120)
            }
            NSWorkspace.shared.open(cache)
        }
    }

    func downloadFile(_ file: RemoteFile) {
        guard let state = storageBrowse else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform("Download \(file.name)", connection: state.bookmark.nickname) {
            try await CoreBridge.shared.fileAction(
                "download", bookmark: state.bookmark,
                credentials: Keychain.readCredentials(id: state.bookmark.id),
                extra: ["path": file.path, "local_path": destination.path], timeout: state.bookmark.protocolKind == "smb" ? nil : 300)
        }
    }

    func uploadFile() {
        guard let state = storageBrowse else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let name = source.lastPathComponent
        let destination = state.path.isEmpty ? name : "\(state.path)/\(name)"
        perform("Upload \(name)", connection: state.bookmark.nickname) {
            try await CoreBridge.shared.fileAction(
                "upload", bookmark: state.bookmark,
                credentials: Keychain.readCredentials(id: state.bookmark.id),
                extra: ["local_path": source.path, "path": destination], timeout: state.bookmark.protocolKind == "smb" ? nil : 300)
            await self.refreshStorageListing()
        }
    }

    func newFolder(_ name: String) {
        guard let state = storageBrowse else { return }
        let path = state.path.isEmpty ? name : "\(state.path)/\(name)"
        perform("New folder \(name)", connection: state.bookmark.nickname) {
            try await CoreBridge.shared.fileAction(
                "mkdir", bookmark: state.bookmark,
                credentials: Keychain.readCredentials(id: state.bookmark.id),
                extra: ["path": path])
            await self.refreshStorageListing()
        }
    }

    func newFolderPrompt() {
        let alert = NSAlert()
        alert.messageText = "New folder"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "Folder name"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
        newFolder(input.stringValue)
    }

    func renamePrompt(_ file: RemoteFile) {
        let alert = NSAlert()
        alert.messageText = "Rename \(file.name)"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = file.name
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn,
              !input.stringValue.isEmpty, input.stringValue != file.name else { return }
        renameStorageFile(file, to: input.stringValue)
    }

    func deleteStorageFile(_ file: RemoteFile) {
        guard let state = storageBrowse else { return }
        perform("Delete \(file.name)", connection: state.bookmark.nickname) {
            try await CoreBridge.shared.fileAction(
                "delete", bookmark: state.bookmark,
                credentials: Keychain.readCredentials(id: state.bookmark.id),
                extra: ["path": file.path, "is_dir": file.isDir])
            await self.refreshStorageListing()
        }
    }

    func renameStorageFile(_ file: RemoteFile, to newName: String) {
        guard let state = storageBrowse else { return }
        let destination = ((file.path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(newName)
        perform("Rename \(file.name)", connection: state.bookmark.nickname) {
            try await CoreBridge.shared.fileAction(
                "rename", bookmark: state.bookmark,
                credentials: Keychain.readCredentials(id: state.bookmark.id),
                extra: ["path": file.path, "destination": destination])
            await self.refreshStorageListing()
        }
    }

    private func refreshStorageListing() async {
        guard let state = storageBrowse else { return }
        let raw = try? await CoreBridge.shared.fileAction(
            "list", bookmark: state.bookmark,
            credentials: Keychain.readCredentials(id: state.bookmark.id),
            extra: ["path": state.path])
        let files = (raw as? [Any] ?? []).map(RemoteFile.init(from:))
        storageBrowse = StorageBrowseState(bookmark: state.bookmark, path: state.path, files: files)
    }

    // MARK: - SMB fixes

    func remountMount(_ mount: SmbMount, force: Bool) {
        perform(force ? "Force remount \(mount.displayName)" : "Remount \(mount.displayName)",
                connection: mount.remoteDescription) {
            if force { try SmbMonitor.shared.forceRemount(mount) }
            else { try SmbMonitor.shared.mount(mount) }
            SmbMonitor.shared.checkNow()
        }
    }

    func disconnectMount(_ mount: SmbMount) {
        perform("Disconnect \(mount.displayName)", connection: mount.remoteDescription) {
            try SmbMonitor.shared.disconnect(mount)
            // An intentional disconnect must not be undone by the auto-remount
            // policy, so forget the share here.
            let key = SmbMonitor.shareKey(mount)
            PrefStore.shared.update { $0.knownSmbShares.removeAll { $0 == key } }
            SmbMonitor.shared.checkNow()
        }
    }

    // MARK: - Fix requests between devices

    func localDeviceName() -> String {
        snapshot?.devices.first(where: { $0.isLocal })?.displayName
            ?? Host.current().localizedName
            ?? "This Mac"
    }

    /// Scans every synced folder's request mailbox. Incoming unanswered
    /// requests surface as attention items; responses to our own requests
    /// become recent-updates entries.
    func scanFixRequests() async {
        guard let snapshot else { return }
        var incoming: [IncomingFixRequest] = []
        for folder in snapshot.folders {
            guard !folder.path.isEmpty,
                  FileManager.default.fileExists(atPath: folder.path) else { continue }
            for pending in FixRequestStore.scan(folderPath: folder.path) {
                let wrapped = IncomingFixRequest(pending: pending, folderId: folder.id,
                                                 folderLabel: folder.displayName,
                                                 folderPath: folder.path)
                if wrapped.fromOthers {
                    if pending.request.targetDeviceId == FixRequestStore.anyDevice
                        || pending.request.targetDeviceId == AttentionCenter.myDeviceId {
                        incoming.append(wrapped)
                    }
                } else {
                    handleOutgoingResponse(wrapped)
                }
            }
        }
        incomingFixRequests = incoming
    }

    private func handleOutgoingResponse(_ wrapped: IncomingFixRequest) {
        guard let response = wrapped.pending.response,
              !announcedResponses.contains(wrapped.id) else { return }
        announcedResponses.insert(wrapped.id)
        let text: String
        switch response.status {
        case "completed":
            text = "Fix completed on \(response.deviceName) · \(wrapped.folderLabel)"
        case "declined":
            text = "\(response.deviceName) declined the fix request · \(wrapped.folderLabel)"
        case "failed":
            text = "Fix failed on \(response.deviceName): \(response.message)"
        default:
            text = "Fix accepted on \(response.deviceName) · \(wrapped.folderLabel)"
        }
        log.append(UpdateEntry(text: text,
                               kind: response.status == "completed" ? "file" : "error",
                               folderId: wrapped.folderId))
        updates = log.updates
    }

    func sendFixRequest(folderId: String, deviceId: String, fix: FixKindRemote) {
        guard let folder = snapshot?.folders.first(where: { $0.id == folderId }) else { return }
        let request = FixRequest(
            id: UUID().uuidString.lowercased(),
            fix: fix.rawValue,
            folderId: folderId,
            created: Date(),
            requesterName: localDeviceName(),
            requesterDeviceId: AttentionCenter.myDeviceId,
            reason: String((folderErrors[folderId]?.first?.message ?? folder.error ?? "").prefix(200)),
            targetDeviceId: deviceId)
        let targetName = snapshot?.devices.first(where: { $0.deviceID == deviceId })?.displayName
            ?? "every device sharing the folder"
        perform("Request fix from peer · \(folder.displayName)", connection: folder.displayName) {
            try FixRequestStore.send(request: request, folderPath: folder.path)
            self.showBanner(.info, "Fix request sent",
                            "\(fix.title) was requested from \(targetName). It runs when their myDrive accepts it.")
            await self.scanFixRequests()
        }
    }

    func acceptFixRequest(requestId: String, folderId: String) {
        guard let incoming = incomingFixRequests.first(where: { $0.id == requestId }) else { return }
        guard let kind = FixKindRemote.safe(incoming.pending.request.fix) else {
            showBanner(.error, "Fix refused",
                       "That fix type is not on the safe list, so myDrive will not run it.")
            return
        }
        perform("Accept fix request · \(incoming.folderLabel)",
                connection: incoming.pending.request.requesterName) {
            try FixRequestStore.respond(requestId: requestId, folderPath: incoming.folderPath,
                                        status: "accepted", message: "",
                                        deviceName: self.localDeviceName())
            do {
                switch kind {
                case .rescan:
                    _ = try await self.syncthing.call("scan",
                                                      payload: ["folder_id": incoming.pending.request.folderId])
                case .unpause:
                    _ = try await self.syncthing.call("pause",
                                                      payload: ["folder_id": incoming.pending.request.folderId,
                                                                "paused": false])
                }
                try FixRequestStore.respond(requestId: requestId, folderPath: incoming.folderPath,
                                            status: "completed", message: "",
                                            deviceName: self.localDeviceName())
                self.showBanner(.info, "Fix completed",
                                "\(kind.title) ran on this Mac for \(incoming.folderLabel).")
            } catch {
                try? FixRequestStore.respond(requestId: requestId, folderPath: incoming.folderPath,
                                             status: "failed", message: Self.errorText(error),
                                             deviceName: self.localDeviceName())
                throw error
            }
            await self.scanFixRequests()
            await self.refreshSnapshot()
        }
    }

    func declineFixRequest(requestId: String, folderId: String) {
        guard let incoming = incomingFixRequests.first(where: { $0.id == requestId }) else { return }
        perform("Decline fix request · \(incoming.folderLabel)",
                connection: incoming.pending.request.requesterName) {
            try FixRequestStore.respond(requestId: requestId, folderPath: incoming.folderPath,
                                        status: "declined", message: "",
                                        deviceName: self.localDeviceName())
            await self.scanFixRequests()
        }
    }

    /// Removes this Mac's own unanswered request, so peers stop seeing it.
    func cancelFixRequest(requestId: String, folderId: String) {
        guard let folder = snapshot?.folders.first(where: { $0.id == folderId }),
              !folder.path.isEmpty else { return }
        FixRequestStore.cancel(requestId: requestId, folderPath: folder.path)
        Task { await scanFixRequests() }
    }

    /// One-click resolution for the "deleted on a peer but not empty here"
    /// error class: removes the listed directories after an explicit
    /// confirmation, then rescans so Syncthing can finish the deletion.
    func deleteLeftovers(folderId: String) {
        guard let folder = snapshot?.folders.first(where: { $0.id == folderId }) else { return }
        let targets = Array(Set((folderErrors[folderId] ?? []).map(\.path))).sorted()
        guard !targets.isEmpty else {
            rescanFolder(folderId)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete these leftover folders on this Mac?"
        alert.informativeText = "Another device deleted them, but this Mac still holds files inside. Syncthing cannot finish the deletion until these copies are gone:\n\n"
            + targets.prefix(8).joined(separator: "\n")
            + (targets.count > 8 ? "\n… and \(targets.count - 8) more" : "")
        alert.addButton(withTitle: "Delete \(targets.count) folders")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Delete leftover folders · \(folder.displayName)", connection: folder.displayName) {
            let root = URL(fileURLWithPath: folder.path, isDirectory: true)
            let rootPath = root.standardizedFileURL.path
            for relative in targets {
                guard !relative.contains(".."), !relative.hasPrefix("/"),
                      !relative.contains("\0") else {
                    throw CoreError(message: "Refusing to follow an unsafe path from the error list.")
                }
                let full = root.appendingPathComponent(relative)
                guard full.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
                    throw CoreError(message: "Refusing to delete outside the folder root.")
                }
                try? FileManager.default.removeItem(at: full)
            }
            _ = try await self.syncthing.call("scan", payload: ["folder_id": folderId])
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self.refreshSnapshot()
        }
    }

    // MARK: - Fixes router

    func applyFix(_ kind: FixKind) {
        switch kind {
        case .retrySnapshot:
            perform("Refresh sync status") {
                await self.refreshSnapshot()
                await self.pollEvents()
            }
        case .rescan(let id): rescanFolder(id)
        case .relocate(let id):
            if let folder = snapshot?.folders.first(where: { $0.id == id }) {
                relocateSyncFolder(folder)
            }
        case .resume(let id):
            if let folder = snapshot?.folders.first(where: { $0.id == id }) {
                pauseFolder(folder, paused: false)
            }
        case .showErrors(let id):
            if let folder = snapshot?.folders.first(where: { $0.id == id }) { openErrors(folder) }
        case .showPending(let id):
            if let folder = snapshot?.folders.first(where: { $0.id == id }) { openPending(folder) }
        case .showAlternatives(let id):
            if let folder = snapshot?.folders.first(where: { $0.id == id }) { openFolderFiles(folder) }
        case .remount(let path):
            if let mount = mounts.first(where: { $0.path == path }) { remountMount(mount, force: false) }
        case .forceRemount(let path):
            if let mount = mounts.first(where: { $0.path == path }) { remountMount(mount, force: true) }
        case .deleteLeftovers(let id):
            deleteLeftovers(folderId: id)
        case .requestFix(let id):
            if let folder = snapshot?.folders.first(where: { $0.id == id }) {
                dialog = .requestFix(folder.id, folder.displayName)
            }
        case .acceptFix(let requestId, let folderId):
            acceptFixRequest(requestId: requestId, folderId: folderId)
        case .declineFix(let requestId, let folderId):
            declineFixRequest(requestId: requestId, folderId: folderId)
        case .applyDSDontWriteStores:
            perform("Stop .DS_Store files on network drives") {
                try SmbMonitor.applyDSDontWriteNetworkStores()
            }
        case .applyDirCacheFix:
            perform("Keep Finder folder listings fresh") {
                guard SmbMonitor.applyDirCacheFix() else {
                    throw CoreError(message: "macOS refused the write to ~/Library/Preferences/nsmb.conf.")
                }
            }
        case .connectionSettings:
            dialog = .syncSettings
        case .refreshMounts:
            SmbMonitor.shared.checkNow()
        }
    }

    // MARK: - Misc

    func openSyncthingWeb() {
        syncthing.discover()
        if let endpoint = syncthing.connection?.endpoint, let url = URL(string: endpoint) {
            NSWorkspace.shared.open(url)
        }
    }

    func openSmbAddress(_ address: String) {
        perform("Open shared folder", connection: address) {
            var cleaned = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("smb://") { cleaned = String(cleaned.dropFirst(6)) }
            let parts = cleaned.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                throw CoreError(message: "Enter a shared folder such as smb://computer/share.")
            }
            let who = String(parts[0])
            let host = who.split(separator: "@").last.map(String.init) ?? who
            let user = who.split(separator: "@").first.map(String.init) ?? ""
            let share = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !share.isEmpty else {
                throw CoreError(message: "Include the share name after the computer name.")
            }
            let mount = SmbMount(path: "", host: host, share: share, user: user)
            try SmbMonitor.shared.mount(mount)
            SmbMonitor.shared.checkNow()
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
