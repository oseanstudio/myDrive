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
    private var routes: [CGWindowID: Route] = [:]
    private var timer: Timer?
    private var idlePoint: CGPoint?
    private var startPoint: CGPoint?
    private var candidate: Session?
    private var hoverSince = Date.distantFuture
    private var shown: Route?
    private var lastPressed = Date.distantPast

    init(receiver: BlipReceiver) {
        self.receiver = receiver
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = target
        target.canDrop = { [weak self] in self?.canSend() == true }
        target.receive = { [weak self] urls in self?.send(urls) == true }
    }

    func assign(_ peer: BlipPeer) {
        let owner = receiver.recipientOwner
        guard !owner.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Assign a Parsec window"
        alert.informativeText = "Move the pointer over the connected Parsec window after clicking Assign. Files dropped there will be sent to \(receiver.recipientLabel(peer))."
        alert.addButton(withTitle: "Assign in 4 seconds")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        name.placeholderString = "Computer name"
        name.setAccessibilityLabel("Computer name")
        alert.accessoryView = name
        guard BlipReceiver.runSignInPrompt(alert, field: name) == .alertFirstButtonReturn else { return }
        let label = String(name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard owner == receiver.recipientOwner,
                  let (session, _) = window(at: NSEvent.mouseLocation) else {
                receiver.reportSend("Point to an open Parsec window and assign it again.")
                return
            }
            routes[session.window] = Route(session: session, computer: label.isEmpty ? (session.title ?? "Parsec") : label,
                                           owner: owner, peer: peer)
            receiver.reportSend("Parsec window assigned to " + receiver.recipientLabel(peer) + ".")
        }
    }

    func beginPointerPress() {
        guard !routes.isEmpty, timer == nil else { return }
        idlePoint = NSEvent.mouseLocation
        start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        shown = nil
        routes.removeAll()
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
              let route = routes[session.window], route.session == session, route.owner == receiver.recipientOwner,
              !bounds.contains(startPoint) else { candidate = nil; hide(); return }
        if shown?.session == session, panel.frame.contains(point) { return }
        hide()
        if candidate != session { candidate = session; hoverSince = now; return }
        guard now.timeIntervalSince(hoverSince) >= 0.24 else { return }
        shown = route
        target.label.stringValue = "Send to " + receiver.recipientLabel(route.peer)
        target.computer.stringValue = route.computer + " · Blip"
        let area = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? bounds
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
        return shown.session == actual && (receiver.recipients + receiver.people + receiver.directoryRecipients)
            .contains { $0.peer == shown.peer.peer && !receiver.isArchived($0) }
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
        for row in list where (row[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                  let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { continue }
            let frame = CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
            guard frame.contains(point) else { continue }
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
