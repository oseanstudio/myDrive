import SwiftUI

// Read-only details navigate inside the regular popup; no second dialog shell.
struct SyncInfoView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            SyncDetailsHeader(title: app.syncInfo?.title ?? "Folder details",
                              refreshing: app.busy != nil || app.syncInfoLoading,
                              back: app.closeSyncInfo, refresh: app.refreshSyncInfo)
            Text(app.syncInfo?.label ?? "")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if let info = app.syncInfo, info.errors {
                HStack(spacing: 6) {
                    if let folder = app.snapshot?.folders.first(where: { $0.id == info.folderId }), !folder.path.isEmpty {
                        Button("Choose new location…") { app.relocateSyncFolder(folder) }
                    }
                    Button("Rescan folder") { app.rescanFolder(info.folderId) }
                }.controlSize(.small).disabled(app.busy != nil || app.syncInfoLoading)
            }
            if app.syncInfoLoading {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let failure = app.syncInfoFailure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if app.syncInfo?.errors == true {
                ErrorsDialog()
            } else if app.syncInfo?.action == "device_progress" {
                if app.syncDeviceProgress.isEmpty { Text("This folder has no other devices.").font(.system(size: 12)) }
                ForEach(app.syncDeviceProgress.indices, id: \.self) { index in
                    let device = app.syncDeviceProgress[index]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.optStr("name") ?? "Device").font(.system(size: 12, weight: .semibold))
                        Text(progressCaption(device)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                PendingDialog()
            }
        }
    }

    private func progressCaption(_ device: JSON) -> String {
        var parts = [device.str("state")]
        if let bytes = device["remaining_bytes"] as? NSNumber {
            parts.append(Format.bytes(bytes.int64Value) + " remaining")
        }
        if let percent = device["percent"] as? NSNumber {
            parts.append(percent.doubleValue.formatted(.number.precision(.fractionLength(0...1))) + "%")
        }
        return parts.joined(separator: " · ")
    }
}

struct SyncAttentionView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            SyncDetailsHeader(title: "Sync errors", refreshing: app.busy != nil || app.syncAttentionLoading,
                              back: { app.view = .sync }, refresh: { app.refreshSyncAttention() })
            if app.syncAttentionLoading {
                ProgressView().controlSize(.small).accessibilityLabel("Loading folder errors")
            } else {
                if let failure = app.syncAttentionFailure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if app.foldersNeedingAttention.isEmpty {
                    Text("No folders need attention.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(app.foldersNeedingAttention) { folder in
                    let report = app.syncAttentionReport.dict(folder.id)
                    let issue = IssueItem.rows(from: report).first
                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.displayName).font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle).help(folder.displayName)
                        if let issue, !issue.path.isEmpty {
                            Text(issue.path).font(.system(size: 11)).lineLimit(1)
                                .truncationMode(.middle).help(issue.path)
                        }
                        let message = issue?.message ?? folder.error ?? report.optStr("failure")
                            ?? "Syncthing reported a sync problem."
                        Text(message).font(.system(size: 11)).lineLimit(3).help(message)
                        let advice = issue?.advice ?? folder.errorAdvice
                        if !advice.isEmpty {
                            Text(advice).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            if !folder.path.isEmpty {
                                Button("Choose new location…") { app.relocateSyncFolder(folder) }
                            }
                            Button("Rescan") { app.rescanFolder(folder.id) }
                            Button("View errors") { app.openErrors(folder) }
                        }
                        .controlSize(.small).disabled(app.busy != nil)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
        }
    }
}

private struct SyncDetailsHeader: View {
    let title: String
    let refreshing: Bool
    let back: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 12)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).accessibilityLabel("Back")
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).disabled(refreshing).accessibilityLabel("Refresh \(title)")
        }
    }
}
