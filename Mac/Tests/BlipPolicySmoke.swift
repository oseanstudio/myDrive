import Foundation
@main struct BlipPolicySmoke {
    static func main() throws {
        let account="11111111-1111-4111-8111-111111111111", device="22222222-2222-4222-8222-222222222222"
        let peer=account+":"+device
        let policy=BlipPolicy(account:account,peers:[peer])
        let incoming=BlipTransfer(transfer_id:UUID().uuidString,peer:peer,direction:"Incoming",status:"Invited",completed:false,has_error:false,link_files:[],link_only:true)
        precondition(policy.autoReceive(incoming,account:account))
        let invited=BlipTransfer(transfer_id:UUID().uuidString,peer:peer,direction:"Incoming",status:"Invited",completed:false,has_error:false,link_files:[],link_only:true);precondition(policy.autoReceive(invited,account:account))
        precondition(!BlipPolicy().allows(incoming,account:account))
        precondition(!policy.allows(incoming,account:device))
        precondition(!BlipPolicy.exactPeer("Known laptop"))
        let accepted=BlipTransfer(transfer_id:UUID().uuidString,peer:peer,direction:"Incoming",status:"Pending",completed:false,has_error:false,link_files:[],link_only:true);precondition(!policy.autoReceive(accepted,account:account))
        let normal=BlipTransfer(transfer_id:UUID().uuidString,peer:peer,direction:"Incoming",status:"Invited",completed:false,has_error:false,link_files:[],link_only:false)
        precondition(!policy.autoReceive(normal,account:account))
        let filePolicy=BlipPolicy(account:account,files:[peer]);precondition(filePolicy.autoReceive(normal,account:account,openLinks:false));precondition(!filePolicy.allows(normal,account:account))
        let legacy=try JSONDecoder().decode(BlipPolicy.self,from:Data("{\"account\":\"\(account)\",\"peers\":[\"\(peer)\"]}".utf8));precondition(legacy.files.isEmpty&&legacy.peers.contains(peer))
        // /var is a system symlink on macOS; use an isolated cache fixture with no symlink ancestors.
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/myDrive-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("test.url")
        let catalog=try BlipContactStore(root.appendingPathComponent("senders.json"))
        let contactSaved=try catalog.merge(account:account,selfPeer:account+":"+account,peers:[BlipPeer(peer:peer,name:"Studio Mac",name_known:true)],transfers:[incoming],approved:[])
        precondition(contactSaved.count==1)
        let restored=try BlipContactStore(root.appendingPathComponent("senders.json")).merge(account:account,selfPeer:account+":"+account,peers:[],transfers:[incoming],approved:[])
        precondition(restored.first?.name=="Studio Mac")
        try catalog.setNickname(account:account,peer:peer,name:"Travel MacBook")
        let renamed=try BlipContactStore(root.appendingPathComponent("senders.json")).merge(account:account,selfPeer:account+":"+account,peers:[BlipPeer(peer:peer,name:"Remote name",name_known:true)],transfers:[incoming],approved:[])
        precondition(renamed.first?.displayName=="Travel MacBook" && renamed.first?.peer==peer)
        let unnamed = BlipPeer(peer: peer, name: "Phone", online: false, can_relay: false, name_known: false, kind: "Phone", user_name: "Studio tester")
        precondition(unnamed.displayName == "Phone" &&
                     !unnamed.hasDeviceName && unnamed.contactName == "Studio tester")
        precondition(unnamed.recipientCaption(account: device, device: unnamed.displayName,
                                              person: unnamed.contactName, distinguish: false) == "Studio tester")
        precondition(unnamed.recipientCaption(account: device, device: unnamed.displayName,
                                              person: unnamed.contactName, distinguish: true) == "Studio tester · Phone")
        let owned = BlipPeer(peer: account + ":" + UUID().uuidString, name: "Mac", name_known: true, user_name: "Fixture user")
        precondition(owned.recipientCaption(account: account, device: owned.displayName, person: owned.contactName,
                                            distinguish: true) == "Mac")
        let remembered = try BlipContactStore(root.appendingPathComponent("senders.json"))
            .merge(account: account, selfPeer: account + ":" + account, peers: [unnamed], transfers: [], approved: [])
        precondition(remembered.first?.name == "Remote name" && remembered.first?.online == false && remembered.first?.can_relay == false)
        let historical = try BlipContactStore(root.appendingPathComponent("senders.json"))
            .merge(account: account, selfPeer: account + ":" + account,
                   peers: [BlipPeer(peer: peer, name: "Previous device", history: true)], transfers: [], approved: [])
        precondition(historical.first?.contactName == "Studio tester" && historical.first?.kind == "Phone")
        for target in ["file:///private/data","javascript:alert(1)","https://name:password@example.com/"] {
            try Data("[InternetShortcut]\nURL=\(target)".utf8).write(to:file)
            precondition(BlipWebLink.read(file.path)==nil)
        }
        try Data("[InternetShortcut]\nURL=https://example.com/".utf8).write(to:file)
        precondition(BlipWebLink.read(file.path)?.host=="example.com")
        let linked=root.appendingPathComponent("linked.url")
        try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:file)
        precondition(BlipWebLink.read(linked.path)==nil)
        let received=BlipReceivedItem(name:"test.url",path:file.path,size:32)
        var complete=BlipTransfer(transfer_id:UUID().uuidString,peer:peer,direction:"Incoming",status:"Completed",completed:true,has_error:false,link_files:[],link_only:true)
        complete.received_items=[received]
        precondition(BlipReceivedPath.url(received,in:complete)?.path==file.path)
        var pending=incoming;pending.received_items=[received];precondition(BlipReceivedPath.url(received,in:pending)==nil)
        let linkedItem=BlipReceivedItem(name:"linked.url",path:linked.path,size:32);complete.received_items=[linkedItem];precondition(BlipReceivedPath.url(linkedItem,in:complete)==nil)
        let remoteItem=BlipReceivedItem(name:"remote.url",path:"file://server/share/test.url",size:32);complete.received_items=[remoteItem];precondition(BlipReceivedPath.url(remoteItem,in:complete)==nil)
        let ledger=root.appendingPathComponent("claims.json"), claims=try BlipClaims(ledger)
        let first = try claims.claim("fixture-claim"), repeated = try BlipClaims(ledger).claim("fixture-claim")
        precondition(first && !repeated)
        let saved = try String(contentsOf:ledger,encoding:.utf8); precondition(!saved.contains("fixture-claim"))
        print("Blip trust, parser and persisted-claim checks passed")
    }
}
