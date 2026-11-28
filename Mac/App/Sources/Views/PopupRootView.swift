// Compact popup shell with window controls in the header and progress at the bottom.
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let myDriveExpand = Notification.Name("io.mydrive.expand")
    static let myDriveCompact = Notification.Name("io.mydrive.compact")
}

enum PopupMetrics {
    static let width: CGFloat = 344
    static let maxHeight: CGFloat = 420
    static let rowHeight: CGFloat = 44
}

struct PopupRootView: View {
    @EnvironmentObject var app: AppState
    @State private var hoveringSyncTab = false
    var fullWindow = false

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionBar
            if let banner = app.banner {
                BannerRow(banner: banner) { app.banner = nil }
            }
            if app.dialog != nil {
                DialogContainer(dialog: app.dialog!) {
                    app.dialog = nil
                }
            } else {
                ScrollView {
                    content
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
            }
            if let busy = app.busy {
                Divider()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Cancel") { app.cancelOperation() }
                        .font(.system(size: 11))
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .frame(width: fullWindow ? 560 : PopupMetrics.width)
        .frame(height: fullWindow ? nil : PopupMetrics.maxHeight)
        .frame(maxHeight: fullWindow ? .infinity : PopupMetrics.maxHeight)
        .background {
            if fullWindow { Color(nsColor: .windowBackgroundColor) }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: app.receiveDropProviders)
    }

    private var sectionBar: some View {
        HStack(spacing: 3) {
            ForEach(PopupViewKind.tabs) { kind in
                if kind == .activity { Spacer(minLength: 4) }
                let selected = app.view.tab == kind
                Button { app.view = kind } label: {
                    Group {
                        switch kind {
                        case .cloud: Image(systemName: "cloud")
                        case .activity: Image(systemName: "clock")
                        case .settings: Image(systemName: "gearshape")
                        default: Text(kind.label)
                        }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 27)
                    .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(kind.label)
                .accessibilityLabel(kind.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .modifier(SyncTabDrop(active: kind == .sync, hover: $hoveringSyncTab, app: app))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 5)
        .disabled(app.busy != nil || app.dialog != nil)
    }

    @ViewBuilder
    private var content: some View {
        switch app.view {
        case .sync:
            if app.syncDropPaths.isEmpty { SyncView() }
            else { SyncDropView(blip: app.blip) }
        case .syncFiles: SyncFilesView()
        case .syncInfo: SyncInfoView()
        case .syncAttention: SyncAttentionView()
        case .connections: ConnectionsView()
        case .cloud: CloudDrivesView(model: app.cloud)
        case .activity: ActivityView()
        case .transfers: BlipView(receiver: app.blip)
        case .settings: SettingsView(fullWindow: fullWindow)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("myDrive").font(.system(size: 13, weight: .semibold))
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text(version).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                let updateTitle = app.checkingForAppUpdate ? "Checking for updates" :
                    app.availableAppUpdate.map(app.updateOfferTitle) ?? "Check for updates"
                Button(action: app.fetchAppUpdate) {
                    Group {
                        if app.checkingForAppUpdate || app.installingAppUpdate {
                            ProgressView().controlSize(.small).scaleEffect(0.75)
                        } else if app.availableAppUpdate != nil {
                            Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
                        } else {
                            Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.checkingForAppUpdate || app.installingAppUpdate)
                .help(updateTitle)
                .accessibilityLabel(updateTitle)
            }
            .fixedSize()
            Spacer(minLength: 4)
            Button {
                app.view = .transfers
                app.blip.pasteAndSend()
            } label: {
                Image(systemName: "clipboard").font(.system(size: 13)).frame(width: 24, height: 24)
            }.buttonStyle(.plain).help("Paste and send with Blip").accessibilityLabel("Paste clipboard and send")
            Menu {
                Button("Sync a folder…") { app.dialog = .share }
                Button("Send with Blip…") { app.view = .transfers; app.blip.chooseFilesToSend() }
                Button("Paste and send…") { app.view = .transfers; app.blip.pasteAndSend() }
                Divider()
                Button("Send via AirDrop…", action: app.chooseAirDropFiles)
                Button("Paste via AirDrop", action: app.pasteViaAirDrop)
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add folder or connection")
            let windowModeLabel = fullWindow ? "Open compact popup" : "Open full window"
            Button {
                NotificationCenter.default.post(name: fullWindow ? .myDriveCompact : .myDriveExpand, object: nil)
            } label: {
                Image(systemName: fullWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(windowModeLabel)
            .accessibilityLabel(windowModeLabel)
            .disabled(!fullWindow && app.busy != nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct SyncTabDrop: ViewModifier {
    let active: Bool
    @Binding var hover: Bool
    let app: AppState

    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content
                .onDrop(of: [.fileURL], isTargeted: $hover) { providers in
                    FileDropInput.receive(providers) { app.prepareSyncDrop($0) }
                }
                .onChange(of: hover) { entered in
                    if entered && app.busy == nil && app.dialog == nil { app.view = .sync }
                }
        } else {
            content
        }
    }
}

struct BannerRow: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(banner.kind == .error ? Color.red : Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(banner.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Shared header row used by list views: title + trailing icon buttons.
struct SectionToolbar: View {
    let title: String
    var actions: [ToolbarAction] = []

    struct ToolbarAction: Identifiable {
        let symbol: String
        let label: String
        let perform: () -> Void
        var id: String { label }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ForEach(actions) { action in
                Button(action: action.perform) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.label)
            }
        }
        .padding(.vertical, 2)
    }
}
