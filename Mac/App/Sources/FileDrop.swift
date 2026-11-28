import AppKit
import UniformTypeIdentifiers

@MainActor final class StatusFileDropView: NSView {
    private weak var button: NSStatusBarButton?
    private let showMenu: () -> Void
    private let receive: ([URL]) -> Void

    init(button: NSStatusBarButton, showMenu: @escaping () -> Void, receive: @escaping ([URL]) -> Void) {
        self.button = button
        self.showMenu = showMenu
        self.receive = receive
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { button?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { button?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) else { return [] }
        DispatchQueue.main.async { [showMenu] in showMenu() }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let values = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !values.isEmpty else { return false }
        DispatchQueue.main.async { [receive] in receive(values) }
        return true
    }
}

@MainActor enum FileDropInput {
    static func localFiles(_ candidates: [URL]) -> [URL]? {
        guard (1...256).contains(candidates.count) else { return nil }
        var seen = Set<URL>()
        var urls = [URL]()
        for path in candidates.map(\.standardizedFileURL) {
            guard path.isFileURL, (path.host ?? "").isEmpty, FileManager.default.fileExists(atPath: path.path) else { return nil }
            if seen.insert(path).inserted { urls.append(path) }
        }
        return urls
    }

    static func receive(_ providers: [NSItemProvider], then handle: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task.detached {
            guard files.count <= 256 else {
                await handle([])
                return
            }
            var urls = [URL]()
            var seen = Set<URL>()
            for provider in files {
                let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                guard let path = url?.standardizedFileURL, path.isFileURL, (path.host ?? "").isEmpty,
                      FileManager.default.fileExists(atPath: path.path) else {
                    await handle([])
                    return
                }
                if seen.insert(path).inserted { urls.append(path) }
            }
            await handle(urls)
        }
        return true
    }
}

@MainActor extension AppState {
    func receiveDropProviders(_ providers: [NSItemProvider]) -> Bool {
        FileDropInput.receive(providers, then: handleFileDrop)
    }

    func handleFileDrop(_ candidates: [URL]) {
        guard busy == nil, dialog == nil else { return }
        var seen = Set<URL>()
        let urls = candidates.map(\.standardizedFileURL).filter { $0.isFileURL && ($0.host ?? "").isEmpty &&
            FileManager.default.fileExists(atPath: $0.path) && seen.insert($0).inserted }
        guard !urls.isEmpty else { return }
        if view == .sync {
            prepareSyncDrop(urls)
            return
        }
        let send = {
            self.view = .transfers
            self.blip.sendDropped(urls)
        }
        let folder = urls.count == 1 ? urls.first.flatMap { candidate in
            (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? candidate : nil
        } : nil
        let actions = NSAlert()
        actions.messageText = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files and folders"
        let openedFromPopup = popoverVisible
        var commands: [() -> Void] = []
        func add(_ title: String, _ work: @escaping () -> Void) {
            actions.addButton(withTitle: title)
            commands.append(work)
        }
        add("Send with Blip", send)
        add("Send via AirDrop") { self.sendAirDropFiles(urls) }
        if let folder {
            add("Sync Folder") {
                self.shareFolderPath = folder.path
                self.dialog = .share
                if openedFromPopup && !self.popoverVisible {
                    NotificationCenter.default.post(name: .myDriveShow, object: nil)
                }
            }
            add("Share over SMB") { self.createPrivateShare(folder) }
        }
        actions.addButton(withTitle: "Cancel")
        let choice = actions.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if commands.indices.contains(choice) { commands[choice]() }
    }
}
