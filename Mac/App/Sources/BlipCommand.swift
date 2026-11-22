import Darwin
import Foundation

@MainActor enum BlipCommand {
    static func run(_ arguments: [String]) -> Never {
        do {
            if arguments == ["serve"] {
                try BlipMacEngine.runBackground(allowDownload: true)
                exit(0)
            }
            let process = Process()
            process.executableURL = CoreBridge.shared.executable
            process.environment = BlipMacPaths.environment
            process.arguments = ["--blip-engine"] + arguments
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
