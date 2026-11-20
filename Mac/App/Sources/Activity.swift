// Activity history and the Syncthing recent-updates feed, capped and persisted
// with atomic writes (mirrors the Windows 200-entry activity model).
import Foundation

struct ActivityEntry: Identifiable, Codable {
    var id = UUID()
    let time: Date
    let operation: String
    let connection: String
    let detail: String
    let success: Bool

    init(time: Date = Date(), operation: String, connection: String, detail: String, success: Bool) {
        self.time = time
        self.operation = operation
        self.connection = connection
        self.detail = detail
        self.success = success
    }
}

struct UpdateEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let time: Date
    let text: String
    let kind: String // "file" | "device" | "folder" | "error"
    let folderId: String
    var eventID: UInt64? = nil

    init(time: Date = Date(), text: String, kind: String, folderId: String) {
        self.time = time
        self.text = text
        self.kind = kind
        self.folderId = folderId
    }
}

final class ActivityLog {
    static let shared = ActivityLog()
    private(set) var activity: [ActivityEntry] = []
    private(set) var updates: [UpdateEntry] = []
    private let limit = 200
    private let activityURL = Paths.dataDir.appendingPathComponent("activity.json")
    private let updatesURL = Paths.dataDir.appendingPathComponent("recent-updates.json")
    private let writer = DispatchQueue(label: "io.mydrive.activity-writer", qos: .utility)
    private var pendingWrite: DispatchWorkItem?

    private init() {
        if let raw = AtomicFile.readJSON(activityURL) {
            let data = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data()
            activity = (try? JSONDecoder().decode([ActivityEntry].self, from: data)) ?? []
        }
        if let raw = AtomicFile.readJSON(updatesURL) {
            let data = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data()
            updates = (try? JSONDecoder().decode([UpdateEntry].self, from: data)) ?? []
        }
    }

    func append(_ entry: ActivityEntry) {
        activity.insert(entry, at: 0)
        if activity.count > limit { activity.removeLast(activity.count - limit) }
        persist()
    }

    func append(_ update: UpdateEntry) {
        append(contentsOf: [update])
    }

    func append(contentsOf batch: [UpdateEntry]) {
        var ids = Set(updates.compactMap(\.eventID))
        let fresh = batch.filter { entry in
            if let id = entry.eventID { return ids.insert(id).inserted }
            return !updates.contains { $0.time == entry.time && $0.text == entry.text && $0.kind == entry.kind && $0.folderId == entry.folderId }
        }
        guard !fresh.isEmpty else { return }
        updates.insert(contentsOf: fresh.reversed(), at: 0)
        if updates.count > limit { updates.removeLast(updates.count - limit) }
        persist()
    }

    private func persist() {
        pendingWrite?.cancel()
        let activity = activity, updates = updates, activityURL = activityURL, updatesURL = updatesURL
        let item = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(activity) { try? AtomicFile.write(data, to: activityURL) }
            if let data = try? JSONEncoder().encode(updates) { try? AtomicFile.write(data, to: updatesURL) }
        }
        pendingWrite = item
        writer.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func flush() {
        pendingWrite?.cancel(); pendingWrite = nil
        let activity = activity, updates = updates
        writer.sync {
            if let data = try? JSONEncoder().encode(activity) { try? AtomicFile.write(data, to: activityURL) }
            if let data = try? JSONEncoder().encode(updates) { try? AtomicFile.write(data, to: updatesURL) }
        }
    }
}
