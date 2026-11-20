// Derives the "needs attention" list with one-click fixes from live state:
// Syncthing folder errors (with their real error text), device availability,
// SMB mounts, and pending fix requests from other devices.
import Foundation

enum FixKind: Equatable {
    case retrySnapshot
    case rescan(String)              // folder id
    case resume(String)              // folder id
    case showErrors(String)          // folder id
    case showPending(String)         // folder id
    case showAlternatives(String)    // folder id
    case deleteLeftovers(String)     // folder id: remove dirs a peer deleted
    case requestFix(String)          // folder id: open the request dialog
    case acceptFix(String, String)   // request id, folder id
    case declineFix(String, String)  // request id, folder id
    case remount(String)             // mount path
    case forceRemount(String)        // mount path
    case applyDSDontWriteStores
    case applyDirCacheFix
    case connectionSettings
    case refreshMounts
}

enum AttentionSeverity: Int {
    case error = 0, warning = 1, info = 2
}

struct AttentionFix: Identifiable {
    let label: String
    let kind: FixKind
    var id: String { label + String(describing: kind) }
}

struct AttentionItem: Identifiable {
    let id: String
    let severity: AttentionSeverity
    let title: String
    let detail: String
    let fixes: [AttentionFix]
}

/// One incoming fix request bundled with the local folder it belongs to.
struct IncomingFixRequest: Identifiable, Equatable {
    let pending: PendingFixRequest
    let folderId: String
    let folderLabel: String
    let folderPath: String
    var id: String { pending.request.id }
    var fromOthers: Bool { pending.request.requesterDeviceId != AttentionCenter.myDeviceId }
}

/// Classifies Syncthing folder-error text into a plain-language summary with
/// the fixes that apply to it.
enum ErrorClass: Equatable {
    case leftoverFolders   // deleted on a peer, still non-empty locally
    case diskFull
    case permissions
    case tooManyOpenFiles
    case pathMissing
    case peerConnection
    case other

    init(errorText: String) {
        let lower = errorText.lowercased()
        if lower.contains("directory has been deleted on a remote device but is not empty") {
            self = .leftoverFolders
        } else if lower.contains("no space left") || lower.contains("disk full") {
            self = .diskFull
        } else if lower.contains("permission denied") || lower.contains("operation not permitted") {
            self = .permissions
        } else if lower.contains("too many open files") {
            self = .tooManyOpenFiles
        } else if lower.contains("folder path missing") || lower.contains("no such file or directory") {
            self = .pathMissing
        } else if lower.contains("timeout") || lower.contains("connection")
            || lower.contains("index") || lower.contains("beacon") {
            self = .peerConnection
        } else {
            self = .other
        }
    }

    /// Plain-language summary. `count` is the number of failed items,
    /// `first` the first failing path.
    func summary(count: Int, first: String) -> String {
        switch self {
        case .leftoverFolders:
            return count == 1
                ? "A peer deleted \(first), but this Mac still holds files inside it."
                : "A peer deleted \(count) folders, but this Mac still holds files inside them (for example \(first))."
        case .diskFull:
            return "This Mac ran out of disk space while syncing \(count) items."
        case .permissions:
            return "macOS or file permissions blocked \(count) items. Grant myDrive's Full Disk Access if it repeats."
        case .tooManyOpenFiles:
            return "This Mac hit its open-file limit while syncing \(count) items."
        case .pathMissing:
            return "The folder's storage is missing on this Mac. Reconnect its volume, then rescan."
        case .peerConnection:
            return "The other device did not respond for \(count) items. Check that it is online."
        case .other:
            return first.isEmpty ? "Syncthing reported \(count) problem(s)." : "Syncthing reported: \(first)"
        }
    }

    /// The fix that most likely clears the class on this Mac.
    var primaryFixLabel: String {
        switch self {
        case .leftoverFolders: return "Delete leftovers here"
        case .diskFull: return "Rescan after freeing space"
        case .permissions, .tooManyOpenFiles: return "Rescan"
        case .pathMissing: return "Rescan after reconnecting"
        case .peerConnection: return "Ask the other device"
        case .other: return "Rescan"
        }
    }

    /// True when the likely root cause sits on the peer, so a safe fix
    /// request is the better button than a local rescan.
    var needsPeerHelp: Bool {
        self == .peerConnection
    }
}

enum AttentionCenter {
    static var myDeviceId = ""

    static func derive(snapshot: Snapshot?, snapshotError: String?,
                       mounts: [SmbMount],
                       folderErrors: [String: [IssueItem]],
                       incoming: [IncomingFixRequest]) -> [AttentionItem] {
        var items: [AttentionItem] = []

        for request in incoming where !request.pending.isAnswered {
            let kind = FixKindRemote.safe(request.pending.request.fix)
            guard kind != nil else { continue } // non-safe requests never surface
            items.append(AttentionItem(
                id: "incoming-\(request.id)",
                severity: .warning,
                title: "\(request.pending.request.requesterName) requests a fix for \(request.folderLabel)",
                detail: "\(kind!.title): \(kind!.effect)",
                fixes: [AttentionFix(label: "Accept", kind: .acceptFix(request.id, request.folderId)),
                        AttentionFix(label: "Decline", kind: .declineFix(request.id, request.folderId))]
            ))
        }

        if let snapshotError {
            items.append(AttentionItem(
                id: "snapshot",
                severity: .error,
                title: "Syncthing unavailable",
                detail: snapshotError,
                fixes: [AttentionFix(label: "Retry", kind: .retrySnapshot),
                        AttentionFix(label: "Connection…", kind: .connectionSettings)]
            ))
        } else if let snapshot {
            let errorFolders = snapshot.folders.filter(\.hasError)
            for folder in errorFolders.sorted(by: { $0.displayName < $1.displayName }) {
                let rows = folderErrors[folder.id] ?? []
                let first = rows.first
                let errorClass = ErrorClass(errorText: first?.message ?? folder.error ?? "")
                let detail = errorClass.summary(count: max(rows.count, Int(folder.status.pullErrors), 1),
                                                first: first?.path ?? "")
                var fixes: [AttentionFix] = []
                if errorClass == .leftoverFolders {
                    fixes.append(AttentionFix(label: "Delete leftovers here",
                                              kind: .deleteLeftovers(folder.id)))
                    fixes.append(AttentionFix(label: "Rescan", kind: .rescan(folder.id)))
                } else if errorClass.needsPeerHelp {
                    fixes.append(AttentionFix(label: "Ask the other device",
                                              kind: .requestFix(folder.id)))
                    fixes.append(AttentionFix(label: "Rescan here", kind: .rescan(folder.id)))
                } else {
                    fixes.append(AttentionFix(label: errorClass.primaryFixLabel,
                                              kind: .rescan(folder.id)))
                }
                fixes.append(AttentionFix(label: "Show all errors", kind: .showErrors(folder.id)))
                fixes.append(AttentionFix(label: "Request a different fix…", kind: .requestFix(folder.id)))
                items.append(AttentionItem(
                    id: "folder-error-\(folder.id)",
                    severity: .error,
                    title: "\(folder.displayName) can't finish syncing",
                    detail: detail,
                    fixes: fixes
                ))
            }

            let pending = snapshot.folders.filter { !$0.paused && !$0.hasError && $0.status.needFiles > 0 }
            for folder in pending.sorted(by: { $0.status.needFiles > $1.status.needFiles }).prefix(3) {
                items.append(AttentionItem(
                    id: "pending-\(folder.id)",
                    severity: .warning,
                    title: "\(folder.displayName) is waiting for \(folder.status.needFiles) files",
                    detail: "Files resume automatically when a device with the content is connected.",
                    fixes: [AttentionFix(label: "Pending files", kind: .showPending(folder.id)),
                            AttentionFix(label: "Rescan", kind: .rescan(folder.id))]
                ))
            }

            let paused = snapshot.folders.filter(\.paused)
            if snapshot.folders.count > 1 && paused.count == snapshot.folders.count {
                items.append(AttentionItem(
                    id: "paused-all",
                    severity: .warning,
                    title: "Sync is paused",
                    detail: "All folders are paused on this computer.",
                    fixes: paused.prefix(5).map {
                        AttentionFix(label: "Resume \($0.displayName)", kind: .resume($0.id))
                    }
                ))
            }

            let remoteDevices = snapshot.devices.filter { !$0.isLocal && !$0.paused }
            let anyConnected = remoteDevices.contains(where: \.connected)
            let waitingForPeers = snapshot.folders.contains {
                !$0.paused && !$0.hasError && $0.status.needBytes > 0
            }
            if !remoteDevices.isEmpty && !anyConnected && waitingForPeers {
                items.append(AttentionItem(
                    id: "offline",
                    severity: .info,
                    title: "Working offline",
                    detail: "No other device is connected. Pending files start as soon as one comes online.",
                    fixes: []
                ))
            }
        }

        let broken = mounts.filter { $0.health == .unavailable }
        for mount in broken {
            items.append(AttentionItem(
                id: "mount-\(mount.path)",
                severity: .error,
                title: "\(mount.displayName) is unavailable",
                detail: "\(mount.remoteDescription) did not respond. Files on it cannot open right now.",
                fixes: [AttentionFix(label: "Remount", kind: .remount(mount.path)),
                        AttentionFix(label: "Force remount", kind: .forceRemount(mount.path))]
            ))
        }

        return items.sorted { $0.severity.rawValue < $1.severity.rawValue }
    }
}
