// SMB/network-drive health for macOS. Mounts are discovered from the OS
// (getmntinfo); health uses a deadline-bounded stat probe, and remounts go
// through the system mounter so Keychain credentials apply. This mirrors the
// original macOS babysitter's 12-second checks plus wake handling, and adds
// the nsmb.conf folder-cache fix and known-share auto-remount.
import AppKit
import Foundation
import Network

enum MountHealth: Equatable {
    case checking
    case connected
    case unavailable
    case reconnected
}

struct SmbMount: Identifiable, Equatable {
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
        case .unavailable: return "Unavailable"
        case .reconnected: return "Reconnected"
        }
    }
}

final class SmbMonitor {
    static let shared = SmbMonitor()
    /// Called on the main queue whenever a check pass completes.
    var onMountsChanged: (([SmbMount]) -> Void)?

    private(set) var mounts: [SmbMount] = []
    private var checking = false
    private let healthTimeout: TimeInterval = 3
    private static let enumerationLock = NSLock()
    private static let probeLock = NSLock()
    private static var activeProbes = Set<String>()

    /// Enumerates current SMB-family mounts from the OS.
    static func enumerate() -> [SmbMount] {
        enumerationLock.lock(); defer { enumerationLock.unlock() }
        var buffer: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let stats = buffer else { return [] }
        let types: Set<String> = ["smbfs", "cifs", "afpfs", "nsmb"]
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
            let user = first.split(separator: "@").first.map(String.init) ?? ""
            let share = parts.count > 1 ? String(parts[1]) : ""
            let free = Int64(fs.f_bavail) * Int64(fs.f_bsize)
            let total = Int64(fs.f_blocks) * Int64(fs.f_bsize)
            mounts.append(SmbMount(path: on, host: host, share: share, user: user,
                                   health: .checking, freeBytes: free, totalBytes: total))
        }
        return mounts
    }

    /// Reads a fixed-size CChar tuple as a NUL-terminated C string.
    private static func cString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { buffer in
            String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Runs one health pass. Each mount root is probed with a deadline so a
    /// wedged SMB mount cannot hang the monitor. When auto-remount is on,
    /// remembered shares that dropped off the mount list are mounted again.
    func checkNow() {
        guard !checking else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var updated = SmbMonitor.enumerate()
            for index in updated.indices {
                let reachable = SmbMonitor.probe(updated[index].path, timeout: self.healthTimeout)
                updated[index].health = reachable ? .connected : .unavailable
            }
            self.rememberShares(updated)
            // Self-heal: shares that vanished (sleep, reboot, dead session)
            // come back on their own, using the Keychain credentials.
            if PrefStore.shared.preferences.autoRemount {
                var remounted = false
                for candidate in self.droppedShares(current: updated) {
                    let key = SmbMonitor.shareKey(candidate)
                    do {
                        try self.mount(candidate)
                        self.autoFailCount[key] = 0
                        remounted = true
                    } catch {
                        self.autoFailCount[key, default: 0] += 1
                    }
                    self.lastAutoAttempt[key] = Date()
                }
                if remounted {
                    var fresh = SmbMonitor.enumerate()
                    for index in fresh.indices {
                        let reachable = SmbMonitor.probe(fresh[index].path, timeout: self.healthTimeout)
                        fresh[index].health = reachable ? .connected : .unavailable
                    }
                    self.rememberShares(fresh)
                    updated = fresh
                }
            }
            DispatchQueue.main.async {
                self.checking = false
                var decorated = updated
                for index in decorated.indices {
                    if let previous = self.mounts.first(where: { $0.path == decorated[index].path }),
                       previous.health == .unavailable, decorated[index].health == .connected {
                        decorated[index].health = .reconnected
                    }
                }
                self.mounts = decorated
                self.onMountsChanged?(decorated)
            }
        }
    }

    /// Deadline-bounded filesystem probe. `false` also covers wedged mounts
    /// whose stat never returns inside the timeout.
    static func probe(_ path: String, timeout: TimeInterval) -> Bool {
        // A timed-out stat may remain in the kernel. Reserve its path until
        // return and cap all such work, instead of leaking a new probe each tick.
        probeLock.lock()
        guard !activeProbes.contains(path), activeProbes.count < 4 else { probeLock.unlock(); return false }
        activeProbes.insert(path); probeLock.unlock()
        let semaphore = DispatchSemaphore(value: 0)
        final class Result {
            var reachable = false
        }
        let result = Result()
        DispatchQueue.global(qos: .utility).async {
            var status = stat()
            result.reachable = stat(path, &status) == 0
            probeLock.lock(); activeProbes.remove(path); probeLock.unlock()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return false
        }
        return result.reachable
    }

    /// After wake, allow an immediate auto-remount attempt again: SMB sessions
    /// usually die during sleep, so the next check should not wait out the
    /// per-share backoff.
    func retryAfterWake() {
        lastAutoAttempt.removeAll()
    }

    // MARK: - Known-share self-heal

    private var autoFailCount: [String: Int] = [:]
    private var lastAutoAttempt: [String: Date] = [:]

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
    private func rememberShares(_ mounts: [SmbMount]) {
        let seen = Set(mounts.map { SmbMonitor.shareKey($0) })
        guard !seen.isEmpty else { return }
        PrefStore.shared.update { preferences in
            var known = preferences.knownSmbShares
            let before = known.count
            for key in seen where !known.contains(key) { known.append(key) }
            if known.count != before { preferences.knownSmbShares = known }
        }
    }

    /// Known shares missing from the mount list whose server answers on port
    /// 445. Safe-retry policy, matching the original babysitter: at most one
    /// attempt per minute per share, and at most three consecutive failures
    /// before the share waits for a manual remount to reset the counter.
    func droppedShares(current: [SmbMount]) -> [SmbMount] {
        let mounted = Set(current.map { SmbMonitor.shareKey($0) })
        var hostsUp: [String: Bool] = [:]
        var candidates: [SmbMount] = []
        for key in PrefStore.shared.preferences.knownSmbShares where !mounted.contains(key) {
            guard let parts = SmbMonitor.parseShareKey(key) else { continue }
            if (autoFailCount[key] ?? 0) >= 3 { continue }
            if let last = lastAutoAttempt[key], Date().timeIntervalSince(last) < 60 { continue }
            if hostsUp[parts.host] == nil { hostsUp[parts.host] = SmbMonitor.hostUp(parts.host, timeout: 3) }
            guard hostsUp[parts.host] == true else { continue }
            candidates.append(SmbMount(path: "", host: parts.host, share: parts.share, user: parts.user))
        }
        return candidates
    }

    /// TCP 445 reachability so an offline server never spawns mount attempts
    /// every cycle.
    static func hostUp(_ host: String, timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var up = false
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 445, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                up = true
                connection.cancel()
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        return up
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
