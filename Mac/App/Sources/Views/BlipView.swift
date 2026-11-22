import SwiftUI

struct BlipView: View {
    @ObservedObject var receiver: BlipReceiver
    @State var senders = false
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var searchStatus = ""
    @State private var searching = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(receiver.state).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Refresh") { Task { await receiver.refresh() } }.controlSize(.small)
            }
            HStack {
                Button("Send…") { receiver.chooseFilesToSend() }
                    .disabled(receiver.preparingSend || receiver.sending)
                Button("Received files") { receiver.openReceived() }
                Menu {
                    Toggle("Keep Blip available in the background",
                           isOn: Binding(get: { receiver.backgroundEnabled }, set: receiver.setBackground))
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Blip options")
            }.controlSize(.small)
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
            ForEach(receiver.transfers.filter(\.isLive)) { transfer in
                liveTransfer(transfer)
            }
            DisclosureGroup("Sender permissions", isExpanded: $senders) {
                BlipSenderPermissionsView(receiver: receiver)
            }.font(.system(size: 12))
        }.onChange(of: receiver.recipientOwner) {
            query = ""
            submittedQuery = ""
            searchStatus = ""
        }
    }

    private var recipientPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField("Find people & devices", text: $query)
                    .accessibilityLabel("Find people & devices")
                    .onSubmit(search)
                Button(action: search) { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search Blip for a person")
                    .help("Search Blip for a person")
                    .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.controlSize(.small)
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty {
                let known = receiver.recipients.filter {
                    [$0.contactName, $0.contact, $0.name, $0.displayName].compactMap { $0 }
                        .contains { $0.localizedStandardContains(term) }
                }
                let searched = term == submittedQuery
                let matches = unique(known + (searched ? receiver.directoryRecipients : []))
                ForEach(matches.prefix(30)) { peer in
                    recipientRow(receiver.recipientLabel(peer), peer: peer)
                }
                if searched && !searchStatus.isEmpty {
                    Text(searchStatus).font(.caption).foregroundStyle(.secondary)
                } else if matches.isEmpty {
                    Text(searched ? "No matching Blip devices." : "Press Return to search Blip.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !receiver.recentRecipients.isEmpty {
                Text("Recent recipients").font(.caption).fontWeight(.semibold)
                let groups = Dictionary(grouping: receiver.recentRecipients) { accountPart($0.peer) }
                var seen = Set<String>()
                let order = receiver.recentRecipients.map { accountPart($0.peer) }.filter { seen.insert($0).inserted }
                ForEach(order, id: \.self) { account in
                    let entries = groups[account] ?? []
                    if entries.count > 1 && account.caseInsensitiveCompare(receiver.account) != .orderedSame,
                       let name = receiver.recipients.first(where: { accountPart($0.peer) == account })?.contactName,
                       !name.isEmpty {
                        recipientRow(name, peer: nil, removing: account)
                    }
                    ForEach(entries) { entry in
                        let device = receiver.recipients.first { $0.peer.caseInsensitiveCompare(entry.peer) == .orderedSame }
                        recipientRow(device.map(receiver.recipientLabel) ?? entry.label, peer: device, removing: entry.peer)
                    }
                }
            }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searching, !term.isEmpty else { return }
        let owner = receiver.recipientOwner
        submittedQuery = term
        searching = true
        searchStatus = "Searching Blip…"
        Task {
            defer { searching = false }
            do {
                try await receiver.findRecipients(term)
                if receiver.recipientOwner == owner { searchStatus = "" }
            } catch {
                if receiver.recipientOwner == owner { searchStatus = error.localizedDescription }
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

    private func recipientRow(_ name: String, peer: BlipPeer?, removing: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let peer {
                Button { receiver.chooseFiles(to: peer) } label: {
                    Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityLabel("Send files to " + name)
                    .help(name)
                    .disabled(receiver.sending || receiver.preparingSend)
                    .contextMenu { Button("Paste and send") { receiver.pasteAndSend(to: peer) } }
            } else {
                Text(name).lineLimit(1).help(name).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let removing {
                Button { receiver.removeRecent(removing) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Remove " + name + " from recent recipients")
                    .help("Remove from recent recipients")
            }
        }.controlSize(.small).font(.system(size: 12))
    }

    private func liveTransfer(_ transfer: BlipTransfer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(receiver.senderLabel(transfer.peer)).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(transfer.has_error ? "Needs attention" : receiver.receiving.contains(transfer.id) ? "Receiving" :
                    transfer.pending ? "Waiting for you" : transfer.status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if transfer.pending && !receiver.receiving.contains(transfer.id) {
                Button("Receive") { receiver.receive(transfer) }.controlSize(.small)
            }
        }.frame(minHeight: 44)
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
