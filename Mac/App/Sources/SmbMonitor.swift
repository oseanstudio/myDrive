// Discover native mounts and use the shared core to check them.
import AppKit
import Foundation

enum MountHealth: Equatable, Sendable {
    case checking
    case connected
    case accessDenied
    case unavailable
    case reconnected
}

struct SmbMount: Identifiable, Equatable, Sendable {
    let path: String          // mount point, e.g. /Volumes/Dropbox
    let host: String
    let share: String
    let user: String
    var health: MountHealth = .checking
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var id: String { path }

    var displayName: String { (path as NSString).lastPathComponent }
    var remoteDescription: String {
        let who = user.isEmpty ? "" : "\(user)@"
        return "smb://\(who)\(host)/\(share)"
    }
    var smbURL: String {
        let who = user.isEmpty ? "" : "\(user)@"
        return "smb://\(who)\(host)/\(share)"
    }
    var healthLabel: String {
        switch health {
        case .checking: return "Checking…"
        case .connected: return "Connected"
        case .accessDenied: return "Access denied"
        case .unavailable: return "Unavailable"
        case .reconnected: return "Reconnected"
        }
    }
}

final class SmbMonitor {
    static let shared = SmbMonitor()
    @MainActor var onMountsChanged: (([SmbMount], [String: String]) -> Void)?
    @MainActor var bookmarks: [Bookmark] = []
    @MainActor private var mounts: [SmbMount] = []
    @MainActor private var bookmarkHealth: [String: String] = [:]
    @MainActor private var states: JSON = [:]
    @MainActor private var timer: Timer?
    @MainActor private var running: Task<Void, Never>?
    @MainActor private var pendingTrigger = "periodic"
    @MainActor private var stopped = false
    private static let enumerationLock = NSLock()

    /// Enumerates current SMB-family mounts from the OS.
    static func enumerate() -> [SmbMount] {
        enumerationLock.lock(); defer { enumerationLock.unlock() }
        var buffer: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let stats = buffer else { return [] }
        let types: Set<String> = ["smbfs", "cifs", "nsmb"]
        var mounts: [SmbMount] = []
        for index in 0..<Int(count) {
            let fs = stats[index]
            let type = cString(fs.f_fstypename)
            guard types.contains(type) else { continue }
            let from = cString(fs.f_mntfromname)   // //user@100.64.0.1/Dropbox
            let on = cString(fs.f_mntonname)
            let trimmed = from.hasPrefix("//") ? String(from.dropFirst(2)) : from
            let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            let host = first.split(separator: "@").last.map(String.init) ?? String(first)
            let user = first.contains("@") ? String(first.prefix { $0 != "@" }) : ""
            let share = parts.count > 1 ? String(parts[1]) : ""
            let free = Int64(fs.f_bavail) * Int64(fs.f_bsize)
            let total = Int64(fs.f_blocks) * Int64(fs.f_bsize)
            mounts.append(SmbMount(path: on, host: host, share: share, user: user,
                                   health: .checking, freeBytes: free, totalBytes: total))
        }
        return mounts.sorted { $0.path < $1.path }
    }

    /// Reads a fixed-size CChar tuple as a NUL-terminated C string.
    private static func cString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { buffer in
            String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    @MainActor func checkNow(_ trigger: String = "mount") {
        guard !stopped else { return }
        if trigger != "periodic" { pendingTrigger = trigger }
        if running == nil { schedule(after: trigger == "wake" || trigger == "network" ? 2 : 1) }
    }

    @MainActor func stop() {
        stopped = true
        timer?.invalidate()
        running?.cancel()
    }

    @MainActor private func schedule(after seconds: Int) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startPass() }
        }
    }

    @MainActor private func startPass() {
        guard !stopped, running == nil else { return }
        let trigger = pendingTrigger
        pendingTrigger = "periodic"
        running = Task { @MainActor in
            let next = await check(trigger)
            running = nil
            if !stopped { schedule(after: pendingTrigger == "periodic" ? next : 2) }
        }
    }

    @MainActor private func check(_ trigger: String) async -> Int {
        var current = await Task.detached(priority: .utility) { Self.enumerate() }.value
        rememberShares(current)
        let missing = droppedShares(current: current)
        let saved = bookmarks.filter { $0.protocolKind == "smb" }
        func target(_ id: String, _ kind: String, _ value: String) -> JSON {
            ["id": id, "probe": ["kind": kind, "value": value]]
        }
        let mountedIDs = saved.reduce(into: [String: String]()) { ids, bookmark in
            if let mount = current.first(where: { mount in
                if !bookmark.mountPath.isEmpty { return bookmark.mountPath == mount.path }
                let share = bookmark.path.split(separator: "/").first.map(String.init)
                return bookmark.host.caseInsensitiveCompare(mount.host) == .orderedSame &&
                    share?.caseInsensitiveCompare(mount.share.removingPercentEncoding ?? mount.share) == .orderedSame
            }) { ids[bookmark.id] = "mount:" + mount.id }
        }
        let hosts = Set(missing.map(\.host) + saved.filter { mountedIDs[$0.id] == nil }.map(\.host))
        let targets = current.map { target("mount:" + $0.id, "path", $0.path) }
            + hosts.sorted().map { target("host:" + $0, "host", $0) }

        let payload: JSON = ["trigger": trigger, "targets": targets, "previous": states]
        let response = try? await CoreBridge.shared.call(action: "smb.health", request: ["payload": payload], timeout: 8)
        guard !Task.isCancelled else { return 90 }
        if let data = response as? JSON { states = data.dict("states") }
        func status(_ id: String) -> String { (states[id] as? JSON)?.str("status") ?? "" }

        for index in current.indices {
            let id = current[index].id
            switch status("mount:" + id) {
            case "connected":
                current[index].health = mounts.first(where: { $0.id == id })?.health == .unavailable ? .reconnected : .connected
            case "access_denied": current[index].health = .accessDenied
            case "unavailable": current[index].health = .unavailable
            default: break
            }
        }
        var labels: [String: String] = [:]
        for bookmark in saved {
            switch status(mountedIDs[bookmark.id] ?? "host:" + bookmark.host) {
            case "connected": labels[bookmark.id] = "Connected"
            case "server_reachable": labels[bookmark.id] = "Server reachable"
            case "access_denied": labels[bookmark.id] = "Access denied"
            case "unavailable": labels[bookmark.id] = "Unavailable"
            default: break
            }
        }
        if mounts != current || bookmarkHealth != labels {
            mounts = current
            bookmarkHealth = labels
            onMountsChanged?(current, labels)
        }

        // Try only shares the OS no longer lists as mounted. Let the native
        // SMB client recover sessions that still have a mounted volume.
        if response != nil, recovery == nil, PrefStore.shared.preferences.autoRemount,
           let candidate = missing.first(where: { status("host:" + $0.host) == "server_reachable" }) {
            let key = Self.shareKey(candidate)
            lastAutoAttempt[key] = Date()
            recovery = Task { @MainActor in
                let result = await Task.detached(priority: .utility) {
                    guard !Self.enumerate().contains(where: { Self.shareKey($0) == key }) else { return true }
                    do {
                        try Self.shared.mount(candidate)
                        return true
                    } catch { return false }
                }.value
                autoFailCount[key] = result ? 0 : (autoFailCount[key] ?? 0) + 1
                recovery = nil
                if result { checkNow() }
            }
        }
        return (response as? JSON)?["next_seconds"] as? Int ?? 90
    }

    // MARK: - Known-share self-heal

    @MainActor private var autoFailCount: [String: Int] = [:]
    @MainActor private var lastAutoAttempt: [String: Date] = [:]
    @MainActor private var recovery: Task<Void, Never>?

    /// Stable identity for a share whether or not it is currently mounted:
    /// `user@host/share` (user omitted when the mount has none).
    static func shareKey(_ mount: SmbMount) -> String {
        let who = mount.user.isEmpty ? mount.host : "\(mount.user)@\(mount.host)"
        return "\(who)/\(mount.share)"
    }

    static func parseShareKey(_ key: String) -> (host: String, share: String, user: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let who = String(key[..<slash])
        let share = String(key[key.index(after: slash)...])
        guard !share.isEmpty else { return nil }
        if let at = who.firstIndex(of: "@") {
            let user = String(who[..<at])
            let host = String(who[who.index(after: at)...])
            guard !host.isEmpty else { return nil }
            return (host, share, user)
        }
        return (who, share, "")
    }

    /// Persists every share seen mounted, so one that disappears can be
    /// mounted again automatically. Empty lists are ignored so an offline
    /// stretch never wipes the memory.
    @MainActor private func rememberShares(_ mounts: [SmbMount]) {
        let known = PrefStore.shared.preferences.knownSmbShares
        let additions = Set(mounts.map { Self.shareKey($0) }).subtracting(known)
        guard !additions.isEmpty else { return }
        PrefStore.shared.update { $0.knownSmbShares += additions.sorted() }
    }

    @MainActor private func droppedShares(current: [SmbMount]) -> [SmbMount] {
        let prefs = PrefStore.shared.preferences
        guard prefs.autoRemount else { return [] }
        let mounted = Set(current.map { Self.shareKey($0) })
        return prefs.knownSmbShares.compactMap { key in
            guard !mounted.contains(key), let parts = Self.parseShareKey(key),
                  (autoFailCount[key] ?? 0) < 3,
                  lastAutoAttempt[key].map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return nil }
            return SmbMount(path: "", host: parts.host, share: parts.share, user: parts.user)
        }
    }

    // MARK: - Finder blank-folder fix (nsmb.conf)

    private static let cacheFixKeys = ["dir_cache_max_cnt", "dir_cache_off"]

    static var nsmbConfPath: String {
        NSHomeDirectory() + "/Library/Preferences/nsmb.conf"
    }

    static func cacheFixApplied() -> Bool {
        let current = (try? String(contentsOfFile: nsmbConfPath, encoding: .utf8)) ?? ""
        return cacheFixKeys.allSatisfy { current.contains($0) }
    }

    /// Writes the user-level nsmb.conf that turns off the SMB client's
    /// directory enumeration cache — Apple's documented fix for Finder
    /// showing stale, partial, or empty folder listings
    /// (support.apple.com/en-us/101918). Existing mounts pick it up on their
    /// next remount. An existing file is backed up first; macOS ignores
    /// unknown keys, so setting every documented spelling is safe.
    @discardableResult
    static func applyDirCacheFix() -> Bool {
        if cacheFixApplied() { return true }
        let path = nsmbConfPath
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            let backup = path + ".backup-\(Int(Date().timeIntervalSince1970))"
            try? fm.moveItem(atPath: path, toPath: backup)
        }
        let text = """
        # myDrive: disable local SMB directory enumeration caching
        # so Finder never shows a stale / partial / empty folder listing.
        [default]
        dir_cache_max_cnt=0
        dir_cache_off=yes
        dir_cache_max=0
        dir_cache_min=0
        dir_cache_async_cnt=0
        """
        let temporary = path + ".mydrive.tmp"
        do {
            try text.write(toFile: temporary, atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
            try fm.moveItem(atPath: temporary, toPath: path)
            return fm.fileExists(atPath: path)
        } catch {
            try? fm.removeItem(atPath: temporary)
            return false
        }
    }

    // MARK: - Fixes

    /// Mounts via the system mounter so Keychain-stored credentials apply.
    func mount(_ mount: SmbMount, timeout: TimeInterval = 30) throws {
        let escaped = mount.smbURL.replacingOccurrences(of: "\"", with: "%22")
        let output = try Shell.run("/usr/bin/osascript",
                                   ["-e", "mount volume \"\(escaped)\""], timeout: timeout)
        if output.code != 0 {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CoreError(message: SmbMonitor.friendlyMountError(
                message.isEmpty ? "The system could not mount the volume." : message))
        }
    }

    func forceRemount(_ mount: SmbMount) throws {
        let unmount = try Shell.run("/usr/sbin/diskutil", ["unmount", "force", mount.path], timeout: 20)
        if unmount.code != 0 {
            let message = unmount.stdout.isEmpty ? unmount.stderr : unmount.stdout
            throw CoreError(message: "Files may be open on this drive: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try self.mount(mount)
    }

    func disconnect(_ mount: SmbMount) throws {
        let unmount = try Shell.run("/usr/sbin/diskutil", ["unmount", mount.path], timeout: 20)
        if unmount.code != 0 {
            let message = unmount.stdout.isEmpty ? unmount.stderr : unmount.stdout
            throw CoreError(message: "Files may be open on this drive: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func friendlyMountError(_ raw: String) -> String {
        if raw.contains("already mounted") { return "The volume is already mounted." }
        if raw.lowercased().contains("host is down") || raw.contains("error code 64") {
            return "The SMB server cannot be reached. Check that both computers are online."
        }
        if raw.lowercased().contains("authentication") || raw.lowercased().contains("logon") {
            return "The SMB server rejected the saved credentials. Mount the share once in Finder to update them."
        }
        return raw
    }

    /// One-click fix for the Finder blank-folder bug on network shares.
    static func dsStoreFixApplied() -> Bool {
        UserDefaults(suiteName: "com.apple.desktopservices")?.bool(forKey: "DSDontWriteNetworkStores") ?? false
    }

    static func applyDSDontWriteNetworkStores() throws {
        let output = try Shell.run("/usr/bin/defaults",
                                   ["write", "com.apple.desktopservices", "DSDontWriteNetworkStores", "-bool", "true"],
                                   timeout: 10)
        if output.code != 0 {
            throw CoreError(message: "macOS refused the .DS_Store change. Try again from Terminal: defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true")
        }
    }
}
