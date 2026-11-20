import Foundation

struct FolderPeer: Identifiable {
    let id: String
    let name: String
    let state: String
}

extension Snapshot {
    func peers(for folder: SyncthingFolder) -> [FolderPeer] {
        let known = Dictionary(devices.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(folder.deviceIDs).sorted().compactMap { id in
            if let device = known[id] {
                guard !device.isLocal else { return nil }
                return FolderPeer(id: id, name: device.displayName,
                                  state: device.paused ? "Paused" : device.connected ? "Connected" : "Offline")
            }
            return FolderPeer(id: id, name: String(id.prefix(7)), state: "Unavailable")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func peerCaption(for folder: SyncthingFolder) -> String {
        let shared = peers(for: folder)
        if shared.isEmpty { return folder.deviceCount > 1 ? "Shared devices unavailable" : "Not shared with another device" }
        return folder.peerDirection + " " + shared.map { $0.name + ($0.state == "Connected" ? "" : " (" + $0.state.lowercased() + ")") }.joined(separator: ", ")
    }
}
