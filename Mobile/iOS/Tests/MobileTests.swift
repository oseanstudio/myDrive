import XCTest
@testable import myDrive

final class MobileTests: XCTestCase {
    func testPathsRejectTraversalAndAbsolutePaths() throws {
        for value in ["../private", "a/../../b", "C:/data", "a\\b", "x\0"] { XCTAssertThrowsError(try RemotePath.clean(value)) }
        XCTAssertEqual(try RemotePath.child("My folder", "雪.txt"), "My folder/雪.txt")
    }
    func testTailscaleServerAndCustomPort() throws {
        XCTAssertEqual(try RemotePath.server("smb://device.example.ts.net").0, "device.example.ts.net")
        XCTAssertEqual(try RemotePath.server("100.64.0.1:1445").1, 1445)
        for value in ["smb://name:password@server", "smb://server/share", "http://server"] { XCTAssertThrowsError(try RemotePath.server(value)) }
    }
    func testDefaultDoesNotResetOptOut() {
        let key = "blip_auto_open_links", previous = UserDefaults.standard.object(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key); XCTAssertTrue(LocalStore.autoOpenLinks)
        LocalStore.autoOpenLinks = false; XCTAssertFalse(LocalStore.autoOpenLinks)
    }
    func testDeviceExportContainsNoPassword() throws {
        let device = Device(name: "Computer", host: "computer", share: "Files")
        let data = try JSONEncoder().encode(device)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
        XCTAssertEqual(try JSONDecoder().decode(Device.self, from: data), device)
    }
    func testShortcutSchemesAndCompletionAreDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.url")
        for value in ["javascript:alert(1)", "file:///private/data", "https://name:password@example.com/"] { try Data("[InternetShortcut]\nURL=\(value)".utf8).write(to: file); XCTAssertNil(LinkTarget.read(file)) }
        try Data("[InternetShortcut]\nURL=https://example.com/".utf8).write(to: file); XCTAssertEqual(LinkTarget.read(file)?.host, "example.com")
        XCTAssertFalse(Transfer(name: "Fixture", device: "Blip", direction: "Outgoing", state: "Handed to Blip").active)
    }
}
