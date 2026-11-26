import AppKit
import CoreGraphics

@MainActor final class ParsecDrop {
    private struct Session: Equatable {
        let window: CGWindowID
        let process: pid_t
        let launched: Date?
        let title: String?
    }

    private struct Route {
        let session: Session
        let computer: String
        let owner: String
        let peer: BlipPeer
    }

    private let receiver: BlipReceiver
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 66),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let target = ParsecDropView(frame: .zero)
    private struct Connection {
        let app: NSRunningApplication
        let owner: String
        let peer: BlipPeer
    }

    private var connection: Connection?
    private var starting = false
    private var timer: Timer?
    private var idlePoint: CGPoint?
    private var startPoint: CGPoint?
    private var sourceProcess: pid_t?
    private var candidate: Session?
    private var hoverSince = Date.distantFuture
    private var shown: Route?
    private var lastPressed = Date.distantPast

    init(receiver: BlipReceiver) {
        self.receiver = receiver
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if #available(macOS 26.0, *) {
            panel.collectionBehavior.insert(.canJoinAllApplications)
        }
        panel.contentView = target
        target.canDrop = { [weak self] in self?.canSend() == true }
        target.receive = { [weak self] urls in self?.send(urls) == true }
    }

    func connect(_ peer: BlipPeer, edit: Bool) {
        let owner = receiver.recipientOwner
        guard !owner.isEmpty, !starting else { return }
        let key = owner + "/" + peer.peer
        let current = PrefStore.shared.preferences.parsecComputers?[key]
        var host = current ?? ""
        if edit || current == nil {
            let prompt = NSAlert()
            prompt.messageText = "Link a Parsec computer"
            prompt.informativeText = "Copy the Peer ID from Parsec’s Computers tab. A connection to that computer from myDrive will send drops to " + receiver.recipientLabel(peer) + "."
            prompt.addButton(withTitle: edit ? "Save" : "Save & Connect")
            prompt.addButton(withTitle: "Cancel")
            if edit, current != nil { prompt.addButton(withTitle: "Unlink") }
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 24))
            input.placeholderString = "Parsec Peer ID"
            input.setAccessibilityLabel("Parsec Peer ID")
            input.stringValue = host
            prompt.accessoryView = input
            let result = BlipReceiver.runSignInPrompt(prompt, field: input)
            guard owner == receiver.recipientOwner else { return }
            if result == .alertThirdButtonReturn {
                PrefStore.shared.update { $0.parsecComputers?.removeValue(forKey: key) }
                connection = nil
                hide()
                return
            }
            guard result == .alertFirstButtonReturn else { return }
            host = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
                receiver.reportSend("Enter the Parsec Peer ID shown in the Computers tab.")
                return
            }
            PrefStore.shared.update {
                var computers = $0.parsecComputers ?? [:]
                computers[key] = host
                $0.parsecComputers = computers
            }
            if edit { connection = nil; hide(); return }
        }

        let urls = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Parsec.app"),
            URL(fileURLWithPath: "/Applications/Parsec.app", isDirectory: true)
        ]
        guard let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            receiver.reportSend("Install Parsec to connect to a linked computer.")
            return
        }
        let existing = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["peer_id=" + host]
        connection = nil
        hide()
        starting = true
        Task {
            defer { starting = false }
            do {
                let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                guard owner == receiver.recipientOwner else { return }
                guard !existing.contains(app.processIdentifier), !app.isTerminated else {
                    receiver.reportSend("Parsec reused an existing session. Use the recipient row to send files.")
                    return
                }
                connection = Connection(app: app, owner: owner, peer: peer)
            } catch { receiver.reportSend("Could not open Parsec. " + error.localizedDescription) }
        }
    }

    private func route(for session: Session) -> Route? {
        guard let connection, !connection.app.isTerminated, connection.owner == receiver.recipientOwner,
              connection.app.processIdentifier == session.process, connection.app.launchDate == session.launched,
              let peer = (receiver.recipients + receiver.people + receiver.directoryRecipients)
                .first(where: { $0.peer == connection.peer.peer && !receiver.isArchived($0) }) else { return nil }
        return Route(session: session, computer: "Parsec connection", owner: connection.owner, peer: peer)
    }

    func beginPointerPress() {
        guard connection?.app.isTerminated == false else { return }
        let point = NSEvent.mouseLocation
        idlePoint = point
        startPoint = point
        // The same screen coordinates can belong to Finder before a Space switch
        // and to fullscreen Parsec after it. Track the source process.
        sourceProcess = window(at: point)?.0.process
        candidate = nil
        hide()
        start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        shown = nil
        connection = nil
        panel.orderOut(nil)
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func tick() {
        let now = Date()
        let point = NSEvent.mouseLocation
        guard NSEvent.pressedMouseButtons & 1 == 1 else {
            idlePoint = point
            startPoint = nil
            sourceProcess = nil
            candidate = nil
            if now.timeIntervalSince(lastPressed) > 0.3 {
                hide()
                timer?.invalidate()
                timer = nil
            }
            return
        }
        lastPressed = now
        if startPoint == nil { startPoint = idlePoint ?? point }
        guard let startPoint, hypot(point.x - startPoint.x, point.y - startPoint.y) >= 20,
              NSApp.modalWindow == nil, receiver.connected, !receiver.sending,
              let (session, bounds) = window(at: point),
              let route = route(for: session), sourceProcess != session.process else {
            candidate = nil
            hide()
            return
        }
        if shown?.session == session, panel.frame.contains(point) { return }
        hide()
        if candidate != session { candidate = session; hoverSince = now; return }
        guard now.timeIntervalSince(hoverSince) >= 0.24 else { return }
        shown = route
        target.label.stringValue = "Send to " + receiver.recipientLabel(route.peer)
        target.computer.stringValue = route.computer + " · Blip"
        let area = NSScreen.screens.first { $0.frame.contains(point) }?.frame ?? bounds
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: max(area.minX, min(area.maxX - size.width, point.x - size.width / 2)),
                                    y: max(area.minY, min(area.maxY - size.height, point.y - size.height / 2))))
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard shown != nil else { return }
        shown = nil
        panel.orderOut(nil)
    }

    private func canSend() -> Bool {
        guard let shown, receiver.connected, !receiver.sending, shown.owner == receiver.recipientOwner,
              let (actual, _) = window(at: NSEvent.mouseLocation) else { return false }
        return shown.session == actual && route(for: actual)?.peer.peer == shown.peer.peer
    }

    private func send(_ candidates: [URL]) -> Bool {
        guard canSend(), let route = shown, let urls = FileDropInput.localFiles(candidates) else { return false }
        hide()
        receiver.send(.forFiles(urls), to: route.peer)
        return true
    }

    private func window(at point: CGPoint) -> (Session, CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
        for row in list {
            guard let layer = row[kCGWindowLayer as String] as? Int, layer >= 0,
                  let id = row[kCGWindowNumber as String] as? CGWindowID, Int(id) != panel.windowNumber,
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                  let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { continue }
            let frame = CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
            guard frame.contains(point) else { continue }
            // Fullscreen surfaces can sit above the normal window layer.
            if layer > 0 {
                guard let screen, frame.contains(screen.frame.insetBy(dx: 10, dy: 10)) else { continue }
            }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  ["parsec", "parsecd"].contains(app.executableURL?.lastPathComponent.lowercased() ?? ""),
                  app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == "parsec" else { return nil }
            let title = (row[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (Session(window: id, process: pid, launched: app.launchDate, title: title), frame)
        }
        return nil
    }
}

@MainActor private final class ParsecDropView: NSView {
    let label = NSTextField(labelWithString: "")
    let computer = NSTextField(labelWithString: "")
    var canDrop: () -> Bool = { false }
    var receive: ([URL]) -> Bool = { _ in false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        computer.font = .systemFont(ofSize: 11)
        computer.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, computer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canDrop() && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return receive(urls)
    }
}
