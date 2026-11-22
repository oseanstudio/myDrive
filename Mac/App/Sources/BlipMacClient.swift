import Foundation

@MainActor final class BlipMacClient {
    struct Unavailable: Error {}
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    static func request(_ action: String, _ payload: JSON) async throws -> JSON {
        let reply = try await CoreBridge.shared.call(action: "blip.native." + action,
            request: ["payload": payload], timeout: 30)
        guard let result = reply as? JSON else { throw invalidReply }
        return result
    }

    func poll() async throws -> JSON {
        if process?.isRunning != true {
            stop()
            let child = Process()
            let requests = Pipe(), replies = Pipe()
            child.executableURL = CoreBridge.shared.executable
            child.arguments = ["--blip-mac-poll"]
            child.standardInput = requests
            child.standardOutput = replies
            child.standardError = FileHandle.nullDevice
            try child.run()
            process = child
            input = requests.fileHandleForWriting
            output = replies.fileHandleForReading
        }
        guard let input, let output else { throw Self.invalidReply }
        let bytes: Data
        do {
            try input.write(contentsOf: Data("POLL\n".utf8))
            bytes = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try Self.readReply(output)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } catch {
            stop()
            throw error
        }
        guard let reply = (try? JSONSerialization.jsonObject(with: bytes)) as? JSON else {
            stop()
            throw Self.invalidReply
        }
        guard reply.bool("ok"), let result = reply["data"] as? JSON else {
            if reply.bool("unavailable") { throw Unavailable() }
            throw CoreError(message: reply.str("error"))
        }
        return result
    }

    func stop() {
        try? input?.close()
        input = nil
        output = nil
        process = nil
    }

    nonisolated private static var invalidReply: CoreError {
        CoreError(message: "Blip returned an unreadable response. Refresh Blip and try again.")
    }

    nonisolated private static func readReply(_ handle: FileHandle) throws -> Data {
        var reply = Data()
        while reply.count < 64 * 1024 * 1024 {
            let bytes = handle.availableData
            guard !bytes.isEmpty else { break }
            reply.append(bytes)
            if bytes.last == 10 { return reply }
        }
        throw invalidReply
    }
}
