// myDrive macOS entry point. --diagnose runs the self-test and exits; every
// other launch shows the status-item app (or activates the running copy).
import AppKit

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--blip-cli" {
    MainActor.assumeIsolated { BlipCommand.run(Array(arguments.dropFirst(2))) }
}
if arguments.count == 3, arguments[1] == "--blip-background-engine" {
    do { try BlipMacEngine.runInstalled(appPath: arguments[2]) }
    catch let failure as BlipMacEngine { exit(failure.rawValue) }
    catch { exit(BlipMacEngine.launch.rawValue) }
    exit(0)
}
if let index = arguments.firstIndex(of: "--diagnose-layout"),index+1<arguments.count {
    Diagnostics.runLayout(outputDirectory:arguments[index+1])
}
if let index = arguments.firstIndex(of: "--diagnose") {
    let output = index + 1 < arguments.count
        ? arguments[index + 1]
        : (NSTemporaryDirectory() as NSString).appendingPathComponent("mydrive-diagnose")
    Diagnostics.run(outputDirectory: output)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
