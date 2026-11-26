// Sync view: status first, attention items with one-click fixes, dense folder
// rows; plus the per-file selection browser (parity with the Windows popup).
import SwiftUI

struct SyncView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        LazyVStack(spacing: 4) {
            statusHeader
            if let error = app.snapshot?.scheduledPauseError {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !app.attention.isEmpty {
                ForEach(app.attention) { item in
                    AttentionCard(item: item)
                }
            }
            if let snapshot = app.snapshot {
                if snapshot.folders.isEmpty {
                    VStack(spacing: 8) {
                        Text("No synced folders yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Sync your first folder…") { app.dialog = .share }
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(sortedFolders(snapshot)) { folder in
                        FolderRow(folder: folder)
                    }
                }
            } else if app.snapshotError == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }

    private func sortedFolders(_ snapshot: Snapshot) -> [SyncthingFolder] {
        let project = Paths.projectFolder()
        func rank(_ folder: SyncthingFolder) -> Int {
            if folder.hasError { return 0 }
            if folder.path == project { return 1 }
            if folder.status.needFiles > 0 { return 2 }
            return folder.paused ? 4 : 3
        }
        return snapshot.folders.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            return left == right ? lhs.displayName.lowercased() < rhs.displayName.lowercased() : left < right
        }
    }

    /// Matches the menu bar icon tint so the popup and the status item agree.
    private var statusColor: Color {
        switch app.statusTint {
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .gray: return .gray
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Status: \(app.statusTitle)")
                if app.snapshotError == nil && !app.foldersNeedingAttention.isEmpty {
                    Button { app.openSyncAttention() } label: {
                        HStack(spacing: 4) {
                            Text(app.statusTitle).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.link)
                    .disabled(app.busy != nil)
                    .accessibilityHint("Open sync errors and fixes")
                } else {
                    Text(app.statusTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Devices…") { app.dialog = .devices }
                    Button("Sync a folder…") { app.dialog = .share }
                    Button("Open Syncthing") { app.openSyncthingWeb() }
                    Button("Connection settings…") { app.dialog = .syncSettings }
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Sync tools")
                Button {
                    app.applyFix(.retrySnapshot)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(app.busy != nil)
                .accessibilityLabel("Refresh sync status")
            }
            Text(app.statusDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct AttentionCard: View {
    @EnvironmentObject var app: AppState
    let item: AttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(item.severity == .error ? Color.red : Color.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !item.fixes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.fixes.prefix(2)) { fix in
                            Button(fix.label) { app.applyFix(fix.kind) }
                                .font(.system(size: 10))
                                .controlSize(.small)
                                .disabled(app.busy != nil)
                        }
                        if item.fixes.count > 2 {
                            Menu {
                                ForEach(Array(item.fixes.dropFirst(2))) { fix in
                                    Button(fix.label) { app.applyFix(fix.kind) }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 12))
                                    .frame(width: 20, height: 20)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("More fixes")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

struct FolderRow: View {
    @EnvironmentObject var app: AppState
    let folder: SyncthingFolder

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if !folder.paused { app.openFolderFiles(folder) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("\(folder.path)\n\(captionText)")
                    Text(captionText)
                        .font(.system(size: 11))
                        .foregroundStyle(captionColor)
                        .lineLimit(1)
                    Text(app.snapshot?.peerCaption(for: folder) ?? "Shared devices unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(peerHelp)
                }
                .frame(minHeight: PopupMetrics.rowHeight - 10, alignment: .leading)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            Button {
                app.pauseFolder(folder, paused: !folder.paused)
            } label: {
                Image(systemName: folder.paused ? "play.circle" : "pause.circle")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(app.busy != nil)
            .accessibilityLabel("\(folder.paused ? "Resume" : "Pause") \(folder.displayName)")
            Menu {
                if let snapshot = app.snapshot {
                    Section(folder.peerDirection) {
                        ForEach(snapshot.peers(for: folder)) { peer in
                            Text("\(peer.name) · \(peer.state)")
                        }
                    }
                }
                Button("Choose files") { app.openFolderFiles(folder) }
                Button("Open local folder") { app.openLocalFolder(folder.path) }
                Button("Device progress") { app.openDeviceProgress(folder) }
                Button("Pause until…") { app.chooseSyncPause(folder) }
                Button("Pending files") { app.openPending(folder) }
                Button("Saved versions") { app.openVersions(folder) }
                Divider()
                Button("Rescan") { app.rescanFolder(folder.id) }
                Button("Show errors") { app.openErrors(folder) }
                Button("Protect version history") { app.protectHistory(folder) }
                Divider()
                Button("Stop syncing folder…") { app.stopFolder(folder) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(folder.displayName)")
        }
        .padding(.horizontal, 2)
    }

    private var captionText: String {
        if folder.paused {
            return folder.pausedUntil.map { "Paused until " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Paused"
        }
        if folder.hasError { return "Needs attention" }
        if folder.status.needFiles > 0 {
            return folder.status.needFiles == 1 ? "1 file pending" : "\(folder.status.needFiles) files pending"
        }
        switch folder.status.state {
        case "scanning": return "Checking changes"
        case "syncing": return "Syncing"
        case "idle":
            let remoteConnected = app.snapshot?.peers(for: folder).contains { $0.state == "Connected" } ?? false
            return remoteConnected ? "Local up to date" : "Available offline"
        case "": return "Unavailable"
        default: return folder.status.state.capitalized
        }
    }

    private var captionColor: Color {
        folder.hasError ? .red : (folder.paused ? Color.secondary : Color.primary.opacity(0.65))
    }
    private var peerHelp: String {
        guard let snapshot = app.snapshot else { return "Shared devices unavailable" }
        let peers = snapshot.peers(for: folder)
        return peers.isEmpty ? snapshot.peerCaption(for: folder) : folder.peerDirection + "\n" + peers.map { "\($0.name) · \($0.state)" }.joined(separator: "\n")
    }
}

struct SyncFilesView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        LazyVStack(spacing: 4) {
            if let state = app.syncBrowse {
                HStack(spacing: 4) {
                    Button {
                        app.view = .sync
                        app.syncBrowse = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to synced folders")
                    Text(state.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        app.browseSyncUp()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.busy != nil || !state.path.contains("/"))
                    .accessibilityLabel("Parent folder")
                    Button {
                        app.browseSyncPath(state.path)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.busy != nil)
                    .accessibilityLabel("Refresh files")
                    Menu {
                        Button(state.result.onDemand ? "Resume default syncing…" : "Download when needed…") {
                            app.setDownloadWhenNeeded(!state.result.onDemand)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(app.busy != nil)
                    .accessibilityLabel("Download options")
                }
                Text(state.path.isEmpty ? "All files" : state.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let visible = state.result.entries.filter { !$0.isAlternative }
                if !state.path.isEmpty {
                    Button("Sync this subfolder with another device…"){app.shareBrowsedSubfolder()}
                        .font(.system(size:11)).controlSize(.small).disabled(app.busy != nil)
                }
                if state.result.localLimitReached {
                    Text("Some local files are not shown. Open a smaller subfolder or use Finder.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if visible.isEmpty {
                    Text("Nothing to choose in this folder.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    ForEach(visible.sorted { $0.sortKey < $1.sortKey }) { entry in
                        SelectionRow(entry: entry, onDemand: state.result.onDemand)
                    }
                }
                let alternatives = state.result.entries.filter(\.isAlternative)
                if !alternatives.isEmpty {
                    Divider()
                    Button {
                        app.dialog = .alternatives(state.folderId, state.label)
                    } label: {
                        Label("Saved edits (\(alternatives.count))", systemImage: "doc.badge.clock")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
                HStack(spacing: 4) {
                    Spacer()
                    Button("Selection help") { app.dialog = .selectionHelp }
                        .font(.system(size: 10))
                    Text(state.result.onDemand ? "Download when needed is on." : "Selections apply on this computer.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.bottom, 2)
            } else {
                Text("Choose a synced folder first.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
    }
}

struct SelectionRow: View {
    @EnvironmentObject var app: AppState
    let entry: BrowseEntry
    let onDemand: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(entry.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(entry.path)\n\(note)")
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(onDemand ? "Pin" : "Sync") { app.setSelection(entry, sync: true) }
                .help(onDemand ? "Keep offline" : "Sync this item")
                .font(.system(size: 10))
                .controlSize(.small)
                .foregroundStyle(entry.selection == "sync" ? Color.accentColor : Color.primary)
                .disabled(app.busy != nil || (onDemand ? entry.pinned : entry.selection == "sync"))
            Button(onDemand ? "Unpin" : "Stop") { app.setSelection(entry, sync: false) }
                .help(onDemand ? "Unpin and keep any downloaded copy" : "Stop syncing and keep any downloaded copy")
                .font(.system(size: 10))
                .controlSize(.small)
                .foregroundStyle(entry.selection == "exclude" ? Color.accentColor : Color.primary)
                .disabled(app.busy != nil || (onDemand ? !entry.pinned : entry.selection == "exclude"))
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 38)
        .onTapGesture(count: 2) { if !entry.isDir { app.openSyncedFile(entry) } }
        .contextMenu {
            Button("Open") { app.openSyncedFile(entry) }
        }
    }

    private var note: String {
        let kind = entry.isDir ? "Folder" : Format.bytes(entry.size)
        if onDemand {
            if entry.pinned {
                return kind + (entry.isDir ? " · Pinned folder" : entry.local ? " · Kept offline" : " · Pinned, waiting for download")
            }
            return kind + (entry.local ? " · On this device" : " · Online")
        }
        let rule: String
        switch entry.selection {
        case "sync": rule = "Sync enabled"
        case "exclude": rule = "Stopped here"
        default: rule = "Default rules"
        }
        let availability = entry.local ? "" : (entry.remote ? " · needs download" : "")
        return "\(kind) · \(rule)\(availability)"
    }
}
