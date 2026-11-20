// Run on macOS only:
// swiftc -swift-version 5 App/Sources/CoreBridge.swift Tests/CoreBridgeSmoke.swift -o /tmp/mydrive-bridge-test
// /tmp/mydrive-bridge-test
import Foundation

typealias JSON = [String: Any]
extension Dictionary where Key == String, Value == Any {
    func bool(_ key: String) -> Bool { self[key] as? Bool ?? false }
    func str(_ key: String) -> String { self[key] as? String ?? "" }
}
struct Bookmark { init(from: JSON) {}; var dict: JSON { [:] } }
struct Credentials { var dict: JSON { [:] } }

@main struct CoreBridgeSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mydrive-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("fixture.sh")
        let script = #"""
        #!/bin/sh
        request=$(cat)
        case "$request" in
          *'"slow"'*) sleep 2 ;;
          *'"medium"'*) sleep 0.5 ;;
          *'"stderr"'*) dd if=/dev/zero bs=65536 count=4 >&2 ;;
          *'"timeout"'*) exec /bin/sleep 10 ;;
        esac
        printf '{"ok":true,"data":"finished"}\n'
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let bridge = CoreBridge(executable: helper)
        let slow = Task { try await bridge.call(action: "slow") }
        try await Task.sleep(nanoseconds: 100_000_000)
        let medium = Task { try await bridge.call(action: "medium") }
        try await Task.sleep(nanoseconds: 100_000_000)
        slow.cancel()
        guard try await medium.value as? String == "finished" else { fatalError("Cancelling A interrupted B") }
        do { _ = try await slow.value; fatalError("Expected cancellation") } catch is CancellationError {}
        print("PASS cancellation affects only its own invocation")
        _ = try await bridge.call(action: "stderr", timeout: 3)
        print("PASS stderr larger than pipe capacity is drained")
        do { _ = try await bridge.call(action: "timeout", timeout: 0.1); fatalError("Expected timeout") }
        catch let error as CoreError { guard error.message.contains("too long") else { throw error } }
        print("PASS timeout is reported distinctly")
        let cancelled = Task { try await bridge.call(action: "slow") }; cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Expected early cancellation") } catch is CancellationError {}
        print("PASS cancellation before launch")
    }
}
