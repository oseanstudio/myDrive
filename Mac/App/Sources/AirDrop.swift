import AppKit

@MainActor extension AppState {
    func chooseAirDropFiles() {
        let picker = NSOpenPanel()
        picker.title = "Send via AirDrop"
        picker.prompt = "Choose"
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        sendAirDropFiles(picker.urls)
    }

    func sendAirDropFiles(_ files: [URL]) {
        guard let local = FileDropInput.localFiles(files) else {
            showBanner(.error, "AirDrop", "Choose available files or folders.")
            return
        }
        shareViaAirDrop(local)
    }

    func pasteViaAirDrop() {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            sendAirDropFiles(files)
        } else if let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string), !text.isEmpty {
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                shareViaAirDrop([url])
            } else {
                shareViaAirDrop([text])
            }
        } else if let image = NSImage(pasteboard: pasteboard) {
            shareViaAirDrop([image])
        } else {
            showBanner(.error, "AirDrop", "Copy a file, photo, link, or text first.")
        }
    }

    private func shareViaAirDrop(_ items: [Any]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: items) else {
            showBanner(.error, "AirDrop", "AirDrop cannot share these items. Check that AirDrop is available on this Mac.")
            return
        }
        service.perform(withItems: items)
    }
}
