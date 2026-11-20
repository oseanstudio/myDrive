import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI
import CoreTransferable

@main struct MyDriveApp: App {
    @StateObject private var app = AppState()
    var body: some Scene { WindowGroup { RootView().environmentObject(app) } }
}

struct OriginalMedia: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photos/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return OriginalMedia(url: target)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var phase
    @State private var editor = false
    @State private var editing: Device?
    @State private var filePicker = false
    @State private var connectionPicker = false
    @State private var receivedPicker = false
    @State private var settings = false
    @State private var link = false
    @State private var linkText = ""
    @State private var photos: [PhotosPickerItem] = []
    var body: some View {
        TabView(selection: $app.tab) {
            NavigationStack { DevicesView(edit: { editing = $0; editor = true }, add: { editing = nil; editor = true }, pick: { filePicker = true }).toolbar { tools } }.tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }.tag(0)
            NavigationStack { BrowserView().toolbar { tools } }.tabItem { Label("Browse", systemImage: "folder") }.tag(1)
            NavigationStack { TransfersView().toolbar { tools } }.tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }.tag(2)
        }
        .tint(Color(red: 0.19, green: 0.30, blue: 0.80))
        .safeAreaInset(edge: .bottom) {
            if !app.selected.isEmpty { HStack { Text("\(app.selected.count) files ready").font(.subheadline); Spacer(); Button("Blip") { app.prepareShare() }.buttonStyle(.borderedProminent); if app.active != nil { Button("Upload here") { app.upload() }.buttonStyle(.bordered) }; Button { app.selected = [] } label: { Image(systemName: "xmark") }.accessibilityLabel("Clear selection") }.padding(12).background(.regularMaterial) }
        }
        .sheet(isPresented: $editor) { DeviceEditor(device: editing) }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(item: $app.share) { item in ShareSheet(items: item.items) { activity, completed in app.shareCompleted(activity: activity, accepted: completed, label: item.label) } }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in do { app.selected = try result.get() } catch { app.error = "Files could not be selected." } }
        .fileImporter(isPresented: $connectionPicker, allowedContentTypes: [.json]) { result in if case .success(let file) = result { Task { await app.importConnections(file) } } }
        .fileImporter(isPresented: $receivedPicker, allowedContentTypes: [.folder]) { result in if case .success(let folder) = result { app.receivedFolder(folder); app.tab = 1 } }
        .alert("Send a link with Blip", isPresented: $link) { TextField("Link or text", text: $linkText); Button("Choose Blip") { app.prepareShare(text: linkText) }; Button("Cancel", role: .cancel) {} } message: { Text("Choose Blip in the iOS share sheet to use your existing account.") }
        .alert("myDrive", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) { Button("OK") { app.error = nil } } message: { Text(app.error ?? "") }
        .onChange(of: phase) { _, newPhase in if newPhase == .active { app.openReceivedLinks() } }
        .onChange(of: photos) { _, items in if !items.isEmpty { Task { do { var urls: [URL] = []; for item in items { if let file = try await item.loadTransferable(type: OriginalMedia.self) { urls.append(file.url) } }; app.selected = urls; photos = [] } catch { app.error = "The original photos or videos could not be prepared." } } } }
    }
    private var tools: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Add SMB device", systemImage: "plus") { editing = nil; editor = true }
                Button("Choose files", systemImage: "doc") { filePicker = true }
                PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) { Label("Choose photos or videos", systemImage: "photo.on.rectangle") }
                Button("Send a link with Blip", systemImage: "link") { link = true }
                Button("Import connections", systemImage: "square.and.arrow.down") { connectionPicker = true }
                Button("Choose Blip received folder", systemImage: "folder.badge.plus") { receivedPicker = true }
                Button("Settings", systemImage: "gearshape") { settings = true }
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More options")
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: (UIActivity.ActivityType?, Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController { let controller = UIActivityViewController(activityItems: items, applicationActivities: nil); controller.completionWithItemsHandler = { activity, completed, _, _ in completion(activity, completed) }; return controller }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
