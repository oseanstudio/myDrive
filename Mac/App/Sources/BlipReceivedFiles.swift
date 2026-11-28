import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import Quartz
import PDFKit
import ImageIO

enum BlipFileKind {
    static func text(_ url:URL)->Bool{["txt","md","csv","json","xml","log","yaml","yml","ini","css","html","htm","svg","js","ts","cs","swift","py","rs"].contains(url.pathExtension.lowercased())}
    static func text(_ item: BlipReceivedItem, at url: URL? = nil) -> Bool {
        !item.is_directory && (text(URL(fileURLWithPath: item.name)) || text(url ?? URL(fileURLWithPath: item.path)))
    }
    static func image(_ url:URL)->Bool{["png","jpg","jpeg","gif","bmp","webp","tif","tiff","heic","avif"].contains(url.pathExtension.lowercased())}
    static func shortcut(_ url:URL)->Bool{["url","webloc"].contains(url.pathExtension.lowercased())}
    static func textPrefix(_ url:URL)->String? {
        guard let file=try? FileHandle(forReadingFrom:url) else{return nil};defer{try? file.close()}
        guard let data=try? file.read(upToCount:8192) else{return nil}
        let text=(data.starts(with:[0xff,0xfe])||data.starts(with:[0xfe,0xff])) ? String(data:data,encoding:.utf16):String(data:data,encoding:.utf8)
        guard let text,!text.contains("\0") else{return nil};return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(12).joined(separator: "\n")
    }

    static func receivedClipboardURL(_ transfer: BlipTransfer) -> URL? {
        guard transfer.item_names == ["Clipboard text.txt"],
              let items = transfer.received_items, items.count == 1, let item = items.first,
              !item.is_directory, let url = BlipReceivedPath.url(item, in: transfer), text(url) else { return nil }
        return url
    }

    static func clipboardText(_ url: URL) throws -> String? {
        let limit = 16 * 1024 * 1024
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data()
        while let chunk = try file.read(upToCount: min(65536, limit + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            if bytes.count > limit { return nil }
        }
        let markers: [([UInt8], String.Encoding)] = [
            ([0xff, 0xfe, 0, 0], .utf32LittleEndian), ([0, 0, 0xfe, 0xff], .utf32BigEndian),
            ([0xff, 0xfe], .utf16LittleEndian), ([0xfe, 0xff], .utf16BigEndian),
            ([0xef, 0xbb, 0xbf], .utf8)
        ]
        let marker = markers.first { bytes.starts(with: $0.0) }
        var encoding = marker?.1 ?? .utf8
        let hasZero = marker == nil && bytes.contains(0)
        if hasZero, bytes.count % 2 == 0 {
            var evenZero = false
            var oddZero = false
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                evenZero = evenZero || bytes[offset] == 0
                oddZero = oddZero || bytes[offset + 1] == 0
                if evenZero && oddZero { break }
            }
            if evenZero != oddZero { encoding = evenZero ? .utf16BigEndian : .utf16LittleEndian }
        }
        var content = String(data: bytes.dropFirst(marker?.0.count ?? 0), encoding: encoding)
        if content == nil, marker == nil, !hasZero { content = String(data: bytes, encoding: .windowsCP1252) }
        guard let content, content.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return value >= 32 && !(127...159).contains(value) || [9, 10, 12, 13].contains(value)
        }) else { return nil }
        return content
    }
}
struct BlipFilePreview {
    var image:NSImage?=nil
    var text:String?=nil
    static func load(_ url:URL,item:BlipReceivedItem)async->BlipFilePreview {
        if item.is_directory{return BlipFilePreview()}
        if BlipFileKind.shortcut(url){return BlipFilePreview(text:BlipWebLink.read(url.path)?.absoluteString ?? "Web link preview unavailable")}
        if BlipFileKind.text(item, at: url){return await Task.detached{BlipFilePreview(text:BlipFileKind.textPrefix(url) ?? "Preview unavailable")}.value}
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
    nonisolated static func url(_ item:BlipReceivedItem,_ transfer:BlipTransfer)throws->URL{guard let url=BlipReceivedPath.url(item,in:transfer) else{throw BlipReceiverError.message("This received file is unavailable or has moved.")};return url}
    static func open(_ item:BlipReceivedItem,_ transfer:BlipTransfer)throws {
        let file=try url(item,transfer),target:URL
        if BlipFileKind.shortcut(file){guard let link=BlipWebLink.read(file.path) else{throw BlipReceiverError.message("This shortcut does not contain a supported web link.")};target=link}else{target=file}
        guard NSWorkspace.shared.open(target) else{throw BlipReceiverError.message("The default app could not open this item.")}
    }
    static func copy(_ items:[BlipReceivedItem],_ transfer:BlipTransfer,paths:Bool=false)throws {
        let urls=try items.prefix(256).map{try url($0,transfer)}
        let clipboard = NSPasteboard.general
        if paths {
            try writeText(urls.map(\.path).joined(separator: "\n"), clipboard: clipboard)
            return
        }
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
    nonisolated static func textForClipboard(_ items: [BlipReceivedItem], transfer: BlipTransfer) async throws -> String? {
        let files = try items.map { try url($0, transfer) }
        guard zip(items, files).allSatisfy({ BlipFileKind.text($0.0, at: $0.1) }) else { return nil }
        return try await Task.detached {
            var parts: [String] = []
            var count = 0
            for file in files {
                guard let text = try BlipFileKind.clipboardText(file), count + text.utf8.count <= 16 * 1024 * 1024 else {
                    throw BlipReceiverError.message("This text could not be copied. Use Copy File to keep it as an attachment.")
                }
                count += text.utf8.count + 2
                parts.append(text)
            }
            return parts.joined(separator: "\n\n")
        }.value
    }

    @discardableResult static func copyItems(_ items: [BlipReceivedItem], transfer: BlipTransfer,
                                            stillAllowed: () -> Bool = { true }) async throws -> Bool {
        let items = Array(items.prefix(256))
        guard !items.isEmpty, stillAllowed() else { return false }
        let text = try await textForClipboard(items, transfer: transfer)
        guard stillAllowed() else { return false }
        if let text { try writeText(text, clipboard: .general) }
        else { try copy(items, transfer) }
        return true
    }

    static func copyAutomatically(_ transfer: BlipTransfer, stillAllowed: () -> Bool) async throws -> Bool {
        let clipboard = NSPasteboard.general
        let changeCount = clipboard.changeCount
        return try await copyItems(transfer.received_items ?? [], transfer: transfer) {
            stillAllowed() && clipboard.changeCount == changeCount
        }
    }
    static func writeText(_ text: String, clipboard: NSPasteboard) throws {
        let entry = NSPasteboardItem()
        guard entry.setString(text, forType: .string) else {
            throw BlipReceiverError.message("The received text could not be copied.")
        }
        clipboard.clearContents()
        guard clipboard.writeObjects([entry]) else {
            throw BlipReceiverError.message("The received text could not be copied.")
        }
    }
    static func reveal(_ item:BlipReceivedItem,_ transfer:BlipTransfer)throws{NSWorkspace.shared.activateFileViewerSelecting([try url(item,transfer)])}
    static func folder(_ item:BlipReceivedItem,_ transfer:BlipTransfer)throws{let file=try url(item,transfer);guard NSWorkspace.shared.open(item.is_directory ? file:file.deletingLastPathComponent()) else{throw BlipReceiverError.message("The received folder could not open.")}}
    static func openWith(_ app:URL?,item:BlipReceivedItem,transfer:BlipTransfer)throws {
        let file=try url(item,transfer);var chosen=app
        if chosen==nil{let picker=NSOpenPanel();picker.title="Choose application";picker.directoryURL=URL(fileURLWithPath:"/Applications");picker.allowedContentTypes=[.application];picker.canChooseDirectories=false;picker.allowsMultipleSelection=false;guard picker.runMyDrivePicker() == .OK else{return};chosen=picker.url}
        guard let chosen else{return};NSWorkspace.shared.open([file],withApplicationAt:chosen,configuration:NSWorkspace.OpenConfiguration())
    }
}

@MainActor struct BlipReceivedFileView<Header: View>: View {
    let transfer: BlipTransfer
    let header: Header
    var fixturePreview:BlipFilePreview?=nil
    var onAction: () -> Void = {}
    var onActionError: (String) -> Void = { _ in }
    @State private var selection=""
    @State private var preview=BlipFilePreview()
    @State private var message=""
    private var items:[BlipReceivedItem]{transfer.direction=="Incoming"&&transfer.confirmed ? Array((transfer.received_items ?? []).prefix(256)).sorted{$0.name<$1.name}:[]}
    private var selected:BlipReceivedItem?{items.first{$0.path==selection} ?? items.first}
    private var file:URL?{selected.flatMap{BlipReceivedPath.url($0,in:transfer)}}
    private func showActionError(_ error: Error) {
        message = error.localizedDescription
        onActionError(message)
    }
    private func act(_ action: () throws -> Void) {
        onAction()
        do { try action(); message = "" }
        catch { showActionError(error) }
    }
    private func copy(_ item: BlipReceivedItem) {
        Task {
            do {
                if try await BlipFileActions.copyItems([item], transfer: transfer) { onAction() }
            } catch { showActionError(error) }
        }
    }
    private func actionMenu(_ item: BlipReceivedItem) -> some View {
        let location = file
        let isShortcut = location.map(BlipFileKind.shortcut) == true
        let isText = BlipFileKind.text(item, at: location)
        return Menu {
            Button("Open") { act { try BlipFileActions.open(item, transfer) } }
            Menu("Open With") {
                if let location {
                    ForEach(NSWorkspace.shared.urlsForApplications(toOpen: location), id: \.self) { app in
                        Button(app.deletingPathExtension().lastPathComponent) {
                            act { try BlipFileActions.openWith(app, item: item, transfer: transfer) }
                        }
                    }
                }
                Button("Choose Application…") { act { try BlipFileActions.openWith(nil, item: item, transfer: transfer) } }
            }.disabled(item.is_directory || isShortcut)
            Button(isText ? "Copy Text" : "Copy") { copy(item) }
            if isText {
                Button("Copy File") { act { try BlipFileActions.copy([item], transfer) } }
            }
            Button("Copy Path") { act { try BlipFileActions.copy([item], transfer, paths: true) } }
            Divider()
            Button("Open Folder") { act { try BlipFileActions.folder(item, transfer) } }
            Button("Show in Finder") { act { try BlipFileActions.reveal(item, transfer) } }
            Button("Quick Look") { act { if let location { BlipQuickLook.shared.show(location) } } }.disabled(isShortcut)
            if items.count > 1 {
                Divider()
                Button("Copy Listed Files") { act { try BlipFileActions.copy(items, transfer) } }
                Button("Copy Listed Paths") { act { try BlipFileActions.copy(items, transfer, paths: true) } }
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 10))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 6).accessibilityLabel("Received file actions")
    }
    private var itemLabel:String{let names=transfer.item_names ?? [];return names.isEmpty ? "Incoming transfer":names.joined(separator:", ")}
    private var previewContent: some View {
        let content = fixturePreview ?? preview
        return ZStack {
            Color.primary.opacity(0.06)
            if let image = content.image {
                Image(nsImage: image).resizable().scaledToFit()
                    .accessibilityLabel("Received file preview")
            } else if let text = content.text {
                Text(text).font(.system(size: 12, design: .monospaced)).lineLimit(9).textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 13).padding(.top, 42).padding(.bottom, 71)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: selected?.is_directory == true ? "folder" : "doc")
                        .font(.system(size: 35)).foregroundStyle(.secondary)
                    if selected == nil || file == nil {
                        Text("File unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var previewHeight: CGFloat {
        let content = fixturePreview ?? preview
        if let size = content.image?.size, size.width > 0, size.height > 0 {
            return min(252, max(178, (BlipReceiveNotice.width - 8) * size.height / size.width))
        }
        if let text = content.text {
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .reduce(0) { $0 + max(1, ($1.count + 37) / 38) }
            return min(252, max(150, 114 + CGFloat(lines) * 16))
        }
        return 252
    }

    var body: some View {
        previewContent
            .frame(height: previewHeight)
            .overlay(alignment: .top) {
                header.padding(.leading, 8).padding(.trailing, 3)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white).padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    if items.count > 1 {
                        Menu {
                            ForEach(items) { item in Button(item.displayName) { selection = item.path } }
                        } label: {
                            HStack(spacing: 5) {
                                Text(selected?.displayName ?? itemLabel).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                            }
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .accessibilityLabel("Choose received file").accessibilityValue(selected?.displayName ?? "")
                    } else {
                        Text(selected?.displayName ?? itemLabel)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            .help(selected?.path ?? "")
                    }
                    if let selected {
                        HStack(spacing: 0) {
                            Button("Open") { act { try BlipFileActions.open(selected, transfer) } }
                            actionMenu(selected)
                            Button(BlipFileKind.text(selected, at: file) ? "Copy Text" : "Copy") { copy(selected) }
                                .padding(.leading, 6)
                        }.disabled(file == nil)
                    }
                    if !message.isEmpty { Text(message).font(.system(size: 11)).lineLimit(2) }
                }
                .controlSize(.small).environment(\.colorScheme, .dark)
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .task(id:transfer.id+":"+String(transfer.confirmed)+":"+(selected?.path ?? "")){
            preview=BlipFilePreview();message="";guard let selected,let file else{return};let result=await BlipFilePreview.load(file,item:selected);guard !Task.isCancelled else{return};preview=result
        }
    }
}
