import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import Quartz
import PDFKit
import ImageIO

enum BlipFileKind {
    static func text(_ url:URL)->Bool{["txt","md","csv","json","xml","log","yaml","yml","ini","css","html","htm","svg","js","ts","cs","swift","py","rs"].contains(url.pathExtension.lowercased())}
    static func image(_ url:URL)->Bool{["png","jpg","jpeg","gif","bmp","webp","tif","tiff","heic","avif"].contains(url.pathExtension.lowercased())}
    static func shortcut(_ url:URL)->Bool{["url","webloc"].contains(url.pathExtension.lowercased())}
    static func textPrefix(_ url:URL)->String? {
        guard let file=try? FileHandle(forReadingFrom:url) else{return nil};defer{try? file.close()}
        guard let data=try? file.read(upToCount:8192) else{return nil}
        let text=(data.starts(with:[0xff,0xfe])||data.starts(with:[0xfe,0xff])) ? String(data:data,encoding:.utf16):String(data:data,encoding:.utf8)
        guard let text,!text.contains("\0") else{return nil};return text.components(separatedBy:.newlines).prefix(6).joined(separator:"\n")
    }
}
struct BlipFilePreview {
    var image:NSImage?=nil
    var text:String?=nil
    static func load(_ url:URL,item:BlipReceivedItem)async->BlipFilePreview {
        if item.is_directory{return BlipFilePreview()}
        if BlipFileKind.shortcut(url){return BlipFilePreview(text:BlipWebLink.read(url.path)?.absoluteString ?? "Web link preview unavailable")}
        if BlipFileKind.text(url){return await Task.detached{BlipFilePreview(text:BlipFileKind.textPrefix(url) ?? "Preview unavailable")}.value}
        if BlipFileKind.image(url) {
            return await Task.detached{
                guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? NSNumber,let height=properties[kCGImagePropertyPixelHeight] as? NSNumber,width.doubleValue*height.doubleValue<=100_000_000,
                      let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{return BlipFilePreview()}
                return BlipFilePreview(image:NSImage(cgImage:image,size:.zero))
            }.value
        }
        if url.pathExtension.lowercased()=="pdf",item.size<100_000_000 {
            return await Task.detached{BlipFilePreview(image:PDFDocument(url:url)?.page(at:0)?.thumbnail(of:NSSize(width:600,height:400),for:.mediaBox))}.value
        }
        guard ["mp4","mov","mkv","docx","pptx","xlsx","pages","numbers","key"].contains(url.pathExtension.lowercased()) else{return BlipFilePreview()}
        let request=QLThumbnailGenerator.Request(fileAt:url,size:CGSize(width:300,height:200),scale:2,representationTypes:.thumbnail)
        let image:NSImage?=await withCheckedContinuation {continuation in
            let reply=BlipThumbnailReply(continuation)
            QLThumbnailGenerator.shared.generateBestRepresentation(for:request){representation,_ in reply.finish(representation?.nsImage)}
            DispatchQueue.global().asyncAfter(deadline:.now()+4){QLThumbnailGenerator.shared.cancel(request);reply.finish(nil)}
        }
        return BlipFilePreview(image:image)
    }
}
private final class BlipThumbnailReply:@unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<NSImage?,Never>?
    init(_ value:CheckedContinuation<NSImage?,Never>){continuation=value}
    func finish(_ image:NSImage?){lock.lock();let value=continuation;continuation=nil;lock.unlock();value?.resume(returning:image)}
}

@MainActor final class BlipQuickLook:NSObject,QLPreviewPanelDataSource {
    static let shared=BlipQuickLook()
    private var urls:[URL]=[]
    func show(_ url:URL){urls=[url];guard let panel=QLPreviewPanel.shared() else{return};panel.dataSource=self;panel.reloadData();panel.makeKeyAndOrderFront(nil)}
    func numberOfPreviewItems(in panel:QLPreviewPanel!)->Int{urls.count}
    func previewPanel(_ panel:QLPreviewPanel!,previewItemAt index:Int)->QLPreviewItem!{urls[index] as NSURL}
}

@MainActor enum BlipFileActions {
    static func url(_ item:BlipReceivedItem,_ transfer:BlipTransfer)throws->URL{guard let url=BlipReceivedPath.url(item,in:transfer) else{throw BlipReceiverError.message("This received file is unavailable or has moved.")};return url}
    static func open(_ item:BlipReceivedItem,_ transfer:BlipTransfer)throws {
        let file=try url(item,transfer),target:URL
        if BlipFileKind.shortcut(file){guard let link=BlipWebLink.read(file.path) else{throw BlipReceiverError.message("This shortcut does not contain a supported web link.")};target=link}else{target=file}
        guard NSWorkspace.shared.open(target) else{throw BlipReceiverError.message("The default app could not open this item.")}
    }
    static func copy(_ items:[BlipReceivedItem],_ transfer:BlipTransfer,paths:Bool=false)throws {
        let urls=try items.prefix(256).map{try url($0,transfer)};let clipboard=NSPasteboard.general
        if paths {clipboard.clearContents();clipboard.setString(urls.map(\.path).joined(separator:"\n"),forType:.string);return}
        let entries=urls.map {url->NSPasteboardItem in
            let entry=NSPasteboardItem();entry.setString(url.absoluteString,forType:.fileURL)
            if urls.count==1 {
                if BlipFileKind.shortcut(url),let link=BlipWebLink.read(url.path){entry.setString(link.absoluteString,forType:.string);entry.setString(link.absoluteString,forType:.URL)}
                let types:[String:NSPasteboard.PasteboardType]=["png":.png,"tiff":.tiff,"tif":.tiff,"jpg":NSPasteboard.PasteboardType("public.jpeg"),"jpeg":NSPasteboard.PasteboardType("public.jpeg")]
                if let type=types[url.pathExtension.lowercased()],let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=32_000_000,let data=try? Data(contentsOf:url,options:.mappedIfSafe){entry.setData(data,forType:type)}
            };return entry
        }
        clipboard.clearContents();guard clipboard.writeObjects(entries) else{throw BlipReceiverError.message("The received item could not be copied.")}
    }
    static func reveal(_ item:BlipReceivedItem,_ transfer:BlipTransfer)throws{NSWorkspace.shared.activateFileViewerSelecting([try url(item,transfer)])}
    static func folder(_ item:BlipReceivedItem,_ transfer:BlipTransfer)throws{let file=try url(item,transfer);guard NSWorkspace.shared.open(item.is_directory ? file:file.deletingLastPathComponent()) else{throw BlipReceiverError.message("The received folder could not open.")}}
    static func openWith(_ app:URL?,item:BlipReceivedItem,transfer:BlipTransfer)throws {
        let file=try url(item,transfer);var chosen=app
        if chosen==nil{let picker=NSOpenPanel();picker.title="Choose application";picker.directoryURL=URL(fileURLWithPath:"/Applications");picker.allowedContentTypes=[.application];picker.canChooseDirectories=false;picker.allowsMultipleSelection=false;guard picker.runModal() == .OK else{return};chosen=picker.url}
        guard let chosen else{return};NSWorkspace.shared.open([file],withApplicationAt:chosen,configuration:NSWorkspace.OpenConfiguration())
    }
}

@MainActor struct BlipReceivedFileView:View {
    let transfer:BlipTransfer
    var fixturePreview:BlipFilePreview?=nil
    @State private var selection=""
    @State private var preview=BlipFilePreview()
    @State private var message=""
    private var items:[BlipReceivedItem]{transfer.direction=="Incoming"&&transfer.confirmed ? Array((transfer.received_items ?? []).prefix(256)).sorted{$0.name<$1.name}:[]}
    private var selected:BlipReceivedItem?{items.first{$0.path==selection} ?? items.first}
    private var file:URL?{selected.flatMap{BlipReceivedPath.url($0,in:transfer)}}
    private func act(success:String="",_ action:()throws->Void){do{try action();message=success}catch{message=error.localizedDescription}}
    private var itemLabel:String{let names=transfer.item_names ?? [];return names.isEmpty ? "Incoming transfer":names.joined(separator:", ")}
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            ZStack {
                RoundedRectangle(cornerRadius:6).fill(Color.secondary.opacity(0.08))
                let content=fixturePreview ?? preview
                if let image=content.image{Image(nsImage:image).resizable().scaledToFit().padding(3)}
                else if let text=content.text{Text(text).font(.system(size:11,design:.monospaced)).lineLimit(6).textSelection(.enabled).padding(8).frame(maxWidth:.infinity,alignment:.leading)}
                else if let file{Image(nsImage:NSWorkspace.shared.icon(forFile:file.path)).resizable().scaledToFit().frame(width:48,height:48)}
                else{Image(systemName:"doc").font(.system(size:32)).foregroundStyle(.secondary)}
            }.frame(height:transfer.confirmed ? 200:80).accessibilityLabel("Received file preview")
            if items.count>1{Picker("Received file",selection:Binding(get:{selected?.path ?? ""},set:{selection=$0})){ForEach(items){Text($0.displayName).tag($0.path)}}.labelsHidden().frame(maxWidth:.infinity)}
            else{Text(selected?.displayName ?? itemLabel).font(.system(size:12)).lineLimit(1).truncationMode(.middle).help(selected?.path ?? "")}
            if transfer.confirmed,let selected {
                HStack(spacing:0){
                    Button("Open"){act{try BlipFileActions.open(selected,transfer)}}
                    Menu {
                        Button("Open"){act{try BlipFileActions.open(selected,transfer)}}
                        Menu("Open With"){
                            if let file{ForEach(NSWorkspace.shared.urlsForApplications(toOpen:file),id:\.self){app in Button(app.deletingPathExtension().lastPathComponent){act{try BlipFileActions.openWith(app,item:selected,transfer:transfer)}}}}
                            Button("Choose Application…"){act{try BlipFileActions.openWith(nil,item:selected,transfer:transfer)}}
                        }.disabled(selected.is_directory||file.map(BlipFileKind.shortcut)==true)
                        Button("Copy"){act(success:"Copied"){try BlipFileActions.copy([selected],transfer)}}
                        Button("Copy Path"){act(success:"Path copied"){try BlipFileActions.copy([selected],transfer,paths:true)}}
                        Divider()
                        Button("Open Folder"){act{try BlipFileActions.folder(selected,transfer)}}
                        Button("Show in Finder"){act{try BlipFileActions.reveal(selected,transfer)}}
                        Button("Quick Look"){if let file{BlipQuickLook.shared.show(file)}}.disabled(file.map(BlipFileKind.shortcut)==true)
                        if items.count>1{Divider();Button("Copy Listed Files"){act{try BlipFileActions.copy(items,transfer)}};Button("Copy Listed Paths"){act{try BlipFileActions.copy(items,transfer,paths:true)}}}
                    }label:{Image(systemName:"chevron.down").font(.system(size:10))}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.horizontal,6).accessibilityLabel("Received file actions")
                    Button("Copy"){act(success:"Copied"){try BlipFileActions.copy([selected],transfer)}}.padding(.leading,6)
                }.controlSize(.small).disabled(file==nil)
                if file==nil{Text("File moved or unavailable").font(.system(size:11)).foregroundStyle(.secondary)}
            }
            if !message.isEmpty{Text(message).font(.system(size:11)).lineLimit(2)}
        }.task(id:transfer.id+":"+String(transfer.confirmed)+":"+(selected?.path ?? "")){
            preview=BlipFilePreview();message="";guard let selected,let file else{return};let result=await BlipFilePreview.load(file,item:selected);guard !Task.isCancelled else{return};preview=result
        }
    }
}
