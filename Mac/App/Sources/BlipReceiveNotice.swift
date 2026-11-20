import AppKit
import SwiftUI

@MainActor final class BlipReceiveNotice:NSObject,NSWindowDelegate {
    private let receiver:BlipReceiver
    let panel:NSPanel
    private var id=""
    private var dismissed=Set<String>()
    private var expiry:Timer?
    private let openTransfers:()->Void
    private let anchor:()->NSRect?
    init(receiver:BlipReceiver,openTransfers:@escaping ()->Void,anchor:@escaping ()->NSRect?) {
        self.anchor=anchor
        self.receiver=receiver;self.openTransfers=openTransfers
        panel=NSPanel(contentRect:NSRect(x:0,y:0,width:352,height:340),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init();panel.title="myDrive · Incoming transfer";panel.level = .floating;panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false;panel.delegate=self
        panel.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
    }
    func show(_ id:String) {
        guard !dismissed.contains(id),let transfer=receiver.transfers.first(where:{$0.id==id}) else {return}
        self.id=id;expiry?.invalidate()
        panel.contentView=NSHostingView(rootView:BlipReceiveNoticeView(receiver:receiver,id:id,openTransfers:openTransfers).onHover{[weak self] inside in self?.updateExpiry(hovered:inside)})
        if !panel.isVisible {
            let icon=anchor(),screen=icon.flatMap{rect in NSScreen.screens.first{$0.frame.intersects(rect)}} ?? NSScreen.main
            if let screen {let frame=screen.visibleFrame,x=(icon?.maxX ?? frame.maxX)-panel.frame.width,y=(icon?.minY ?? frame.maxY)-panel.frame.height-8;panel.setFrameOrigin(NSPoint(x:min(max(x,frame.minX+8),frame.maxX-panel.frame.width-8),y:min(max(y,frame.minY+8),frame.maxY-panel.frame.height-8)))}
        }
        panel.orderFrontRegardless()
        updateExpiry(hovered:false)
    }
    private func updateExpiry(hovered:Bool){expiry?.invalidate();guard !hovered,let transfer=receiver.transfers.first(where:{$0.id==id}),transfer.confirmed||transfer.has_error||transfer.status=="Cancelled" else{return};expiry=Timer.scheduledTimer(withTimeInterval:30,repeats:false){[weak self]_ in Task{@MainActor in self?.panel.orderOut(nil)}}}
    func windowShouldClose(_ sender:NSWindow)->Bool {dismissed.insert(id);expiry?.invalidate();panel.orderOut(nil);return false}
    func stop(){expiry?.invalidate();panel.orderOut(nil)}
}

struct BlipReceiveNoticeView:View {
    @ObservedObject var receiver:BlipReceiver
    let id:String
    let openTransfers:()->Void
    var fixturePreview:BlipFilePreview?=nil
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:8) {
            if let transfer=receiver.transfers.first(where:{$0.id==id}) {
                HStack(spacing:8) {
                    Text(receiver.senderLabel(transfer.peer)).font(.system(size:13,weight:.semibold)).lineLimit(1).truncationMode(.middle).help(transfer.peer)
                    Spacer(minLength:0)
                    Text(transfer.has_error ? "Needs attention" : transfer.confirmed ? "Received" : receiver.receiving.contains(transfer.id) ? "Requesting…" : transfer.status=="Pending" ? "Connecting" : transfer.status).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal:true,vertical:false)
                }
                BlipReceivedFileView(transfer:transfer,fixturePreview:fixturePreview).id(transfer.id)
                if transfer.pending,let problem=receiver.problem {Text(problem).font(.system(size:11)).foregroundStyle(.red)}
                if transfer.status=="Active" {
                    if let total=transfer.total_bytes,total>0,let progress=transfer.progress,progress>=0,progress<=total {
                        ProgressView(value:Double(progress),total:Double(total));Text("\(Int(100*Double(progress)/Double(total)))% received").font(.system(size:11))
                    }else{ProgressView().controlSize(.small)}
                }
                HStack {
                    if transfer.pending && !receiver.receiving.contains(transfer.id) {Button("Receive"){receiver.receive(transfer)}}
                    Button(PopupViewKind.transfers.label,action:openTransfers)
                }.controlSize(.small)
            } else {Text("Open Send & Receive for the current status.").font(.system(size:12));Button(PopupViewKind.transfers.label,action:openTransfers)}
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading)}.background(Color(nsColor:.windowBackgroundColor))
    }
}
