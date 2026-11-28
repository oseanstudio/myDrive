import SwiftUI

struct SyncDropView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var blip: BlipReceiver
    @State private var linking: String?

    private var devices: [SyncthingDevice] {
        (app.snapshot?.devices ?? []).filter { !$0.isLocal && !$0.paused }
    }

    var body: some View {
        let paths = app.syncDropPaths
        let owner = blip.recipientOwner
        let recent = owner.isEmpty ? [] : blip.recentRecipients.filter { $0.archived == nil && $0.peer != owner }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(paths.count == 1 ? paths[0].lastPathComponent : "\(paths.count) items")
                    .font(.headline).lineLimit(1)
                Spacer()
                Button("Cancel") { app.syncDropPaths = [] }
            }
            if devices.isEmpty {
                Text("Pair a device in Syncthing before offering files or folders.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let key = linking {
                Text("Choose this person’s paired device to start two-way sync.")
                    .font(.caption).foregroundStyle(.secondary)
                deviceRows { app.shareDroppedItems(paths, with: $0, link: key, owner: owner) }
                Button("Back") { linking = nil }
            } else {
                if !recent.isEmpty {
                    Text("Recent recipients").font(.caption.weight(.semibold))
                    ForEach(recent) { item in
                        let key = owner + "/" + item.peer.lowercased()
                        let saved = PrefStore.shared.preferences.syncRecipientDevices?[key]
                        let linked = devices.first { $0.deviceID == saved }
                        HStack(spacing: 4) {
                            target(item.nickname ?? item.person_nickname ?? item.fallbackLabel) {
                                if let linked { app.shareDroppedItems(paths, with: linked, link: key, owner: owner) }
                                else { linking = key }
                            }
                            .help(linked.map { "Sync with " + $0.displayName } ?? "Choose a paired Syncthing device")
                            if linked != nil {
                                Button { linking = key } label: { Image(systemName: "pencil") }
                                    .help("Change the linked Syncthing device")
                                    .accessibilityLabel("Change sync device for " + item.fallbackLabel)
                            }
                        }
                    }
                }
                Text("Other devices").font(.caption.weight(.semibold))
                deviceRows { app.shareDroppedItems(paths, with: $0) }
            }
        }
        .controlSize(.small)
        .onChange(of: owner) { linking = nil }
    }

    private func deviceRows(_ select: @escaping (SyncthingDevice) -> Void) -> some View {
        ForEach(devices) { device in
            target(device.displayName) { select(device) }
                .help(device.displayName + " · " + device.deviceID)
        }
    }

    private func target(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.borderless)
    }
}

@MainActor extension AppState {
    func prepareSyncDrop(_ paths: [URL]) {
        guard busy == nil, dialog == nil else { return }
        guard let selection = FileDropInput.localFiles(paths) else {
            showBanner(.error, "Sync selection", "Drop up to 256 available files or folders.")
            return
        }
        view = .sync
        syncDropPaths = selection
        if snapshot == nil { Task { await refreshSnapshot() } }
    }

    func shareDroppedItems(_ paths: [URL], with device: SyncthingDevice, link: String? = nil, owner: String = "") {
        guard busy == nil, !paths.isEmpty, paths == syncDropPaths,
              link == nil || owner == blip.recipientOwner && link?.hasPrefix(owner + "/") == true else { return }
        perform("Start two-way sync", connection: device.displayName) {
            let raw = try await self.syncthing.call("share.drop", payload: [
                "local_paths": paths.map(\.path), "device_id": device.deviceID
            ], timeout: 60)
            if let link, owner == self.blip.recipientOwner {
                PrefStore.shared.update { preferences in
                    var links = preferences.syncRecipientDevices ?? [:]
                    links[link] = device.deviceID
                    preferences.syncRecipientDevices = links
                }
            }
            self.syncDropPaths = []
            self.showBanner(.info, "Offered to \(device.displayName)",
                            (raw as? JSON)?.bool("created") == true
                            ? "Accept the share on the other device to start syncing."
                            : "This selection is shared for two-way sync.")
            await self.refreshSnapshot()
        }
    }
}
