import AppKit
import Foundation

struct HostedSmbShare: Decodable, Equatable {
    let name: String
    let folder: String?
    let host: String
    let username: String
    let password: String
    let writable: Bool

    var address: String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return "smb://\(host)/\(encoded)"
    }
}

struct SmbTailDevice: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let address: String
    let online: Bool

    var url: URL? {
        let host = address.contains(":") ? "[\(address)]" : address
        return URL(string: "smb://\(host)/")
    }
}

final class SmbSharingHost: @unchecked Sendable {
    struct Reply: Decodable {
        let error: String?
        let share: HostedSmbShare?
        let shares: [HostedSmbShare]?
    }

    private let queue = DispatchQueue(label: "io.mydrive.smb-sharing", qos: .userInitiated)
    private var child: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()

    func request(_ action: String, name: String = "", folder: String = "", writable: Bool = false) async throws -> Reply {
        let payload = try JSONSerialization.data(withJSONObject: [
            "action": action, "name": name, "folder": folder, "writable": writable
        ]) + Data([10])
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.call(action, payload: payload)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() {
        queue.async { self.close() }
    }

    private func call(_ action: String, payload: Data) throws -> Reply {
        if child?.isRunning != true { close() }
        if child == nil {
            guard action == "add" else { return Reply(error: nil, share: nil, shares: nil) }
            try start()
        }
        let response: Reply
        do {
            guard let input, let output else { throw CoreError(message: "SMB host pipes are unavailable.") }
            try input.write(contentsOf: payload)
            while !pending.contains(10) {
                let next = output.availableData
                guard !next.isEmpty, pending.count + next.count <= 64 * 1024 else {
                    throw CoreError(message: "The SMB host did not respond.")
                }
                pending.append(next)
            }
            let end = pending.firstIndex(of: 10)!
            response = try JSONDecoder().decode(Reply.self, from: Data(pending[..<end]))
            pending.removeSubrange(...end)
        } catch {
            close()
            throw CoreError(message: "The private SMB host stopped. Open SMB Drives and try again.")
        }
        if let error = response.error { throw CoreError(message: error) }
        return response
    }

    private func start() throws {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "mydrive-smb-host") else {
            throw CoreError(message: "The SMB host is missing. Install the latest myDrive build.")
        }
        let command = Process()
        let commandInput = Pipe()
        let commandOutput = Pipe()
        command.executableURL = executable
        command.standardInput = commandInput
        command.standardOutput = commandOutput
        command.standardError = FileHandle.nullDevice
        try command.run()
        child = command
        input = commandInput.fileHandleForWriting
        output = commandOutput.fileHandleForReading
    }

    private func close() {
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        child = nil
        pending = Data()
    }
}

@MainActor extension AppState {
    func createPrivateShare(_ selected: URL? = nil) {
        guard busy == nil else { return }
        let folder: URL
        if let selected {
            folder = selected
        } else {
            let picker = NSOpenPanel()
            picker.title = "Choose a folder to share over SMB"
            picker.canChooseDirectories = true
            picker.canChooseFiles = false
            guard picker.runModal() == .OK, let picked = picker.url else { return }
            folder = picked
        }

        let alert = NSAlert()
        alert.messageText = "Share over encrypted SMB"
        alert.informativeText = "Your Tailscale devices can connect while myDrive is running."
        alert.addButton(withTitle: "Share")
        alert.addButton(withTitle: "Cancel")
        let suggested = folder.lastPathComponent.replacingOccurrences(of: "[^a-zA-Z0-9 _-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let field = NSTextField(string: suggested.range(of: "^[a-zA-Z0-9]", options: .regularExpression) == nil
            ? "Shared folder" : String(suggested.prefix(63)))
        field.placeholderString = "Share name"
        field.setAccessibilityLabel("Share name")
        let write = NSButton(checkboxWithTitle: "Allow changes to files", target: nil, action: nil)
        let fields = NSStackView(views: [field, write])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        field.widthAnchor.constraint(equalToConstant: 270).isActive = true
        alert.accessoryView = fields
        alert.window.initialFirstResponder = field
        alert.window.appearance = AppDelegate.appearance(for: PrefStore.shared.preferences.appearance)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let writable = write.state == .on
        view = .connections
        perform("Share folder over encrypted SMB") {
            let result = try await self.smbHosting.request("add", name: name, folder: folder.path, writable: writable)
            if let share = result.share {
                self.hostedSmbShares.removeAll { $0.name == share.name }
                self.hostedSmbShares.append(share)
                self.showPrivateShare(share)
            }
        }
    }

    func managePrivateShares() {
        guard busy == nil else { return }
        perform("Read active SMB shares") {
            let result = try await self.smbHosting.request("list")
            let shares = result.shares ?? []
            let alert = NSAlert()
            alert.messageText = "Stop sharing these folders?"
            if shares.isEmpty {
                alert.informativeText = "This session has no active SMB shares."
                alert.addButton(withTitle: "Done")
                alert.runModal()
                return
            }
            let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 270, height: 26))
            selector.setAccessibilityLabel("Active share")
            selector.addItems(withTitles: shares.map(\.name))
            alert.accessoryView = selector
            alert.addButton(withTitle: "View share")
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Stop all shares")
            alert.window.appearance = AppDelegate.appearance(for: PrefStore.shared.preferences.appearance)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if shares.indices.contains(selector.indexOfSelectedItem) { self.showPrivateShare(shares[selector.indexOfSelectedItem]) }
            case .alertThirdButtonReturn:
                _ = try await self.smbHosting.request("stop")
                self.hostedSmbShares = []
            default: break
            }
        }
    }

    func refreshSmbInventory() async {
        let hosted = (try? await smbHosting.request("list"))?.shares ?? []
        if hosted != hostedSmbShares { hostedSmbShares = hosted }
        let result = try? await CoreBridge.shared.call(action: "smb.devices", timeout: 10)
        let devices: [SmbTailDevice]
        if let rows = result as? [JSON], let data = try? JSONSerialization.data(withJSONObject: rows) {
            devices = (try? JSONDecoder().decode([SmbTailDevice].self, from: data)) ?? []
        } else { devices = [] }
        if devices != smbTailDevices { smbTailDevices = devices }
    }

    func showPrivateShare(_ share: HostedSmbShare) {
        let alert = NSAlert()
        alert.messageText = share.name
        alert.informativeText = "\(share.address)\nUsername: \(share.username)\n\(share.writable ? "Read and write" : "Read-only")"
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy address")
        alert.addButton(withTitle: "Copy password")
        alert.window.appearance = AppDelegate.appearance(for: PrefStore.shared.preferences.appearance)
        let result = alert.runModal()
        if result == .alertSecondButtonReturn || result == .alertThirdButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result == .alertSecondButtonReturn ? share.address : share.password, forType: .string)
        }
    }
}
