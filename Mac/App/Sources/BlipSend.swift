import AppKit
import Darwin

struct BlipSendPayload {
    let files: [URL]
    let description: String
    var stagingDirectory: URL? = nil

    func discard() {
        guard let stagingDirectory else { return }
        for file in files where file.deletingLastPathComponent() == stagingDirectory {
            try? FileManager.default.removeItem(at: file)
        }
        // The directory can only be removed while empty.
        _ = rmdir(stagingDirectory.path)
    }

    @MainActor static func clipboard(_ clipboard: NSPasteboard, outbox: URL) throws -> Self {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let files = (clipboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { $0.isFileURL && ($0.host ?? "").isEmpty }
        if !files.isEmpty { return forFiles(files) }
        if let text = clipboard.string(forType: .URL) ?? clipboard.string(forType: .string), !text.isEmpty {
            return try textPayload(text, outbox: outbox)
        }
        if let data = clipboard.data(forType: .png) {
            return try stage(data, name: "Clipboard image.png", description: "Image from clipboard", outbox: outbox)
        }
        if let tiff = clipboard.data(forType: .tiff) {
            return try stage(tiff, name: "Clipboard image.tiff", description: "Image from clipboard", outbox: outbox)
        }
        throw BlipReceiverError.message("Copy a file, folder, image, web link or text first.")
    }

    static func forFiles(_ files: [URL]) -> Self {
        Self(files: files, description: files.count == 1 ? files[0].lastPathComponent : "\(files.count) files or folders")
    }

    static func textPayload(_ text: String, outbox: URL) throws -> Self {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let links = lines.prefix(17).compactMap(webClipboardURL)
        if !links.isEmpty, links.count <= 16, links.count == lines.count {
            let items = links.enumerated().map { index, link in
                let name = links.count == 1 ? "Clipboard link.url" : String(format: "Clipboard link %02d.url", index + 1)
                return (name, Data("[InternetShortcut]\r\nURL=\(link.absoluteString)\r\n".utf8))
            }
            return try stage(items, description: links.count == 1 ? "Web link from clipboard" : "\(links.count) web links from clipboard", outbox: outbox)
        }
        return try stage(Data(text.utf8), name: "Clipboard text.txt", description: "Text from clipboard", outbox: outbox)
    }

    private static func webClipboardURL(_ text: String) -> URL? {
        guard text.utf8.count <= 8192, !text.contains(where: \.isWhitespace),
              text.rangeOfCharacter(from: .controlCharacters) == nil, !text.contains("\\") else { return nil }
        var address = text
        // A copied address can omit its scheme. Require a DNS name and a URL delimiter before inferring HTTPS.
        let domainWithPath = #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}[/?#]"#
        if text.range(of: domainWithPath, options: [.regularExpression, .caseInsensitive]) != nil {
            address = "https://" + text
        }
        guard address.utf8.count <= 8192, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func stage(_ data: Data, name: String, description: String, outbox: URL) throws -> Self {
        try stage([(name, data)], description: description, outbox: outbox)
    }

    private static func stage(_ items: [(String, Data)], description: String, outbox: URL) throws -> Self {
        let directory = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = items.map { directory.appendingPathComponent($0.0) }
        let payload = Self(files: files, description: description, stagingDirectory: directory)
        do { for (item, file) in zip(items, files) { try item.1.write(to: file, options: .atomic) } }
        catch { payload.discard(); throw error }
        return payload
    }
}

@MainActor extension BlipReceiver {
    func chooseFilesToSend() {
        prepareSend { self.pickFilesForRecipient() }
    }

    private func pickFilesForRecipient() {
        guard let choice = chooseRecipient(description: nil) else { return }
        if choice.paste { pasteAndSend(to: choice.peer) }
        else { chooseFiles(to: choice.peer) }
    }

    func chooseFiles(to peer: BlipPeer) {
        guard connected, !sending else { return }
        let owner = recipientOwner
        let picker = NSOpenPanel()
        picker.title = "Send with Blip"
        picker.message = "Send to \(recipientLabel(peer))"
        picker.prompt = "Choose"
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.treatsFilePackagesAsDirectories = true
        guard picker.runModal() == .OK, !picker.urls.isEmpty, recipientOwner == owner else { return }
        send(.forFiles(picker.urls), to: peer)
    }

    func pasteAndSend() {
        do {
            let payload = try BlipSendPayload.clipboard(.general, outbox: outboxDirectory)
            sendPrepared(payload)
        }
        catch { reportSend(error.localizedDescription) }
    }

    func pasteAndSend(to peer: BlipPeer) {
        do { send(try .clipboard(.general, outbox: outboxDirectory), to: peer) }
        catch { reportSend(error.localizedDescription) }
    }

    func sendDropped(_ urls: [URL]) {
        sendPrepared(.forFiles(urls))
    }

    private func sendPrepared(_ payload: BlipSendPayload) {
        prepareSend({ self.chooseRecipientAndSend(payload) }, onUnavailable: { payload.discard() })
    }

    private func chooseRecipientAndSend(_ payload: BlipSendPayload) {
        guard let choice = chooseRecipient(description: payload.description) else {
            payload.discard()
            return
        }
        if choice.paste {
            payload.discard()
            pasteAndSend(to: choice.peer)
        } else {
            send(payload, to: choice.peer)
        }
    }

    private func canChooseRecipient() -> Bool {
        guard connected, !sending, recipients.contains(where: { !isArchived($0) }) else {
            reportSend("Connect to Blip and wait for a recipient device to appear in the Blip tab.")
            return false
        }
        return true
    }

    private func chooseRecipient(description: String?) -> (peer: BlipPeer, paste: Bool)? {
        guard canChooseRecipient() else { return nil }
        var choices = recipients.filter { !isArchived($0) }
        let owner = recipientOwner
        let picker = BlipRecipientPicker(labels: choices.map { recipientLabel($0) }, description: description,
            availability: choices.map(\.online),
            rename: { index in
                guard self.recipientOwner == owner, let updated = self.rename(choices[index]) else { return nil }
                choices[index] = updated
                return self.recipientLabel(updated)
            })
        picker.window.appearance = AppDelegate.appearance(for: PrefStore.shared.preferences.appearance)
        guard let selected = picker.run(), recipientOwner == owner, choices.indices.contains(selected.row)
        else { return nil }
        return (choices[selected.row], selected.paste)
    }
}

@MainActor final class BlipRecipientTable: NSTableView {
    var activateRow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if selectedRow >= 0, [36, 49, 76].contains(event.keyCode) {
            activateRow?(selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor final class BlipRecipientPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let window: NSPanel
    let table = BlipRecipientTable()
    let scroll = NSScrollView()
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var labels: [String]
    private let availability: [Bool?]
    private var choice: (row: Int, paste: Bool)?
    private let rename: ((Int) -> String?)?

    init(labels: [String], description: String?, availability: [Bool?] = [], rename: ((Int) -> String?)? = nil) {
        self.labels = labels
        self.availability = availability
        self.rename = rename
        let listHeight = CGFloat(max(1, min(labels.count, 6)) * 30 + 2)
        let height = listHeight + (description == nil ? 49 : 70)
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: height),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Send with Blip"
        window.delegate = self
        window.isReleasedWhenClosed = false
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        table.setAccessibilityLabel("Recipient devices")
        table.style = .plain
        table.headerView = nil
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = false
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recipient"))
        column.resizingMask = .autoresizingMask
        column.width = 276
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.activateRow = { [weak self] row in self?.activate(row) }

        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        guard let content = window.contentView else { return }
        let footer = NSStackView(views: [cancelButton])
        footer.orientation = .horizontal
        var views: [NSView] = []
        if let description {
            let text = NSTextField(labelWithString: description)
            text.maximumNumberOfLines = 1
            text.lineBreakMode = .byTruncatingTail
            text.toolTip = description
            views.append(text)
        }
        views += [scroll, footer]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: listHeight),
        ])
        if let text = views.first as? NSTextField {
            text.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.layoutSubtreeIfNeeded()
        table.sizeLastColumnToFit()
        table.reloadData()
    }

    func run() -> (row: Int, paste: Bool)? {
        choice = nil
        window.initialFirstResponder = table
        window.center()
        defer { window.orderOut(nil) }
        return NSApp.runModal(for: window) == .OK ? choice : nil
    }

    @objc private func cancel(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(nil)
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { labels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = labels[row]
        let cell = NSTableCellView()
        let online = availability.indices.contains(row) ? availability[row] : nil
        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.contentTintColor = online == true ? .systemGreen : .tertiaryLabelColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(dot)
        let send = NSButton(title: label, target: self, action: #selector(choseDevice(_:)))
        send.isBordered = false
        send.alignment = .left
        send.font = .systemFont(ofSize: 12)
        send.attributedTitle = NSAttributedString(string: label, attributes: [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12),
        ])
        send.lineBreakMode = .byTruncatingTail
        send.tag = row
        send.toolTip = label
        let state = online.map { $0 ? "Online" : "Offline" } ?? "Status unknown"
        send.setAccessibilityLabel("Send to " + label + ", " + state)
        send.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(send)
        let paste = NSButton(title: "", target: self, action: #selector(pasteToDevice(_:)))
        paste.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
        paste.isBordered = false
        paste.tag = row
        paste.toolTip = "Paste and send to " + label
        paste.setAccessibilityLabel("Paste and send to " + label)
        paste.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(paste)
        let edit = NSButton(title: "", target: self, action: #selector(showOptions(_:)))
        edit.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        edit.isBordered = false
        edit.tag = row
        edit.toolTip = "Options for " + label
        edit.setAccessibilityLabel("Options for " + label)
        edit.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(edit)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            send.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            send.trailingAnchor.constraint(equalTo: paste.leadingAnchor, constant: -4),
            send.topAnchor.constraint(equalTo: cell.topAnchor),
            send.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            paste.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -2),
            paste.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            paste.widthAnchor.constraint(equalToConstant: 24),
            paste.heightAnchor.constraint(equalToConstant: 24),
            edit.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            edit.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            edit.widthAnchor.constraint(equalToConstant: 24),
            edit.heightAnchor.constraint(equalToConstant: 24),
        ])
        return cell
    }

    @objc private func choseDevice(_ sender: NSButton) {
        activate(sender.tag)
    }

    @objc private func pasteToDevice(_ sender: NSButton) {
        activate(sender.tag, paste: true)
    }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Edit Name…", action: #selector(renameDevice(_:)), keyEquivalent: "")
        item.target = self
        item.tag = sender.tag
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    @objc private func renameDevice(_ sender: NSMenuItem) {
        let row = sender.tag
        guard labels.indices.contains(row), let updated = rename?(row) else { return }
        labels[row] = updated
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func activate(_ row: Int, paste: Bool = false) {
        guard choice == nil, labels.indices.contains(row) else { return }
        choice = (row, paste)
        NSApp.stopModal(withCode: .OK)
    }
}
