// Safe fix requests between devices. A request is a small JSON envelope the
// requester writes into the shared folder at .mydrive-requests/<id>.json;
// Syncthing delivers it to every peer. The accepting device's myDrive scans
// that directory, offers a one-click Accept for whitelisted fixes, and writes
// <id>.response.json, which travels back the same way. Non-whitelisted fix
// kinds are refused on both ends.
import Foundation

/// Fix kinds a remote myDrive may be asked to run. Both the sender and the
/// acceptor validate against this list; anything else is refused.
enum FixKindRemote: String, Codable, CaseIterable {
    case rescan
    case unpause

    var title: String {
        switch self {
        case .rescan: return "Rescan this folder"
        case .unpause: return "Resume syncing this folder"
        }
    }

    var effect: String {
        switch self {
        case .rescan: return "Re-scans the folder on this computer and re-checks every file. No files are changed."
        case .unpause: return "Resumes syncing this folder on this computer. Paused folders stay paused otherwise."
        }
    }

    static func safe(_ raw: String?) -> FixKindRemote? {
        guard let raw else { return nil }
        return FixKindRemote(rawValue: raw)
    }
}

struct FixRequest: Codable, Identifiable, Equatable {
    let id: String
    let fix: String              // FixKindRemote raw value
    let folderId: String
    let created: Date
    let requesterName: String
    let requesterDeviceId: String
    let reason: String
    let targetDeviceId: String   // specific device id or "any"

    enum CodingKeys: String, CodingKey {
        case id, fix, created, reason
        case folderId = "folder_id"
        case requesterName = "requester_name"
        case requesterDeviceId = "requester_device_id"
        case targetDeviceId = "target_device_id"
    }
}

struct FixResponse: Codable, Equatable {
    let requestId: String
    let status: String           // accepted | declined | completed | failed
    let message: String
    let deviceName: String
    let time: Date

    enum CodingKeys: String, CodingKey {
        case status, message
        case requestId = "request_id"
        case deviceName = "device_name"
        case time
    }
}

/// One pending incoming (or unanswered outgoing) request found on disk.
struct PendingFixRequest: Identifiable, Equatable {
    let request: FixRequest
    let response: FixResponse?   // present when answered already
    var id: String { request.id }
    var isAnswered: Bool { response != nil }
}

enum FixRequestStore {
    static let directoryName = ".mydrive-requests"
    static let anyDevice = "any"

    static func directory(folderPath: String) -> URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Writes a request into the folder. Returns the file path.
    @discardableResult
    static func send(request: FixRequest, folderPath: String) throws -> String {
        guard FixKindRemote.safe(request.fix) != nil else {
            throw CoreError(message: "That fix type is not on the safe list, so it cannot be requested.")
        }
        let directory = self.directory(folderPath: folderPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        let url = directory.appendingPathComponent("\(request.id).json")
        try AtomicFile.write(data, to: url)
        return url.path
    }

    static func respond(requestId: String, folderPath: String, status: String,
                        message: String, deviceName: String) throws {
        let directory = self.directory(folderPath: folderPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let response = FixResponse(requestId: requestId, status: status, message: message,
                                   deviceName: deviceName, time: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        try AtomicFile.write(data, to: directory.appendingPathComponent("\(requestId).response.json"))
    }

    /// Reads every request file in the folder's mailbox and pairs it with a
    /// response when one exists. Malformed files are skipped. Unreadable
    /// folders return an empty list.
    static func scan(folderPath: String) -> [PendingFixRequest] {
        let directory = self.directory(folderPath: folderPath)
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var requests: [FixRequest] = []
        for name in names where name.hasSuffix(".json") && !name.contains(".response") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let request = try? decoder.decode(FixRequest.self, from: data) else { continue }
            requests.append(request)
        }
        var pending: [PendingFixRequest] = []
        for request in requests {
            let responseURL = directory.appendingPathComponent("\(request.id).response.json")
            var response: FixResponse?
            if let data = try? Data(contentsOf: responseURL) {
                response = try? decoder.decode(FixResponse.self, from: data)
            }
            pending.append(PendingFixRequest(request: request, response: response))
        }
        return pending.sorted { $0.request.created > $1.request.created }
    }

    /// Deletes the caller's own unanswered request, so the peer stops seeing it.
    static func cancel(requestId: String, folderPath: String) {
        let directory = self.directory(folderPath: folderPath)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(requestId).json"))
    }
}
