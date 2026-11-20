import Foundation

struct Device: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var host: String
    var share: String
    var root = ""
    var username = ""
    var domain = ""
    var port = 445
    var encrypted = false
}
struct RemoteEntry: Identifiable, Equatable {
    var name: String
    var path: String
    var directory: Bool
    var size: Int64
    var linked = false
    var id: String { path }
}
struct Transfer: Identifiable, Codable {
    var id = UUID().uuidString
    var name: String
    var device: String
    var direction: String
    var state = "Queued"
    var bytes: Int64 = 0
    var total: Int64 = 0
    var localPath: String?
    var error: String?
    var active: Bool { ["Queued", "Connecting", "Transferring", "Saving"].contains(state) }
}
enum DriveError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
enum RemotePath {
    static func clean(_ value: String) throws -> String {
        guard !value.contains("\\"), !value.contains(":"), !value.contains("\0") else { throw DriveError.message("Use a relative path inside the share.") }
        let parts = value.split(separator: "/").filter { $0 != "." }
        guard !parts.contains("..") else { throw DriveError.message("The path must stay inside this share.") }
        return parts.joined(separator: "/")
    }
    static func name(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", value.rangeOfCharacter(from: CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)) == nil,
              !value.hasSuffix("."), !value.hasSuffix(" ") else { throw DriveError.message("Enter a single valid file or folder name.") }
        return value
    }
    static func child(_ parent: String, _ name: String) throws -> String { try clean([parent, self.name(name)].filter { !$0.isEmpty }.joined(separator: "/")) }
    static func server(_ input: String) throws -> (String, Int) {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: raw.lowercased().hasPrefix("smb://") ? raw : "smb://" + raw), url.scheme?.lowercased() == "smb",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path),
              (1...65535).contains(url.port ?? 445) else { throw DriveError.message("Enter the server hostname or Tailscale address; put the share in its own field.") }
        return (host, url.port ?? 445)
    }
}
enum LinkTarget {
    static func read(_ file: URL) -> URL? {
        guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 65536,
              let data = try? Data(contentsOf: file) else { return nil }
        var target: String?
        if file.pathExtension.lowercased() == "webloc" {
            target = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["URL"] as? String
        } else if file.pathExtension.lowercased() == "url", let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
            var section = false
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
                if line.hasPrefix("[") { section = line.lowercased() == "[internetshortcut]"; continue }
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if section, pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "url" { if target != nil { return nil }; target = String(pair[1]) }
            }
        }
        guard let raw = target?.trimmingCharacters(in: .whitespacesAndNewlines), raw.rangeOfCharacter(from: .controlCharacters) == nil, !raw.contains("\\"),
              let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
