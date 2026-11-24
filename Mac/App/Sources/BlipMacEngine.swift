import AppKit
import CryptoKit
import Darwin
import Foundation

enum BlipMacPaths {
    static let managedNamespace = "net.oseanstudio.mydrive.blip/"
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["TMPDIR"] = FileManager.default.temporaryDirectory.path
        return environment
    }
    static var managedProfile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myDrive/Blip", isDirectory: true)
    }
    static var managedCache: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mdblip", isDirectory: true)
    }
    static var receivedDirectory: URL {
        URL.downloadsDirectory.appendingPathComponent("myDrive", isDirectory: true)
    }
}

enum BlipMacEngine: Int32, LocalizedError {
    case missing = 20
    case version = 21
    case profile = 22
    case launch = 23
    case permission = 24
    case download = 25

    var errorDescription: String? {
        switch self {
        case .missing: return "Choose Set up Blip to get the background engine."
        case .version: return "This Blip version is unsupported by the background service."
        case .profile: return "myDrive could not open its Blip profile."
        case .launch: return "The native background Blip engine could not start."
        case .permission: return "myDrive needs permission to access Blip’s local data. Allow access if macOS asks, then refresh the Blip tab."
        case .download: return "The Blip engine could not be downloaded. Check your internet connection and try again."
        }
    }

    static let group = "AY8UB8KTUX.blip"
    static let bundleID = "net.blip.macos"
    static let frameworkPath = "Contents/Frameworks/BlipKit.framework/Versions/A/BlipKit"
    static let supportPath = "Contents/Frameworks/libswiftCompatibilitySpan.dylib"
    private static let frameworkBundlePath = "Contents/Frameworks/BlipKit.framework"
    private static let reviewedHash = "d839f07f7ff1c15c4ed144dbf2d09300d3a2c4b061f974a099c1f31a1a34d500"
    private static let archiveHash = "1109ced4e804026c73bb108c2a9b1ae1324d99a94b9d7f1725d7c1f191b37825"
    private static let supportHash = "05256a8721361bb24eb006313bc95b02f326895f3ab71644e9ec2af98840b882"
    private static let archiveURL = "https://static.blip.net/mac/Blip-20261029214736.zip"
    private static var runtimeDirectory: URL { BlipMacPaths.managedProfile.appendingPathComponent("runtime-1", isDirectory: true) }
    private static var runtimeLibrary: URL { runtimeDirectory.appendingPathComponent(frameworkPath) }
    static func frameworkBundle(containing library: URL) -> URL {
        (0..<3).reduce(library) { path, _ in path.deletingLastPathComponent() }
    }
    static func supportLibrary(beside framework: URL) -> URL {
        frameworkBundle(containing: framework).deletingLastPathComponent()
            .appendingPathComponent("libswiftCompatibilitySpan.dylib")
    }
    static var groupDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/" + group, isDirectory: true)
    }

    @MainActor static var installedApplication: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? [URL(fileURLWithPath: "/Applications/Blip.app"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Blip.app")]
            .first { Bundle(url: $0)?.bundleIdentifier == bundleID }
    }

    @MainActor static var engineAvailable: Bool {
        FileManager.default.fileExists(atPath: runtimeLibrary.path) || installedApplication != nil
    }

    @MainActor static func runBackground(allowDownload: Bool) throws {
        let framework = try prepareEngine(installed: installedApplication, allowDownload: allowDownload)
        let desktopState = groupDirectory.appendingPathComponent("state.dat")
        let storage = BlipMacPaths.managedProfile.appendingPathComponent("state", isDirectory: true)
        let useDesktopProfile: Bool
        do {
            try checkProfile(desktopState)
            useDesktopProfile = true
        } catch BlipMacEngine.permission {
            // A separate, existing myDrive sign-in is still usable if access to Blip's profile was denied.
            guard (try? checkProfile(storage.appendingPathComponent("state.dat"))) != nil else { throw Self.permission }
            useDesktopProfile = false
        } catch BlipMacEngine.profile {
            useDesktopProfile = false
        }
        if useDesktopProfile {
            let cache = groupDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try run(framework: framework, cache: cache, storage: groupDirectory,
                    server: "https://prod.blip.net", namespace: group + "/")
        } else {
            let cache = BlipMacPaths.managedCache
            for directory in [storage, cache] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw Self.profile }
            }
            try run(framework: framework, cache: cache, storage: storage,
                    server: "https://prod.blip.net", namespace: BlipMacPaths.managedNamespace,
                    prepare: prepareManagedProfile)
        }
    }

    private static func prepareManagedProfile() throws {
        guard let core = Bundle.main.url(forResource: "mydrive-core", withExtension: nil) else { throw Self.launch }
        let process = Process()
        process.executableURL = core
        process.environment = BlipMacPaths.environment
        process.arguments = ["--blip-engine", "prepare"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Self.launch }
    }

    private static func checkedContents(_ file: URL, hash: String, limit: UInt64) -> Data? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let length = values.fileSize, length > 0, UInt64(length) <= limit,
              let bytes = try? Data(contentsOf: file, options: .mappedIfSafe),
              bytes.count == length,
              CryptoKit.SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else { return nil }
        return bytes
    }

    private static func prepareEngine(installed: URL?, allowDownload: Bool) throws -> URL {
        let limit: UInt64 = 64 * 1024 * 1024
        func verified(_ root: URL) -> Bool {
            checkedContents(root.appendingPathComponent(supportPath), hash: supportHash, limit: 1024 * 1024) != nil &&
                checkedContents(root.appendingPathComponent(frameworkPath), hash: reviewedHash, limit: limit) != nil
        }
        if verified(runtimeDirectory) { return runtimeLibrary }
        let fm = FileManager.default
        try fm.createDirectory(at: BlipMacPaths.managedProfile, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let work = BlipMacPaths.managedProfile.appendingPathComponent(".engine-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let staged = work.appendingPathComponent("Blip.app", isDirectory: true)
        if let installed, verified(installed) {
            let signedBundle = staged.appendingPathComponent(frameworkBundlePath)
            try fm.createDirectory(at: signedBundle.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: installed.appendingPathComponent(frameworkBundlePath), to: signedBundle)
            try fm.copyItem(at: installed.appendingPathComponent(supportPath), to: staged.appendingPathComponent(supportPath))
        } else {
            guard allowDownload else { throw installed == nil ? Self.missing : Self.version }
            let archive = work.appendingPathComponent("blip.zip")
            try tool("/usr/bin/curl", ["--fail", "--silent", "--location", "--proto", "=https", "--proto-redir", "=https",
                                      "--max-time", "120", "--max-filesize", String(limit), "--output", archive.path, archiveURL])
            guard checkedContents(archive, hash: archiveHash, limit: limit) != nil else { throw Self.version }
            try tool("/usr/bin/unzip", ["-q", archive.path, "Blip.app/" + frameworkBundlePath + "/*",
                                      "Blip.app/" + supportPath, "-d", work.path])
        }
        guard verified(staged) else { throw Self.version }
        // Preserve the bundle's resources and signature. dyld rejects the bare framework executable.
        try tool("/usr/bin/codesign", ["--verify", "--strict", staged.appendingPathComponent(frameworkBundlePath).path])
        do {
            if fm.fileExists(atPath: runtimeDirectory.path) {
                if verified(runtimeDirectory) { return runtimeLibrary }
                _ = try fm.replaceItemAt(runtimeDirectory, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: runtimeDirectory)
            }
        } catch {
            guard verified(runtimeDirectory) else { throw error }
        }
        guard verified(runtimeDirectory) else { throw Self.version }
        return runtimeLibrary
    }

    private static func tool(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Self.download }
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
    static func run(framework: URL, cache: URL, storage: URL, server: String, namespace: String,
                    prepare: (() throws -> Void)? = nil, diagnostic: ((String) -> Void)? = nil) throws {
        guard checkedContents(framework, hash: reviewedHash, limit: 64 * 1024 * 1024) != nil else { throw Self.version }
        let support = supportLibrary(beside: framework)
        guard checkedContents(support, hash: supportHash, limit: 1024 * 1024) != nil else { throw Self.version }
        // The vendor library has an @rpath dependency on this Swift compatibility library.
        guard dlopen(support.path, RTLD_NOW | RTLD_GLOBAL) != nil,
              let library = dlopen(framework.path, RTLD_NOW | RTLD_LOCAL),
              let startSymbol = dlsym(library, "libblip_host"), let stopSymbol = dlsym(library, "libblip_host_stop") else {
            if let detail = dlerror() { diagnostic?(String(cString: detail)) }
            throw Self.launch
        }
        typealias CString = UnsafePointer<CChar>
        typealias Start = @convention(c) (Int32, CString, CString, CString, CString) -> Void
        typealias Stop = @convention(c) () -> Void
        let start = unsafeBitCast(startSymbol, to: Start.self)
        let stop = unsafeBitCast(stopSymbol, to: Stop.self)
        start(1, cache.path, storage.path, server, namespace)
        defer { stop() }
        try prepare?()
        _ = FileHandle.standardInput.availableData
    }
}
