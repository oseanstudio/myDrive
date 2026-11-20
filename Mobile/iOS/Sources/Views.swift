import SwiftUI
import UniformTypeIdentifiers

struct DevicesView: View {
    @EnvironmentObject var app: AppState
    let edit: (Device) -> Void
    let add: () -> Void
    let pick: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Browse shared folders. Send files wherever you are.").foregroundStyle(.secondary)
                Button(action: pick) {
                    HStack(spacing: 18) { Image(systemName: "paperplane.fill").font(.largeTitle); VStack(alignment: .leading) { Text("Send with Blip").font(.headline); Text("Choose files, then Blip in the share sheet").font(.subheadline) }; Spacer() }.padding(20).frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(.plain)
                ForEach(app.devices) { device in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer").font(.largeTitle).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) { Text(device.name).font(.headline); Text("\(device.host) / \(device.share)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            Spacer(); Button { edit(device) } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit \(device.name)")
                        }
                        HStack { Button("Browse") { app.browse(device) }.buttonStyle(.borderedProminent); if !app.selected.isEmpty { Button("Choose upload folder") { app.browse(device) }.buttonStyle(.bordered) } }
                    }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                }
                Button(action: add) { Label("Add SMB device", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Text("Use the computer's Tailscale name or address. Keep Tailscale connected on both devices.").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("Your devices")
    }
}

struct BrowserView: View {
    @EnvironmentObject var app: AppState
    @State private var editName: NameAction?
    @State private var deleting: RemoteEntry?
    var body: some View {
        List {
            if let device = app.active {
                Section {
                    HStack {
                        if !app.path.isEmpty { Button { app.path = (app.path as NSString).deletingLastPathComponent; app.refresh() } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Parent folder") }
                        Text(app.path.isEmpty ? device.share : app.path).font(.subheadline).lineLimit(1).truncationMode(.middle)
                        Spacer(); Button { app.refresh() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh folder")
                        Button { editName = NameAction(kind: "New folder", entry: nil) } label: { Image(systemName: "folder.badge.plus") }.accessibilityLabel("New folder")
                    }.disabled(app.loading)
                    if app.loading { ProgressView("Loading folder…") }
                }
                Section {
                    if !app.loading && app.entries.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary) }
                    ForEach(app.entries) { entry in
                        Button { if entry.directory { app.browse(device, at: entry.path) } else { app.download(entry) } } label: {
                            HStack(spacing: 12) { Image(systemName: entry.directory ? "folder.fill" : "doc.fill").font(.title2).foregroundStyle(.tint); VStack(alignment: .leading, spacing: 3) { Text(entry.name).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle); Text(entry.linked ? "Linked item · not followed" : entry.directory ? "Folder" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }; Spacer(); if entry.directory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) } }
                        }.disabled(entry.linked || app.loading).contextMenu {
                            if !entry.directory { Button("Download", systemImage: "arrow.down.circle") { app.download(entry) }.disabled(entry.linked) }
                            Button("Rename", systemImage: "pencil") { editName = NameAction(kind: "Rename", entry: entry) }.disabled(entry.linked)
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }.disabled(entry.linked)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Choose a device", systemImage: "externaldrive.connected.to.line.below", description: Text("Add an SMB share to browse your computer over Tailscale."))
                Button("Your devices") { app.tab = 0 }
            }
            if !app.receivedEntries.isEmpty {
                Section("Blip received folder") {
                    ForEach(app.receivedEntries, id: \.self) { file in Button { app.importReceived(file) } label: { Label("Import \(file.lastPathComponent)", systemImage: "square.and.arrow.down") } }
                    Text("Wait until Blip finishes receiving a file before importing it.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(app.active?.name ?? "Browse").refreshable { if app.active != nil { app.refresh() }; app.loadReceived() }
        .sheet(item: $editName) { action in NameEditor(action: action) }
        .alert("Delete item?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let item = deleting { app.change { try await $0.delete(item) } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Delete \(deleting?.name ?? "this item") from the server? Folders must be empty.") }
    }
}

struct TransfersView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            if app.transfers.isEmpty { ContentUnavailableView("No transfers yet", systemImage: "arrow.up.arrow.down", description: Text("SMB progress and Blip handoffs will appear here.")) }
            ForEach(app.transfers) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(item.device) · \(item.state)").font(.subheadline).foregroundStyle(.secondary)
                    if item.active { if item.total > 0 { ProgressView(value: Double(item.bytes), total: Double(item.total)) } else { ProgressView() }; HStack { Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption); Spacer(); Button("Cancel") { app.cancel(item.id) } } }
                    if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if let path = item.localPath { ShareLink(item: URL(fileURLWithPath: path)) { Label("Open or share", systemImage: "square.and.arrow.up") } }
                    if item.state == "Handed to Blip" || item.state == "Handed to app" { Text("Check the receiving app for acceptance and delivery.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
        }.navigationTitle("Transfers")
    }
}

struct DeviceEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let device: Device?
    @State private var name = ""
    @State private var host = ""
    @State private var share = ""
    @State private var root = ""
    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var encrypted = false
    @State private var problem: String?
    @State private var removing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Computer") {
                    TextField("Device name", text: $name)
                    TextField("Host or Tailscale name", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Shared folder name", text: $share).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Start folder (optional)", text: $root).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section { TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled(); TextField("Domain (optional)", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled(); SecureField(device == nil ? "Password" : "New password (blank keeps saved)", text: $password) } header: { Text("SMB account") } footer: { Text("Use the computer account password, not a Windows Hello PIN. Passwords are kept in this phone's Keychain.") }
                Section { Toggle("Require SMB3 encryption", isOn: $encrypted) }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
                if device != nil { Section { Button("Remove saved connection", role: .destructive) { removing = true } } }
            }.navigationTitle(device == nil ? "Add SMB device" : "Edit device").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.isEmpty || host.isEmpty || share.isEmpty) } }
            .onAppear { if let d = device { name = d.name; let address = d.host.contains(":") && !d.host.hasPrefix("[") ? "[\(d.host)]" : d.host; host = d.port == 445 ? address : "\(address):\(d.port)"; share = d.share; root = d.root; username = d.username; domain = d.domain; encrypted = d.encrypted } }
            .confirmationDialog("Remove this connection? Remote files stay on the computer.", isPresented: $removing) { Button("Remove saved connection", role: .destructive) { do { if let device { try app.remove(device) }; dismiss() } catch { problem = error.localizedDescription } } }
        }
    }
    private func save() {
        do { let(server, port) = try RemotePath.server(host); let result = Device(id: device?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespaces), host: server, share: share, root: root, username: username, domain: domain, port: port, encrypted: encrypted); try app.save(result, password: password); password = ""; dismiss() }
        catch { problem = error.localizedDescription }
    }
}

struct NameAction: Identifiable { let id = UUID(); let kind: String; let entry: RemoteEntry? }
struct NameEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let action: NameAction
    @State private var name = ""
    @State private var problem: String?
    var body: some View {
        NavigationStack { Form { TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled(); if let problem { Text(problem).foregroundStyle(.red) } }.navigationTitle(action.kind).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { do { let target = try RemotePath.child(app.path, name); let entry = action.entry; app.change { client in if let entry { try await client.rename(entry.path, to: target) } else { try await client.mkdir(target) } }; dismiss() } catch { problem = error.localizedDescription } }.disabled(name.isEmpty) } }.onAppear { name = action.entry?.name ?? "" } }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("blip_auto_open_links") private var autoOpen = true
    var body: some View {
        NavigationStack { Form {
            Section { Toggle("Open received web links", isOn: $autoOpen) } footer: { Text("Completed myDrive downloads open once in your default browser when the app is active. Blip manages its own receiving preferences.") }
            Section("Connections") { Text("Keep Tailscale running on the phone and computer for remote SMB access."); Text("Blip sends use the installed Blip app's account through the iOS share sheet."); Text("Syncthing continues syncing your paired computers. Phone folder synchronization is not part of this preview.") }
            Section("About") { Text("myDrive 0.4.0 mobile preview"); Text("SMB via AMSMB2 4.0.3"); Link("Blip for iPhone", destination: URL(string: "https://apps.apple.com/app/id6463305181")!); Link("Open-source components", destination: URL(string: "https://github.com/amosavian/AMSMB2")!) }
        }.navigationTitle("Settings").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
}
