import AppKit
import Foundation
import Combine

enum BlipReceiverError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

extension Notification.Name { static let myDriveIncomingBlip = Notification.Name("io.mydrive.blip.incoming") }

/// Reads desktop Blip through its same-user local socket. No account files or directory watchers.
@MainActor final class BlipReceiver: ObservableObject {
    @Published var state = "Waiting for desktop Blip"
    @Published var peers: [BlipPeer] = []
    @Published var transfers: [BlipTransfer] = []
    @Published var problem: String?
    @Published private(set) var policy = BlipPolicy()
    @Published var autoOpen = PrefStore.shared.preferences.blipAutoOpenLinks
    @Published private(set) var backgroundEnabled = PrefStore.shared.preferences.blipBackgroundReceiving ?? true
    @Published private(set) var sending = false
    @Published private(set) var preparingSend = false
    @Published private(set) var sendMessage: String?
    @Published private(set) var relayWaiting = 0
    @Published private(set) var receiving = Set<String>()
    private let root: URL
    private var task: Task<Void, Never>?
    private var session = ""
    private(set) var account = ""
    private var noticeSession=""
    private var noticeStates:[String:String]=[:]
    private var contacts:BlipContactStore?
    private var claims: BlipClaims?
    private var canSavePolicy = true
    private var refreshing = false
    private var activity: NSObjectProtocol?
    private var backgroundProcess: Process?
    private var backgroundInput: FileHandle?
    private var backgroundFailure: String?
    private var nextHostAttempt = Date.distantPast
    private var hostStartedAt = Date.distantPast
    private var fallbackStartedAt = Date.distantPast
    private var selfPeer = ""
    private var connectedPeers = Set<String>()
    private var relayReceived: [String: BlipTransfer] = [:]
    private var relaySession = ""
    var recipients: [BlipPeer] {
        peers.filter { connectedPeers.contains($0.peer) && $0.peer != selfPeer }.sorted {
            let contactOrder = ($0.contactName ?? "").localizedCaseInsensitiveCompare($1.contactName ?? "")
            if contactOrder != .orderedSame { return contactOrder == .orderedAscending }
            let deviceOrder = $0.displayName.localizedStandardCompare($1.displayName)
            return deviceOrder == .orderedSame ? $0.peer < $1.peer : deviceOrder == .orderedAscending
        }
    }
    var connected: Bool { !selfPeer.isEmpty }
    var outboxDirectory: URL { root.appendingPathComponent("outbox", isDirectory: true) }

    func reportSend(_ message: String) { sendMessage = message }

    func send(_ payload: BlipSendPayload, to peer: BlipPeer) {
        guard !sending, connected, recipients.contains(where: { $0.peer == peer.peer }),
              let socket = BlipLocalRPC.socketURL() else {
            payload.discard()
            reportSend("This device is unavailable. Refresh Transfers before sending.")
            return
        }
        let sender = selfPeer
        let paths = payload.files.map(\.path)
        let destination = peer.peer
        sending = true
        reportSend("Preparing transfer…")
        Task {
            defer { sending = false }
            do {
                if try await queueRelay(paths: paths, target: peer, owner: sender, socket: socket) {
                    payload.discard()
                    sendMessage = nil
                } else {
                    try await Task.detached(priority: .utility) {
                        try BlipLocalRPC.send(paths: paths, peer: destination, sender: sender, socket: socket)
                    }.value
                    sendMessage = nil
                }
            } catch {
                reportSend("Blip could not confirm the send. Refresh Transfers before retrying.")
            }
            await refresh()
        }
    }

    private func sameAccount(_ peer: String, _ account: String) -> Bool {
        BlipPolicy.exactPeer(peer) && peer.split(separator: ":").first?.lowercased() == account.lowercased()
    }

    private func queueRelay(paths: [String], target: BlipPeer, owner: String, socket: URL) async throws -> Bool {
        guard sameAccount(target.peer, account) else { return false }
        let snapshot = try await Task.detached { try BlipLocalRPC.request("poll", arguments: [], socket: socket) }.value
        let status = snapshot.dict("status")
        guard status.bool("authenticated"), status.str("user_id") + ":" + status.str("device_id") == owner else { return false }
        let devices = snapshot["devices"] as? [JSON] ?? []
        guard let final = devices.first(where: { $0.str("peer") == target.peer && !$0.bool("history") }),
              final.bool("can_relay"), final["online"] as? Bool == false else { return false }
        let relays = devices.filter {
            $0.bool("can_relay") && $0.bool("online") && !$0.bool("history") &&
            $0.str("peer").lowercased() != owner.lowercased() && $0.str("peer").lowercased() != target.peer.lowercased() &&
            sameAccount($0.str("peer"), status.str("user_id"))
        }.map { $0.str("peer") }
        guard let relay = relays.first else { return false }
        _ = try await CoreBridge.shared.call(action: "relay.stage", request: ["data_dir": Paths.dataDir.path,
            "payload": ["self": owner, "target": target.peer, "relay": relay, "alternatives": Array(relays.dropFirst()), "paths": paths]], timeout: 3600)
        return true
    }

    private func updateRelay(_ snapshot: JSON, owner: String, rawTransfers: [BlipTransfer]) async throws {
        if relaySession != owner { relayReceived.removeAll(); relaySession = owner }
        let payload: JSON = ["self": owner, "inbox": BlipLocalRPC.receivedDirectory.path,
                             "downloads": BlipLocalRPC.receivedDirectory.deletingLastPathComponent().path,
                             "devices": snapshot.array("devices"), "transfers": snapshot.array("transfers")]
        guard let result = try await CoreBridge.shared.call(action: "relay.tick",
                request: ["data_dir": Paths.dataDir.path, "payload": payload], timeout: 10) as? JSON else { return }
        relayWaiting = Int(result.int64("waiting"))
        let command = result.dict("command")
        let id = command.str("id")
        switch command.str("action") {
        case "accept":
            _ = try await request("accept", ["--id", id])
        case "send":
            guard let socket = BlipLocalRPC.socketURL(), let paths = command["paths"] as? [String] else { return }
            let destination = command.str("peer")
            try await Task.detached(priority: .utility) {
                try BlipLocalRPC.send(paths: paths, peer: destination, sender: owner, socket: socket, requestID: id)
            }.value
        case "deliver":
            guard let transport = rawTransfers.first(where: { $0.id == id && $0.direction == "Incoming" && $0.confirmed }),
                  sameAccount(transport.peer, account), let paths = command["paths"] as? [String] else { return }
            var delivery = transport
            delivery.received_items = paths.compactMap { path in
                var folder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { return nil }
                return BlipReceivedItem(name: URL(fileURLWithPath: path).lastPathComponent, path: path, is_directory: folder.boolValue)
            }
            delivery.item_names = delivery.received_items?.map(\.name)
            relayReceived[id] = delivery
            guard autoOpen, policy.allows(transport, account: account) else { return }
            let shortcuts = paths.filter { ["url", "webloc"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.prefix(16)
            var opened = Set<URL>()
            for path in shortcuts {
                let link = await Task.detached { BlipWebLink.read(path) }.value
                if let link, autoOpen, policy.allows(transport, account: account),
                   selfPeer == owner, opened.insert(link).inserted { NSWorkspace.shared.open(link) }
            }
        default: break
        }
    }
    init(root: URL = Paths.dataDir.appendingPathComponent("Blip", isDirectory: true)) {
        self.root=root
        do {
            let file = root.appendingPathComponent("link-policy.json")
            if FileManager.default.fileExists(atPath:file.path) { policy = try JSONDecoder().decode(BlipPolicy.self, from: Data(contentsOf:file)) }
            claims = try BlipClaims(root.appendingPathComponent("link-claims.json"))
            contacts=try BlipContactStore(root.appendingPathComponent("sender-catalog.json"))
        } catch { canSavePolicy = false; problem = "Saved Blip policy or history is unavailable. Its data has been kept." }
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil; stopBackground(); setActivity(false) }

    private var desktopAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: BlipMacEngine.bundleID)
            ?? [URL(fileURLWithPath: "/Applications/Blip.app"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Blip.app")]
            .first { Bundle(url: $0)?.bundleIdentifier == BlipMacEngine.bundleID }
    }

    private func ensureBackground() {
        guard backgroundEnabled, backgroundProcess == nil, Date() >= nextHostAttempt else { return }
        nextHostAttempt = Date().addingTimeInterval(30)
        guard let app = desktopAppURL, let executable = Bundle.main.executableURL else {
            backgroundFailure = BlipMacEngine.missing.localizedDescription
            return
        }
        let process = Process()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = ["--blip-background-engine", app.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor in
                guard let self, self.backgroundProcess === child else { return }
                self.backgroundProcess = nil
                try? self.backgroundInput?.close()
                self.backgroundInput = nil
                let failure: BlipMacEngine = status == 21 ? .version : status == 22 ? .profile : status == 20 ? .missing : .launch
                self.backgroundFailure = self.backgroundEnabled ? failure.localizedDescription : nil
                self.nextHostAttempt = self.backgroundEnabled ? Date().addingTimeInterval(30) : .distantPast
            }
        }
        do {
            try process.run()
            backgroundProcess = process
            backgroundInput = input.fileHandleForWriting
            backgroundFailure = nil
            hostStartedAt = Date()
        } catch { backgroundFailure = BlipMacEngine.launch.localizedDescription }
    }

    private func launchDesktopInBackground() {
        guard backgroundEnabled, !adapterAvailable, let app = desktopAppURL,
              NSRunningApplication.runningApplications(withBundleIdentifier: BlipMacEngine.bundleID).isEmpty,
              fallbackStartedAt == .distantPast else { return }
        fallbackStartedAt = Date()
        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        options.hides = true
        options.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: app, configuration: options) { [weak self] _, error in
            if error != nil {
                Task { @MainActor in self?.backgroundFailure = "macOS could not launch Blip in the background." }
            }
        }
    }

    func prepareSend(_ action: @escaping () -> Void, onUnavailable: @escaping () -> Void = {}) {
        guard !sending, !preparingSend else { onUnavailable(); return }
        if connected && adapterAvailable { action(); return }
        preparingSend = true
        reportSend("Connecting to Blip…")
        if !adapterAvailable && backgroundProcess == nil { nextHostAttempt = .distantPast }
        fallbackStartedAt = .distantPast
        Task {
            defer { preparingSend = false }
            let deadline = Date().addingTimeInterval(35)
            repeat {
                await refresh()
                if connected {
                    sendMessage = nil
                    action()
                    return
                }
                if desktopAppURL == nil || state == "Sign in in desktop Blip" { break }
                if !backgroundEnabled && !adapterAvailable { break }
                try? await Task.sleep(for: .milliseconds(500))
            } while Date() < deadline && !Task.isCancelled
            onUnavailable()
            reportSend("Blip is unavailable. " + (backgroundFailure ?? state))
        }
    }

    private func stopBackground() {
        try? backgroundInput?.close()
        backgroundInput = nil
    }

    func setBackground(_ enabled: Bool) {
        backgroundEnabled = enabled
        PrefStore.shared.update { $0.blipBackgroundReceiving = enabled }
        nextHostAttempt = .distantPast
        backgroundFailure = nil
        fallbackStartedAt = .distantPast
        if !enabled { stopBackground() }
        Task { await refresh() }
    }
    private func setActivity(_ enabled: Bool) {
        if enabled && activity == nil {activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Watch for incoming Blip transfers")}
        if !enabled,let activity {ProcessInfo.processInfo.endActivity(activity);self.activity=nil}
    }
    var adapterAvailable: Bool { BlipLocalRPC.socketURL() != nil }
    private func request(_ command: String, _ arguments: [String] = []) async throws -> JSON {
        guard let socket = BlipLocalRPC.socketURL() else { throw BlipRPCError.unavailable }
        return try await Task.detached(priority: .utility) {
            try BlipLocalRPC.request(command,arguments:arguments,socket:socket)
        }.value
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        ensureBackground()
        guard adapterAvailable else {
            let starting = backgroundEnabled && backgroundInput != nil && Date().timeIntervalSince(hostStartedAt) < 20
            if backgroundInput != nil && !starting {
                stopBackground()
                backgroundFailure = BlipMacEngine.launch.localizedDescription
            }
            if !starting && backgroundFailure != nil { launchDesktopInBackground() }
            let launchingDesktop = Date().timeIntervalSince(fallbackStartedAt) < 15
            state = starting || launchingDesktop ? "Starting Blip in the background…" : "Blip is unavailable"
            problem = starting || launchingDesktop ? nil : backgroundFailure
            session = ""; selfPeer = ""; setActivity(false)
            return
        }
        do {
            let value = try await request("poll"), status = value.dict("status")
            guard !Task.isCancelled else { return }
            guard status.bool("authenticated"), status.bool("desktop_session") else { state = "Sign in in desktop Blip"; account="";session="";selfPeer="";peers=[];transfers=[];setActivity(false);return }
            account = status.str("user_id"); guard UUID(uuidString:account) != nil else { throw BlipReceiverError.message("Blip identity could not be verified.") }
            let identity = account + ":" + status.str("device_id")
            let data = try JSONSerialization.data(withJSONObject:value.array("transfers"))
            let rawTransfers = try JSONDecoder().decode([BlipTransfer].self, from:data)
            selfPeer = identity
            var relayProblem: String?
            do { try await updateRelay(value, owner: identity, rawTransfers: rawTransfers) }
            catch { relayProblem = "A relay action needs attention. Stored files are kept." }
            transfers = rawTransfers.filter {
                !sameAccount($0.peer, account) || ($0.item_names?.count != 1 || $0.item_names?.first?.hasPrefix("mydrive-relay-v1.") != true)
            } + relayReceived.values.sorted { $0.id < $1.id }
            receiving.formIntersection(Set(transfers.filter(\.pending).map(\.id)))
            let incomingPeers=try JSONDecoder().decode([BlipPeer].self, from: JSONSerialization.data(withJSONObject:value.array("devices")))
            selfPeer = identity
            connectedPeers = Set(incomingPeers.filter { $0.history != true }.map(\.peer))
            peers=try contacts?.merge(account:account,selfPeer:identity,peers:incomingPeers,transfers:transfers,approved:policy.account.lowercased()==account.lowercased() ? policy.peers.union(policy.files) : []) ?? incomingPeers
            guard let claims else { throw BlipReceiverError.message("Receive history is unavailable. Automatic actions are disabled.") }
            if session != identity {
                for transfer in transfers where transfer.confirmed { try claims.claim(identity+":skip:"+transfer.id) }
                session = identity
            }
            let nativeHost = backgroundEnabled && backgroundProcess?.isRunning == true
                && NSRunningApplication.runningApplications(withBundleIdentifier: BlipMacEngine.bundleID).isEmpty
            state = nativeHost ? "Ready in the background" : "Using desktop Blip"
            problem = relayProblem
            setActivity(true)
            let baseline=noticeSession != identity
            if baseline {noticeStates=[:];noticeSession=identity}
            for transfer in transfers where transfer.direction=="Incoming" && (transfer.dismissed != true || transfer.confirmed) {
                let state=transfer.status+":"+String(transfer.has_error),changed=noticeStates[transfer.id] != state
                noticeStates[transfer.id]=state
                let live = !transfer.has_error && ["Invited","Pending","Active","Paused","ResumeRequested"].contains(transfer.status)
                if changed && (!baseline || live) {NotificationCenter.default.post(name:.myDriveIncomingBlip,object:transfer.id)}
            }
            for transfer in transfers where transfer.pending {
                if policy.autoReceive(transfer,account:account,openLinks:autoOpen) {
                    if try claims.claim(identity+":accept:"+transfer.id) {
                        receiving.insert(transfer.id)
                        do {_ = try await request("accept",["--id",transfer.id])}catch{receiving.remove(transfer.id);problem=error.localizedDescription}
                    }
                }
            }
            for transfer in transfers where transfer.direction == "Incoming" && transfer.confirmed {
                let skip = identity+":skip:"+transfer.id
                if claims.contains(skip) { continue }
                guard autoOpen && policy.allows(transfer,account:account) else { try claims.claim(skip); continue }
                for location in (transfer.link_files ?? []).prefix(256) {
                    let fileKey = identity+":file:"+transfer.id+":"+location
                    if claims.contains(fileKey) { continue }
                    guard let url = await Task.detached(operation:{BlipWebLink.read(location)}).value else { continue }
                    guard autoOpen && policy.allows(transfer,account:account) && session == identity else { continue }
                    let open = try claims.claim(identity+":link:"+transfer.id+":"+url.absoluteString)
                    try claims.claim(fileKey)
                    if open {
                        if !NSWorkspace.shared.open(url) { problem = "The received link could not open. Open it manually from the received folder." }
                    }
                }
            }
        } catch { problem = error.localizedDescription; state = "Blip needs attention"; session = "";selfPeer="";setActivity(false) }
    }
    func setTrusted(_ peer: BlipPeer, _ enabled: Bool,files:Bool=false) {
        guard canSavePolicy, UUID(uuidString:account) != nil, BlipPolicy.exactPeer(peer.peer) else { return }
        var updated = policy
        if updated.account.lowercased() != account.lowercased() { updated = BlipPolicy(account:account,peers:[]) }
        if files {if enabled{updated.files.insert(peer.peer.lowercased())}else{updated.files.remove(peer.peer.lowercased())}}
        else {if enabled { updated.peers.insert(peer.peer.lowercased()) } else { updated.peers.remove(peer.peer.lowercased()) }}
        do { try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try JSONEncoder().encode(updated).write(to:root.appendingPathComponent("link-policy.json"),options:.atomic);policy=updated;session="" }
        catch { problem = "Sender approval could not be saved." }
    }
    func isTrusted(_ peer: BlipPeer) -> Bool { policy.account.lowercased()==account.lowercased() && policy.peers.contains(peer.peer.lowercased()) }
    func isFileTrusted(_ peer:BlipPeer)->Bool {policy.account.lowercased()==account.lowercased() && policy.files.contains(peer.peer.lowercased())}
    func deviceName(_ peer:BlipPeer)->String {
        let person=peer.peer.split(separator:":").first
        let same=peers.filter{$0.peer.split(separator:":").first==person && $0.displayName.caseInsensitiveCompare(peer.displayName) == .orderedSame}.sorted{$0.peer<$1.peer}
        return same.count>1 ? peer.displayName+" "+String((same.firstIndex(where:{$0.peer==peer.peer}) ?? 0)+1) : peer.displayName
    }
    func recipientLabel(_ peer: BlipPeer) -> String {
        let label = deviceName(peer)
        guard let person = peer.contactName, !person.isEmpty else { return label }
        return peer.hasDeviceName ? label + " · " + person : person + " · " + label
    }
    func senderLabel(_ identity: String) -> String {
        guard let peer = peers.first(where: { $0.peer.caseInsensitiveCompare(identity) == .orderedSame }) else {
            return "Previous device"
        }
        return recipientLabel(peer)
    }
    @discardableResult func rename(_ peer:BlipPeer) -> BlipPeer? {
        let owner = account
        let alert=NSAlert();alert.messageText="Device name";alert.informativeText="Choose a name for this device in myDrive.";alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel")
        alert.window.appearance = AppDelegate.appearance(for: PrefStore.shared.preferences.appearance)
        let input=NSTextField(string:peer.nickname ?? "");input.placeholderString=peer.displayName;input.frame=NSRect(x:0,y:0,width:280,height:24);alert.accessoryView=input
        guard alert.runModal() == .alertFirstButtonReturn, owner == account, let contacts else {return nil}
        do {
            try contacts.setNickname(account: owner, peer: peer.peer, name: input.stringValue)
            var changed = peer
            changed.nickname = String(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(80))
            if let index = peers.firstIndex(where: { $0.peer == peer.peer }) { peers[index].nickname = changed.nickname }
            return changed
        } catch {
            problem = "The device name could not be saved."
            return nil
        }
    }
    func receive(_ transfer: BlipTransfer) { guard transfer.pending, UUID(uuidString:transfer.id) != nil, BlipPolicy.exactPeer(transfer.peer), !receiving.contains(transfer.id) else {return};receiving.insert(transfer.id);Task { do {try claims?.claim(session+":accept:"+transfer.id);_ = try await request("accept",["--id",transfer.id]);await refresh()}catch{receiving.remove(transfer.id);problem=error.localizedDescription} } }
    func setAutoOpen(_ value: Bool) { autoOpen=value;PrefStore.shared.update{$0.blipAutoOpenLinks=value};session="" }
    func openReceived() {
        do {let directory=BlipLocalRPC.receivedDirectory;try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);NSWorkspace.shared.open(directory)}
        catch {problem="The received-files folder could not open."}
    }
    func openBlip() {
        if let app = desktopAppURL { NSWorkspace.shared.open(app); return }
        problem="Open the installed Blip app on this Mac, then refresh."
    }
}
