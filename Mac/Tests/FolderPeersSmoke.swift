import Foundation
typealias JSON = [String: Any]
extension [String: Any] {
    func str(_ key: String) -> String { self[key] as? String ?? "" }
    func optStr(_ key: String) -> String? { self[key] as? String }
    func int64(_ key: String) -> Int64 { (self[key] as? NSNumber)?.int64Value ?? 0 }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    func dict(_ key: String) -> JSON { self[key] as? JSON ?? [:] }
    func array(_ key: String) -> [Any] { self[key] as? [Any] ?? [] }
}
@main struct FolderPeersSmoke {
    static func main() {
        func snapshot(_ type: String, _ peers: [String]) -> Snapshot {
            Snapshot(from: ["folders": [["id":"folder", "type":type, "device_count":peers.count, "device_ids":peers]],
                            "devices": [["deviceID":"self", "is_local":true],
                                        ["deviceID":"mac", "name":"MacBook", "connection":["connected":true]],
                                        ["deviceID":"pc", "name":"PC", "connection":["connected":false]],
                                        ["deviceID":"other", "name":"Unrelated device", "connection":["connected":true]]]])
        }
        let both=snapshot("sendreceive", ["self","mac","pc"])
        precondition(both.peers(for:both.folders[0]).map(\.name)==["MacBook","PC"])
        precondition(both.peerCaption(for:both.folders[0])=="To & from MacBook, PC (offline)")
        let send=snapshot("sendonly", ["self","mac"])
        precondition(send.peerCaption(for:send.folders[0])=="To MacBook")
        let receive=snapshot("receiveonly", ["self","pc"])
        precondition(receive.peerCaption(for:receive.folders[0])=="From PC (offline)")
        let alone=snapshot("sendreceive", ["self"])
        precondition(alone.peerCaption(for:alone.folders[0])=="Not shared with another device")
        let unknown=snapshot("sendreceive", ["self","unknown-id"])
        precondition(unknown.peers(for:unknown.folders[0]).first?.state=="Unavailable")
        print("Folder peer checks passed")
    }
}
