// Native local transport: public DRPC framing + the observed frontend protobuf contract.
// No account files, vendor binaries, JVM or network listener are used by this client.
// Framing reference: https://github.com/storj/drpc/blob/main/drpcwire/packet.go
import Foundation
import Darwin

enum BlipRPCError: LocalizedError {
    case unavailable, invalid, rejected, limit, searchInput, searchUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The Blip connection is unavailable. Refresh Blip in the Send view to try again."
        case .invalid: return "Blip returned an unsupported local response. Automatic actions are disabled."
        case .rejected: return "Blip did not confirm this request. Refresh before retrying."
        case .limit: return "Blip's local response exceeded its size or time limit."
        case .searchInput: return "Enter a name or email address."
        case .searchUnavailable: return "Blip search is unavailable. Try again in a moment."
        }
    }
}

struct BlipProto {
    enum Value { case number(UInt64), bytes(Data) }
    let values: [Int: [Value]]
    init(_ data: Data) throws {
        var fields: [Int: [Value]] = [:], offset = 0, count = 0
        while offset < data.count {
            count += 1; guard count <= 200_000 else { throw BlipRPCError.limit }
            let key = try Self.readVar(data, &offset), tag = Int(key >> 3)
            guard tag > 0, tag <= 536_870_911 else { throw BlipRPCError.invalid }
            switch key & 7 {
            case 0: fields[tag, default: []].append(.number(try Self.readVar(data, &offset)))
            case 2:
                let length = try Self.readVar(data, &offset)
                guard length <= UInt64(data.count - offset) else { throw BlipRPCError.invalid }
                fields[tag, default: []].append(.bytes(data.subdata(in: offset..<(offset+Int(length)))))
                offset += Int(length)
            case 1: guard data.count-offset >= 8 else { throw BlipRPCError.invalid }; offset += 8
            case 5: guard data.count-offset >= 4 else { throw BlipRPCError.invalid }; offset += 4
            default: throw BlipRPCError.invalid
            }
        }
        values = fields
    }
    func bytes(_ tag: Int) -> Data? { guard values[tag]?.count == 1, case .bytes(let data) = values[tag]!.first! else { return nil }; return data }
    func number(_ tag: Int) -> UInt64 { guard values[tag]?.count == 1, case .number(let number) = values[tag]!.first! else { return 0 }; return number }
    func string(_ tag: Int) -> String { bytes(tag).flatMap { String(data:$0,encoding:.utf8) } ?? "" }
    func messages(_ tag: Int) throws -> [BlipProto] {
        try (values[tag] ?? []).map { guard case .bytes(let data) = $0 else { throw BlipRPCError.invalid }; return try BlipProto(data) }
    }
    static func readVar(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from:0,through:63,by:7) {
            guard offset < data.count else { throw BlipRPCError.invalid }
            let byte = data[offset]; offset += 1
            if shift == 63 && byte > 1 { throw BlipRPCError.invalid }
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw BlipRPCError.invalid
    }
    static func varint(_ value: UInt64) -> Data {
        var n = value, result = Data()
        repeat { let byte = UInt8(n & 127); n >>= 7; result.append(byte | (n == 0 ? 0 : 128)) } while n != 0
        return result
    }
    static func field(_ tag: Int, _ value: Data) -> Data { varint(UInt64(tag*8+2)) + varint(UInt64(value.count)) + value }
    static func string(_ tag: Int, _ value: String) -> Data { field(tag,Data(value.utf8)) }
    static func numeric(_ tag: Int, _ value: UInt64) -> Data { varint(UInt64(tag*8)) + varint(value) }
}

enum BlipLocalRPC {
    static let maximum = 32*1024*1024
    static let managedNamespace = "net.oseanstudio.mydrive.blip/"
    static var managedProfile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myDrive/Blip", isDirectory: true)
    }
    static var managedCache: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mdblip", isDirectory: true)
    }
    static var managedCandidates: [URL] {
        let fm = FileManager.default
        return [managedCache, fm.temporaryDirectory.appendingPathComponent(managedNamespace),
                URL(fileURLWithPath: "/tmp").appendingPathComponent(managedNamespace)]
            .map { $0.appendingPathComponent("sock") }
    }
    static func isManaged(_ socket: URL) -> Bool {
        managedCandidates.contains { $0.resolvingSymlinksInPath() == socket.resolvingSymlinksInPath() }
    }
    static func socketURL() -> URL? {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let override = home.appendingPathComponent("Library/Application Support/myDrive/Blip/desktop-socket.txt")
        var candidates: [URL] = []
        if let configured = try? String(contentsOf:override,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines), configured.hasPrefix("/") {
            candidates = [URL(fileURLWithPath:configured)]
        } else {
            if let managed = liveSocket(in: managedCandidates) { return managed }
            let group = "AY8UB8KTUX.blip"
            let container = home.appendingPathComponent("Library/Group Containers/" + group)
            candidates = [fm.temporaryDirectory.appendingPathComponent(group + "/sock"),
                          URL(fileURLWithPath: "/tmp").appendingPathComponent(group + "/sock"),
                          container.appendingPathComponent("Library/Caches/sock"),
                          fm.temporaryDirectory.appendingPathComponent("net.blip.desktop/sock"),
                          home.appendingPathComponent("Library/Caches/net.blip.desktop/sock"),
                          home.appendingPathComponent("Library/Caches/net.blip.Blip/sock"),
                          home.appendingPathComponent("Library/Caches/net.blip.macos/sock")]
            // Only inspect Blip-named cache directories, never account-file contents.
            let cache = home.appendingPathComponent("Library/Caches")
            for directory in ((try? fm.contentsOfDirectory(at:cache,includingPropertiesForKeys:[.isDirectoryKey])) ?? []).filter({$0.lastPathComponent.lowercased().contains("blip")}).prefix(16) {
                candidates += [directory.appendingPathComponent("sock"),directory.appendingPathComponent("cache/sock")]
            }
            for base in [home.appendingPathComponent("Library/Application Support"),fm.temporaryDirectory] {
                for directory in ((try? fm.contentsOfDirectory(at:base,includingPropertiesForKeys:[.isDirectoryKey])) ?? []).filter({$0.lastPathComponent.lowercased().contains("blip")}).prefix(16) {
                    candidates += [directory.appendingPathComponent("sock"),directory.appendingPathComponent("cache/sock")]
                }
            }
        }
        return liveSocket(in: candidates)
    }

    static func liveSocket(in candidates: [URL]) -> URL? {
        var valid: [URL: URL] = [:]
        for path in candidates.sorted(by: { $0.path.utf8.count < $1.path.utf8.count }) {
            let resolved = path.resolvingSymlinksInPath().standardizedFileURL
            guard valid[resolved] == nil, let descriptor = try? connect(to: path, wait: 0) else { continue }
            Darwin.close(descriptor)
            valid[resolved] = path
        }
        return valid.count == 1 ? valid.values.first : nil
    }
    static func frame(_ kind: UInt8, _ message: UInt64, _ data: Data) -> Data {
        Data([kind*2+1]) + BlipProto.varint(1) + BlipProto.varint(message) + BlipProto.varint(UInt64(data.count)) + data
    }
    private static func connect(to socket: URL, wait: Int32) throws -> Int32 {
        let path = Array(socket.path.utf8) + [UInt8(0)]
        guard path.count <= 104 else { throw BlipRPCError.unavailable }
        var info = stat()
        guard lstat(socket.path,&info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { throw BlipRPCError.unavailable }
        let fd = Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { throw BlipRPCError.unavailable }
        var readyToUse = false
        defer { if !readyToUse { Darwin.close(fd) } }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of:&address.sun_path) { raw in raw.copyBytes(from:path) }
        let flags=fcntl(fd,F_GETFL,0)
        guard flags>=0,fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0 else {throw BlipRPCError.unavailable}
        let connected = withUnsafePointer(to:&address) { ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            guard errno==EINPROGRESS else {throw BlipRPCError.unavailable}
            var ready=pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
            guard Darwin.poll(&ready,1,wait)>0 else {throw BlipRPCError.unavailable}
            var socketError:Int32=0,length=socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&socketError,&length)==0,socketError==0 else {throw BlipRPCError.unavailable}
        }
        guard fcntl(fd,F_SETFL,flags)==0 else {throw BlipRPCError.unavailable}
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd,&uid,&gid) == 0, uid == geteuid() else { throw BlipRPCError.unavailable }
        readyToUse = true
        return fd
    }

    static func call(socket: URL, method: String, body: Data) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        let fd = try connect(to: socket, wait: 5000)
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let metadata = BlipProto.field(1,BlipProto.string(1,"user-agent") + BlipProto.string(2,"myDrive-macOS/0.4.1"))
        let request = frame(7,1,metadata) + frame(1,2,Data(method.utf8)) + frame(2,3,body) + frame(6,4,Data())
        var sent = 0
        try request.withUnsafeBytes { raw in
            while sent < request.count {
                guard ProcessInfo.processInfo.systemUptime<deadline else {throw BlipRPCError.limit}
                let count = Darwin.send(fd,raw.baseAddress!.advanced(by:sent),request.count-sent,0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BlipRPCError.rejected }; sent += count
            }
        }
        func read(_ count: Int) throws -> Data {
            guard count <= maximum else { throw BlipRPCError.limit }
            var data = Data(count:count), offset = 0
            try data.withUnsafeMutableBytes { raw in
                while offset < count {
                    guard ProcessInfo.processInfo.systemUptime<deadline else {throw BlipRPCError.limit}
                    let n = Darwin.recv(fd,raw.baseAddress!.advanced(by:offset),count-offset,0)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw BlipRPCError.rejected }; offset += n
                }
            }; return data
        }
        func varint() throws -> UInt64 {
            var bytes = Data()
            for _ in 0..<10 { let byte = try read(1)[0]; bytes.append(byte); if byte & 128 == 0 { var index=0; return try BlipProto.readVar(bytes,&index) } }
            throw BlipRPCError.invalid
        }
        var payload = Data(), activeMessage: UInt64?
        for _ in 0..<4096 {
            let flags = try read(1)[0], stream = try varint(), message = try varint(), length = try varint()
            guard length <= UInt64(maximum) else { throw BlipRPCError.limit }
            let data = try read(Int(length)), kind = (flags & 126) >> 1
            if flags & 128 != 0 { continue }
            guard stream == 1 else { throw BlipRPCError.invalid }
            if kind == 3 { throw BlipRPCError.rejected }
            if kind == 5 { throw BlipRPCError.rejected }
            guard kind == 2 else { continue }
            if let activeMessage, activeMessage != message { throw BlipRPCError.invalid }
            activeMessage = message
            guard payload.count+data.count <= maximum else { throw BlipRPCError.limit }
            payload.append(data)
            if flags & 1 != 0 { return payload }
        }
        throw BlipRPCError.limit
    }
    static func decodedPath(_ value: String) -> String? {
        if value.hasPrefix("/") { return value }
        if let url=URL(string:value),url.isFileURL,url.host==nil || url.host=="" { return url.path }
        let directories: [String:FileManager.SearchPathDirectory] = ["downloads:":.downloadsDirectory,"documents:":.documentDirectory,"desktop:":.desktopDirectory,"pictures:":.picturesDirectory,"music:":.musicDirectory,"movies:":.moviesDirectory]
        guard let match=directories.first(where:{value.hasPrefix($0.key)}), let root=FileManager.default.urls(for:match.value,in:.userDomainMask).first else {return nil}
        let suffix=String(value.dropFirst(match.key.count))
        guard !suffix.contains("\\"), !suffix.contains("\0"), !suffix.split(separator:"/",omittingEmptySubsequences:false).contains("..") else {return nil}
        return root.appendingPathComponent(suffix).path
    }
    static var receivedDirectory: URL {
        FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0].appendingPathComponent("myDrive",isDirectory:true)
    }
    static func snapshot(_ envelope: Data) throws -> JSON {
        let response=try BlipProto(envelope)
        guard let raw=response.bytes(2) else {throw BlipRPCError.invalid}
        let state=try BlipProto(raw), auth=try BlipProto(state.bytes(201) ?? Data())
        let config=try BlipProto(state.bytes(100) ?? Data()), registration=try BlipProto(state.bytes(200) ?? Data())
        let user=auth.string(202),device=auth.string(204), authenticated=(auth.bytes(201)?.isEmpty==false)
        guard !authenticated || (UUID(uuidString:user) != nil && UUID(uuidString:device) != nil) else {throw BlipRPCError.invalid}
        var peers: [JSON]=[], transfers: [JSON]=[],contacts:[String:String]=[:],userNames:[String:String]=[:]
        if let users=state.bytes(500) {
            for entry in try BlipProto(users).messages(1) {
                guard let value=entry.bytes(2) else {continue};let knownUser=try BlipProto(value), id=knownUser.string(8)
                guard UUID(uuidString:id) != nil else {continue}
                let candidate=knownUser.string(1)
                let contact=candidate.count<=254 && candidate.rangeOfCharacter(from:.controlCharacters)==nil && candidate.range(of:"^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$",options:.regularExpression) != nil ? candidate : ""
                contacts[id]=contact
                let human=knownUser.string(2);let userName=human.count<=100 && human.rangeOfCharacter(from:.controlCharacters)==nil && !human.isEmpty ? human : contact;userNames[id]=userName
                for item in try knownUser.messages(7) {
                    guard let data=item.bytes(2) else {continue};let peer=try BlipProto(data), peerID=peer.string(1)
                    if UUID(uuidString:peerID) != nil {
                        let name = peer.string(3)
                        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                            name.unicodeScalars.count <= 160 && name.rangeOfCharacter(from: .controlCharacters) == nil
                        let kind = [2:"Phone",3:"Tablet",4:"Laptop",5:"Desktop"][Int(exactly:peer.number(2)) ?? 0] ?? "Device"
                        var row: JSON = ["peer": id+":"+peerID, "name": hasName ? name : kind, "kind": kind,
                                         "contact": contact, "user_name": userName, "history": false,
                                         "name_known": hasName, "can_relay": kind == "Desktop" || kind == "Laptop"]
                        if let reach = peer.bytes(4) { row["online"] = try BlipProto(reach).number(1) != 0 }
                        peers.append(row)
                    }
                }
            }
        }
        let names=[0:"UnknownStatus",1:"Created",2:"InviteRequested",3:"Invited",4:"Pending",5:"Active",6:"Paused",7:"ResumeRequested",8:"Completed",9:"Cancelled"]
        for entry in try state.messages(600) {
            guard let data=entry.bytes(2) else {continue};let transfer=try BlipProto(data),id=transfer.string(100)
            guard UUID(uuidString:id) != nil else {continue}
            let peer=try BlipProto(transfer.bytes(200) ?? Data()), peerID=peer.string(1)+":"+peer.string(2)
            let direction = [1:"Incoming", 2:"Outgoing"][Int(exactly: transfer.number(700)) ?? 0] ?? "UnknownDirection"
            let incoming=direction=="Incoming", completed=transfer.number(800)==8, dismissed=transfer.number(1000) != 0
            let error=transfer.values[600] != nil || transfer.values[601] != nil
            var files:[String]=[],received:[JSON]=[],linkOnly=false,itemNames:[String]=[],total:UInt64=0
            if incoming && !error, let archive=transfer.bytes(400) {
                let metadata=try BlipProto(archive), entries=try metadata.messages(1)
                var roots:[String]=[], valid=true, locations:[String:String]=[:]
                for saved in try metadata.messages(2) {locations[saved.string(1)]=saved.string(2)}
                for item in entries {
                    let path=item.string(1)
                    guard let itemData=item.bytes(2) else {valid=false;continue}
                    let kind=try BlipProto(itemData)
                    let root = !path.isEmpty && !path.contains("/") && !path.contains("\\") && path != "." && path != ".."
                    if root && itemNames.count<3 {itemNames.append(String(path.filter{!$0.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})}.prefix(160)))}
                    if let file=kind.bytes(1) {let size=try BlipProto(file).number(1);let sum=total.addingReportingOverflow(size);total=sum.overflow ? UInt64.max : sum.partialValue}
                    let shortcut=path.lowercased().hasSuffix(".url") || path.lowercased().hasSuffix(".webloc")
                    let regular=kind.bytes(1) != nil && kind.values[2]==nil && kind.values[3]==nil && kind.values[4]==nil
                    let folder=kind.bytes(2) != nil && kind.values[1]==nil && kind.values[3]==nil && kind.values[4]==nil
                    if completed && root && (regular||folder) && received.count<256,let location=locations[path].flatMap(decodedPath) {
                        let size:UInt64
                        if regular {size=try BlipProto(kind.bytes(1)!).number(1)}else{size=0}
                        received.append(["name":path,"path":location,"is_directory":folder,"size":Int64(exactly:size) ?? 0])
                    }
                    if root && shortcut && regular {
                        roots.append(path)
                        let size=try BlipProto(kind.bytes(1)!).number(1)
                        if size==0 || size>65536 {valid=false}
                    } else {valid=false}
                }
                linkOnly = !dismissed && valid && !roots.isEmpty && roots.count<=16
                if completed && !dismissed {files=roots.compactMap{locations[$0].flatMap(decodedPath)}}
            }
            if direction == "Outgoing", let archive = transfer.bytes(400) {
                itemNames = try BlipProto(archive).messages(1).lazy.map { $0.string(1) }
                    .filter { !$0.contains("/") && !$0.contains("\\") }.prefix(3).map { String($0.prefix(160)) }
            }
            let updated = try BlipProto(transfer.bytes(1300) ?? Data()).number(1)
            transfers.append(["transfer_id":id,"peer":peerID,"direction":direction,"updated_at":updated,"status":names[Int(exactly:transfer.number(800)) ?? -1] ?? "UnknownStatus","completed":completed,"has_error":error,"link_files":files,"link_only":linkOnly,"dismissed":dismissed,"progress":Int64(exactly:transfer.number(1100)) ?? 0,"total_bytes":Int64(exactly:total) ?? 0,"item_names":itemNames,"received_items":received])
            if incoming,UUID(uuidString:peer.string(1)) != nil,UUID(uuidString:peer.string(2)) != nil,!peers.contains(where:{$0["peer"] as? String == peerID}) {
                let contact=contacts[peer.string(1)] ?? "";peers.append(["peer":peerID,"name":"Previous device","contact":contact,"user_name":userNames[peer.string(1)] ?? contact,"history":true,"name_known":false])
            }
        }
        return ["ok":true,"status":["authenticated":authenticated,"desktop_session":true,"user_id":user,"device_id":device,
                "registration_code_sent":registration.number(1) == 2,"registration_failed":registration.values[999] != nil,
                "receive_policy_verified":config.number(2) != 0 && config.string(4) == receivedDirectory.path],
                "devices":peers,"transfers":transfers]
    }

    static func dispatch(_ name: String, _ body: Data, socket: URL) throws {
        let event = BlipProto.string(1, "type.googleapis.com/event." + name) + BlipProto.field(2, body)
        _ = try call(socket: socket, method: "/rpc.Service/Dispatch", body: BlipProto.field(1, event))
    }

    static func search(_ query: String, owner: String, socket: URL) throws -> [JSON] {
        let key = "6971d326-6e6d-4915-aed7-581eafa9b26d"
        guard (1...254).contains(query.unicodeScalars.count),
              query.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BlipRPCError.searchInput
        }
        let id = BlipProto.string(1, key)
        try dispatch("AbandonSearch", id, socket: socket)
        try dispatch("Search", id + BlipProto.string(2, query), socket: socket)
        let deadline = ProcessInfo.processInfo.systemUptime + 7
        while ProcessInfo.processInfo.systemUptime < deadline {
            let response = try call(socket: socket, method: "/rpc.Service/GetState", body: Data())
            let envelope = try BlipProto(response)
            let state = try BlipProto(envelope.bytes(2) ?? Data())
            if let entry = try state.messages(800).first(where: { $0.string(1) == key }),
               let body = entry.bytes(2) {
                let result = try BlipProto(body)
                if result.string(1) == query && result.number(2) == 2 { break }
                if result.string(1) == query && result.number(2) == 3 {
                    let snapshot = try Self.snapshot(response)
                    let status = snapshot["status"] as? JSON ?? [:]
                    guard status["authenticated"] as? Bool == true,
                          let user = status["user_id"] as? String, let device = status["device_id"] as? String,
                          user + ":" + device == owner
                    else { throw BlipRPCError.rejected }
                    let matches = try result.messages(3) + result.messages(4)
                    let users = Set(matches.filter { $0.string(2).isEmpty }.map { $0.string(1).lowercased() })
                    let peers = Set(matches.map { ($0.string(1) + ":" + $0.string(2)).lowercased() })
                    return (snapshot["devices"] as? [JSON] ?? []).filter { device in
                        let peer = (device["peer"] as? String ?? "").lowercased()
                        let user = peer.split(separator: ":").first.map(String.init) ?? ""
                        return device["history"] as? Bool == false && peer != owner.lowercased() &&
                            (users.contains(user) || peers.contains(peer))
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw BlipRPCError.searchUnavailable
    }

    static func prepareManagedProfile() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let socket = liveSocket(in: managedCandidates) {
                let agent = BlipProto.string(101, "Mac") + BlipProto.numeric(102, 5) +
                    BlipProto.string(200, "macOS") + BlipProto.string(300, "net.oseanstudio.mydrive") +
                    BlipProto.string(301, "myDrive")
                try dispatch("SetUserAgent", BlipProto.field(1, agent), socket: socket)
                try configureManagedReceive(socket)
                return
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw BlipRPCError.unavailable
    }

    static func configureManagedReceive(_ socket: URL) throws {
        try FileManager.default.createDirectory(at: receivedDirectory, withIntermediateDirectories: true)
        try dispatch("TransferSetAutoAccept", BlipProto.numeric(1, 0), socket: socket)
        try dispatch("TransferSetCustomDefaultSavePath", BlipProto.string(1, receivedDirectory.path), socket: socket)
    }

    static func register(_ input: String, verifying: Bool, socket: URL) throws {
        guard isManaged(socket) else { throw BlipRPCError.invalid }
        let current = try request("poll", arguments: [], socket: socket)["status"] as? JSON
        guard current?["authenticated"] as? Bool == false else { throw BlipRPCError.rejected }
        let name = "myDrive on Mac"
        if verifying {
            guard input.range(of: "^[A-Za-z0-9-]{4,16}$", options: .regularExpression) != nil else { throw BlipRPCError.invalid }
            let identityFile = managedProfile.appendingPathComponent("registration-device.txt")
            let identity: String
            if let existing = try? String(contentsOf: identityFile, encoding: .utf8), UUID(uuidString: existing) != nil {
                identity = existing
            } else {
                identity = UUID().uuidString.lowercased()
                try Data(identity.utf8).write(to: identityFile, options: .atomic)
            }
            try dispatch("RegistrationRequested", BlipProto.string(1, input) + BlipProto.string(2, identity) +
                         BlipProto.string(3, name) + BlipProto.numeric(4, 5), socket: socket)
        } else {
            guard input.utf8.count <= 254, input.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
            else { throw BlipRPCError.invalid }
            try dispatch("SendRegistrationCodeRequested", BlipProto.string(1, input) + BlipProto.string(2, name), socket: socket)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            let status = try request("poll", arguments: [], socket: socket)["status"] as? JSON
            if verifying && status?["authenticated"] as? Bool == true {
                try configureManagedReceive(socket)
                return
            }
            if !verifying && status?["registration_code_sent"] as? Bool == true { return }
            if status?["registration_failed"] as? Bool == true { throw BlipRPCError.rejected }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw BlipRPCError.rejected
    }
    static func request(_ command: String, arguments: [String], socket: URL) throws -> JSON {
        switch command {
        case "poll", "devices": return try snapshot(call(socket:socket,method:"/rpc.Service/GetState",body:Data()))
        case "accept":
            guard arguments.count==2,arguments[0]=="--id",UUID(uuidString:arguments[1]) != nil else {throw BlipRPCError.invalid}
            let before=try snapshot(call(socket:socket,method:"/rpc.Service/GetState",body:Data()))
            guard let invitation=(before["transfers"] as? [JSON] ?? []).first(where:{$0["transfer_id"] as? String==arguments[1]}),invitation["direction"] as? String=="Incoming",invitation["has_error"] as? Bool==false,invitation["dismissed"] as? Bool==false else {throw BlipRPCError.rejected}
            if ["Pending","Active","Completed"].contains(invitation["status"] as? String ?? ""){return ["ok":true,"phase":"already_receiving"]}
            guard invitation["status"] as? String=="Invited" else {throw BlipRPCError.rejected}
            let root=receivedDirectory.appendingPathComponent(arguments[1],isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let event=BlipProto.string(1,arguments[1])+BlipProto.string(2,root.path)
            let any=BlipProto.string(1,"type.googleapis.com/event.TransferAcceptanceRequested")+BlipProto.field(2,event)
            _ = try call(socket:socket,method:"/rpc.Service/Dispatch",body:BlipProto.field(1,any))
            let deadline=ProcessInfo.processInfo.systemUptime+5
            repeat {
                let latest=try snapshot(call(socket:socket,method:"/rpc.Service/GetState",body:Data()))
                if let transfer=(latest["transfers"] as? [JSON] ?? []).first(where:{$0["transfer_id"] as? String==arguments[1]}) {
                    let status=transfer["status"] as? String ?? ""
                    guard transfer["has_error"] as? Bool==false,status != "Cancelled" else {throw BlipRPCError.rejected}
                    if ["Pending","Active","Completed"].contains(status){return ["ok":true,"phase":"receiving_confirmed"]}
                }
                Thread.sleep(forTimeInterval:0.125)
            }while ProcessInfo.processInfo.systemUptime<deadline
            throw BlipRPCError.rejected
        default: throw BlipRPCError.invalid
        }
    }

    static func send(paths: [String], peer: String, sender: String, socket: URL, requestID: String? = nil) throws {
        let components = peer.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2, components.allSatisfy({ UUID(uuidString: $0) != nil }),
              peer.caseInsensitiveCompare(sender) != .orderedSame, !paths.isEmpty, paths.count <= 256 else { throw BlipRPCError.invalid }
        let locals = try paths.map { path -> String in
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values.isRegularFile == true || values.isDirectory == true else { throw BlipRPCError.invalid }
            return url.path
        }
        let state = try request("poll", arguments: [], socket: socket)
        guard let status = state["status"] as? JSON, status["authenticated"] as? Bool == true,
              let account = status["user_id"] as? String, let device = status["device_id"] as? String,
              account + ":" + device == sender,
              let devices = state["devices"] as? [JSON],
              devices.contains(where: { $0["peer"] as? String == peer && $0["history"] as? Bool == false }) else { throw BlipRPCError.rejected }
        let id = requestID ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: id) != nil,
              !(state["transfers"] as? [JSON] ?? []).contains(where: { $0["transfer_id"] as? String == id }) else { throw BlipRPCError.rejected }
        for event in sendEvents(paths: locals, peer: components, id: id) {
            _ = try call(socket: socket, method: "/rpc.Service/Dispatch", body: event)
        }
    }

    static func sendEvents(paths: [String], peer: [String], id: String) -> [Data] {
        let destination = BlipProto.string(1, peer[0]) + BlipProto.string(2, peer[1])
        let transfer = BlipProto.string(1, id)
        let routed = transfer + BlipProto.field(2, destination)
        let content = paths.reduce(into: transfer) { $0.append(BlipProto.string(2, $1)) }
        return [("TransferCreateRequested", routed), ("TransferAddContentRequested", content), ("TransferInviteRequested", routed)].map { kind, payload in
            let any = BlipProto.string(1, "type.googleapis.com/event." + kind) + BlipProto.field(2, payload)
            return BlipProto.field(1, any)
        }
    }
}
