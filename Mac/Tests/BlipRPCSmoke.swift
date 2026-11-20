import Foundation
import Darwin
import Dispatch
typealias JSON = [String:Any]
@main struct BlipRPCSmoke {
    static func main() throws {
        let user="11111111-1111-4111-8111-111111111111",device="22222222-2222-4222-8222-222222222222",sender="33333333-3333-4333-8333-333333333333",remote="44444444-4444-4444-8444-444444444444",id="55555555-5555-4555-8555-555555555555"
        let auth=BlipProto.field(201,Data("fixture-only".utf8))+BlipProto.string(202,user)+BlipProto.string(204,device)
        let peer=BlipProto.string(1,sender)+BlipProto.string(2,remote)
        let file=BlipProto.numeric(1,42)
        let metadata=BlipProto.field(1,BlipProto.string(1,"test.url")+BlipProto.field(2,BlipProto.field(1,file)))+BlipProto.field(2,BlipProto.string(1,"test.url")+BlipProto.string(2,"downloads:myDrive-test/test.url"))
        let transfer=BlipProto.string(100,id)+BlipProto.field(200,peer)+BlipProto.field(400,metadata)+BlipProto.numeric(700,1)+BlipProto.numeric(800,4)
        let state=BlipProto.field(201,auth)+BlipProto.field(600,BlipProto.string(1,id)+BlipProto.field(2,transfer))
        let result=try BlipLocalRPC.snapshot(BlipProto.field(2,state))
        let status=result["status"] as! JSON, transfers=result["transfers"] as! [JSON]
        precondition(status["authenticated"] as? Bool == true && status["user_id"] as? String == user)
        precondition(transfers.count==1 && transfers[0]["link_only"] as? Bool == true && transfers[0]["peer"] as? String == sender+":"+remote)
        let completeTransfer=BlipProto.string(100,id)+BlipProto.field(200,peer)+BlipProto.field(400,metadata)+BlipProto.numeric(700,1)+BlipProto.numeric(800,8)
        let complete=try BlipLocalRPC.snapshot(BlipProto.field(2,BlipProto.field(201,auth)+BlipProto.field(600,BlipProto.string(1,id)+BlipProto.field(2,completeTransfer))))
        let received=((complete["transfers"] as! [JSON])[0]["received_items"] as! [JSON]);precondition(received.count==1 && received[0]["name"] as? String=="test.url")
        precondition((transfers[0]["received_items"] as! [JSON]).isEmpty)
        let mixed=transfer+BlipProto.numeric(600,1)
        let errored=try BlipLocalRPC.snapshot(BlipProto.field(2,BlipProto.field(201,auth)+BlipProto.field(600,BlipProto.string(1,id)+BlipProto.field(2,mixed))))
        precondition((errored["transfers"] as! [JSON])[0]["has_error"] as? Bool == true)
        precondition(BlipLocalRPC.decodedPath("downloads:../outside.url")==nil)
        let paths = ["/tmp/file with spaces.txt", "/tmp/Testing 🌊"]
        let events = try BlipLocalRPC.sendEvents(paths: paths, peer: [sender, remote], id: id).map { body in
            try BlipProto(BlipProto(body).bytes(1)!)
        }
        precondition(events.map { $0.string(1) } == ["TransferCreateRequested", "TransferAddContentRequested", "TransferInviteRequested"].map { "type.googleapis.com/event." + $0 })
        let destination = try BlipProto(BlipProto(events[2].bytes(2)!).bytes(2)!)
        precondition(destination.string(1) == sender && destination.string(2) == remote)
        let content = try BlipProto(events[1].bytes(2)!)
        precondition(content.string(1) == id && content.values[2]?.compactMap { entry in
            if case .bytes(let value) = entry { return String(data: value, encoding: .utf8) }
            return nil
        } == paths)
        var index=0;let number=try BlipProto.readVar(BlipProto.varint(16384),&index);precondition(number==16384)
        do {_ = try BlipProto(Data([0x12,0xff]));preconditionFailure("Truncated protobuf accepted")}catch{}
        try staleSocketCheck()
        try socketRoundtrip(BlipProto.field(2,state))
        print("Native Blip RPC schema, Unix socket framing and malformed-data checks passed")
    }
    static func staleSocketCheck() throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("md-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        func bind(_ socket: URL) -> Int32 {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(fd >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socket.path.utf8) + [0]) }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            precondition(bound == 0)
            return fd
        }
        let stale = folder.appendingPathComponent("stale")
        let active = folder.appendingPathComponent("active")
        Darwin.close(bind(stale))
        let listener = bind(active)
        defer { Darwin.close(listener) }
        precondition(Darwin.listen(listener, 2) == 0)
        precondition(BlipLocalRPC.liveSocket(in: [stale]) == nil)
        precondition(BlipLocalRPC.liveSocket(in: [stale, active]) == active.resolvingSymlinksInPath())
    }

    static func socketRoundtrip(_ response: Data) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("md-"+UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("s"), path=Array(url.path.utf8)+[UInt8(0)]
        precondition(path.count<=104)
        let listener=Darwin.socket(AF_UNIX,SOCK_STREAM,0);precondition(listener>=0)
        defer {Darwin.close(listener)}
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:path)}
        let bound=withUnsafePointer(to:&address){ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        precondition(bound==0 && Darwin.listen(listener,1)==0)
        let finished=DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            defer {finished.signal()}
            let client=Darwin.accept(listener,nil,nil);precondition(client>=0);defer{Darwin.close(client)}
            var timeout=timeval(tv_sec:5,tv_usec:0),yes:Int32=1
            _=setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
            _=setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))
            var request=Data(), buffer=[UInt8](repeating:0,count:2048)
            while !request.suffix(4).elementsEqual([UInt8(13),1,4,0]) {
                let count=Darwin.recv(client,&buffer,buffer.count,0);precondition(count>0)
                request.append(contentsOf:buffer.prefix(count));precondition(request.count<8192)
            }
            precondition(request.range(of:Data("/rpc.Service/GetState".utf8)) != nil)
            let split=response.count/2
            let first=Data([4,1,1])+BlipProto.varint(UInt64(split))+response.prefix(split)
            let last=BlipLocalRPC.frame(2,1,Data(response.dropFirst(split)))
            let reply=first+last
            reply.withUnsafeBytes {raw in
                var offset=0
                while offset<reply.count {let count=Darwin.send(client,raw.baseAddress!.advanced(by:offset),reply.count-offset,0);precondition(count>0);offset+=count}
            }
        }
        let actual=try BlipLocalRPC.call(socket:url,method:"/rpc.Service/GetState",body:Data())
        precondition(actual==response)
        precondition(finished.wait(timeout:.now()+10) == .success)
    }
}
