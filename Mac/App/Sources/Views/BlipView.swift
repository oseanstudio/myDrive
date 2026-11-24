import AppKit
import SwiftUI

struct BlipView: View {
    @ObservedObject var receiver: BlipReceiver
    @State var senders = false
    @State private var query = ""

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if !receiver.connected {
                Text(receiver.state).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Button("Send…") { receiver.chooseFilesToSend() }
                    .disabled(receiver.preparingSend || receiver.sending)
                Button("Received Files") { receiver.openReceived() }
                Spacer(minLength: 0)
                Button { Task { await receiver.refreshConnection() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("Refresh Blip").accessibilityLabel("Refresh Blip")
                Menu {
                    Toggle("Keep Blip available in the background",
                           isOn: Binding(get: { receiver.backgroundEnabled }, set: receiver.setBackground))
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Blip options")
            }.controlSize(.small)
            ForEach(receiver.transfers.filter { $0.direction == "Outgoing" && $0.isLive }) { transfer in
                liveTransfer(transfer)
            }
            if receiver.connected {
                ForEach(receiver.relayQueued) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(receiver.senderLabel(item.peer) + " · Queued for relay")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button("Cancel") { receiver.cancelQueuedSend(item) }
                            .controlSize(.small).disabled(receiver.cancellingSends.contains(item.id))
                    }.frame(minHeight: 44)
                }
            }
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
            if receiver.relayWaiting > 0 {
                Text("\(receiver.relayWaiting) waiting for relay or delivery")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let problem = receiver.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
            }
            ForEach(receiver.transfers.filter { $0.direction != "Outgoing" && $0.isLive }) { transfer in
                liveTransfer(transfer)
            }
            DisclosureGroup("Sender permissions", isExpanded: $senders) {
                BlipSenderPermissionsView(receiver: receiver)
            }.font(.system(size: 12))
        }.onChange(of: receiver.recipientOwner) {
            query = ""
        }.onChange(of: query) { _, text in receiver.suggestRecipients(text) }
    }

    private var recipientPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            BlipSearchField(text: $query) { receiver.suggestRecipients(query, immediate: true) }
                .frame(height: 24)
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let available = receiver.recipients.filter { !receiver.isArchived($0) }
            if !term.isEmpty {
                let known = available.filter {
                    [$0.contactName, $0.contact, $0.name, receiver.deviceName($0), receiver.personName($0)].compactMap { $0 }
                        .contains { $0.localizedStandardContains(term) }
                }
                let searched = term.caseInsensitiveCompare(receiver.directoryQuery) == .orderedSame
                let remote = searched ? receiver.directoryRecipients.filter { !receiver.isArchived($0) } : []
                let matches = unique(known + remote)
                ForEach(matches.prefix(30)) { peer in
                    recipientRow(receiver.recipientLabel(peer), peer: peer)
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
                if !myDevices.isEmpty {
                    Text("My devices").font(.caption).fontWeight(.semibold)
                    ForEach(myDevices) { device in
                        let recent = receiver.recentRecipients.first { $0.peer.caseInsensitiveCompare(device.peer) == .orderedSame }
                        recipientRow(receiver.deviceName(device), peer: device,
                                     nickname: recent?.nickname, deviceShortcut: true)
                    }
                }
                let listed = Set(myDevices.map { $0.peer.lowercased() })
                let recents = receiver.recentRecipients.filter { $0.archived == nil }
                recentRows(recents.filter { !listed.contains($0.peer.lowercased()) }, available: available)
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

    private func unique(_ peers: [BlipPeer]) -> [BlipPeer] {
        var seen = Set<String>()
        return peers.filter { seen.insert($0.peer.lowercased()).inserted }
            .sorted { receiver.recipientLabel($0).localizedStandardCompare(receiver.recipientLabel($1)) == .orderedAscending }
    }

    private func accountPart(_ peer: String) -> String {
        peer.split(separator: ":").first.map { $0.lowercased() } ?? ""
    }

    private func firstName(_ names: String?...) -> String {
        names.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Device"
    }

    private func recipientRow(_ name: String, peer: BlipPeer?, removing: String? = nil,
                              nickname: String? = nil, person: Bool = false, deviceShortcut: Bool = false) -> some View {
        HStack(spacing: 4) {
            if let peer {
                Button { receiver.chooseFiles(to: peer) } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(peer.online == true ? Color.green : Color.secondary.opacity(peer.online == nil ? 0.26 : 0.52))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(name).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityLabel("Send files to " + name)
                    .accessibilityHint(receiver.deviceAvailability(peer))
                    .help(name + " · " + receiver.deviceAvailability(peer))
                    .buttonStyle(.plain)
                    .disabled(receiver.sending || receiver.preparingSend)
                    .contextMenu { Button("Paste and send") { receiver.pasteAndSend(to: peer) } }
            } else {
                Text(name).fontWeight(person ? .semibold : .regular)
                    .lineLimit(1).help(name).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let peer, deviceShortcut || removing != nil {
                Button { receiver.pasteAndSend(to: peer) } label: { Image(systemName: "clipboard") }
                    .accessibilityLabel("Paste and send to " + name)
                    .help("Paste and send")
                    .disabled(receiver.sending || receiver.preparingSend)
            }
            if deviceShortcut || removing != nil {
                Menu {
                    Button("Edit Name…") {
                        if let peer { receiver.rename(peer) }
                        else if let removing { receiver.renameRecent(removing, displayed: name, nickname: nickname, person: person) }
                    }
                    if let removing {
                        Button("Remove") { receiver.archiveRecipient(removing, peer: peer) }
                    }
                } label: { Image(systemName: "gearshape").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options for " + name)
                .help("Options for " + name)
            }
        }.controlSize(.small).font(.system(size: 12)).frame(minHeight: 27)
    }

    private func liveTransfer(_ transfer: BlipTransfer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                let name = receiver.senderLabel(transfer.peer)
                Text(transfer.direction == "Outgoing" ? transfer.item_names?.first ?? name : name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                let progress = transfer.has_error ? "Needs attention" : receiver.receiving.contains(transfer.id) ? "Receiving" :
                    transfer.pending ? "Waiting for you" : transfer.status
                Text(transfer.direction == "Outgoing" ? name + " · " + progress : progress)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if transfer.pending && !receiver.receiving.contains(transfer.id) {
                Button("Receive") { receiver.receive(transfer) }.controlSize(.small)
            } else if transfer.direction == "Outgoing" {
                Button(receiver.cancellingSends.contains(transfer.id) ? "Cancelling…" : "Cancel") {
                    receiver.cancelSend(transfer)
                }.controlSize(.small).disabled(receiver.cancellingSends.contains(transfer.id))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Open approved senders’ web links",
                   isOn: Binding(get: { receiver.autoOpen }, set: receiver.setAutoOpen))
                .toggleStyle(.checkbox)
            let groups = Dictionary(grouping: receiver.peers) { $0.peer.split(separator: ":").first?.lowercased() ?? "" }
            ForEach(groups.keys.sorted(), id: \.self) { user in
                let devices = (groups[user] ?? []).sorted {
                    let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    return order == .orderedSame ? $0.peer < $1.peer : order == .orderedAscending
                }
                let person = user == receiver.account.lowercased() ? "Your devices"
                    : devices.compactMap(\.contactName).first { !$0.isEmpty } ?? "Previous sender"
                Text(person).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(person)
                ForEach(devices) { peer in devicePermissions(peer) }
            }
            if receiver.peers.isEmpty {
                Text("Devices appear after Blip connects.").foregroundStyle(.secondary)
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
            HStack(spacing: 14) {
                Toggle("Auto-receive files",
                       isOn: Binding(get: { receiver.isFileTrusted(peer) }, set: { receiver.setTrusted(peer, $0, files: true) }))
                    .accessibilityLabel("Auto-receive files from " + name)
                Toggle("Auto-open links",
                       isOn: Binding(get: { receiver.isTrusted(peer) }, set: { receiver.setTrusted(peer, $0) }))
                    .accessibilityLabel("Auto-open links from " + name)
            }.toggleStyle(.checkbox)
        }
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
