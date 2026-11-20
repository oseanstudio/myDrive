import AppKit
import UniformTypeIdentifiers

@MainActor final class StatusFileDropView: NSView {
    private weak var button: NSStatusBarButton?
    private let receive: ([URL]) -> Void

    init(button: NSStatusBarButton, receive: @escaping ([URL]) -> Void) {
        self.button = button
        self.receive = receive
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { button?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { button?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let values = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !values.isEmpty else { return false }
        DispatchQueue.main.async { [receive] in receive(values) }
        return true
    }
}

@MainActor extension AppState {
    func receiveDropProviders(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in files {
                let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                if let url { urls.append(url) }
            }
            handleFileDrop(urls)
        }
        return true
    }

    func handleFileDrop(_ candidates: [URL]) {
        guard busy == nil, dialog == nil else { return }
        var seen = Set<URL>()
        let urls = candidates.map(\.standardizedFileURL).filter { $0.isFileURL && ($0.host ?? "").isEmpty &&
            FileManager.default.fileExists(atPath: $0.path) && seen.insert($0).inserted }
        guard !urls.isEmpty else { return }
        let send = {
            self.view = .transfers
            self.blip.sendDropped(urls)
        }
        guard urls.count == 1, let folder = urls.first,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            send()
            return
        }
        let actions = NSAlert()
        actions.messageText = folder.lastPathComponent
        actions.informativeText = "Choose what to do with this folder."
        actions.addButton(withTitle: "Send with Blip")
        actions.addButton(withTitle: "Sync Folder")
        actions.addButton(withTitle: "Share over SMB")
        actions.addButton(withTitle: "Cancel")
        switch actions.runModal() {
        case .alertFirstButtonReturn: send()
        case .alertSecondButtonReturn:
            shareFolderPath = folder.path
            dialog = .share
        case .alertThirdButtonReturn: createPrivateShare(folder)
        default: break
        }
    }
}
