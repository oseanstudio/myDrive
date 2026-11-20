import Foundation
import SwiftUI
import UIKit

@MainActor final class AppState: ObservableObject {
    @Published var devices: [Device] = []
    @Published var transfers: [Transfer] = []
    @Published var active: Device?
    @Published var path = ""
    @Published var entries: [RemoteEntry] = []
    @Published var loading = false
    @Published var tab = 0
    @Published var error: String?
    @Published var selected: [URL] = []
    @Published var share: ShareItems?
    @Published var receivedEntries: [URL] = []
    private var readable = true
    private var historyReadable = true
    private var jobs: [String: (Task<Void, Never>, CancellationFlag)] = [:]
    private var opened = Set<String>()
    init() {
        do { devices = try LocalStore.read("devices.json", fallback: [Device]()) }
        catch { readable = false; self.error = "Saved devices could not be loaded. Their existing data has been kept." }
        do { transfers = try LocalStore.read("history.json", fallback: [Transfer]()).map { t in var result = t; if t.active { result.state = "Interrupted"; result.error = "The app stopped. Check the destination before retrying." }; return result } }
        catch { historyReadable = false; self.error = "Saved transfer history could not be loaded. Its existing data has been kept." }
        opened = Set(UserDefaults.standard.stringArray(forKey: "opened_links") ?? [])
        // Do not launch old transfer history when the app starts.
        opened.formUnion(transfers.filter { $0.state == "Completed" }.map(\.id))
    }
    func save(_ device: Device, password: String) throws {
        guard readable else { throw DriveError.message("Restore the saved device list before adding another connection.") }
        guard !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DriveError.message("Enter a device name.") }
        _ = try RemotePath.name(device.share); _ = try RemotePath.clean(device.root)
        let previous = devices.first { $0.id == device.id }
        guard previous == nil || !password.isEmpty || (previous?.host == device.host && previous?.port == device.port && previous?.username == device.username && previous?.domain == device.domain) else { throw DriveError.message("Re-enter the password after changing the server or account.") }
        let oldSecret = previous == nil ? nil : try Passwords.read(device.id)
        if !password.isEmpty || previous == nil { try Passwords.save(device.id, password) }
        let updated = devices.filter { $0.id != device.id } + [device]
        do { try LocalStore.save(updated, "devices.json"); devices = updated }
        catch { if let oldSecret { try? Passwords.save(device.id, oldSecret) } else { Passwords.remove(device.id) }; throw error }
    }
    func remove(_ device: Device) throws {
        guard readable else { throw DriveError.message("The saved device list is unavailable.") }
        let updated = devices.filter { $0.id != device.id }; try LocalStore.save(updated, "devices.json")
        Passwords.remove(device.id); devices = updated
        if active?.id == device.id { active = nil; entries = [] }
    }
    func browse(_ device: Device, at path: String = "") { active = device; self.path = path; tab = 1; refresh() }
    func refresh() {
        guard let device = active, !loading else { return }; loading = true
        let currentPath = path
        Task {
            do { let service = try SMBService(device); do { let files = try await service.list(currentPath); if active?.id == device.id && path == currentPath { entries = files } } catch { await service.disconnect(); throw error }; await service.disconnect() }
            catch { entries = []; self.error = Self.friendly(error) }
            loading = false
        }
    }
    func change(_ action: @escaping (SMBService) async throws -> Void) {
        guard let device = active, !loading else { return }; loading = true
        Task {
            do { let service = try SMBService(device); do { try await action(service) } catch { await service.disconnect(); throw error }; await service.disconnect() }
            catch { self.error = Self.friendly(error) }
            loading = false; refresh()
        }
    }
    private func update(_ transfer: Transfer) {
        transfers.removeAll { $0.id == transfer.id }; transfers.insert(transfer, at: 0)
        if historyReadable && (!transfer.active || ["Queued", "Connecting"].contains(transfer.state)) { try? LocalStore.save(Array(transfers.prefix(200)), "history.json") }
        UIApplication.shared.isIdleTimerDisabled = transfers.contains { $0.active }
    }
    func download(_ entry: RemoteEntry) { guard let device = active else { return }; transfer(device, entry: entry, source: nil, directory: path) }
    func upload() { guard let device = active else { return }; for url in selected { transfer(device, entry: nil, source: url, directory: path) }; selected = []; tab = 2 }
    private func transfer(_ device: Device, entry: RemoteEntry?, source: URL?, directory: String) {
        var item = Transfer(name: entry?.name ?? source?.lastPathComponent ?? "File", device: device.name, direction: source == nil ? "Incoming" : "Outgoing")
        let flag = CancellationFlag(); let id = item.id; update(item); tab = 2
        let task = Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "myDrive transfer") { flag.cancel() }
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) }; jobs.removeValue(forKey: id) }
            do {
                let service = try SMBService(device); item.state = "Connecting"; update(item)
                let progress: @Sendable (Int64, Int64) -> Void = { [weak self] done, total in
                    Task { @MainActor in guard let self, let index = self.transfers.firstIndex(where: { $0.id == id }), self.transfers[index].active else { return }; self.transfers[index].state = "Transferring"; self.transfers[index].bytes = done; self.transfers[index].total = total }
                }
                do {
                    if let entry { item.localPath = try await service.download(entry, flag: flag, progress: progress).path }
                    else if let source { try await service.upload(source, to: directory, flag: flag, progress: progress) }
                    guard flag.active else { throw CancellationError() }
                } catch { await service.disconnect(); throw error }
                await service.disconnect(); item.state = "Completed"; update(item); openReceivedLinks()
            } catch { item.state = flag.active ? "Needs attention" : "Cancelled"; item.error = flag.active ? Self.friendly(error) : "Transfer stopped. Check the destination before retrying."; update(item) }
        }
        jobs[id] = (task, flag)
    }
    func cancel(_ id: String) { jobs[id]?.1.cancel(); jobs[id]?.0.cancel() }
    func openReceivedLinks() {
        guard UIApplication.shared.applicationState == .active else { return }
        for item in transfers where item.state == "Completed" && item.direction == "Incoming" && !opened.contains(item.id) {
            opened.insert(item.id); UserDefaults.standard.set(Array(opened), forKey: "opened_links")
            if LocalStore.autoOpenLinks, let file = item.localPath, let url = LinkTarget.read(URL(fileURLWithPath: file)) { UIApplication.shared.open(url) }
        }
    }
    func prepareShare(text: String? = nil) {
        let files = selected
        Task {
            do {
                let copied = try await Task.detached(priority: .userInitiated) { try files.map { try Self.copyForShare($0) } }.value
                var items: [Any] = copied
                if let text { items.append(text) }
                guard !items.isEmpty else { throw DriveError.message("Choose files or enter a link.") }
                share = ShareItems(items: items, label: copied.isEmpty ? "Shared link" : copied.count == 1 ? copied[0].lastPathComponent : "\(copied.count) files")
            } catch { self.error = Self.friendly(error) }
        }
    }
    nonisolated private static func copyForShare(_ file: URL) throws -> URL {
        let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(try RemotePath.name(file.lastPathComponent))
        var problem: NSError?; var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: file, options: .withoutChanges, error: &problem) { url in do { try FileManager.default.copyItem(at: url, to: target) } catch { copyError = error } }
        if let problem { throw problem }; if let copyError { throw copyError }; return target
    }
    func shareCompleted(activity: UIActivity.ActivityType?, accepted: Bool, label: String) {
        guard accepted else { return }
        let blip = activity?.rawValue.localizedCaseInsensitiveContains("blip") == true
        update(Transfer(name: label, device: blip ? "Blip account" : "iOS share sheet", direction: "Outgoing", state: blip ? "Handed to Blip" : "Handed to app"))
        selected = []; tab = 2
    }
    func importConnections(_ file: URL) async {
        do {
            guard readable else { throw DriveError.message("The saved device list is unavailable.") }
            let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max; guard size <= 262144 else { throw DriveError.message("The connection file is too large.") }
            struct Export: Decodable { let devices: [Device] }
            let imported = try JSONDecoder().decode(Export.self, from: Data(contentsOf: file)); guard imported.devices.count <= 100 else { throw DriveError.message("Too many connections.") }
            var updated = devices
            for candidate in imported.devices { var device = candidate; device.id = UUID().uuidString; guard !device.name.trimmingCharacters(in: .whitespaces).isEmpty, (1...65535).contains(device.port) else { throw DriveError.message("The connection profile is invalid.") }; _ = try RemotePath.server(device.host); _ = try RemotePath.name(device.share); _ = try RemotePath.clean(device.root); if !updated.contains(where: { $0.host == device.host && $0.share == device.share && $0.root == device.root }) { updated.append(device) } }
            try LocalStore.save(updated, "devices.json"); devices = updated
        } catch { self.error = Self.friendly(error) }
    }
    func receivedFolder(_ folder: URL) {
        do { let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }; UserDefaults.standard.set(try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "blip_received_folder"); loadReceived() }
        catch { self.error = "This folder could not be kept. Choose it again from Files." }
    }
    private func resolveReceived() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "blip_received_folder") else { return nil }; var stale = false
        return try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    func loadReceived() {
        do { guard let folder = try resolveReceived() else { return }; let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }; receivedEntries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } }
        catch { error = "The selected received folder is unavailable. Choose it again." }
    }
    func importReceived(_ source: URL) {
        Task { do { guard let folder = try resolveReceived() else { return }; let target = try await Task.detached { let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }; let directory = LocalStore.received.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); let target = directory.appendingPathComponent(source.lastPathComponent); try FileManager.default.copyItem(at: source, to: target); return target }.value; update(Transfer(name: target.lastPathComponent, device: "Blip received folder", direction: "Incoming", state: "Imported", localPath: target.path)); tab = 2 } catch { self.error = "The received file could not be imported. Wait until Blip finishes receiving it, then try again." } }
    }
    static func friendly(_ error: Error) -> String { if let own = error as? DriveError { return own.localizedDescription }; return "The operation could not be confirmed. Check Tailscale, the share name, account password and server permissions before retrying." }
}

struct ShareItems: Identifiable { let id = UUID(); let items: [Any]; let label: String }
