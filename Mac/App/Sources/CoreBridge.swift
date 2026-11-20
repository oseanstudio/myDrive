// Bridge to the shared Rust core (mydrive-core). One sidecar process per
// request: a single JSON request on stdin, a single {"ok",...} line on stdout.
// Secrets travel only through stdin; cancellation terminates the process.
import Foundation
import Darwin

struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class CoreBridge {
    static let shared = CoreBridge()
    let executable: URL

    init(executable overrideURL: URL? = nil) {
        if let overrideURL { executable = overrideURL; return }
        if let bundled = Bundle.main.url(forResource: "mydrive-core", withExtension: nil) {
            executable = bundled
        } else if let sibling = Bundle.main.resourceURL?.appendingPathComponent("mydrive-core"),
                  FileManager.default.isExecutableFile(atPath: sibling.path) {
            executable = sibling
        } else {
            executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("mydrive-core")
        }
    }

    /// Sends one request. `request` supplies the fields documented in
    /// Core/src/main.rs (bookmark, credentials, path, syncthing, payload...).
    func call(action: String, request: [String: Any] = [:], timeout: TimeInterval? = 45) async throws -> Any? {
        var payload: JSON = ["action": action]
        for (key, value) in request { payload[key] = value }
        let stdinData = try JSONSerialization.data(withJSONObject: payload)

        try Task.checkCancellation()
        let invocation = CoreInvocation(executable: executable)
        let result: (code: Int32, output: Data) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try invocation.run(payload: stdinData, timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            invocation.stop(cancelled: true)
        }
        try Task.checkCancellation()

        if result.code == 9 || result.code == 15 {
            throw CoreError(message: "The connection service stopped unexpectedly. Please try again.")
        }
        let parsed = (try? JSONSerialization.jsonObject(with: result.output)) as? JSON
        guard let parsed else {
            throw CoreError(message: "The connection service returned an unreadable response. Please try again.")
        }
        if parsed.bool("ok") { return parsed["data"] }
        throw CoreError(message: parsed.str("error").isEmpty
            ? "The connection service reported an unknown problem."
            : parsed.str("error"))
    }

    // MARK: - Process plumbing

    // MARK: - Typed helpers

    func loadBookmarks(dataDir: URL) async throws -> [Bookmark] {
        let data = try await call(action: "bookmarks.load", request: ["data_dir": dataDir.path])
        return (data as? [Any] ?? []).map { Bookmark(from: $0 as? JSON ?? [:]) }
    }

    func saveBookmarks(_ bookmarks: [Bookmark], dataDir: URL) async throws {
        try await call(action: "bookmarks.save",
                       request: ["data_dir": dataDir.path,
                                 "bookmarks": bookmarks.map(\.dict)])
    }

    func fileAction(_ action: String, bookmark: Bookmark, credentials: Credentials,
                    extra: [String: Any] = [:], timeout: TimeInterval? = 45) async throws -> Any? {
        var request: JSON = ["bookmark": bookmark.dict, "credentials": credentials.dict, "data_dir": Paths.dataDir.path]
        for (key, value) in extra { request[key] = value }
        return try await call(action: action, request: request, timeout: timeout)
    }
}

/// One owner per call: cancelling a transfer cannot terminate a concurrent poll.
/// Launch and early cancellation share a lock so cancellation cannot miss launch.
private final class CoreInvocation: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancellation = false
    private var timedOut = false
    init(executable: URL) { process.executableURL = executable }

    func stop(cancelled: Bool) {
        lock.lock()
        if cancelled { cancellation = true } else { timedOut = true }
        let running = process.isRunning
        if running { process.terminate() }
        lock.unlock()
        if running {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
                lock.lock(); defer { lock.unlock() }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func run(payload: Data, timeout: TimeInterval?) throws -> (code: Int32, output: Data) {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        lock.lock()
        if cancellation { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        let watchdog = DispatchWorkItem { [weak self] in self?.stop(cancelled: false) }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }
        defer { watchdog.cancel() }
        // Drain stderr concurrently, without keeping credentials/diagnostic text.
        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            while !stderr.fileHandleForReading.readData(ofLength: 16_384).isEmpty {}
            drains.leave()
        }
        do { try stdin.fileHandleForWriting.write(contentsOf: payload) }
        catch { stop(cancelled: false) }
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); drains.wait()
        lock.lock(); let cancelled = cancellation; let expired = timedOut; lock.unlock()
        if cancelled { throw CancellationError() }
        if expired { throw CoreError(message: "The connection service took too long. Please try again.") }
        return (process.terminationStatus, output)
    }
}
