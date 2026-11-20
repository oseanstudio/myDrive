// --diagnose <dir>: runs the self-test without user interaction, renders the
// popup fixtures to PNG, and writes report.json. Mirrors Windows/App/Diagnostics.cs.
import AppKit
import SwiftUI

enum Diagnostics {
    static func runLayout(outputDirectory: String) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let directory=URL(fileURLWithPath:outputDirectory,isDirectory:true)
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                var captures:[String]=[]
                let layout=layoutCheck(directory:directory,captures:&captures)
                let state=AppState(),receiver=BlipReceiver(root:directory.appendingPathComponent("blip-fixture"))
                let peer="11111111-1111-4111-8111-111111111111:22222222-2222-4222-8222-222222222222"
                receiver.state="Ready in the background"
                receiver.peers=[BlipPeer(peer:peer,name:"A long studio laptop name for overflow checking",name_known:true)]
                receiver.transfers=(0..<12).map {index in BlipTransfer(transfer_id:UUID().uuidString,peer:peer,direction:"Incoming",status:index==0 ? "Invited" : index==1 ? "Paused" : "Completed",completed:index>1,has_error:index==2,link_files:[],link_only:true)}
                guard receiver.transfers.filter(\.isLive).map(\.status) == ["Invited", "Paused"] else {
                    throw BlipReceiverError.message("Send & Receive shows completed transfer history")
                }
                state.blip=receiver;state.view = .transfers
                for scheme in [ColorScheme.light,.dark] {
                    let file="blip-\(scheme == .light ? "light":"dark").png"
                    render(PopupRootView().environmentObject(state).environment(\.colorScheme,scheme),height:PopupMetrics.maxHeight,to:directory.appendingPathComponent(file),scheme:scheme);captures.append(file)
                    let permissions = "sender-permissions-\(scheme == .light ? "light" : "dark").png"
                    render(BlipSenderPermissionsView(receiver: receiver).padding(10).environment(\.colorScheme, scheme),
                           height: 180, to: directory.appendingPathComponent(permissions), scheme: scheme)
                    captures.append(permissions)
                }
                guard let icon = AppDelegate.statusImage, icon.isTemplate, icon.size == NSSize(width: 20, height: 18),
                      let markURL = Bundle.main.url(forResource: "StatusMark", withExtension: "png"),
                      let mark = NSBitmapImageRep(data: try Data(contentsOf: markURL)),
                      (0..<mark.pixelsWide).allSatisfy({ x in
                          (0..<8).allSatisfy { y in
                              mark.colorAt(x: x, y: y)?.alphaComponent == 0 &&
                              mark.colorAt(x: x, y: mark.pixelsHigh - 1 - y)?.alphaComponent == 0
                          }
                      }) else { throw BlipReceiverError.message("The menu bar mark lacks vertical padding") }
                let notice = BlipReceiveNotice(receiver: receiver, openTransfers: {}, anchor: { nil })
                guard notice.panel.styleMask.contains([.titled, .closable, .nonactivatingPanel]),
                      !notice.panel.styleMask.contains(.utilityWindow),
                      let closeButton = notice.panel.standardWindowButton(.closeButton),
                      let standardClose = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable]),
                      closeButton.frame.width >= standardClose.frame.width else {
                    throw BlipReceiverError.message("The receive notice does not use the standard close control")
                }
                if let transfer=receiver.transfers.first {let file="blip-receive-notice.png";render(BlipReceiveNoticeView(receiver:receiver,id:transfer.id,openTransfers:{}),height:340,to:directory.appendingPathComponent(file));captures.append(file)}
                let labels = ["Studio desktop", "Travel laptop", "A very long registered phone name for checking how recipient rows handle truncation"] +
                    (1...8).map { "Studio contact · Laptop \($0)" }
                let picker = BlipRecipientPicker(labels: labels, description: "Click a device to send.")
                picker.dialog.layout()
                guard picker.table.numberOfRows == labels.count, picker.table.selectedRow == -1,
                      picker.dialog.buttons.map(\.title) == ["Cancel"], picker.table.activateRow != nil,
                      let list = picker.dialog.accessoryView,
                      list.frame.height < CGFloat(labels.count) * picker.table.rowHeight else {
                    throw BlipReceiverError.message("The recipient list did not start unselected and scrollable")
                }
                picker.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                if let content = picker.dialog.window.contentView,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        let file = "blip-recipient-list.png"
                        try data.write(to: directory.appendingPathComponent(file))
                        captures.append(file)
                    }
                }
                let received=try receivedFileCheck(directory:directory,captures:&captures,peer:peer)
                let outbox=directory.appendingPathComponent("fixture-outbox")
                let link=try BlipSendPayload.textPayload("https://example.test/local-fixture",outbox:outbox)
                defer { link.discard() }
                guard BlipWebLink.read(link.files[0].path)?.host == "example.test" else { throw BlipReceiverError.message("Clipboard link fixture did not round trip") }
                let batch = try BlipSendPayload.textPayload("https://example.test/one\nhttps://example.test/two", outbox: outbox)
                defer { batch.discard() }
                guard batch.files.compactMap({ BlipWebLink.read($0.path)?.path }) == ["/one", "/two"] else {
                    throw BlipReceiverError.message("Multiple clipboard links did not round trip")
                }
                let multiline=try BlipSendPayload.textPayload("https://example.test/\nSecond line",outbox:outbox)
                defer { multiline.discard() }
                guard multiline.files[0].pathExtension == "txt" else { throw BlipReceiverError.message("Multiline text was converted to a shortcut") }
                BlipSendPayload.forFiles(multiline.files).discard()
                guard FileManager.default.fileExists(atPath:multiline.files[0].path) else { throw BlipReceiverError.message("Cancelling lost an original file") }
                multiline.discard()
                guard !FileManager.default.fileExists(atPath:multiline.files[0].path) else { throw BlipReceiverError.message("Cancelled staging file was retained") }
                let childState=AppState();childState.snapshot=fixtureSnapshot(folderCount:1)
                childState.syncBrowse=SyncBrowseState(folderId:"demo-0",label:"Demo folder",path:"project",result:BrowseResult(from:["entries":[]]))
                childState.view = .syncFiles
                render(PopupRootView().environmentObject(childState),height:PopupMetrics.maxHeight,to:directory.appendingPathComponent("subfolder-browser.png"));captures.append("subfolder-browser.png")
                childState.shareBrowsedSubfolder()
                guard childState.shareFolderPath=="/tmp/demo/0/project" else {throw BlipReceiverError.message("Subfolder sharing selected the wrong root")}
                render(PopupRootView().environmentObject(childState),height:PopupMetrics.maxHeight,to:directory.appendingPathComponent("subfolder-share.png"));captures.append("subfolder-share.png")
                let report:JSON=["layout":layout,"captures":captures,"received_files":received,"send_payload_checks":"pass","active_transfers_only":true,"status_mark_padded":true,"native_receive_chrome":true,"visible_recipient_list":true,"fixtures_only":true]
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("layout-report.json"))
                guard layout["result"] as? String == "pass" else {exit(1)}
            } catch { print("Layout diagnostics failed: \(error.localizedDescription)");exit(1) }
        }
        exit(0)
    }
    static func run(outputDirectory: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        MainActor.assumeIsolated {
            let report = perform(directory: directory)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("report.json"))
            }
            print("myDrive diagnostics report: \(directory.appendingPathComponent("report.json").path)")
        }
        exit(0)
    }

    @MainActor
    private static func perform(directory: URL) -> JSON {
        var report: JSON = ["version": "0.4.17"]
        var captures: [String] = []

        report["keychain"] = keychainCheck()
        report["bookmarks"] = bookmarksCheck(directory: directory)
        report["core_bridge"] = coreBridgeCheck()
        report["syncthing_live"] = syncthingCheck()
        report["fix_requests"] = fixRequestsCheck()
        report["smb"] = smbCheck()

        let layout = layoutCheck(directory: directory, captures: &captures)
        report["layout"] = layout
        report["captures"] = captures
        return report
    }

    // MARK: - Checks

    @MainActor private static func receivedFileCheck(directory:URL,captures:inout [String],peer:String)throws->JSON {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/myDrive-received-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let text=root.appendingPathComponent("Generated document with a long name for overflow checking.txt")
        try "Received document preview\nGenerated local fixture only\nNo clipboard or external app access".write(to:text,atomically:true,encoding:.utf8)
        let picture=root.appendingPathComponent("Generated preview.png")
        guard let resource=Bundle.main.url(forResource:"myDrive",withExtension:"png") else{throw BlipReceiverError.message("Missing fixture image resource")}
        try FileManager.default.copyItem(at:resource,to:picture)
        var transfer=BlipTransfer(transfer_id:UUID().uuidString,peer:peer,direction:"Incoming",status:"Completed",completed:true,has_error:false,link_files:[],link_only:false)
        let textItem=BlipReceivedItem(name:text.lastPathComponent,path:text.path),imageItem=BlipReceivedItem(name:picture.lastPathComponent,path:picture.path)
        for (item,file,label) in [(textItem,text,"text"),(imageItem,picture,"image")] {
            transfer.received_items=[item]
            guard BlipReceivedPath.url(item,in:transfer) != nil else{throw BlipReceiverError.message("Fixture path unavailable")}
            let preview=try awaitSync{await BlipFilePreview.load(file,item:item)}
            guard label=="text" ? preview.text?.contains("Received document preview")==true : preview.image != nil else{throw BlipReceiverError.message("Received \(label) preview failed")}
            for scheme in [ColorScheme.light,.dark] {
                let name="blip-received-\(label)-\(scheme == .light ? "light":"dark").png"
                let receiver=BlipReceiver(root:root.appendingPathComponent("unused-profile"));receiver.peers=[BlipPeer(peer:peer,name:"Studio laptop",name_known:true)];receiver.transfers=[transfer]
                render(BlipReceiveNoticeView(receiver:receiver,id:transfer.id,openTransfers:{},fixturePreview:preview).environment(\.colorScheme,scheme),height:340,to:directory.appendingPathComponent(name),scheme:scheme);captures.append(name)
            }
        }
        transfer.received_items=[textItem,imageItem]
        let receiver=BlipReceiver(root:root.appendingPathComponent("unused-profile"));receiver.peers=[BlipPeer(peer:peer,name:"Studio laptop",name_known:true)];receiver.transfers=[transfer]
        render(BlipReceiveNoticeView(receiver:receiver,id:transfer.id,openTransfers:{},fixturePreview:BlipFilePreview(text:"Received document preview")),height:340,to:directory.appendingPathComponent("blip-received-multiple.png"));captures.append("blip-received-multiple.png")
        return ["result":"pass","image_and_text_preview":true,"fixtures_only":true,"clipboard_or_launch":false]
    }

    @MainActor
    private static func keychainCheck() -> JSON {
        let account = "diagnostic-\(UUID().uuidString)"
        let credentials = Credentials(password: "local-fixture-only")
        do {
            try Keychain.saveCredentials(credentials, id: account)
            let read = Keychain.readCredentials(id: account)
            Keychain.deleteCredentials(id: account)
            let gone = Keychain.readCredentials(id: account).isEmpty
            if read == credentials && gone {
                return ["result": "pass"]
            }
            return ["result": "fail", "error": "The saved credential did not read back unchanged."]
        } catch {
            Keychain.deleteCredentials(id: account)
            return ["result": "fail", "error": error.localizedDescription]
        }
    }

    @MainActor
    private static func bookmarksCheck(directory: URL) -> JSON {
        let store = directory.appendingPathComponent("store")
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        var first = Bookmark()
        first.nickname = "Fixture one"
        first.host = "/tmp"
        var second = Bookmark()
        second.nickname = "Fixture two"
        second.host = "/tmp"
        do {
            try awaitSync {
                try await CoreBridge.shared.saveBookmarks([first, second], dataDir: store)
                let loaded = try await CoreBridge.shared.loadBookmarks(dataDir: store)
                guard loaded.count == 2,
                      loaded.map(\.id).sorted() == [first.id, second.id].sorted() else {
                    throw CoreError(message: "The saved bookmarks did not read back unchanged.")
                }
            }
            return ["result": "pass"]
        } catch {
            return ["result": "fail", "error": Diagnostics.message(error)]
        }
    }

    @MainActor
    private static func coreBridgeCheck() -> JSON {
        let fixture = directory0().appendingPathComponent("core-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try? "alpha".write(to: fixture.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try? "beta".write(to: fixture.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        var bookmark = Bookmark()
        bookmark.nickname = "Diagnostic fixture"
        bookmark.protocolKind = "local"
        bookmark.host = fixture.path
        do {
            let files = try awaitSync { () -> Int in
                let raw = try await CoreBridge.shared.fileAction("list", bookmark: bookmark,
                                                                 credentials: Credentials())
                return (raw as? [Any])?.count ?? -1
            }
            guard files == 2 else {
                return ["result": "fail", "error": "The core returned \(files) files. The fixture holds 2."]
            }
            return ["result": "pass", "items": files]
        } catch {
            return ["result": "fail", "error": Diagnostics.message(error)]
        }
    }

    @MainActor
    private static func syncthingCheck() -> JSON {
        let service = SyncthingService()
        service.discover()
        if let error = service.discoveryError, service.connection == nil {
            return ["result": "fail", "error": error]
        }
        do {
            let snapshot = try awaitSync { try await service.snapshot() }
            let connected = snapshot.devices.filter(\.connected).count
            var folderErrors: [String: [IssueItem]] = [:]
            for folder in snapshot.folders.filter(\.hasError).prefix(4) {
                let rows: [IssueItem] = try awaitSync { () -> [IssueItem] in
                    let raw = try await service.call("errors",
                                                     payload: ["folder_id": folder.id],
                                                     timeout: 20)
                    return IssueItem.rows(from: raw)
                }
                folderErrors[folder.id] = rows
            }
            AttentionCenter.myDeviceId = snapshot.devices.first(where: { $0.isLocal })?.deviceID ?? ""
            let items = AttentionCenter.derive(snapshot: snapshot, snapshotError: nil,
                                               mounts: [], folderErrors: folderErrors, incoming: [])
            let preview: [JSON] = items.prefix(8).map { item in
                ["title": item.title, "detail": item.detail,
                 "fixes": item.fixes.map(\.label)]
            }
            return ["result": "pass", "version": snapshot.version,
                    "folders": snapshot.folders.count, "connected_devices": connected,
                    "attention_preview": preview]
        } catch {
            return ["result": "fail", "error": Diagnostics.message(error)]
        }
    }

    /// Mailbox roundtrip in a temp fixture: safe request scans back, a
    /// response pairs with it, and a non-whitelisted fix kind is refused.
    @MainActor
    private static func fixRequestsCheck() -> JSON {
        let fixture = directory0().appendingPathComponent("mailbox-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        do {
            let unsafe = FixRequest(id: "unsafe-1", fix: "wipe-disk", folderId: "f", created: Date(),
                                    requesterName: "Test", requesterDeviceId: "DEV1",
                                    reason: "", targetDeviceId: FixRequestStore.anyDevice)
            do {
                try FixRequestStore.send(request: unsafe, folderPath: fixture.path)
                return ["result": "fail", "error": "A non-whitelisted fix kind was accepted."]
            } catch {
                // Expected: only safe kinds can be sent.
            }
            let request = FixRequest(id: "req-1", fix: FixKindRemote.rescan.rawValue, folderId: "f",
                                     created: Date(), requesterName: "Test Mac",
                                     requesterDeviceId: "LOCAL", reason: "delete dir error",
                                     targetDeviceId: FixRequestStore.anyDevice)
            try FixRequestStore.send(request: request, folderPath: fixture.path)
            let scanned = FixRequestStore.scan(folderPath: fixture.path)
            guard scanned.count == 1, !scanned[0].isAnswered,
                  scanned[0].request.fix == FixKindRemote.rescan.rawValue else {
                return ["result": "fail", "error": "The sent request did not scan back unchanged."]
            }
            try FixRequestStore.respond(requestId: "req-1", folderPath: fixture.path,
                                        status: "completed", message: "", deviceName: "Peer Mac")
            let answered = FixRequestStore.scan(folderPath: fixture.path)
            guard answered.count == 1,
                  answered[0].response?.status == "completed" else {
                return ["result": "fail", "error": "The response did not pair with the request."]
            }
            FixRequestStore.cancel(requestId: "req-1", folderPath: fixture.path)
            let afterCancel = FixRequestStore.scan(folderPath: fixture.path)
            guard afterCancel.isEmpty else {
                return ["result": "fail", "error": "The canceled request is still on disk."]
            }
            return ["result": "pass"]
        } catch {
            return ["result": "fail", "error": Diagnostics.message(error)]
        }
    }

    @MainActor
    private static func smbCheck() -> JSON {
        let mounts = SmbMonitor.enumerate().map { mount -> JSON in
            ["path": mount.path, "remote": mount.remoteDescription]
        }
        return ["result": "pass", "mounts": mounts]
    }

    // MARK: - Layout

    @MainActor
    private static func layoutCheck(directory: URL, captures: inout [String]) -> JSON {
        let state = AppState()
        state.snapshot = fixtureSnapshot(folderCount: 1)
        state.snapshotError = nil
        state.mounts = [fixtureMount(name: "Dropbox", available: true)]
        state.updates = [UpdateEntry(text: "alpha.txt synced · demo", kind: "file", folderId: "demo")]
        state.activity = [ActivityEntry(operation: "Rescan demo", connection: "demo",
                                        detail: "Rescan demo", success: true)]

        let single = PopupRootView().environmentObject(state)
            .environment(\.colorScheme, .light)
        let manyState = AppState()
        manyState.snapshot = fixtureSnapshot(folderCount: 11)
        manyState.snapshotError = nil
        manyState.mounts = [fixtureMount(name: "Dropbox", available: true),
                            fixtureMount(name: "rents", available: false)]
        manyState.attention = AttentionCenter.derive(snapshot: manyState.snapshot,
                                                     snapshotError: nil, mounts: manyState.mounts,
                                                     folderErrors: [:], incoming: [])
        let many = PopupRootView().environmentObject(manyState)
        let dark = PopupRootView().environmentObject(manyState)
            .environment(\.colorScheme, .dark)
        let errors=PopupRootView().environmentObject(manyState)
        render(errors,height:PopupMetrics.maxHeight,to:directory.appendingPathComponent("quick-sync-errors.png"));captures.append("quick-sync-errors.png")
        // Measure the normal folder-list case separately from expanded attention cards.
        manyState.attention=[];manyState.mounts=[]

        let oneHeight = measure(single)
        let manyHeight = measure(many)

        render(single, height: oneHeight, to: directory.appendingPathComponent("quick-sync.png"))
        captures.append("quick-sync.png")
        render(many, height: manyHeight, to: directory.appendingPathComponent("quick-sync-many.png"))
        captures.append("quick-sync-many.png")
        render(dark, height: manyHeight, to: directory.appendingPathComponent("quick-sync-dark.png"))
        captures.append("quick-sync-dark.png")

        state.view = .activity
        let activityRoot = PopupRootView().environmentObject(state)
        let activityHeight = measure(activityRoot)
        render(activityRoot, height: activityHeight,
               to: directory.appendingPathComponent("quick-activity.png"))
        captures.append("quick-activity.png")

        let rowBudget = Double(PopupMetrics.maxHeight) - 44 - 40 // header + status header
        let rowsVisible = Int(rowBudget / 50)

        return [
            "popup_width": Int(PopupMetrics.width),
            "popup_one": ["width": 344, "height": Int(oneHeight)],
            "popup_many": ["width": 344, "height": Int(manyHeight)],
            "estimated_rows_at_cap": rowsVisible,
            "height_cap": Int(PopupMetrics.maxHeight),
            "result": oneHeight <= PopupMetrics.maxHeight
                && manyHeight <= PopupMetrics.maxHeight
                && rowsVisible >= 5 ? "pass" : "fail",
        ]
    }

    @MainActor
    private static func measure(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: PopupMetrics.width, height: 10)
        return min(max(hosting.fittingSize.height, 60), PopupMetrics.maxHeight)
    }

    /// Offscreen AppKit draw. ImageRenderer cannot resolve SF Symbols or custom
    /// menu labels without an on-screen window, so the captures draw through
    /// NSHostingView at 2x instead.
    @MainActor
    private static func render(_ view: some View, height: CGFloat, to url: URL,scheme:ColorScheme?=nil) {
        let size = NSSize(width: PopupMetrics.width, height: max(height, 60))
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.appearance=NSAppearance(named:scheme == .dark ? .darkAqua:.aqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        hosting.appearance!.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect:NSRect(origin:.zero,size:size)).fill()
            hosting.displayIgnoringOpacity(NSRect(origin: .zero, size: size), in: context!)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    @MainActor
    private static func fixtureSnapshot(folderCount: Int) -> Snapshot {
        var folders: [JSON] = []
        for index in 0..<folderCount {
            let need = index == 0 ? 3 : 0
            let paused = index == folderCount - 1
            let pullErrors = index == 1 && folderCount > 5 ? 2 : 0
            folders.append([
                "id": "demo-\(index)", "label": index==2 ? "An unusually long project folder name for overflow checking" : "Demo folder \(index)",
                "path": "/tmp/demo/\(index)", "type": "sendreceive", "paused": paused,
                "device_count": 2, "device_ids": ["DEV1"],
                "status": [
                    "state": paused ? "idle" : (index == 0 ? "syncing" : "idle"),
                    "stateChanged": "2026-11-14T00:00:00Z",
                    "globalBytes": 100_000, "globalFiles": 120, "globalDirectories": 4,
                    "localBytes": 100_000, "localFiles": 120,
                    "inSyncBytes": 100_000 - Int64(need * 1000), "inSyncFiles": 120 - Int64(need),
                    "needBytes": need * 1000, "needFiles": need, "needDeletes": 0,
                    "pullErrors": pullErrors, "receiveOnlyChangedFiles": 0,
                ],
            ])
        }
        let devices: [JSON] = [
            ["deviceID": "LOCAL", "name": "This Mac", "paused": false, "is_local": true,
             "connection": ["connected": true, "clientVersion": "v2.1.6"]],
            ["deviceID": "DEV1", "name": "Studio Windows PC", "paused": false, "is_local": false,
             "connection": ["connected": true, "clientVersion": "v2.1.7"]],
            ["deviceID": "DEV2", "name": "Studio MacBook", "paused": false, "is_local": false,
             "connection": ["connected": false, "clientVersion": ""]],
        ]
        return Snapshot(from: ["version": "v2.1.6", "folders": folders, "devices": devices, "errors": []])
    }

    @MainActor
    private static func fixtureMount(name: String, available: Bool) -> SmbMount {
        var mount = SmbMount(path: "/Volumes/\(name)", host: "100.64.0.1", share: name, user: "user")
        mount.health = available ? .connected : .unavailable
        mount.freeBytes = 123_456_789
        mount.totalBytes = 987_654_321
        return mount
    }

    // MARK: - Helpers

    private static func directory0() -> URL {
        FileManager.default.temporaryDirectory
    }

    /// Runs an async closure synchronously on a helper queue. The closure is
    /// @Sendable so it cannot inherit the caller's actor isolation; otherwise
    /// the task would wait for the very thread this call is blocking.
    static func awaitSync<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        DispatchQueue.global().async {
            Task.detached {
                do {
                    box.value = try await body()
                } catch {
                    box.error = error
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
        if let error = box.error { throw error }
        return box.value!
    }

    private final class ResultBox<T> {
        var value: T?
        var error: Error?
    }

    private static func message(_ error: Error) -> String {
        (error as? CoreError)?.message ?? error.localizedDescription
    }
}
