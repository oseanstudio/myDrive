import CryptoKit
import Darwin
import Foundation

enum BlipMacEngine: Int32, LocalizedError {
    case missing = 20
    case version = 21
    case profile = 22
    case launch = 23
    case permission = 24

    var errorDescription: String? {
        switch self {
        case .missing: return "Install Blip for Mac and sign in once."
        case .version: return "This Blip version is unsupported by the background service."
        case .profile: return "Use Open Blip to sign in once, then refresh Send & Receive."
        case .launch: return "The native background Blip engine could not start."
        case .permission: return "myDrive needs permission to access Blip’s local data. Allow access if macOS asks, then refresh Send & Receive."
        }
    }

    static let group = "AY8UB8KTUX.blip"
    static let bundleID = "net.blip.macos"
    static let frameworkPath = "Contents/Frameworks/BlipKit.framework/Versions/A/BlipKit"
    private static let reviewedHash = "d839f07f7ff1c15c4ed144dbf2d09300d3a2c4b061f974a099c1f31a1a34d500"
    static var groupDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/" + group, isDirectory: true)
    }

    static func runInstalled(appPath: String) throws {
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else { throw Self.missing }
        let storage = groupDirectory
        try checkProfile(storage.appendingPathComponent("state.dat"))

        try run(framework: app.appendingPathComponent(frameworkPath),
                cache: storage.appendingPathComponent("Library/Caches", isDirectory: true),
                storage: storage, server: "https://prod.blip.net", namespace: group + "/")
    }

    private static func checkProfile(_ profile: URL) throws {
        let descriptor = Darwin.open(profile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            let failure = errno
            throw failure == EACCES || failure == EPERM ? Self.permission : Self.profile
        }
        defer { Darwin.close(descriptor) }
        var state = stat()
        guard fstat(descriptor, &state) == 0, state.st_uid == geteuid(),
              (state.st_mode & S_IFMT) == S_IFREG else { throw Self.profile }
    }

    // The reviewed framework starts asynchronously and elects one host per namespace.
    // Keep this library in a child process so stop/EOF can flush it even if the UI quits.
    static func run(framework: URL, cache: URL, storage: URL, server: String, namespace: String) throws {
        guard let bytes = try? Data(contentsOf: framework, options: .mappedIfSafe), bytes.count <= 64 * 1024 * 1024,
              CryptoKit.SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == reviewedHash else { throw Self.version }
        guard let library = dlopen(framework.path, RTLD_NOW | RTLD_LOCAL),
              let startSymbol = dlsym(library, "libblip_host"), let stopSymbol = dlsym(library, "libblip_host_stop") else { throw Self.launch }
        typealias CString = UnsafePointer<CChar>
        typealias Start = @convention(c) (Int32, CString, CString, CString, CString) -> Void
        typealias Stop = @convention(c) () -> Void
        let start = unsafeBitCast(startSymbol, to: Start.self)
        let stop = unsafeBitCast(stopSymbol, to: Stop.self)
        start(1, cache.path, storage.path, server, namespace)
        _ = FileHandle.standardInput.availableData
        stop()
    }
}
