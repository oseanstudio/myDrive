import AppKit
import Darwin
import Foundation

typealias JSON = [String: Any]

@main struct BlipHostSmoke {
    static func main() throws {
        let args = CommandLine.arguments
        let framework = URL(fileURLWithPath: args[1])
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let namespace = "mydrive-" + root.lastPathComponent + "/"
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        if args[3] == "child" {
            try BlipMacEngine.run(framework: framework, cache: cache, storage: storage,
                                  server: "https://127.0.0.1:9", namespace: namespace,
                                  diagnostic: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
            return
        }
        let fm = FileManager.default
        let core = URL(fileURLWithPath: args[3])
        let home = root.appendingPathComponent("home")
        let profile = home.appendingPathComponent("Library/Application Support/myDrive/Blip")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        let override = profile.appendingPathComponent("desktop-socket.txt")
        precondition(NSRunningApplication.runningApplications(withBundleIdentifier: BlipMacEngine.bundleID).isEmpty)
        let cached = root.appendingPathComponent(BlipMacEngine.frameworkPath)
        let cachedBundle = BlipMacEngine.frameworkBundle(containing: cached)
        let support = BlipMacEngine.supportLibrary(beside: cached)
        try fm.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: BlipMacEngine.frameworkBundle(containing: framework), to: cachedBundle)
        try fm.copyItem(at: BlipMacEngine.supportLibrary(beside: framework), to: support)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        func start() throws -> (Process, Pipe) {
            let child = Process()
            let input = Pipe()
            child.executableURL = URL(fileURLWithPath: args[0])
            child.arguments = [cached.path, root.path, "child"]
            child.standardInput = input
            try child.run()
            return (child, input)
        }
        func stop(_ child: (Process, Pipe)) {
            try? child.1.fileHandleForWriting.close()
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while child.0.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(50_000) }
            if child.0.isRunning { child.0.terminate() }
        }
        let first = try start()
        defer { stop(first) }
        func poll() throws {
            let candidates = [cache, root, fm.temporaryDirectory.appendingPathComponent(namespace),
                              URL(fileURLWithPath: "/tmp").appendingPathComponent(namespace)]
                .map { $0.appendingPathComponent("sock") }
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while ProcessInfo.processInfo.systemUptime < deadline {
                for socket in candidates {
                    var info = stat()
                    guard lstat(socket.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { continue }
                    try socket.path.write(to: override, atomically: true, encoding: .utf8)
                    let client = Process(), input = Pipe(), output = Pipe()
                    client.executableURL = core
                    client.arguments = ["--blip-mac-poll"]
                    var environment = ProcessInfo.processInfo.environment
                    environment["HOME"] = home.path
                    client.environment = environment
                    client.standardInput = input
                    client.standardOutput = output
                    try client.run()
                    try input.fileHandleForWriting.write(contentsOf: Data("POLL\n".utf8))
                    try input.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    client.waitUntilExit()
                    if client.terminationStatus == 0,
                       let response = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
                       let snapshot = response["data"] as? JSON,
                       let status = snapshot["status"] as? JSON, status["authenticated"] as? Bool == false {
                        print("Reached isolated Blip engine via \(socket.path)")
                        return
                    }
                }
                usleep(100_000)
            }
            let fixturePaths = (try? fm.subpathsOfDirectory(atPath: root.path)) ?? []
            throw NSError(domain: "BlipHostSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No isolated socket at \(candidates.map(\.path)); fixture entries: \(fixturePaths.prefix(30))"])
        }
        try poll()
        let second = try start()
        defer { stop(second) }
        try poll()
        stop(first)
        precondition(!first.0.isRunning && first.0.terminationStatus == 0)
        precondition(second.0.isRunning)
        try poll()
        precondition(NSRunningApplication.runningApplications(withBundleIdentifier: BlipMacEngine.bundleID).isEmpty)
        print("Native engine starts without the UI, serves the local socket, and hands over after EOF")
    }
}
