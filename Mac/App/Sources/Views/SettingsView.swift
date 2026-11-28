import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    var fullWindow = false
    @State private var startupEnabled = true
    @State private var startupConfigured = false
    @State private var startupLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Appearance", selection: Binding(
                get: { app.settingsPref.appearance },
                set: { value in
                    PrefStore.shared.update { $0.appearance = value }
                    app.settingsPref = PrefStore.shared.preferences
                    AppDelegate.applyAppearance(value)
                })) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.menu)

            Toggle("Start at boot", isOn: Binding(
                get: { startupEnabled },
                set: { value in changeStartup(value ? "startup.enable" : "startup.disable") }))
                .disabled(startupLoading)
            if startupEnabled && !startupConfigured {
                Button("Set up before-sign-in startup…") { changeStartup("startup.setup") }
                    .disabled(startupLoading)
            }

            Toggle("Install updates automatically", isOn: Binding(
                get: { app.settingsPref.autoInstallUpdates == true },
                set: { value in
                    PrefStore.shared.update { $0.autoInstallUpdates = value }
                    app.settingsPref = PrefStore.shared.preferences
                    if value { app.checkForAppUpdate(onOpen: true) }
                }))
                .help("Updates install when myDrive is in the background and idle.")
            Button("Check for updates") { app.checkForAppUpdate(showResult: true) }
            BlipSettingsView(receiver: app.blip)
            Menu("Advanced") {
                Button("Syncthing settings…") { app.dialog = .syncSettings }
                Button("Open Syncthing web interface") { app.openSyncthingWeb() }
                Toggle("Open at sign-in", isOn: Binding(
                    get: { app.settingsPref.startAtLogin }, set: setLogin))
                Toggle("Remount network drives", isOn: Binding(
                    get: { app.settingsPref.autoRemount },
                    set: { value in
                        PrefStore.shared.update { $0.autoRemount = value }
                        app.settingsPref = PrefStore.shared.preferences
                    }))
                if !SmbMonitor.dsStoreFixApplied() {
                    Button("Keep .DS_Store off network drives") { app.applyFix(.applyDSDontWriteStores) }
                }
                if !SmbMonitor.cacheFixApplied() {
                    Button("Refresh Finder folder listings") { app.applyFix(.applyDirCacheFix) }
                }
            }
            Button("Quit myDrive", role: .destructive) { app.quit() }
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await readStartup("startup.status") }
    }

    private func changeStartup(_ action: String) {
        Task { await readStartup(action) }
    }

    @MainActor private func readStartup(_ action: String) async {
        guard !startupLoading else { return }
        startupLoading = true
        defer { startupLoading = false }
        do {
            let reply = try await CoreBridge.shared.call(action: action, timeout: action == "startup.setup" ? nil : 15)
            if let result = reply as? JSON {
                startupEnabled = result.bool("enabled")
                startupConfigured = result.bool("configured")
            }
        } catch {
            if action != "startup.status" { app.showBanner(.error, "Could not change startup", error.localizedDescription) }
        }
    }

    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            PrefStore.shared.update { $0.startAtLogin = enabled }
        } catch {
            app.showBanner(.error, "Could not change login startup", error.localizedDescription)
        }
        app.settingsPref = PrefStore.shared.preferences
    }
}

private struct BlipSettingsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var receiver: BlipReceiver

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Blip").fontWeight(.semibold)
            HStack {
                Text("Download folder")
                Spacer(minLength: 4)
                if receiver.customDownloadDirectory != nil {
                    Button("Use Default") { saveDownloadFolder(nil) }
                }
                Button("Choose…", action: chooseDownloadFolder)
                    .accessibilityLabel("Choose Blip download folder")
            }
            .help("Choose where myDrive saves newly received Blip files.")
            Text((receiver.downloadDirectory.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(receiver.downloadDirectory.path)
            Toggle("Open approved senders’ links automatically",
                   isOn: Binding(get: { receiver.autoOpen }, set: receiver.setAutoOpen))
            Toggle("Keep Blip available in the background",
                   isOn: Binding(get: { receiver.backgroundEnabled }, set: receiver.setBackground))
            Toggle("Automatically match Parsec computers",
                   isOn: Binding(get: { receiver.parsecAutomaticMatching }, set: receiver.setParsecAutomaticMatching))
                .help("Requires screen recording permission to read the myDrive badge in the Parsec window while you drag a file.")
            DisclosureGroup("Sender permissions") {
                BlipSenderPermissionsView(receiver: receiver)
            }
        }
    }

    private func chooseDownloadFolder() {
        let picker = NSOpenPanel()
        picker.title = "Choose Blip Download Folder"
        picker.prompt = "Choose"
        picker.directoryURL = receiver.downloadDirectory
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        guard picker.runMyDrivePicker() == .OK, let folder = picker.url else { return }
        saveDownloadFolder(folder)
    }

    private func saveDownloadFolder(_ folder: URL?) {
        do { try receiver.setDownloadDirectory(folder) }
        catch { app.showBanner(.error, "Could not change the Blip download folder", error.localizedDescription) }
    }
}
