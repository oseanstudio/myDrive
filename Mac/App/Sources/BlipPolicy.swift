import Foundation
import CryptoKit

struct BlipPeer: Identifiable, Codable {
    let peer: String
    var name: String
    var contact: String? = nil
    var history: Bool? = nil
    var online: Bool? = nil
    var can_relay: Bool? = nil
    var name_known: Bool? = nil
    var kind: String? = nil
    var user_name: String? = nil
    var nickname: String? = nil
    var hasDeviceName: Bool { name_known == true || nickname?.isEmpty == false }
    var contactName: String? { user_name.flatMap { $0.isEmpty ? nil : $0 } ?? contact }
    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if name_known == true { return name }
        let type = kind.flatMap { $0.isEmpty ? nil : $0 } ?? name
        if ["Phone", "Tablet", "Laptop", "Desktop"].contains(type) { return type }
        return history == true ? "Previous device" : "Device"
    }
    var id: String { peer }
}
struct BlipReceivedItem:Identifiable,Codable,Equatable {
    let name:String
    let path:String
    var is_directory:Bool=false
    var size:Int64=0
    var id:String{path}
    var displayName:String{String(name.filter{!$0.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})}.prefix(160))}
}
struct BlipTransfer: Identifiable, Codable {
    let transfer_id: String
    let peer: String
    let direction: String
    let status: String
    let completed: Bool
    let has_error: Bool
    let link_files: [String]?
    let link_only: Bool?
    var dismissed: Bool? = nil
    var updated_at: Int64? = nil
    var progress: Int64? = nil
    var total_bytes: Int64? = nil
    var item_names: [String]? = nil
    var received_items:[BlipReceivedItem]?=nil
    var id: String { transfer_id }
    var confirmed: Bool { status == "Completed" && completed && !has_error }
    var isLive: Bool {
        dismissed != true && !completed &&
            ["Created", "InviteRequested", "Invited", "Pending", "Active", "Paused", "ResumeRequested"].contains(status)
    }
    var pending: Bool { direction == "Incoming" && status == "Invited" && !has_error && dismissed != true }
}
enum BlipReceivedPath {
    static func url(_ item:BlipReceivedItem,in transfer:BlipTransfer)->URL? {
        guard transfer.direction=="Incoming",transfer.confirmed,transfer.received_items?.contains(where:{$0.path==item.path})==true,item.path.rangeOfCharacter(from:.controlCharacters)==nil else{return nil}
        let file:URL
        if item.path.hasPrefix("/"){file=URL(fileURLWithPath:item.path)}else{guard let value=URL(string:item.path),value.isFileURL,value.host==nil||value.host=="" else{return nil};file=value}
        let result=file.standardizedFileURL;var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:result.path,isDirectory:&directory),directory.boolValue==item.is_directory else{return nil}
        var ancestor=result
        while ancestor.path != "/" {guard let values=try? ancestor.resourceValues(forKeys:[.isSymbolicLinkKey]),values.isSymbolicLink != true else{return nil};ancestor.deleteLastPathComponent()}
        return result
    }
}
struct BlipPolicy: Codable {
    var account = ""
    var peers: Set<String> = []
    var files: Set<String> = []
    init(account: String="",peers: Set<String>=[],files: Set<String>=[]) {self.account=account;self.peers=peers;self.files=files}
    enum CodingKeys:String,CodingKey {case account,peers,files}
    init(from decoder:Decoder)throws {let values=try decoder.container(keyedBy:CodingKeys.self);account=try values.decodeIfPresent(String.self,forKey:.account) ?? "";peers=try values.decodeIfPresent(Set<String>.self,forKey:.peers) ?? [];files=try values.decodeIfPresent(Set<String>.self,forKey:.files) ?? []}
    static func exactPeer(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { UUID(uuidString: String($0)) != nil }
    }
    func allows(_ transfer: BlipTransfer, account: String) -> Bool {
        UUID(uuidString: account) != nil && self.account.lowercased() == account.lowercased()
            && Self.exactPeer(transfer.peer) && peers.contains(transfer.peer.lowercased())
    }
    func allowsFiles(_ transfer:BlipTransfer,account:String)->Bool {
        UUID(uuidString:account) != nil && self.account.lowercased()==account.lowercased() && Self.exactPeer(transfer.peer) && files.contains(transfer.peer.lowercased())
    }
    func autoReceive(_ transfer: BlipTransfer, account: String,openLinks:Bool=true) -> Bool {
        transfer.pending && (allowsFiles(transfer,account:account)||(openLinks&&allows(transfer,account:account)&&transfer.link_only==true))
    }
}

final class BlipContactStore {
    private let file:URL
    private var accounts:[String:[BlipPeer]]
    init(_ file:URL)throws {self.file=file;accounts=FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode([String:[BlipPeer]].self,from:Data(contentsOf:file)) : [:]}
    func merge(account:String,selfPeer:String,peers:[BlipPeer],transfers:[BlipTransfer],approved:Set<String>)throws->[BlipPeer] {
        guard UUID(uuidString:account) != nil else {return []};let key=account.lowercased(),encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;let before=try encoder.encode(accounts)
        var known:[String:BlipPeer]=[:]
        for peer in accounts[key] ?? [] where BlipPolicy.exactPeer(peer.peer) {known[peer.peer.lowercased()]=peer}
        for peer in peers where BlipPolicy.exactPeer(peer.peer) {
            let old=known[peer.peer.lowercased()]
            var updated = peer
            updated.nickname = old?.nickname
            if let old, old.name_known == true, peer.name_known != true {
                updated.name = old.name
                updated.name_known = true
            }
            if updated.contact?.isEmpty != false { updated.contact = old?.contact }
            if updated.user_name?.isEmpty != false { updated.user_name = old?.user_name }
            if updated.kind?.isEmpty != false { updated.kind = old?.kind }
            known[peer.peer.lowercased()] = updated
        }
        for peer in transfers.filter({$0.direction=="Incoming"}).map(\.peer)+Array(approved) where BlipPolicy.exactPeer(peer) && known[peer.lowercased()]==nil {
            known[peer.lowercased()]=BlipPeer(peer:peer,name:"Previous device",history:true)
        }
        known.removeValue(forKey:selfPeer.lowercased());let result=known.values.sorted{$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending};accounts[key]=result
        let after=try encoder.encode(accounts)
        if before != after {try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try after.write(to:file,options:.atomic)}
        return result
    }
    func setNickname(account:String,peer:String,name:String)throws {
        let key=account.lowercased();guard var devices=accounts[key],let index=devices.firstIndex(where:{$0.peer.lowercased()==peer.lowercased()}) else {return}
        devices[index].nickname=String(name.trimmingCharacters(in:.whitespacesAndNewlines).filter{!$0.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})}.prefix(80))
        var updated=accounts;updated[key]=devices
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(updated).write(to:file,options:.atomic);accounts=updated
    }
}
enum BlipWebLink {
    static func read(_ location: String) -> URL? {
        var file: URL
        if location.hasPrefix("/") { file = URL(fileURLWithPath: location) }
        else { guard let url = URL(string: location), url.isFileURL, url.host == nil || url.host == "" else { return nil }; file = url }
        guard file.isFileURL, ["url", "webloc"].contains(file.pathExtension.lowercased()) else { return nil }
        var ancestor = file
        while ancestor.path != "/" {
            guard let values = try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
            ancestor.deleteLastPathComponent()
        }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 65536,
              let data = try? Data(contentsOf: file), data.count <= 65536 else { return nil }
        var target: String?
        if file.pathExtension.lowercased() == "webloc" {
            target = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["URL"] as? String
        } else if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
            var section = false
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
                if line.hasPrefix("[") { section = line.lowercased() == "[internetshortcut]"; continue }
                if line.hasPrefix(";") || line.hasPrefix("#") { continue }
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if section && pair.count == 2 && pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "url" {
                    guard target == nil else { return nil }; target = String(pair[1])
                }
            }
        }
        guard let raw = target?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count <= 8192,
              raw.rangeOfCharacter(from: .controlCharacters) == nil, !raw.contains("\\"),
              let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
final class BlipClaims {
    private let file: URL
    private var values: Set<String>
    init(_ file: URL) throws {
        self.file = file
        values = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file)) : []
    }
    private func key(_ value: String) -> String { CryptoKit.SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    func contains(_ value: String) -> Bool { values.contains(key(value)) }
    @discardableResult func claim(_ value: String) throws -> Bool {
        let hash = key(value); guard values.insert(hash).inserted else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: file, options: .atomic); return true
        } catch { values.remove(hash); throw error }
    }
}
