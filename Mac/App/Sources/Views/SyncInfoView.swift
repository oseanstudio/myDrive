import SwiftUI

// Read-only details navigate inside the regular popup; no second dialog shell.
struct SyncInfoView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { app.closeSyncInfo() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).accessibilityLabel("Back to synced folders")
                Text(app.syncInfo?.errors == true ? "Folder errors" : "Pending files")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button { app.refreshSyncInfo() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).disabled(app.busy != nil || app.syncInfoLoading)
                .accessibilityLabel("Refresh folder details")
            }
            Text(app.syncInfo?.label ?? "")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if app.syncInfoLoading {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let failure = app.syncInfoFailure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if app.syncInfo?.errors == true {
                ErrorsDialog()
            } else {
                PendingDialog()
            }
        }
    }
}
