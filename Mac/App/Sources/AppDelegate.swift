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
    private let popover = NSPopover()
    private var fullWindow: NSWindow?
    private lazy var blipNotice=BlipReceiveNotice(receiver:appState.blip,openTransfers:{[weak self] in self?.showPopover(view:.transfers)},anchor:{[weak self] in guard let button=self?.statusItem?.button,let window=button.window else{return nil};return window.convertToScreen(button.convert(button.bounds,to:nil))})
    private var timer: Timer?
    private let networkMonitor = NWPathMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            if self.popover.isShown { return true }
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
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        blipNotice.panel.appearance = appearance
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = Self.makeStatusItem()
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addSubview(StatusFileDropView(button: button) { [weak self] urls in
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
            if popover.isShown {
                popover.performClose(nil)
            } else {
                showPopover()
            }
            return
        }
        popover.performClose(nil)
        showStatusMenu()
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let titles: [(String, Selector?)] = [
            ("Open myDrive \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")", #selector(menuOpen(_:))),
            ("Sync", #selector(menuSync(_:))),
            (PopupViewKind.connections.label, #selector(menuConnections(_:))),
            (PopupViewKind.transfers.label, #selector(menuTransfers(_:))),
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
        popover.behavior = .transient
        popover.delegate = self
        let root = PopupRootView().environmentObject(appState)
        popover.contentViewController = NSHostingController(rootView: root)
    }

    func showPopover(view target: PopupViewKind? = nil) {
        if let target { appState.view = target }
        guard let button = statusItem?.button else { return }
        if popover.isShown { return }
        // An accessory app is not active by default; without activation the
        // transient popover closes immediately after showing.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        refreshWindowAppearance()
        appState.popoverVisible = true
        appState.checkForAppUpdate(onOpen: true)
        if appState.view == .connections { SmbMonitor.shared.checkNow("view") }
        Task { await appState.refreshIfStale() }
    }

    func popoverDidClose(_ notification: Notification) {
        appState.popoverVisible = false
    }

    // MARK: - Popover dismissal

    /// A transient popover shown by an accessory app can miss outside clicks
    /// once the app has been activated, so menu bar apps watch for them
    /// explicitly. A global monitor covers clicks in other apps; a local
    /// monitor covers our own windows (full window, other panels) without
    /// swallowing clicks inside the popover or on the status item itself.
    private func installPopoverDismissMonitors() {
        eventMonitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown, NSApp.modalWindow == nil else { return }
            self.popover.performClose(nil)
        })
        eventMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown, NSApp.modalWindow == nil else { return event }
            if let window = event.window,
               window !== self.popover.contentViewController?.view.window,
               window !== self.statusItem?.button?.window {
                self.popover.performClose(nil)
            }
            return event
        })
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
            if let id=notification.object as? String {self?.blipNotice.show(id)}
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: NSApp, queue: .main) { [weak self] _ in
            guard let self, self.popover.isShown, NSApp.modalWindow == nil else { return }
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
