// Run on macOS: see Mac/README.md. No user settings are read or written.
import Foundation

enum Paths {
    static let dataDir = URL(fileURLWithPath: "/unused-mydrive-preferences-fixture")
}
enum AtomicFile {
    static func readJSON(_ url: URL) -> Any? { nil }
    static func write(_ data: Data, to url: URL) throws {}
}

@main struct PreferencesSmoke {
    static func main() throws {
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            print("PASS \(name)")
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var original = Preferences()
        check(original.blipAutoOpenLinks, "new preferences enable received-link opening")
        original.syncthingConfigPath = "/fixture/syncthing/config.xml"
        original.syncthingEndpoint = "http://127.0.0.1:18384/"
        original.syncthingManual = true
        original.lastSyncFolder = "fixture-folder"
        original.lastSyncDevice = "fixture-device"
        original.autoRemount = false
        original.knownSmbShares = ["fixture@server/share"]
        original.lastEventId = 42
        original.startAtLogin = true
        original.appearance = "dark"
        var legacy = try JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "blip_auto_open_links")
        let migrated = try decoder.decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(migrated.blipAutoOpenLinks && migrated == original, "missing new key enables links without resetting existing settings")
        check(migrated.blipBackgroundReceiving != false, "existing preferences enable background receiving")
        var backgroundOptOut = migrated
        backgroundOptOut.blipBackgroundReceiving = false
        let restored = try decoder.decode(Preferences.self, from: encoder.encode(backgroundOptOut))
        check(restored.blipBackgroundReceiving == false, "background opt-out survives upgrading and saving")
        legacy["blip_auto_open_links"] = NSNull()
        let nullSetting = try decoder.decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(nullSetting.blipAutoOpenLinks && nullSetting == original, "null new key uses the enabled default")
        legacy["blip_auto_open_links"] = false
        var optedOut = try decoder.decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(!optedOut.blipAutoOpenLinks, "explicit opt-out is preserved")
        let roundTrip = try decoder.decode(Preferences.self, from: encoder.encode(optedOut))
        check(roundTrip == optedOut && !roundTrip.blipAutoOpenLinks, "opt-out survives a save and reload")
        optedOut.blipAutoOpenLinks = true
        let enabledAgain = try decoder.decode(Preferences.self, from: encoder.encode(optedOut))
        check(enabledAgain.blipAutoOpenLinks, "explicit re-enable survives a save and reload")
        optedOut.blipAutoOpenLinks = migrated.blipAutoOpenLinks
        var expected = original; expected.blipAutoOpenLinks = true
        check(optedOut == expected, "all non-Blip configuration remains intact")
    }
}
