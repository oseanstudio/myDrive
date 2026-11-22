import AppKit
import Foundation
import Combine

enum BlipReceiverError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

extension Notification.Name { static let myDriveIncomingBlip = Notification.Name("io.mydrive.blip.incoming") }

struct BlipRecentRecipient: Codable, Identifiable {
    let peer: String
    let label: String
    var id: String { peer }
}

/// Uses the same-user local socket served by the headless helper or an existing Blip session.
@MainActor final class BlipReceiver: ObservableObject {
    @Published var state = "Connecting to Blip…"
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
    @Published private(set) var recentRecipients: [BlipRecentRecipient] = []
    @Published private(set) var directoryRecipients: [BlipPeer] = []
    private var recentOwner = ""
    private var recentUpdates: Task<Void, Never>?
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
    private let client = BlipMacClient()
    private var adapterAvailable = false
    private var activity: NSObjectProtocol?
    private var backgroundProcess: Process?
    private var backgroundInput: FileHandle?
    private var backgroundFailure: String?
    private var nextHostAttempt = Date.distantPast
    private var hostStartedAt = Date.distantPast
    private var selfPeer = ""
    private var connectedPeers = Set<String>()
    private var relayReceived: [String: BlipTransfer] = [:]
    private var relaySession = ""
    private var relayTransportState = ""
    private var nextRelayDiscovery = Date.distantPast
    var recipients: [BlipPeer] {
        peers.filter { connectedPeers.contains($0.peer) && $0.peer != selfPeer }.sorted {
            let contactOrder = ($0.contactName ?? "").localizedCaseInsensitiveCompare($1.contactName ?? "")
            if contactOrder != .orderedSame { return contactOrder == .orderedAscending }
            let deviceOrder = $0.displayName.localizedStandardCompare($1.displayName)
            return deviceOrder == .orderedSame ? $0.peer < $1.peer : deviceOrder == .orderedAscending
        }
    }
    var connected: Bool { !selfPeer.isEmpty }
    var recipientOwner: String { selfPeer }
    var outboxDirectory: URL { root.appendingPathComponent("outbox", isDirectory: true) }

    func reportSend(_ message: String) { sendMessage = message }

    func send(_ payload: BlipSendPayload, to peer: BlipPeer) {
        guard !sending, connected, (recipients + directoryRecipients).contains(where: { $0.peer == peer.peer }) else {
            payload.discard()
            reportSend("This device is unavailable. Refresh Blip in the Send view before sending.")
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
                if try await queueRelay(paths: paths, target: peer, owner: sender) {
                    payload.discard()
                    sendMessage = nil
                } else {
                    _ = try await BlipMacClient.request("send", ["paths": paths, "peer": destination, "owner": sender])
                    sendMessage = nil
                }
                await updateRecents("remember", owner: sender, peer: peer)
            } catch {
                reportSend("Blip could not confirm the send. Refresh Blip in the Send view before retrying.")
            }
            await refresh()
        }
    }

    func findRecipients(_ query: String) async throws {
        let owner = selfPeer
        guard !owner.isEmpty else { throw BlipReceiverError.message("Sign in to Blip to find recipients.") }
        directoryRecipients = []
        let value = try await BlipMacClient.request("search", ["text": query, "owner": owner])
        guard selfPeer == owner else { return }
        let devices = try JSONDecoder().decode([BlipPeer].self, from: JSONSerialization.data(withJSONObject: value.array("devices")))
        directoryRecipients = devices.filter { $0.peer.caseInsensitiveCompare(owner) != .orderedSame }
    }

    func removeRecent(_ target: String) {
        let owner = selfPeer
        Task { await updateRecents("remove", owner: owner, target: target) }
    }

    private func updateRecents(_ action: String, owner: String, peer: BlipPeer? = nil, target: String? = nil) async {
        let previous = recentUpdates
        let update = Task {
            await previous?.value
            await changeRecents(action, owner: owner, peer: peer, target: target)
        }
        recentUpdates = update
        await update.value
    }

    private func changeRecents(_ action: String, owner: String, peer: BlipPeer?, target: String?) async {
        guard BlipPolicy.exactPeer(owner) else { return }
        let labels = Dictionary(recipients.map { ($0.peer.lowercased(), recipientLabel($0)) },
                                uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let previous = transfers.filter {
            $0.direction == "Outgoing" && $0.confirmed && labels[$0.peer.lowercased()] != nil &&
                $0.item_names?.first?.hasPrefix("mydrive-relay-v1.") != true
        }.sorted { ($0.updated_at ?? 0) > ($1.updated_at ?? 0) }
        let seed: [JSON] = previous.compactMap { transfer in
            let peer = transfer.peer.lowercased()
            guard seen.insert(peer).inserted, let label = labels[peer] else { return nil }
            return ["peer": peer, "label": label]
        }
        var payload: JSON = ["owner": owner, "seed": Array(seed.prefix(24))]
        if let peer { payload["recipient"] = ["peer": peer.peer, "label": recipientLabel(peer)] }
        if let target { payload["target"] = target }
        do {
            let result = try await CoreBridge.shared.call(action: "blip.recents." + action,
                request: ["data_dir": Paths.dataDir.path, "payload": payload])
            guard selfPeer == owner, recentOwner == owner else { return }
            recentRecipients = try JSONDecoder().decode([BlipRecentRecipient].self,
                from: JSONSerialization.data(withJSONObject: result ?? []))
        } catch {
            if selfPeer == owner { reportSend(error.localizedDescription) }
        }
    }

    private func sameAccount(_ peer: String, _ account: String) -> Bool {
        BlipPolicy.exactPeer(peer) && peer.split(separator: ":").first?.lowercased() == account.lowercased()
    }

    private func queueRelay(paths: [String], target: BlipPeer, owner: String) async throws -> Bool {
        guard sameAccount(target.peer, account) else { return false }
        let snapshot = try await BlipMacClient.request("poll", ["owner": owner])
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
        nextRelayDiscovery = .distantPast
        return true
    }

    private func updateRelay(_ snapshot: JSON, owner: String, rawTransfers: [BlipTransfer]) async throws {
        if relaySession != owner {
            relayReceived.removeAll(); relaySession = owner; relayTransportState = ""; nextRelayDiscovery = .distantPast
        }
        let transports = rawTransfers.filter {
            sameAccount($0.peer, account) && $0.item_names?.count == 1 &&
                $0.item_names?.first?.hasPrefix("mydrive-relay-v1.") == true
        }
        let transportState = transports.sorted { $0.id < $1.id }
            .map { "\($0.id):\($0.status):\($0.completed):\($0.has_error)" }.joined(separator: "|")
        let now = Date()
        if relayWaiting == 0, transportState == relayTransportState,
           !transports.contains(where: \.isLive), now < nextRelayDiscovery { return }
        let payload: JSON = ["self": owner, "inbox": BlipMacPaths.receivedDirectory.path,
                             "downloads": BlipMacPaths.receivedDirectory.deletingLastPathComponent().path,
                             "devices": snapshot.array("devices"), "transfers": snapshot.array("transfers")]
        guard let result = try await CoreBridge.shared.call(action: "relay.tick",
                request: ["data_dir": Paths.dataDir.path, "payload": payload], timeout: 10) as? JSON else { return }
        relayTransportState = transportState
        nextRelayDiscovery = now.addingTimeInterval(30)
        relayWaiting = Int(result.int64("waiting"))
        let command = result.dict("command")
        let id = command.str("id")
        switch command.str("action") {
        case "accept":
            _ = try await BlipMacClient.request("accept", ["id": id, "owner": owner])
        case "send":
            guard let paths = command["paths"] as? [String] else { return }
            _ = try await BlipMacClient.request("send", ["paths": paths, "peer": command.str("peer"), "owner": owner, "id": id])
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
                let delay = self?.adapterAvailable == true || self?.backgroundInput != nil ? 2 : 10
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }
    func stop() { task?.cancel(); task = nil; client.stop(); stopBackground(); setActivity(false) }

    @Published private(set) var needsSignIn = false
    @Published private(set) var registrationCodeSent = false
    @Published private(set) var signingIn = false
    private var provisioning = false
    private var downloadRequested = false
    var canSetUpBlip: Bool { backgroundFailure != nil && backgroundProcess == nil }

    func setUpBlip() {
        guard backgroundProcess == nil else { return }
        downloadRequested = true
        setBackground(true)
    }

    private func ensureBackground() {
        guard backgroundEnabled, backgroundProcess == nil, Date() >= nextHostAttempt else { return }
        nextHostAttempt = Date().addingTimeInterval(30)
        guard (downloadRequested || BlipMacEngine.engineAvailable), let executable = Bundle.main.executableURL else {
            backgroundFailure = BlipMacEngine.missing.localizedDescription
            return
        }
        let process = Process()
        let input = Pipe()
        process.executableURL = executable
        provisioning = downloadRequested
        downloadRequested = false
        process.arguments = ["--blip-background-engine"] + (provisioning ? ["--download"] : [])
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor in
                guard let self, self.backgroundProcess === child else { return }
                self.backgroundProcess = nil
                self.provisioning = false
                try? self.backgroundInput?.close()
                self.backgroundInput = nil
                let failure = BlipMacEngine(rawValue: status) ?? .launch
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

    func prepareSend(_ action: @escaping () -> Void, onUnavailable: @escaping () -> Void = {}) {
        guard !sending, !preparingSend else { onUnavailable(); return }
        if connected && adapterAvailable { action(); return }
        preparingSend = true
        reportSend("Connecting to Blip…")
        if !adapterAvailable && backgroundProcess == nil { nextHostAttempt = .distantPast }
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
                if needsSignIn { break }
                if !adapterAvailable && (!backgroundEnabled || backgroundFailure != nil) { break }
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
        if !enabled { stopBackground() }
        Task { await refresh() }
    }
    private func setActivity(_ enabled: Bool) {
        if enabled && activity == nil {activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Watch for incoming Blip transfers")}
        if !enabled,let activity {ProcessInfo.processInfo.endActivity(activity);self.activity=nil}
    }
    func refresh() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        ensureBackground()
        let value: JSON
        do {
            value = try await client.poll()
            guard !Task.isCancelled else { return }
            adapterAvailable = true
        } catch is BlipMacClient.Unavailable {
            guard !Task.isCancelled else { return }
            adapterAvailable = false
            let starting = backgroundEnabled && backgroundInput != nil &&
                Date().timeIntervalSince(hostStartedAt) < (provisioning ? 150 : 30)
            if backgroundInput != nil && !starting {
                stopBackground()
                backgroundFailure = BlipMacEngine.launch.localizedDescription
            }
            if starting {
                state = provisioning ? "Setting up Blip…" : "Starting Blip in the background…"
                problem = nil
            } else {
                state = backgroundEnabled ? "Blip background service is unavailable" : "Blip background service is off"
                problem = backgroundFailure
            }
            needsSignIn = false
            session = ""; selfPeer = ""; setActivity(false)
            return
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
            state = "Blip needs attention"
            session = ""; selfPeer = ""; setActivity(false)
            return
        }
        do {
            let status = value.dict("status")
            let managed = !status.bool("desktop_session")
            provisioning = false
            needsSignIn = managed && !status.bool("authenticated")
            if !signingIn { registrationCodeSent = needsSignIn && status.str("registration") == "CODE_SENT" }
            guard status.bool("authenticated") else {
                state = "Sign in to Blip"
                problem = needsSignIn ? nil : "Set up a myDrive Blip profile to sign in here."
                account="";session="";selfPeer="";peers=[];transfers=[];setActivity(false);return
            }
            if managed && !status.bool("receive_policy_verified") {
                state = "Checking receiving settings…"
                selfPeer = ""
                return
            }
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
            if recentOwner != identity {
                recentOwner = identity
                recentRecipients = []
                directoryRecipients = []
                await updateRecents("list", owner: identity)
            }
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
                        do {
                            _ = try await BlipMacClient.request("accept", ["id": transfer.id, "owner": identity])
                        } catch {
                            receiving.remove(transfer.id); problem = error.localizedDescription
                        }
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
    func signIn() {
        guard needsSignIn, !signingIn else { return }
        let verifying = registrationCodeSent
        let prompt = NSAlert()
        prompt.messageText = verifying ? "Enter your Blip sign-in code" : "Sign in to Blip"
        let input: NSTextField = verifying ? NSSecureTextField() : NSTextField()
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        input.placeholderString = verifying ? "Sign-in code" : "Email address"
        prompt.accessoryView = input
        prompt.addButton(withTitle: verifying ? "Sign in" : "Send code")
        prompt.addButton(withTitle: "Cancel")
        guard Self.runSignInPrompt(prompt, field: input) == .alertFirstButtonReturn else { return }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                _ = try await BlipMacClient.request(verifying ? "verify" : "login", ["text": value])
                registrationCodeSent = !verifying
                await refresh()
            } catch { problem = "Blip could not confirm sign-in. Check the email or code and try again." }
        }
    }

    static func runSignInPrompt(_ prompt: NSAlert, field: NSTextField,
                                paste: @escaping (NSTextView) -> Void = { $0.paste(nil) }) -> NSApplication.ModalResponse {
        prompt.layout()
        prompt.window.initialFirstResponder = field
        // The menu-bar app has no Edit menu to route Command-V to the alert's editor.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.window === prompt.window, modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let editor = field.currentEditor() as? NSTextView,
                  prompt.window.firstResponder === editor else { return event }
            paste(editor)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return prompt.runModal()
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
    func receive(_ transfer: BlipTransfer) {
        let owner = selfPeer
        guard !owner.isEmpty, transfer.pending, UUID(uuidString: transfer.id) != nil,
              BlipPolicy.exactPeer(transfer.peer), receiving.insert(transfer.id).inserted else { return }
        Task {
            do {
                try claims?.claim(owner + ":accept:" + transfer.id)
                _ = try await BlipMacClient.request("accept", ["id": transfer.id, "owner": owner])
                await refresh()
            } catch {
                receiving.remove(transfer.id)
                problem = error.localizedDescription
            }
        }
    }
    func setAutoOpen(_ value: Bool) { autoOpen=value;PrefStore.shared.update{$0.blipAutoOpenLinks=value};session="" }
    func openReceived() {
        do {let directory=BlipMacPaths.receivedDirectory;try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);NSWorkspace.shared.open(directory)}
        catch {problem="The received-files folder could not open."}
    }
}
