// Activity view: the live recent-updates feed from Syncthing events plus the
// local operation history (both persisted, newest first, capped at 200).
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 6) {
            SendActivityView(receiver: app.blip)
            sectionLabel("Recent updates")
            if app.updates.isEmpty {
                Text("Updates appear here as folders sync and devices connect.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(app.updates.prefix(30)) { update in
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: update.kind))
                            .font(.system(size: 11))
                            .foregroundStyle(update.kind == "error" ? Color.red : Color.secondary)
                            .frame(width: 16)
                        Text(update.text)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(update.text)
                        Spacer(minLength: 4)
                        Text(Format.relative(update.time))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 30)
                }
            }
            Divider()
            sectionLabel("Activity")
            if app.activity.isEmpty {
                Text("Your activity will appear here when you connect or transfer a file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(app.activity.prefix(50)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.success ? Color.green : Color.red)
                                .frame(width: 16)
                            Text(entry.operation)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Format.time(entry.time))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(entry.connection)  ·  \(entry.success ? entry.detail : "Failed: \(entry.detail)")")
                            .font(.system(size: 10))
                            .foregroundStyle(entry.success ? Color.secondary : Color.red)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(.leading, 22)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "file": return "doc.badge.arrow.up"
        case "device": return "desktopcomputer"
        case "folder": return "folder.badge.gearshape"
        case "error": return "exclamationmark.triangle"
        default: return "bolt"
        }
    }
}

private struct SendActivityView: View {
    @ObservedObject var receiver: BlipReceiver
    @State private var rows: [JSON] = []
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        if receiver.connected {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Send activity").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh Send activity").accessibilityLabel("Refresh Send activity")
                        .disabled(loading)
                }
                if loading { ProgressView().controlSize(.small) }
                if let failure { Text(failure).font(.system(size: 11)) }
                if !loading && failure == nil && rows.isEmpty {
                    Text("No sends recorded yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(rows.indices, id: \.self) { index in
                    let entry = rows[index]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.str("kind") + " · " + entry.str("name"))
                                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(entry.str("recipient") + " · " + entry.str("status"))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            if let text = entry.optStr("detail"), !text.isEmpty {
                                Text(text).font(.system(size: 11)).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        if entry.bool("can_retry") {
                            Button("Retry") { Task { await load(retry: entry.str("id")) } }.disabled(loading)
                        }
                    }
                }
            }
            .controlSize(.small)
            .task(id: receiver.recipientOwner) { rows = []; await load() }
        }
    }

    private func load(retry id: String? = nil) async {
        let owner = receiver.recipientOwner
        guard !owner.isEmpty, !loading else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            if let id { _ = try await BlipMacClient.request("retry", ["owner": owner, "id": id]) }
            let reply = try await BlipMacClient.request("activity", ["owner": owner])
            guard receiver.recipientOwner == owner, !Task.isCancelled else { return }
            rows = reply.array("entries").compactMap { $0 as? JSON }
        } catch {
            if receiver.recipientOwner == owner && !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
