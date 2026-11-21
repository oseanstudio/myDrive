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
