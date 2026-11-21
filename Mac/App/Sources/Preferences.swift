// Preferences persisted as JSON in the myDrive data dir (mirrors the shape of
// Windows/App/Preferences.cs). A load error keeps the defaults.
import Foundation

struct Preferences: Codable, Equatable {
    var syncthingConfigPath = ""
    var syncthingManual = false
    var syncthingEndpoint = "http://127.0.0.1:8384/"
    var lastSyncFolder = ""
    var lastSyncDevice = ""
    var autoRemount = true
    var lastEventId: UInt64 = 0
    var startAtLogin = false
    var appearance = "system" // system | light | dark
    var autoInstallUpdates: Bool? = nil
    // Optional storage keeps older preference files decodable. Absence means enabled;
    // an explicit opt-out survives saves and upgrades. Consumed by the future Blip receiver.
    private var blipAutoOpenLinksOverride: Bool? = nil
    var blipAutoOpenLinks: Bool {
        get { blipAutoOpenLinksOverride ?? true }
        set { blipAutoOpenLinksOverride = newValue }
    }
    var blipBackgroundReceiving: Bool? = nil
    /// SMB shares (`user@host/share`) seen mounted on this Mac, so ones that
    /// drop off the mount list can be remounted automatically.
    var knownSmbShares: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case syncthingConfigPath = "syncthing_config_path"
        case syncthingManual = "syncthing_manual"
        case syncthingEndpoint = "syncthing_endpoint"
        case lastSyncFolder = "last_sync_folder"
        case lastSyncDevice = "last_sync_device"
        case autoRemount = "auto_remount"
        case lastEventId = "last_event_id"
        case startAtLogin = "start_at_login"
        case appearance
        case autoInstallUpdates = "auto_install_updates"
        case blipAutoOpenLinksOverride = "blip_auto_open_links"
        case blipBackgroundReceiving = "blip_background_receiving"
        case knownSmbShares = "known_smb_shares"
    }
}

final class PrefStore {
    static let shared = PrefStore()
    private(set) var preferences: Preferences
    private let url = Paths.dataDir.appendingPathComponent("preferences.json")

    private init() {
        if let raw = AtomicFile.readJSON(url),
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = Preferences()
        }
    }

    func update(_ change: (inout Preferences) -> Void) {
        change(&preferences)
        if let data = try? JSONEncoder().encode(preferences) {
            try? AtomicFile.write(data, to: url)
        }
    }
}
