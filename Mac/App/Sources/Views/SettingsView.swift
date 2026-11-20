// Settings view. Setup forms stay behind dialogs per the native UI rules; this
// pane only exposes status, toggles and escape hatches.
import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    var fullWindow = false

    var body: some View {
        VStack(spacing: 8) {
            sectionLabel("Sync")
            HStack(spacing: 6) {
                Image(systemName: "sync")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.snapshot.map { "Syncthing \($0.version)" } ?? "Syncthing not connected")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(discoveryCaption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Connection settings…") { app.dialog = .syncSettings }
                    .font(.system(size: 11))
                    .controlSize(.small)
                Button("Open web") { app.openSyncthingWeb() }
                    .font(.system(size: 11))
                    .controlSize(.small)
            }
            .frame(minHeight: 36)

            sectionLabel("Network drives")
            Toggle("Remount drives that become unavailable", isOn: Binding(
                get: { app.settingsPref.autoRemount },
                set: { newValue in
                    PrefStore.shared.update { $0.autoRemount = newValue }
                    app.settingsPref = PrefStore.shared.preferences
                }))
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Skip .DS_Store files on network drives")
                        .font(.system(size: 12))
                    Text(SmbMonitor.dsStoreFixApplied()
                         ? "Already applied on this Mac."
                         : "Fixes Finder showing empty folders on SMB shares.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !SmbMonitor.dsStoreFixApplied() {
                    Button("Apply") { app.applyFix(.applyDSDontWriteStores) }
                        .font(.system(size: 11))
                        .controlSize(.small)
                        .disabled(app.busy != nil)
                }
            }
            .frame(minHeight: 36)

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Finder folder listings fresh")
                        .font(.system(size: 12))
                    Text(SmbMonitor.cacheFixApplied()
                         ? "SMB folder caching is off (nsmb.conf)."
                         : "Applies Apple's documented nsmb.conf fix for stale or empty listings.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !SmbMonitor.cacheFixApplied() {
                    Button("Apply") { app.applyFix(.applyDirCacheFix) }
                        .font(.system(size: 11))
                        .controlSize(.small)
                        .disabled(app.busy != nil)
                }
            }
            .frame(minHeight: 36)

            sectionLabel("General")
            Toggle("Start at login", isOn: Binding(
                get: { app.settingsPref.startAtLogin },
                set: { newValue in setLogin(newValue) }))
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
            Picker("Appearance", selection: Binding(
                get: { app.settingsPref.appearance },
                set: { newValue in
                    PrefStore.shared.update { $0.appearance = newValue }
                    app.settingsPref = PrefStore.shared.preferences
                    AppDelegate.applyAppearance(newValue)
                })) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .font(.system(size: 12))
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text("myDrive 0.4.17 · macOS preview")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit myDrive", role: .destructive) { app.quit() }
                    .font(.system(size: 11))
                    .controlSize(.small)
            }
        }
    }

    private var discoveryCaption: String {
        if app.syncthing.connection != nil { return "Discovered from the running instance" }
        if let error = app.syncthing.discoveryError { return error }
        return "Not configured"
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            PrefStore.shared.update { $0.startAtLogin = enabled }
        } catch {
            app.showBanner(.error, "Could not change login startup", Self.errorText(error))
        }
        app.settingsPref = PrefStore.shared.preferences
    }

    private static func errorText(_ error: Error) -> String {
        (error as? CoreError)?.message ?? error.localizedDescription
    }
}
