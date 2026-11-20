// Connections view: SMB network drives, saved storage connections with health,
// Syncthing devices; plus the storage file browser.
import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if let state = app.storageBrowse {
            StorageFilesView(state: state)
        } else {
            LazyVStack(spacing: 6) {
                sectionHeader("Network drives")
                if app.mounts.isEmpty {
                    Text("No SMB drives are mounted right now.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(app.mounts) { mount in
                        MountRow(mount: mount)
                    }
                }
                Divider()
                sectionHeader("Saved storage")
                if app.bookmarks.isEmpty {
                    Text("Use + to add a folder or connection.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(app.bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark)
                    }
                }
                Divider()
                sectionHeader("Devices")
                if let devices = app.snapshot?.devices, !devices.isEmpty {
                    ForEach(devices) { device in
                        DeviceRow(device: device)
                    }
                } else {
                    Text("Device status appears once Syncthing is connected.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MountRow: View {
    @EnvironmentObject var app: AppState
    let mount: SmbMount

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 13))
                .foregroundStyle(mount.health == .unavailable ? Color.red : Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(mount.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(mount.remoteDescription)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(mount.health == .unavailable ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                app.openLocalFolder(mount.path)
            } label: {
                Image(systemName: "arrow.up.forward.folder")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(mount.health == .unavailable)
            .accessibilityLabel("Open \(mount.displayName) in Finder")
            Menu {
                Button("Browse in myDrive") { app.browseSmbMount(mount) }
                    .disabled(mount.health == .unavailable)
                Button("Open in Finder") { app.openLocalFolder(mount.path) }
                Button("Remount") { app.remountMount(mount, force: false) }
                    .disabled(mount.health == .connected)
                Button("Force remount") { app.remountMount(mount, force: true) }
                Divider()
                Button("Disconnect") { app.disconnectMount(mount) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(mount.displayName)")
        }
        .padding(.horizontal, 2)
        .frame(minHeight: PopupMetrics.rowHeight)
        .onTapGesture { app.openLocalFolder(mount.path) }
    }

    private var caption: String {
        var parts = ["SMB · \(mount.healthLabel)"]
        if mount.health != .unavailable, mount.freeBytes > 0 {
            parts.append("\(Format.bytes(mount.freeBytes)) free")
        }
        return parts.joined(separator: " · ")
    }
}

struct BookmarkRow: View {
    @EnvironmentObject var app: AppState
    let bookmark: Bookmark

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.nickname)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(bookmark.location)
                Text("\(bookmark.protocolName) · Ready")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Test connection") {
                    app.testBookmark(bookmark, credentials: Keychain.readCredentials(id: bookmark.id)) {
                        app.showBanner(.info, "Test connection", $0)
                    }
                }
                Button("Edit connection") { app.dialog = .bookmarkEditor(bookmark) }
                if bookmark.protocolKind == "local" {
                    Button("Open in Finder") { app.openLocalFolder(bookmark.host) }
                }
                Divider()
                Button("Remove connection", role: .destructive) { app.deleteBookmark(bookmark) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(bookmark.nickname)")
        }
        .padding(.horizontal, 2)
        .frame(minHeight: PopupMetrics.rowHeight)
        .onTapGesture { app.browseBookmark(bookmark, path: "") }
    }

    private var symbol: String {
        switch bookmark.protocolKind {
        case "sftp": return "server.rack"
        case "webdav": return "globe"
        case "s3": return "cloud"
        default: return "folder"
        }
    }
}

struct DeviceRow: View {
    let device: SyncthingDevice

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: device.connected ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(device.connected ? Color.green : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(device.displayName)\(device.isLocal ? " (this computer)" : "")")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(device.connected
                     ? "Connected\(device.clientVersion.isEmpty ? "" : " · \(device.clientVersion)")"
                     : "Offline")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 36)
    }
}

struct StorageFilesView: View {
    @EnvironmentObject var app: AppState
    let state: StorageBrowseState

    var body: some View {
        LazyVStack(spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    app.storageBrowse = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to storage")
                Text(state.bookmark.nickname)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Menu {
                    Button("Upload file…") { app.uploadFile() }
                    Button("New folder…") { app.newFolderPrompt() }
                    if state.bookmark.protocolKind == "local" {
                        Button("Open in Finder") { app.openLocalFolder(rootPath) }
                    }
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("File commands")
                Button {
                    app.browseBookmark(state.bookmark, path: state.path)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(app.busy != nil)
                .accessibilityLabel("Refresh files")
            }
            Text(state.path.isEmpty ? rootDisplay : state.path)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture(count: 2) { app.storagePathUp() }
            if state.files.isEmpty {
                Text("This folder is empty.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(state.files) { file in
                    StorageFileRow(file: file)
                }
            }
        }
    }

    private var rootPath: String { state.bookmark.coreHost }
    private var rootDisplay: String { "/" }
}

struct StorageFileRow: View {
    @EnvironmentObject var app: AppState
    let file: RemoteFile

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.isDir ? "folder.fill" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(file.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(file.path)\n\(Format.modified(file.modified))")
                Text(file.isDir ? "Folder" : Format.bytes(file.size))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                if file.isDir {
                    Button("Browse") { app.browseBookmark(currentBookmark, path: file.path) }
                } else {
                    Button("Open") { app.openStorageFile(file) }
                    Button("Download…") { app.downloadFile(file) }
                }
                Divider()
                Button("Rename…") { app.renamePrompt(file) }
                Button("Delete…", role: .destructive) { app.deleteStorageFile(file) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(file.name)")
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 38)
        .onTapGesture {
            if file.isDir {
                app.browseBookmark(currentBookmark, path: file.path)
            } else {
                app.openStorageFile(file)
            }
        }
    }

    private var currentBookmark: Bookmark {
        app.storageBrowse?.bookmark ?? Bookmark()
    }
}
