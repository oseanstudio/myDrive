import SwiftUI

// Read-only details navigate inside the regular popup; no second dialog shell.
struct SyncInfoView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            SyncDetailsHeader(title: app.syncInfo?.errors == true ? "Folder errors" : "Pending files",
                              refreshing: app.busy != nil || app.syncInfoLoading,
                              back: app.closeSyncInfo, refresh: app.refreshSyncInfo)
            Text(app.syncInfo?.label ?? "")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if app.syncInfoLoading {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let failure = app.syncInfoFailure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if app.syncInfo?.errors == true {
                if let id = app.syncInfo?.folderId {
                    Button("Rescan folder") { app.rescanFolder(id) }
                        .controlSize(.small).disabled(app.busy != nil)
                }
                ErrorsDialog()
            } else {
                PendingDialog()
            }
        }
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
