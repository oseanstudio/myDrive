// Shared helpers for the macOS shell. No UI imports.
import CommonCrypto
import Foundation

typealias JSON = [String: Any]

extension [String: Any] {
    func str(_ key: String) -> String { self[key] as? String ?? "" }
    func optStr(_ key: String) -> String? { self[key] as? String }
    func int64(_ key: String) -> Int64 { (self[key] as? NSNumber)?.int64Value ?? 0 }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    func dict(_ key: String) -> JSON { self[key] as? JSON ?? [:] }
    func array(_ key: String) -> [Any] { self[key] as? [Any] ?? [] }
}

enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("myDrive", isDirectory: true)
    }
    static var dataDir: URL {
        let url = appSupport
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static let home = URL(fileURLWithPath: NSHomeDirectory())

    /// The myDrive project folder, found by walking up from the executable
    /// until a directory contains PLAN.md and Core (mirrors the Windows shell).
    static func projectFolder() -> String {
        if let pointer = Bundle.main.url(forResource: "project-root", withExtension: "txt"),
           let saved = try? String(contentsOf: pointer, encoding: .utf8) {
            let path = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.fileExists(atPath: path + "/PLAN.md"),
               FileManager.default.fileExists(atPath: path + "/Core") { return path }
        }
        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            let directory = url.path
            if FileManager.default.fileExists(atPath: directory + "/PLAN.md"),
               FileManager.default.fileExists(atPath: directory + "/Core") {
                return directory
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return Paths.home.appendingPathComponent("Documents").path
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
    static func modified(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsers = [ISO8601DateFormatter(), fractional]
        for parser in parsers {
            if let date = parser.date(from: raw) {
                return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
            }
        }
        // HTTP-date and other server formats fall back to the raw text.
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = rfc.date(from: raw) {
            return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        }
        return raw
    }
    static func time(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .medium)
    }
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Runs a short-lived command-line helper with a hard deadline.
enum Shell {
    struct Output {
        let code: Int32
        let stdout: String
        let stderr: String
    }
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 20) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return Output(
            code: process.terminationStatus,
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? ""
        )
    }
}

enum AtomicFile {
    /// Writes via a temporary file in the same directory, then replaces.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    static func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try write(data, to: url)
    }
    static func readJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

enum SHA256 {
    static func hex(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
