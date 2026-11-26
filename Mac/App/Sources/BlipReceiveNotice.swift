import AppKit
import SwiftUI

private struct ReceiveNoticeHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor final class BlipReceiveNotice: NSObject, NSPopoverDelegate {
    static let width: CGFloat = 308
    private let receiver: BlipReceiver
    private let popover = NSPopover()
    private let openTransfers: () -> Void
    private var id = ""
    private var dismissed = Set<String>()
    private var expiry: Timer?
    var appearance: NSAppearance? { didSet { popover.appearance = appearance } }
    var isShown: Bool { popover.isShown }

    init(receiver: BlipReceiver, openTransfers: @escaping () -> Void) {
        self.receiver = receiver
        self.openTransfers = openTransfers
        super.init()
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: Self.width, height: 112)
        popover.delegate = self
    }

    func canShow(_ id: String) -> Bool {
        !dismissed.contains(id) && receiver.transfers.contains(where: { $0.id == id })
    }

    func show(_ id: String, at anchor: NSView) {
        guard canShow(id) else { return }
        if self.id != id || !popover.isShown {
            self.id = id
            let view = BlipReceiveNoticeView(
                receiver: receiver, id: id,
                openTransfers: { [weak self] in self?.dismiss(); self?.openTransfers() },
                onDismiss: { [weak self] in
                    if self?.id == id { self?.dismiss() }
                },
                onActionError: { [weak receiver] in receiver?.problem = $0 }
            )
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
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
            .onHover { [weak self] inside in self?.updateExpiry(hovered: inside) }
            let controller = NSHostingController(rootView: view)
            popover.contentViewController = controller
            sizeToContent(controller.view.fittingSize.height)
        }
        if !popover.isShown {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        updateExpiry(hovered: false)
    }

    private func sizeToContent(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(popover.contentSize.height - height) >= 1 else { return }
        popover.contentSize = NSSize(width: Self.width, height: ceil(height))
    }

    private func updateExpiry(hovered: Bool) {
        expiry?.invalidate()
        guard !hovered, let transfer = receiver.transfers.first(where: { $0.id == id }),
              transfer.confirmed || transfer.has_error || transfer.status == "Cancelled" else { return }
        let noticeID = id
        expiry = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                if self?.id == noticeID { self?.dismiss() }
            }
        }
    }

    func dismiss() {
        if !id.isEmpty { dismissed.insert(id) }
        expiry?.invalidate()
        expiry = nil
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        expiry?.invalidate()
        expiry = nil
        id = ""
    }
}

struct BlipReceiveNoticeView: View {
    @ObservedObject var receiver:BlipReceiver
    let id:String
    let openTransfers:()->Void
    var fixturePreview:BlipFilePreview?=nil
    var onDismiss: () -> Void = {}
    var onActionError: (String) -> Void = { _ in }
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            if let transfer=receiver.transfers.first(where:{$0.id==id}) {
                HStack(spacing:8) {
                    Text(receiver.senderLabel(transfer.peer)).font(.system(size:13,weight:.semibold)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength:0)
                    let copied = receiver.autoCopiedTextID == id
                    Text(copied ? "Copied" : statusText(transfer))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss transfer")
                }
                BlipReceivedFileView(transfer: transfer, fixturePreview: fixturePreview, onAction: onDismiss, onActionError: onActionError).id(transfer.id)
                if transfer.pending,let problem=receiver.problem {Text(problem).font(.system(size:11)).foregroundStyle(.red).lineLimit(3)}
                if transfer.status=="Active" {
                    if let total=transfer.total_bytes,total>0,let progress=transfer.progress,progress>=0,progress<=total {
                        ProgressView(value:Double(progress),total:Double(total));Text("\(Int(100*Double(progress)/Double(total)))% received").font(.system(size:11))
                    }else{ProgressView().controlSize(.small)}
                }
                if !transfer.confirmed {
                    HStack {
                    if transfer.pending && !receiver.receiving.contains(transfer.id) {Button("Receive"){receiver.receive(transfer)}}
                    Button("Show in Blip",action:openTransfers)
                    }.controlSize(.small)
                }
            } else {Text("Open the Blip tab for the current status.").font(.system(size:12));Button(PopupViewKind.transfers.label,action:openTransfers)}
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ transfer: BlipTransfer) -> String {
        if transfer.has_error { return "Needs attention" }
        if transfer.confirmed { return "Received" }
        if receiver.receiving.contains(transfer.id) { return "Requesting…" }
        return transfer.status == "Pending" ? "Connecting" : transfer.status
    }
}
