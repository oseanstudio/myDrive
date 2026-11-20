// Data models mirroring the Rust core's JSON shapes (Core/src/model.rs and
// Core/src/syncthing.rs). Parsed with JSONSerialization helpers for tolerance.
import Foundation

struct Credentials: Codable, Equatable {
    var password = ""
    var privateKey = ""
    var passphrase = ""
    var sessionToken = ""

    enum CodingKeys: String, CodingKey {
        case password
        case privateKey = "private_key"
        case passphrase
        case sessionToken = "session_token"
    }
    var isEmpty: Bool { self == Credentials() }
    var dict: JSON {
        ["password": password, "private_key": privateKey,
         "passphrase": passphrase, "session_token": sessionToken]
    }
}

struct Bookmark: Identifiable, Equatable {
    var id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var nickname = ""
    var protocolKind = "local"
    var host = ""
    var port = 0
    var path = ""
    var username = ""
    var credentialsRef = ""
    var mountPath = ""
    var options: [String: String] = [:]

    init() {}
    init(from dict: JSON) {
        id = dict.str("id")
        nickname = dict.str("nickname")
        protocolKind = dict.str("protocol")
        if protocolKind.isEmpty { protocolKind = "local" }
        host = dict.str("host")
        port = Int(dict.int64("port"))
        path = dict.str("path")
        username = dict.str("username")
        credentialsRef = dict.str("credentials_ref")
        mountPath = dict.str("mount_path")
        var gathered: [String: String] = [:]
        for (key, value) in dict.dict("options") {
            if let text = value as? String { gathered[key] = text }
        }
        options = gathered
    }

    var dict: JSON {
        ["id": id, "nickname": nickname, "protocol": protocolKind, "host": host,
         "port": port, "path": path, "username": username,
         "credentials_ref": credentialsRef, "mount_path": mountPath, "options": options]
    }

    var protocolName: String {
        switch protocolKind {
        case "local": return "Local folder"
        case "smb": return "SMB"
        case "sftp": return "SFTP"
        case "webdav": return "WebDAV"
        case "s3": return "S3"
        default: return protocolKind.uppercased()
        }
    }
    var location: String {
        switch protocolKind {
        case "local": return host
        case "smb": return "//\(host)/\(path)"
        default: return path.isEmpty ? host : "\(host) / \(path)"
        }
    }
    /// Root path handed to the core. SMB on macOS means an existing /Volumes
    /// mount, which the core's local client serves.
    var coreHost: String {
        protocolKind == "smb" ? mountPath : host
    }
}

struct RemoteFile: Identifiable, Equatable {
    let name: String
    let path: String
    let size: Int64
    let modified: String
    let isDir: Bool
    var id: String { path }

    init(from raw: Any) {
        let dict = raw as? JSON ?? [:]
        name = dict.str("name")
        path = dict.str("path")
        size = dict.int64("size")
        modified = dict.str("modified")
        isDir = dict.bool("is_dir")
    }
}

struct SyncthingFolder: Identifiable {
    let id: String
    let label: String
    let path: String
    let type: String
    let paused: Bool
    let deviceCount: Int
    let deviceIDs: [String]
    let status: FolderStatus
    let error: String?
    let errorAdvice: String
    var displayName: String { label.isEmpty ? id : label }
    var hasError: Bool { (error?.isEmpty == false) || status.pullErrors > 0 || status.errors > 0 }
    var peerDirection: String {
        switch type {
        case "sendonly": return "To"
        case "receiveonly", "receiveencrypted": return "From"
        default: return "To & from"
        }
    }
}

struct FolderStatus {
    let state: String
    let stateChanged: String
    let globalBytes: Int64
    let globalFiles: Int64
    let localFiles: Int64
    let inSyncBytes: Int64
    let inSyncFiles: Int64
    let needBytes: Int64
    let needFiles: Int64
    let needDeletes: Int64
    let pullErrors: Int64
    let errors: Int64
    let receiveOnlyChangedFiles: Int64
}

struct SyncthingDevice: Identifiable {
    let deviceID: String
    let name: String
    let paused: Bool
    let isLocal: Bool
    let connected: Bool
    let clientVersion: String
    var displayName: String {
        if !name.isEmpty { return name }
        return isLocal ? "This computer" : String(deviceID.prefix(7))
    }
    var id: String { deviceID }
}

struct Snapshot {
    let version: String
    let folders: [SyncthingFolder]
    let devices: [SyncthingDevice]
    let systemErrors: [String]

    init(from raw: Any) {
        let dict = raw as? JSON ?? [:]
        version = dict.str("version")
        folders = dict.array("folders").map { raw in
            let f = raw as? JSON ?? [:]
            let status = f.dict("status")
            return SyncthingFolder(
                id: f.str("id"),
                label: f.str("label"),
                path: f.str("path"),
                type: f.str("type"),
                paused: f.bool("paused"),
                deviceCount: Int(f.int64("device_count")),
                deviceIDs: f.array("device_ids").compactMap { $0 as? String },
                status: FolderStatus(
                    state: status.str("state"),
                    stateChanged: status.str("stateChanged"),
                    globalBytes: status.int64("globalBytes"),
                    globalFiles: status.int64("globalFiles"),
                    localFiles: status.int64("localFiles"),
                    inSyncBytes: status.int64("inSyncBytes"),
                    inSyncFiles: status.int64("inSyncFiles"),
                    needBytes: status.int64("needBytes"),
                    needFiles: status.int64("needFiles"),
                    needDeletes: status.int64("needDeletes"),
                    pullErrors: status.int64("pullErrors"),
                    errors: status.int64("errors"),
                    receiveOnlyChangedFiles: status.int64("receiveOnlyChangedFiles")
                ),
                error: f.optStr("error"),
                errorAdvice: f.str("error_advice")
            )
        }
        devices = dict.array("devices").map { raw in
            let d = raw as? JSON ?? [:]
            let connection = d.dict("connection")
            return SyncthingDevice(
                deviceID: d.str("deviceID"),
                name: d.str("name"),
                paused: d.bool("paused"),
                isLocal: d.bool("is_local"),
                connected: connection.bool("connected"),
                clientVersion: connection.str("clientVersion")
            )
        }
        systemErrors = dict.array("errors").compactMap { ($0 as? JSON)?.str("message") }
    }
}

struct BrowseEntry: Identifiable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let modified: String
    let remote: Bool
    let local: Bool
    let alternativeFor: String
    let selection: String
    var id: String { path }
    var isAlternative: Bool { !alternativeFor.isEmpty }
    /// Display order per the Windows reference: directories first, then name.
    var sortKey: String { (isDir ? "0" : "1") + name.lowercased() }
}

struct SyncRule: Codable, Equatable {
    var path: String
    var sync: Bool
    var is_dir: Bool
}

struct BrowseResult {
    let localLimitReached: Bool
    let entries: [BrowseEntry]
    let rules: [SyncRule]
    let ignore: [String]
    let folderId: String
    let folderLabel: String
    let folderPath: String

    init(from raw: Any) {
        let dict = raw as? JSON ?? [:]
        localLimitReached = dict.bool("local_limit_reached")
        entries = dict.array("entries").map { raw in
            let e = raw as? JSON ?? [:]
            return BrowseEntry(
                name: e.str("name"),
                path: e.str("path"),
                isDir: e.bool("is_dir"),
                size: e.int64("size"),
                modified: e.str("modified"),
                remote: e.bool("remote"),
                local: e.bool("local"),
                alternativeFor: e.str("alternative_for"),
                selection: e.str("selection")
            )
        }
        let decoder = JSONDecoder()
        let rulesData = try? JSONSerialization.data(withJSONObject: dict.array("rules"))
        rules = (try? decoder.decode([SyncRule].self, from: rulesData ?? Data())) ?? []
        ignore = dict.array("ignore").compactMap { $0 as? String }
        let folder = dict.dict("folder")
        folderId = folder.str("id")
        folderLabel = folder.str("label")
        folderPath = folder.str("path")
    }
}

struct SyncEvent: Identifiable {
    let id: UInt64
    let type: String
    let time: String
    let data: JSON
}

struct EventsResult {
    let events: [SyncEvent]
    let lastId: UInt64

    init(from raw: Any) {
        let dict = raw as? JSON ?? [:]
        events = dict.array("events").map { raw in
            let e = raw as? JSON ?? [:]
            return SyncEvent(id: UInt64(max(0, e.int64("id"))), type: e.str("type"),
                             time: e.str("time"), data: e.dict("data"))
        }
        lastId = UInt64(max(0, dict.int64("last_id")))
    }
}

/// One pending/failed item row from syncthing.need / syncthing.errors.
struct IssueItem: Identifiable {
    let path: String
    let message: String
    let advice: String
    var id: String { path + message }
    init(from raw: Any) {
        let dict = raw as? JSON ?? [:]
        path = dict.str("path").isEmpty ? dict.str("file") : dict.str("path")
        message = dict.str("error").isEmpty ? dict.str("message") : dict.str("error")
        advice = dict.str("advice")
    }

    /// /rest/folder/errors wraps rows in {"errors": [...]} while need returns
    /// bare arrays; accept both shapes.
    static func rows(from raw: Any?) -> [IssueItem] {
        if let dict = raw as? JSON {
            return dict.array("errors").map(IssueItem.init(from:))
        }
        return (raw as? [Any] ?? []).map(IssueItem.init(from:))
    }
}

struct SavedVersion: Identifiable {
    let path: String
    let versionTime: String
    let modTime: String
    let size: Int64
    var id: String { path + versionTime }
    init(path: String, from raw: Any) {
        let dict = raw as? JSON ?? [:]
        self.path = path
        versionTime = dict.str("versionTime")
        modTime = dict.str("modTime")
        size = dict.int64("size")
    }
}
