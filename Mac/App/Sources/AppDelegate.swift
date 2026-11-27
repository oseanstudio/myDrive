// App shell: status item with compact popover, optional full window, timers,
// wake/mount notifications, and second-launch activation.
import AppKit
import Combine
import Network
import SwiftUI

extension Notification.Name {
    static let myDriveShow = Notification.Name("io.mydrive.show")
    static let myDriveAppearance = Notification.Name("io.mydrive.appearance")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private lazy var parsecDrop = ParsecDrop(receiver: appState.blip)
    private let popover = NSPopover()
    private var fullWindow: NSWindow?
    private lazy var blipNotice = BlipReceiveNotice(receiver: appState.blip) { [weak self] in
        self?.showPopover(view: .transfers)
    }
    private var timer: Timer?
    private let networkMonitor = NWPathMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitors: [Any] = []
    private var outsidePress: (point: NSPoint, button: Int, dragged: Bool)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.blip.connectParsec = { [weak self] peer, edit in
            self?.parsecDrop.connect(peer, edit: edit)
        }
        SingleInstance.install { [weak self] in self?.showPopover() }
        setupStatusItem()
        setupPopover()
        setupNotifications()
        networkMonitor.pathUpdateHandler = { _ in
            Task { @MainActor in SmbMonitor.shared.checkNow("network") }
        }
        networkMonitor.start(queue: .main)
        installPopoverDismissMonitors()
        refreshWindowAppearance()
        appState.updateWindowIsVisible = { [weak self] in
            guard let self else { return true }
            if self.popover.isShown || self.blipNotice.isShown { return true }
            return self.fullWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false
        }
        appState.startup()

        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.appState.tick()
        }

        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusTooltip() }
            }
            .store(in: &cancellables)
        updateStatusTooltip()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc(sendWithMyDrive:userData:error:)
    func sendWithMyDrive(_ pasteboard: NSPasteboard, userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty {
            let paths = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] ?? []
            urls = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty, urls.count <= 256 else {
            error?.pointee = "Choose up to 256 files or folders to send with myDrive."
            return
        }
        var seen = Set<URL>()
        let selection = urls.map(\.standardizedFileURL).filter { url in
            url.isFileURL && url.path.hasPrefix("/") && seen.insert(url).inserted &&
                FileManager.default.fileExists(atPath: url.path)
        }
        guard !selection.isEmpty else {
            error?.pointee = "Choose an available file or folder to send with myDrive."
            return
        }
        Task { @MainActor in
            showPopover(view: .transfers)
            appState.blip.sendDropped(selection)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        parsecDrop.stop()
        blipNotice.dismiss()
        timer?.invalidate()
        networkMonitor.cancel()
        SmbMonitor.shared.stop()
        appState.shutdown()
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
        SingleInstance.release()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState.stoppingUpdateChecks = true
        guard appState.hasPreparedUpdate else { return .terminateNow }
        Task {
            await appState.discardPreparedUpdate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // The Light/Dark preference applies to the app's own windows only. It must
    // never touch NSApp.appearance: that would restyle the status item, which
    // has to keep following the real menu bar's appearance on its own.
    static func applyAppearance(_ value: String) {
        NotificationCenter.default.post(name: .myDriveAppearance, object: nil,
                                        userInfo: ["value": value])
    }

    static func appearance(for preference: String) -> NSAppearance? {
        switch preference {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    private func refreshWindowAppearance() {
        let appearance = AppDelegate.appearance(for: PrefStore.shared.preferences.appearance)
        fullWindow?.appearance = appearance
        if let window = popover.contentViewController?.view.window, window !== statusItem?.button?.window {
            window.appearance = appearance
        }
        blipNotice.appearance = appearance
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = Self.makeStatusItem()
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addSubview(StatusFileDropView(button: button, showMenu: { [weak self] in
                self?.showPopover(view: .transfers, activate: false)
            }) { [weak self] urls in
                guard let self else { return }
                self.showPopover()
                self.appState.handleFileDrop(urls)
            })
        }
        statusItem = item
    }

    static func makeStatusItem(persistPosition: Bool = true) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if persistPosition { item.autosaveName = "net.oseanstudio.myDrive" }
        if let button = item.button {
            button.image = statusImage
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("myDrive")
        }
        return item
    }

    static let statusImage: NSImage? = {
        let image = Bundle.main.url(forResource: "StatusMark", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "myDrive")
        image?.size = NSSize(width: 20, height: 18)
        image?.isTemplate = true
        image?.accessibilityDescription = "myDrive"
        return image
    }()

    static func setStatusTooltip(_ button: NSStatusBarButton, attentionCount: Int) {
        let tooltip = switch attentionCount {
        case 0: "myDrive"
        case 1: "myDrive · 1 item needs attention"
        default: "myDrive · \(attentionCount) items need attention"
        }
        if button.toolTip != tooltip {
            button.toolTip = tooltip
            button.setAccessibilityHelp(tooltip)
        }
    }

    private func updateStatusTooltip() {
        if let button = statusItem?.button {
            Self.setStatusTooltip(button, attentionCount: appState.attentionCount)
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp else {
            if blipNotice.isShown {
                blipNotice.dismiss(showNext: true)
            } else if popover.isShown {
                popover.performClose(nil)
            } else {
                showPopover()
            }
            return
        }
        blipNotice.dismiss()
        popover.performClose(nil)
        showStatusMenu()
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let titles: [(String, Selector?)] = [
            ("Open myDrive \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")", #selector(menuOpen(_:))),
            (PopupViewKind.transfers.label, #selector(menuTransfers(_:))),
            (PopupViewKind.sync.label, #selector(menuSync(_:))),
            (PopupViewKind.connections.label, #selector(menuConnections(_:))),
            ("Activity", #selector(menuActivity(_:))),
            ("Settings", #selector(menuSettings(_:))),
            ("Open full window", #selector(menuExpand(_:))),
            ("Quit myDrive", #selector(menuQuit(_:))),
        ]
        for (index, pair) in titles.enumerated() {
            if index == 5 { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: pair.0, action: pair.1, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuOpen(_ sender: NSMenuItem) { showPopover() }
    @objc private func menuSync(_ sender: NSMenuItem) { showPopover(view: .sync) }
    @objc private func menuConnections(_ sender: NSMenuItem) { showPopover(view: .connections) }
    @objc private func menuTransfers(_ sender: NSMenuItem) { showPopover(view: .transfers) }
    @objc private func menuActivity(_ sender: NSMenuItem) { showPopover(view: .activity) }
    @objc private func menuSettings(_ sender: NSMenuItem) { showPopover(view: .settings) }
    @objc private func menuQuit(_ sender: NSMenuItem) { NSApp.terminate(nil) }

    @objc private func menuExpand(_ sender: NSMenuItem) {
        popover.performClose(nil)
        openFullWindow()
    }

    // MARK: - Popover

    private func setupPopover() {
        popover.contentSize = NSSize(width: PopupMetrics.width, height: PopupMetrics.maxHeight)
        popover.behavior = .applicationDefined
        popover.delegate = self
        let root = PopupRootView().environmentObject(appState)
        popover.contentViewController = NSHostingController(rootView: root)
    }

    func showPopover(view target: PopupViewKind? = nil, activate: Bool = true) {
        if let target { appState.view = target }
        guard let button = statusItem?.button else { return }
        blipNotice.dismiss()
        if popover.isShown { return }
        if target == nil, appState.busy == nil, appState.dialog == nil, fullWindow?.isVisible != true {
            appState.view = .transfers
        }
        // An accessory app is not active by default; without activation the
        // transient popover closes immediately after showing.
        if activate { NSApp.activate(ignoringOtherApps: true) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate { popover.contentViewController?.view.window?.makeKey() }
        refreshWindowAppearance()
        appState.popoverVisible = true
        appState.checkForAppUpdate(onOpen: true)
        if appState.view == .connections { SmbMonitor.shared.checkNow("view") }
        Task { await appState.refreshIfStale() }
    }

    func popoverDidClose(_ notification: Notification) {
        appState.popoverVisible = false
        outsidePress = nil
    }

    // MARK: - Popover dismissal

    /// A mouse-down in Finder may be the start of a drag into the popover.
    /// Dismiss only after a matching outside click, once movement is known.
    private func installPopoverDismissMonitors() {
        let clickEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                  .leftMouseUp, .rightMouseUp, .otherMouseUp,
                                                  .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clickEvents, handler: { [weak self] event in
            self?.observePopoverClick(event, isLocal: false)
        }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clickEvents.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if (event.window === self.popover.contentViewController?.view.window || event.window === self.fullWindow),
                   let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor,
                   let action = Self.textEditAction(for: event), NSApp.sendAction(action, to: editor, from: nil) {
                    return nil
                }
                if event.keyCode == 53, self.popover.isShown, NSApp.modalWindow == nil,
                   event.window === self.popover.contentViewController?.view.window {
                    self.popover.performClose(nil)
                    return nil
                }
            } else {
                self.observePopoverClick(event, isLocal: true)
            }
            return event
        }) { eventMonitors.append(monitor) }
    }

    static func textEditAction(for event: NSEvent) -> Selector? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": return #selector(NSText.selectAll(_:))
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        default: return nil
        }
    }

    private func observePopoverClick(_ event: NSEvent, isLocal: Bool) {
        if event.type == .leftMouseDown { parsecDrop.beginPointerPress() }
        guard popover.isShown, NSApp.modalWindow == nil else { outsidePress = nil; return }
        let point = NSEvent.mouseLocation
        let inside = isLocal && (event.window === popover.contentViewController?.view.window ||
                                event.window === statusItem?.button?.window)
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            outsidePress = inside ? nil : (point, event.buttonNumber, false)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if let press = outsidePress, press.button == event.buttonNumber,
               hypot(point.x - press.point.x, point.y - press.point.y) >= 6 {
                outsidePress?.dragged = true
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let press = outsidePress, press.button == event.buttonNumber else { return }
            outsidePress = nil
            if !inside, !press.dragged, hypot(point.x - press.point.x, point.y - press.point.y) < 6 {
                popover.performClose(nil)
            }
        default: break
        }
    }

    // MARK: - Full window

    private func openFullWindow() {
        if fullWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "myDrive"
            window.isReleasedWhenClosed = false
            window.center()
            let root = PopupRootView(fullWindow: true).environmentObject(appState)
            window.contentView = NSHostingView(rootView: root)
            fullWindow = window
        }
        refreshWindowAppearance()
        fullWindow?.makeKeyAndOrderFront(nil)
        appState.checkForAppUpdate(onOpen: true)
        if appState.view == .connections { SmbMonitor.shared.checkNow("view") }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - System notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(forName: .myDriveIncomingBlip, object: nil, queue: .main) { [weak self] notification in
            guard let id = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self, self.blipNotice.canShow(id) else { return }
                self.popover.close()
                self.blipNotice.show(id)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] notification in
            guard let self, self.popover.isShown, self.appState.dialog == nil,
                  let window = notification.object as? NSWindow,
                  window !== self.popover.contentViewController?.view.window,
                  window !== self.statusItem?.button?.window else { return }
            self.popover.performClose(nil)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: NSApp, queue: .main) { [weak self] _ in
            guard let self, self.popover.isShown, NSApp.modalWindow == nil,
                  NSEvent.pressedMouseButtons == 0, self.outsidePress == nil else { return }
            self.popover.performClose(nil)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        // AppKit renders the same template for each menu bar's appearance.
        // Invalidate the button when the system reconfigures its display hosts.
        workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                    queue: .main) { [weak self] _ in self?.statusItem?.button?.needsDisplay = true }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: NSApp, queue: .main) { [weak self] _ in
            self?.statusItem?.button?.needsDisplay = true
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                    queue: .main) { [weak self] _ in
            SmbMonitor.shared.checkNow("wake")
            self?.appState.tick()
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil,
                                    queue: .main) { _ in SmbMonitor.shared.checkNow() }
        workspaceCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil,
                                    queue: .main) { _ in SmbMonitor.shared.checkNow() }
        DistributedNotificationCenter.default().addObserver(
            forName: .myDriveShow, object: nil, queue: .main) { [weak self] _ in
            self?.showPopover()
        }
        NotificationCenter.default.addObserver(forName: .myDriveExpand, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.popover.performClose(nil)
            self?.openFullWindow()
        }
        NotificationCenter.default.addObserver(forName: .myDriveCompact, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.fullWindow?.performClose(nil)
            self?.showPopover()
        }
        NotificationCenter.default.addObserver(forName: .myDriveAppearance, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refreshWindowAppearance()
        }
    }
}

/// Second-launch activation: a pid lock file plus a distributed notification.
enum SingleInstance {
    static var lockPath = Paths.dataDir.appendingPathComponent("instance.lock").path
    private static var holding = false

    static func install(activate: @escaping () -> Void) {
        if FileManager.default.fileExists(atPath: lockPath) {
            let contents = (try? String(contentsOfFile: lockPath, encoding: .utf8)) ?? ""
            if let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
                // An existing copy is running; ask it to come forward, then exit.
                DistributedNotificationCenter.default()
                    .postNotificationName(.myDriveShow, object: nil, userInfo: nil,
                                          deliverImmediately: true)
                exit(0)
            }
            try? FileManager.default.removeItem(atPath: lockPath)
        }
        let created = FileManager.default.createFile(
            atPath: lockPath,
            contents: "\(getpid())\n".data(using: .utf8),
            attributes: [.posixPermissions: 0o644])
        holding = created
        if !created {
            // Another process created the lock first; let it win.
            DistributedNotificationCenter.default()
                .postNotificationName(.myDriveShow, object: nil, userInfo: nil,
                                      deliverImmediately: true)
            exit(0)
        }
        _ = activate
    }

    static func release() {
        if holding { try? FileManager.default.removeItem(atPath: lockPath) }
    }
}
