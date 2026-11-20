import Foundation
import Security

enum Passwords {
    private static func query(_ id: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "net.oseanstudio.mydrive.smb", kSecAttrAccount as String: id] }
    static func read(_ id: String) throws -> String {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw DriveError.message("The saved password is unavailable. Unlock the phone and edit this device.") }
        return value
    }
    static func save(_ id: String, _ value: String) throws {
        let data = Data(value.utf8); let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DriveError.message("The password could not be saved.") }
        var q = query(id); q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw DriveError.message("The password could not be saved.") }
    }
    static func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}
enum LocalStore {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("myDrive", isDirectory: true)
    static var received: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Received", isDirectory: true) }
    static func read<T: Decodable>(_ name: String, fallback: T) throws -> T {
        let file = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return fallback }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    }
    static func save<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    static var autoOpenLinks: Bool { get { UserDefaults.standard.object(forKey: "blip_auto_open_links") as? Bool ?? true } set { UserDefaults.standard.set(newValue, forKey: "blip_auto_open_links") } }
}
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
}
