import Foundation
import AMSMB2

final class SMBService: @unchecked Sendable {
    let device: Device
    let client: SMB2Manager
    init(_ device: Device) throws {
        self.device = device
        var parts = URLComponents(); parts.scheme = "smb"; parts.host = device.host; parts.port = device.port
        guard let url = parts.url, let manager = SMB2Manager(url: url, domain: device.domain, credential: URLCredential(user: device.username, password: try Passwords.read(device.id), persistence: .forSession)) else { throw DriveError.message("The SMB address is invalid.") }
        client = manager; client.timeout = 30
    }
    private func path(_ relative: String) throws -> String { try RemotePath.clean([device.root, relative].filter { !$0.isEmpty }.joined(separator: "/")) }
    func connect() async throws { try await client.connectShare(name: device.share, encrypted: device.encrypted) }
    func disconnect() async { try? await client.disconnectShare(gracefully: true) }
    func list(_ relative: String) async throws -> [RemoteEntry] {
        try await connect()
        let result = try await client.contentsOfDirectory(atPath: path(relative), recursive: false)
        return try result.compactMap { item in
            guard let name = item[.nameKey] as? String, name != ".", name != ".." else { return nil }
            return RemoteEntry(name: name, path: try RemotePath.child(relative, name), directory: item[.isDirectoryKey] as? Bool ?? false, size: (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0, linked: item[.isSymbolicLinkKey] as? Bool ?? false)
        }.sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    func mkdir(_ relative: String) async throws { try await connect(); try await client.createDirectory(atPath: path(relative)) }
    func rename(_ relative: String, to destination: String) async throws { try await connect(); try await client.moveItem(atPath: path(relative), toPath: path(destination)) }
    func delete(_ entry: RemoteEntry) async throws {
        guard !entry.linked else { throw DriveError.message("Linked items cannot be changed in this preview.") }
        try await connect()
        if entry.directory { try await client.removeDirectory(atPath: path(entry.path), recursive: false) } else { try await client.removeFile(atPath: path(entry.path)) }
    }
    func download(_ entry: RemoteEntry, flag: CancellationFlag, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard !entry.directory, !entry.linked else { throw DriveError.message("Choose a regular file.") }
        try await connect()
        let folder = LocalStore.received.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appendingPathComponent(try RemotePath.name(entry.name)); let partial = folder.appendingPathComponent(".partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await client.downloadItem(atPath: path(entry.path), to: partial, progress: { done, total in progress(done, total); return flag.active })
        guard flag.active else { throw CancellationError() }
        try FileManager.default.moveItem(at: partial, to: final)
        return final
    }
    func upload(_ source: URL, to directory: String, flag: CancellationFlag, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let name = try RemotePath.name(source.lastPathComponent)
        let total = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try await connect()
        let temporary = try path(RemotePath.child(directory, ".mydrive-\(UUID().uuidString).partial"))
        let final = try path(RemotePath.child(directory, name)); var committed = false
        do {
            try await client.uploadItem(at: source, toPath: temporary, progress: { done in progress(done, total); return flag.active })
            guard flag.active else { throw CancellationError() }
            try await client.moveItem(atPath: temporary, toPath: final); committed = true
        } catch { if !committed { try? await client.removeFile(atPath: temporary) }; throw error }
    }
}
