import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BlipView: View {
    @ObservedObject var receiver: BlipReceiver
    var incomingNoticeID: String? = nil
    @State private var query = ""
    @State private var dropPeer: String?
    @State private var permissionSender: String?

    var body: some View {
        recipientsView.onChange(of: receiver.recipientOwner) { permissionSender = nil }
    }

    private var recipientsView: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if !receiver.connected {
                Text(receiver.state).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            searchRow
            if receiver.connected { recipientPanel }
            if receiver.canSetUpBlip {
                Button("Set up Blip…", action: receiver.setUpBlip).controlSize(.small)
            }
            if receiver.needsSignIn {
                Button(receiver.registrationCodeSent ? "Enter code…" : "Sign in to Blip…", action: receiver.signIn)
                    .controlSize(.small).disabled(receiver.signingIn)
            }
            if let message = receiver.sendMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let problem = receiver.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
            }
            let live = receiver.transfers.filter { $0.direction == "Incoming" && $0.isLive && $0.id != incomingNoticeID }
            let recentFailures = receiver.transfers.filter { $0.direction == "Incoming" && !$0.isLive &&
                $0.has_error && $0.dismissed != true && $0.id != incomingNoticeID }
                .sorted { ($0.updated_at ?? 0) > ($1.updated_at ?? 0) }
            ForEach(live + Array(recentFailures.prefix(3))) { transfer in
                liveTransfer(transfer)
            }
        }.onChange(of: receiver.recipientOwner) {
            query = ""
            receiver.suggestRecipients("")
        }
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Button(action: receiver.openReceived) {
                Image(systemName: "folder").frame(width: 18, height: 20)
            }
            .controlSize(.small)
            .accessibilityLabel("Open Blip downloads in Finder")
            .help("Open Blip downloads in Finder")

            BlipSearchField(text: Binding(get: { query }, set: { text in
                query = text
                receiver.suggestRecipients(text)
            })) { receiver.suggestRecipients(query, immediate: true) }
                .frame(height: 24)
                .disabled(!receiver.connected)
        }
    }

    private var recipientPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let available = receiver.recipients.filter { !receiver.isArchived($0) }
            if !term.isEmpty {
                let known = (receiver.people.filter { $0.recent == true && !receiver.isArchived($0) } + available).filter {
                    [$0.contactName, $0.contact, $0.name, receiver.deviceName($0), receiver.personName($0)].compactMap { $0 }
                        .contains { $0.localizedStandardContains(term) }
                }
                let searched = term.caseInsensitiveCompare(receiver.directoryQuery) == .orderedSame
                let remote = searched ? receiver.directoryRecipients.filter { !receiver.isArchived($0) } : []
                let matches = unique(remote + known, query: term)
                let accounts = Set(matches.filter(\.isPerson).map { accountPart($0.peer) })
                if !matches.isEmpty {
                    Text("Suggestions").font(.caption).fontWeight(.semibold)
                }
                let rows = matches.filter { $0.isPerson || !accounts.contains(accountPart($0.peer)) }.prefix(30)
                unlistedSends(excluding: rows.map(\.peer))
                ForEach(rows) { peer in
                    let name = receiver.recipientLabel(peer)
                    let email = peer.contact
                    recipientRow(name, peer: peer,
                                 detail: email?.contains("@") == true && email?.caseInsensitiveCompare(name) != .orderedSame
                                     ? email : nil)
                }
                if searched && !receiver.directorySearchStatus.isEmpty {
                    Text(receiver.directorySearchStatus).font(.caption).foregroundStyle(.secondary)
                } else if matches.isEmpty {
                    Text("No matching people or devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                let account = receiver.account.lowercased()
                let myDevices = available.filter { accountPart($0.peer) == account }
                let listed = Set(myDevices.map { $0.peer.lowercased() })
                let recents = receiver.recentRecipients.filter { $0.archived == nil }
                unlistedSends(excluding: available.map(\.peer) + recents.map(\.peer))
                recentRows(recents.filter { !listed.contains($0.peer.lowercased()) }, available: available + receiver.people)
                if !myDevices.isEmpty {
                    Text("My devices").font(.caption).fontWeight(.semibold)
                    ForEach(myDevices) { device in
                        let recent = receiver.recentRecipients.first { $0.peer.caseInsensitiveCompare(device.peer) == .orderedSame }
                        recipientRow(receiver.deviceName(device), peer: device,
                                     nickname: recent?.nickname, deviceShortcut: true)
                    }
                }
                let seen = listed.union(recents.map { $0.peer.lowercased() })
                let others = available.filter { !seen.contains($0.peer.lowercased()) }
                if !others.isEmpty {
                    Text("Other devices").font(.caption).fontWeight(.semibold)
                    ForEach(others) { device in
                        recipientRow(receiver.recipientLabel(device), peer: device, removing: device.peer)
                    }
                }
                archivedRecipients
            }
        }
    }

    @ViewBuilder private var archivedRecipients: some View {
        let archived = receiver.recentRecipients.filter { $0.archived != nil }
        if !archived.isEmpty {
            DisclosureGroup("Archived") {
                ForEach(archived) { entry in
                    let name = receiver.senderLabel(entry.peer)
                    HStack(spacing: 4) {
                        Text(name).lineLimit(1).help(name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Restore") { receiver.restoreRecipient(entry.peer) }
                            .accessibilityLabel("Restore " + name)
                    }.controlSize(.small)
                }
            }.font(.caption)
        }
    }

    @ViewBuilder private func recentRows(_ recents: [BlipRecentRecipient], available: [BlipPeer]) -> some View {
        if !recents.isEmpty {
            Text("Recent recipients").font(.caption).fontWeight(.semibold)
            let groups = Dictionary(grouping: recents) { accountPart($0.peer) }
            var seen = Set<String>()
            let order = recents.map { accountPart($0.peer) }.filter { seen.insert($0).inserted }
            ForEach(order, id: \.self) { account in
                let entries = groups[account] ?? []
                if let first = entries.first {
                    let grouped = entries.count > 1
                    let own = account.caseInsensitiveCompare(receiver.account) == .orderedSame
                    let person = own ? "Your devices" :
                        firstName(receiver.personName(BlipPeer(peer: first.peer, name: "")), first.fallbackLabel)
                    if grouped {
                        recipientRow(person, peer: nil, removing: account, nickname: first.person_nickname, person: true)
                    }
                    ForEach(entries) { entry in
                        let device = available.first { $0.peer.caseInsensitiveCompare(entry.peer) == .orderedSame }
                        let known = device ?? receiver.peers.first { $0.peer.caseInsensitiveCompare(entry.peer) == .orderedSame }
                            ?? BlipPeer(peer: entry.peer, name: "")
                        let name = grouped ? receiver.deviceName(known) : receiver.recipientLabel(known)
                        recipientRow(name, peer: device, removing: entry.peer, nickname: entry.nickname)
                            .padding(.leading, grouped ? 12 : 0)
                    }
                }
            }
        }
    }

    private func unique(_ peers: [BlipPeer], query: String) -> [BlipPeer] {
        var seen = Set<String>()
        return peers.filter { seen.insert($0.peer.lowercased()).inserted }
            .sorted {
                let firstExact = $0.contact?.caseInsensitiveCompare(query) == .orderedSame
                let secondExact = $1.contact?.caseInsensitiveCompare(query) == .orderedSame
                if firstExact != secondExact { return firstExact }
                return receiver.recipientLabel($0).localizedStandardCompare(receiver.recipientLabel($1)) == .orderedAscending
            }
    }

    private func accountPart(_ peer: String) -> String {
        peer.split(separator: ":").first.map { $0.lowercased() } ?? ""
    }

    private func firstName(_ names: String?...) -> String {
        names.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Device"
    }

    private enum SendingItem: Identifiable {
        case direct(BlipTransfer)
        case relay(BlipQueuedSend)

        var id: String {
            switch self {
            case .direct(let transfer): return transfer.id
            case .relay(let transfer): return transfer.id
            }
        }
        var peer: String {
            switch self {
            case .direct(let transfer): return transfer.peer
            case .relay(let transfer): return transfer.peer
            }
        }
        var name: String {
            switch self {
            case .direct(let transfer): return transfer.item_names?.first ?? "transfer"
            case .relay(let transfer): return transfer.label
            }
        }
    }

    private var sends: [SendingItem] {
        let direct = receiver.transfers.filter { $0.direction == "Outgoing" && $0.isLive }.map(SendingItem.direct)
        let ids = Set(direct.map(\.id))
        return direct + receiver.relayQueued.filter { !ids.contains($0.id) }.map(SendingItem.relay)
    }

    private func containsRecipient(_ recipients: [String], target: String) -> Bool {
        recipients.contains { peer in
            peer.caseInsensitiveCompare(target) == .orderedSame ||
                (peer.hasSuffix(":") && accountPart(peer) == accountPart(target))
        }
    }

    @ViewBuilder private func unlistedSends(excluding recipients: [String]) -> some View {
        let peers = Set(sends.map(\.peer) + [receiver.sendingPeer].compactMap { $0 })
        ForEach(peers.filter { !containsRecipient(recipients, target: $0) }.sorted(), id: \.self) { peer in
            let name = receiver.senderLabel(peer)
            HStack {
                recipientName(name, sending: true)
                Spacer()
                cancelSends(sends.filter { $0.peer == peer }, name: name)
            }.font(.system(size: 12))
        }
    }

    @ViewBuilder private func cancelSends(_ items: [SendingItem], name: String) -> some View {
        if items.count == 1, let item = items.first {
            Button { cancelSend(item) } label: {
                Image(systemName: "xmark").frame(width: 20, height: 24)
            }
            .buttonStyle(.borderless).fixedSize()
            .disabled(receiver.cancellingSends.contains(item.id))
            .accessibilityLabel("Cancel sending to " + name)
            .help("Cancel sending to " + name)
        } else if !items.isEmpty {
            Menu {
                ForEach(items) { item in
                    Button("Cancel " + item.name) { cancelSend(item) }
                        .disabled(receiver.cancellingSends.contains(item.id))
                }
            } label: {
                Image(systemName: "xmark").frame(width: 20, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Cancel sends to " + name)
        }
    }

    private func cancelSend(_ item: SendingItem) {
        switch item {
        case .direct(let transfer): receiver.cancelSend(transfer)
        case .relay(let transfer): receiver.cancelQueuedSend(transfer)
        }
    }

    private func recipientName(_ name: String, sending: Bool) -> some View {
        HStack(spacing: 5) {
            Text(name).lineLimit(1)
            if sending { Text("Sending").font(.caption).foregroundStyle(.secondary).fixedSize() }
        }
    }

    private func sendAction(_ name: String, peer: BlipPeer, detail: String?, sending: Bool) -> some View {
        let availability = receiver.deviceAvailability(peer)
        let hint = detail.map { $0 + ", " + availability } ?? availability
        let tooltip = name + " · " + (detail ?? availability)
        return Button { receiver.chooseFiles(to: peer) } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(peer.online == true ? Color.green : Color.secondary.opacity(peer.online == nil ? 0.26 : 0.52))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    recipientName(name, sending: sending)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Send files to " + name)
        .accessibilityHint(hint)
        .help(tooltip)
        .buttonStyle(.plain)
        .disabled(receiver.sending || receiver.preparingSend)
        .contextMenu {
            Button("Paste and send") { receiver.pasteAndSend(to: peer) }
            if let connect = receiver.connectParsec {
                Button("Connect with Parsec") { connect(peer, false) }
                Button("Edit Parsec computer…") { connect(peer, true) }
            }
        }
    }

    private func recipientRow(_ name: String, peer: BlipPeer?, removing: String? = nil,
                              nickname: String? = nil, person: Bool = false, deviceShortcut: Bool = false,
                              detail: String? = nil) -> some View {
        let keys = [peer?.peer ?? removing].compactMap { $0 }.filter { $0.contains(":") }
        let active = sends.filter { containsRecipient(keys, target: $0.peer) }
        let preparing = receiver.sendingPeer.map { containsRecipient(keys, target: $0) } ?? false
        let sending = !active.isEmpty || preparing
        let target = peer?.peer ?? removing
        let editing = target != nil && permissionSender == target
        return HStack(spacing: 4) {
            if editing, let target {
                inlinePermissions(name, target: target, peer: peer)
            } else if let peer {
                sendAction(name, peer: peer, detail: detail, sending: sending)
            } else {
                recipientName(name, sending: sending).fontWeight(person ? .semibold : .regular)
                    .help(name).frame(maxWidth: .infinity, alignment: .leading)
            }
            cancelSends(active, name: name)
            if let peer, !editing {
                Button { receiver.pasteAndSend(to: peer) } label: { Text("Paste").frame(minWidth: 42) }
                    .accessibilityLabel("Paste and send to " + name)
                    .help("Paste and send")
                    .disabled(receiver.sending || receiver.preparingSend)
            }
            if let target {
                if editing {
                    Menu {
                        recipientOptions(name, peer: peer, removing: removing, nickname: nickname,
                                         person: person, deviceShortcut: deviceShortcut)
                    } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Options for " + name)
                }
                Button { permissionSender = editing ? nil : target } label: {
                    Image(systemName: "gearshape").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless).fixedSize()
                .accessibilityLabel("Sender permissions for " + name)
                .help(editing ? "Close sender permissions" : "Sender permissions")
                .contextMenu {
                    recipientOptions(name, peer: peer, removing: removing, nickname: nickname,
                                     person: person, deviceShortcut: deviceShortcut)
                }
            }
        }
        .controlSize(.small).font(.system(size: 12)).frame(minHeight: 27)
        .background {
            if let peer, dropPeer == peer.id {
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: dropTarget(editing ? nil : peer?.id)) {
            !editing && acceptDrop($0, to: peer)
        }
    }

    @ViewBuilder
    private func recipientOptions(_ name: String, peer: BlipPeer?, removing: String?, nickname: String?,
                                  person: Bool, deviceShortcut: Bool) -> some View {
        if deviceShortcut || removing != nil {
            Button("Edit Name…") {
                if let peer, !peer.isPerson { receiver.rename(peer) }
                else if let removing { receiver.renameRecent(removing, displayed: name, nickname: nickname, person: person) }
            }
        }
        if let removing { Button("Remove") { receiver.archiveRecipient(removing, peer: peer) } }
        if let peer, let connect = receiver.connectParsec {
            Button("Connect with Parsec") { connect(peer, false) }
            Button("Edit Parsec computer…") { connect(peer, true) }
        }
    }

    private func inlinePermissions(_ name: String, target: String, peer: BlipPeer?) -> some View {
        let owner = receiver.recipientOwner
        let individual = BlipPolicy.exactPeer(target)
        let roster = receiver.peers + receiver.directoryRecipients + [peer].compactMap { $0 }
        var seen = Set<String>()
        let devices = roster.filter { device in
            let id = device.peer.lowercased()
            return BlipPolicy.exactPeer(id) && id != owner.lowercased() &&
                (individual ? id == target.lowercased() : accountPart(id) == accountPart(target)) &&
                seen.insert(id).inserted
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(name).fontWeight(.semibold).lineLimit(1)
            if devices.isEmpty { Text("No known devices yet").font(.caption).foregroundStyle(.secondary) }
            ForEach(devices) { device in
                if !individual { Text(receiver.deviceName(device)).font(.caption).lineLimit(1) }
                HStack(spacing: 4) {
                    if device.id == devices.first?.id { Text("Auto:").font(.caption) }
                    inlineToggle("Receive", detail: "Receive files automatically", device: device, owner: owner, rule: \.files)
                    inlineToggle("Copy", detail: "Copy automatically accepted items", device: device, owner: owner, rule: \.clipboard)
                    inlineToggle("Open", detail: "Open web links automatically", device: device, owner: owner, rule: \.peers)
                }.toggleStyle(.button)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineToggle(_ title: String, detail: String, device: BlipPeer, owner: String,
                              rule: WritableKeyPath<BlipPolicy, Set<String>>) -> some View {
        let name = receiver.deviceName(device)
        return Toggle(title, isOn: Binding(get: { receiver.isTrusted(device, for: rule) }, set: {
            if owner == receiver.recipientOwner { receiver.setTrusted(device, $0, for: rule) }
        })).accessibilityLabel(title + " from " + name).help(detail + " from " + name)
    }

    private func dropTarget(_ id: String?) -> Binding<Bool> {
        Binding(
            get: { id != nil && dropPeer == id },
            set: { targeted in
                guard let id else { return }
                if targeted { dropPeer = id }
                else if dropPeer == id { dropPeer = nil }
            }
        )
    }

    private func acceptDrop(_ providers: [NSItemProvider], to peer: BlipPeer?) -> Bool {
        guard let peer, receiver.connected, !receiver.sending, !receiver.preparingSend else { return false }
        let owner = receiver.recipientOwner
        return FileDropInput.receive(providers) { urls in
            guard owner == receiver.recipientOwner else { return }
            if urls.isEmpty { receiver.reportSend("Drop up to 256 available files or folders."); return }
            receiver.send(.forFiles(urls), to: peer)
        }
    }

    private func liveTransfer(_ transfer: BlipTransfer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                let name = receiver.senderLabel(transfer.peer)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                let progress = transfer.has_error ? "Needs attention" : receiver.receiving.contains(transfer.id) ? "Receiving" :
                    transfer.pending ? "Waiting for you" : transfer.status
                Text(progress)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if transfer.has_error {
                    Text(transfer.failureLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                BlipReceiveProgress(transfer: transfer, starting: transfer.pending && receiver.receiving.contains(transfer.id))
            }
            Spacer(minLength: 6)
            if transfer.pending && !receiver.receiving.contains(transfer.id) {
                Button("Receive") { receiver.receive(transfer) }.controlSize(.small)
            }
        }.frame(minHeight: 44)
    }
}

private struct BlipSearchField: NSViewRepresentable {
    @Binding var text: String
    var submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find people & devices"
        field.toolTip = "Search by name, email address, or device name"
        field.setAccessibilityLabel("Find people & devices")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        if let cell = field.cell as? NSSearchFieldCell {
            cell.sendsSearchStringImmediately = false
            cell.sendsWholeSearchString = true
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: BlipSearchField
        init(parent: BlipSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }

        @objc func search(_ field: NSSearchField) {
            parent.text = field.stringValue
            parent.submit()
        }
    }
}

struct BlipSenderPermissionsView: View {
    @ObservedObject var receiver: BlipReceiver
    var sender: String? = nil

    private var knownDevices: [BlipPeer] {
        var seen = Set<String>()
        let roster = sender == nil ? receiver.peers : receiver.peers + receiver.directoryRecipients
        return roster.filter { device in
            let peer = device.peer.lowercased()
            guard BlipPolicy.exactPeer(peer), peer != receiver.recipientOwner.lowercased(), seen.insert(peer).inserted else { return false }
            guard let sender = sender?.lowercased() else { return true }
            return BlipPolicy.exactPeer(sender) ? peer == sender :
                peer.split(separator: ":").first.map(String.init) == sender.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Automatic actions").font(.system(size: 12, weight: .semibold))
            let groups = Dictionary(grouping: knownDevices) { $0.peer.split(separator: ":").first?.lowercased() ?? "" }
            ForEach(groups.keys.sorted(), id: \.self) { user in
                let devices = (groups[user] ?? []).sorted {
                    let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    return order == .orderedSame ? $0.peer < $1.peer : order == .orderedAscending
                }
                let person = user == receiver.account.lowercased() ? "Your devices"
                    : devices.compactMap(\.contactName).first { !$0.isEmpty } ?? "Previous sender"
                if sender == nil { Text(person).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(person) }
                ForEach(devices) { peer in devicePermissions(peer) }
            }
            if groups.isEmpty {
                Text(sender == nil ? "Devices appear after Blip connects." : "No known devices for this sender yet.")
                    .foregroundStyle(.secondary)
            }
        }.font(.system(size: 11)).padding(.vertical, 6)
    }

    private func devicePermissions(_ peer: BlipPeer) -> some View {
        let name = receiver.deviceName(peer)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(name)
                Spacer(minLength: 4)
                Button { receiver.rename(peer) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Rename device")
                    .accessibilityLabel("Rename " + name)
            }
            VStack(alignment: .leading, spacing: 3) {
                permission("Receive files", for: peer, rule: \.files)
                permission("Open links", for: peer, rule: \.peers)
                permission("Copy to clipboard", for: peer, rule: \.clipboard)
                    .help("Copy transfers myDrive accepts automatically from this device")
            }.toggleStyle(.checkbox)
        }
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func permission(_ label: String, for peer: BlipPeer, rule: WritableKeyPath<BlipPolicy, Set<String>>) -> some View {
        Toggle(label, isOn: Binding(get: { receiver.isTrusted(peer, for: rule) },
                                   set: { receiver.setTrusted(peer, $0, for: rule) }))
            .accessibilityLabel(label + " from " + receiver.deviceName(peer))
    }
}
