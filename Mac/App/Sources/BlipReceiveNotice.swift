import AppKit
import SwiftUI

private struct ReceiveNoticeHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private final class BlipNoticePanel: NSPanel {
    var onInteraction: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown: onInteraction?()
        default: break
        }
        super.sendEvent(event)
    }
}

@MainActor final class BlipReceiveNotice {
    static let width: CGFloat = 324
    private let receiver: BlipReceiver
    private let panel = BlipNoticePanel(
        contentRect: NSRect(x: 0, y: 0, width: BlipReceiveNotice.width, height: 112),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    private let openTransfers: (String) -> Void
    private var id = ""
    private var dismissed = Set<String>()
    private var waiting: [String] = []
    private var pointerTimer: Timer?
    private var contentHeight: CGFloat = 112
    var appearance: NSAppearance? { didSet { panel.appearance = appearance } }
    var isShown: Bool { panel.isVisible }

    init(receiver: BlipReceiver, openTransfers: @escaping (String) -> Void) {
        self.receiver = receiver
        self.openTransfers = openTransfers
        panel.title = "Incoming Blip transfer"
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        panel.onInteraction = { [weak self] in self?.stopFollowingPointer() }
    }

    func canShow(_ id: String) -> Bool {
        !dismissed.contains(id) && receiver.transfers.contains(where: { $0.id == id })
    }

    func show(_ id: String) {
        guard canShow(id) else { return }
        if isShown {
            if self.id != id, !waiting.contains(id) { waiting.append(id) }
            return
        }
        waiting.removeAll { $0 == id || !canShow($0) }
        self.id = id
        let view = BlipReceiveNoticeView(
            receiver: receiver, id: id,
            openTransfers: { [weak self] in self?.hideForInline(); self?.openTransfers(id) },
            onDismiss: { [weak self] in
                if self?.id == id { self?.dismiss(showNext: true) }
            },
            onActionError: { [weak receiver] in receiver?.problem = $0 }
        )
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ReceiveNoticeHeight.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(ReceiveNoticeHeight.self) { [weak self] height in
            Task { @MainActor [weak self] in
                if self?.id == id { self?.sizeToContent(height) }
            }
        }
        let controller = NSHostingController(rootView: view)
        panel.contentViewController = controller
        contentHeight = ceil(max(60, controller.view.fittingSize.height))
        place(height: contentHeight, following: true)
        panel.orderFrontRegardless()
        // Only sample the pointer while a notice is waiting for interaction.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pointerTimer != nil, self.isShown else { return }
                self.place(height: self.contentHeight, following: true)
            }
        }
        timer.tolerance = 0.05
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func place(height: CGFloat, following: Bool) {
        let pointer = NSEvent.mouseLocation
        let screen = following ? NSScreen.screens.first(where: { $0.frame.contains(pointer) }) : panel.screen
        guard let bounds = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = Self.noticeFrame(in: bounds, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    static func noticeFrame(in bounds: NSRect, height: CGFloat) -> NSRect {
        let inset: CGFloat = 12
        let width = min(Self.width, max(1, bounds.width - 2 * inset))
        let height = min(height, max(1, bounds.height - 2 * inset))
        return NSRect(x: bounds.maxX - width - inset, y: bounds.maxY - height - inset, width: width, height: height)
    }

    private func sizeToContent(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        contentHeight = ceil(height)
        place(height: contentHeight, following: pointerTimer != nil)
    }

    private func stopFollowingPointer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    @discardableResult
    func hideForInline() -> String? {
        guard isShown, !id.isEmpty else { return nil }
        let visible = id
        id = ""
        stopFollowingPointer()
        panel.orderOut(nil)
        panel.contentViewController = nil
        return visible
    }

    func dismiss(showNext: Bool = false) {
        if !id.isEmpty { dismissed.insert(id) }
        id = ""
        stopFollowingPointer()
        panel.orderOut(nil)
        panel.contentViewController = nil
        if showNext {
            while let next = waiting.first {
                waiting.removeFirst()
                if canShow(next) { show(next); break }
            }
        }
    }
}

struct BlipReceiveNoticeView: View {
    @ObservedObject var receiver:BlipReceiver
    let id:String
    let openTransfers:()->Void
    var fixturePreview:BlipFilePreview?=nil
    var onDismiss: () -> Void = {}
    var onActionError: (String) -> Void = { _ in }
    var showingDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let transfer = receiver.transfers.first(where: { $0.id == id }) {
                if transfer.confirmed {
                    BlipReceivedFileView(transfer: transfer, header: identity(transfer), fixturePreview: fixturePreview,
                                         onAction: onDismiss, onActionError: onActionError)
                        .id(transfer.id)
                } else {
                    identity(transfer)
                    Text((transfer.item_names ?? []).joined(separator: ", "))
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if transfer.has_error {
                        Text(transfer.failureLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if let problem = receiver.problem, transfer.pending {
                        Text(problem).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
                    }
                    BlipReceiveProgress(transfer: transfer, starting: receiver.receiving.contains(transfer.id) && transfer.pending)
                    HStack {
                        if transfer.pending && !receiver.receiving.contains(transfer.id) {
                            Button("Receive") { receiver.receive(transfer) }
                        }
                        if !showingDetails { Button("Show in Blip", action: openTransfers) }
                    }.controlSize(.small)
                }
            } else {
                Button(PopupViewKind.transfers.label, action: openTransfers)
            }
        }
        .padding(receiver.transfers.contains(where: { $0.id == id && $0.confirmed }) ? 4 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identity(_ transfer: BlipTransfer) -> some View {
        HStack(spacing: 7) {
            Text(receiver.senderLabel(transfer.peer))
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(receiver.autoCopiedTransferID == id ? "Copied" : statusText(transfer))
                .font(.system(size: 11, weight: .medium))
                .opacity(0.84).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Dismiss transfer")
        }
    }

    private func statusText(_ transfer: BlipTransfer) -> String {
        if transfer.has_error { return "Needs attention" }
        if transfer.confirmed { return "Received" }
        if receiver.receiving.contains(transfer.id) { return "Requesting…" }
        return transfer.status == "Pending" ? "Connecting" : transfer.status
    }
}

struct BlipReceiveProgress: View {
    let transfer: BlipTransfer
    var starting = false

    var body: some View {
        let moving = transfer.receivingBytes || starting
        let stopped = transfer.has_error || transfer.status == "Cancelled"
        let total = transfer.total_bytes ?? 0
        let bytes = max(0, transfer.progress ?? 0)
        if moving || transfer.has_error || stopped && (total > 0 || bytes > 0) {
            VStack(alignment: .leading, spacing: 3) {
                if total > 0 {
                    ProgressView(value: Double(min(bytes, total)), total: Double(total))
                        .accessibilityLabel("Incoming Blip transfer progress")
                } else if moving && transfer.status != "Paused" {
                    ProgressView().progressViewStyle(.linear).accessibilityLabel("Receiving Blip data")
                }
                Text(transfer.byteLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
