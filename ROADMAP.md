# myDrive implementation roadmap

The reference document is a product specification, not evidence that an existing app or its features are present. The user-selected product name is **myDrive**, and all project paths are portable.

## UI priority on every native platform

The everyday menu popup must be small and readable at a glance, with dense rows, clear current status and frequent controls. Setup/details use native menus/dialogs. The full window is optional. Windows now uses a 344-unit normal width and 420-unit maximum normal height; macOS/Linux must follow the same [native UI requirements](docs/NATIVE-UI.md) in their native shells. Those ports remain unimplemented and their testing is deferred.

## Completed in the first Windows milestone

- Shared Rust core with a JSON-over-stdin native sidecar boundary.
- Atomic bookmark storage, validation and corruption preservation.
- Five connection types: local, SMB, SFTP, WebDAV and S3.
- Native Windows secret store, connection editor, manual file operations, transfer cancellation and local history.
- Default tray popup; optional full window; identical underlying views and actions.
- Native SMB reconnect checks.
- Windows Cloud Files feasibility spike: real dataless placeholder and hydration verified.
- Unit and local HTTP wire tests; runtime layout/credential/core-bridge diagnostic.

## Completed in the Syncthing Windows milestone

- Reuse the running local Syncthing instance, without owning its lifecycle or changing unrelated folders.
- Select this project or another local folder and offer it to an existing device in one action. A new remote share may still require acceptance there.
- Immediate per-file and per-folder Sync/Stop, preserving existing copies and hand-written ignore rules. Nested selections, literal glob characters, stale updates, and overlapping root protection.
- Folder status, device connectivity, pending files, errors, pause/resume and rescan from the tray popup and full window.
- New-share defaults: file watcher, 20 received versions, preserved alternative edits. Existing history settings remain intact.
- Friendly saved alternative edits and version recovery, with a separate backup before restore and protection against same-second archive name collisions.
- Two real isolated Syncthing daemons verify transfer, exclusions, offline divergent edits, reconnection and recovery: 35 integration checks pass.
- Simple SMB address entry; bounded native connection calls and explicit drive-letter collision handling.
- Persisted preferences and current-user single-instance activation.

## Next: complete the Windows P0 mount and sync milestone

1. Remote-backed Cloud Files provider, rooted per bookmark, with enumeration and ranged hydration; Windows Explorer sync-root/sidebar registration.
2. Persisted SQLite sync state, remote revision tracking and retry queue. Do not call a transfer complete until the server confirms it.
3. Background uploads with optimistic concurrency and conflict copies; protect changed files on disconnect or failed transfers.
4. Keep Offline / Free up space, placeholder status, progress reporting, cancellation and reconnection.
5. Multipart S3 uploads, resumed transfers, request signing test vectors, endpoint/provider interoperability tests.
6. SFTP interoperability with a real server, SSH config parsing, host-key enrollment UX, symlink policy and cancellation cleanup.
7. SMB reconnection on wake and real-server recovery validation. Bounded attempts and drive-letter collision handling are implemented.
8. Taskbar jump list, optional login startup and an installer. Preferences and single-instance activation are implemented.

## Native platform ports

- **Android / iPhone / iPad (mobile preview 0.4.0):** Native Compose and SwiftUI sources under [Mobile/](Mobile/README.md), saved SMB connections, browse/upload/download, create/rename/delete, platform secret stores, transfer history/cancellation, connection metadata imports and installed-Blip account sharing. Android APK compilation and native framework checks pass; iPhone compilation/signing and real phone/SMB/Blip tests remain pending. Embedded mobile Blip account transport, recursive folders, resumed SMB, phone Syncthing folder sync and full desktop protocol parity remain open. See [mobile validation](Mobile/VALIDATION.md).

- **macOS:** Partially delivered (preview 0.3.0, see [Mac/README.md](../Mac/README.md)): AppKit/SwiftUI status item and full window over the Rust sidecar; Keychain adapter; the original SMB health/fix behavior (12-second deadline-bounded checks, wake handling, Keychain-backed remount, `.DS_Store` network-stores fix); error classification on attention cards; safe cross-device fix requests over a `.mydrive-requests` mailbox in the shared folder; Syncthing events feed via the new bounded `syncthing.events` core action. Still open: FileProvider extension and Finder integration (mounting SFTP/WebDAV/S3 as volumes), remote acceptance in the Windows shell, smart-sync placeholders, interactive exercise of every fix on live shares, reboot persistence. No original macOS source was attached; the behaviors were rebuilt with regression tests instead.
- **Linux:** GTK4/libadwaita, libsecret, StatusNotifierItem, FUSE 3 helper, native notifications, Flatpak manifest/desktop/metainfo. Resolve host-helper versus sandbox mounting with a real FUSE spike. Build and verify on Linux before claiming availability.
- Shared core code remains free of platform UI imports. Platform mounting, credential stores and shell integration belong in each native shell.

## Teams, encryption and remaining protocols

Follow the reference plan's phases 3–6: durable Smart Sync, locking, S3/object versions and local version stash, interoperable Cryptomator vaults, sharing links, OAuth cloud APIs, FTP/FTPS, Azure/Swift, OS search, retention, throttling, localization and packaging.

Syncthing currently supplies durable device-to-device synchronization. The cloud-provider mounting, cloud upload queue and cloud locking requirements above remain distinct unfinished work. macOS now has a running preview validated on the real machine (see docs/VALIDATION.md, 2026-11-14); Linux and cloud-account testing remain deferred at the user's request, and macOS items listed above as open are not marked complete.

Cryptomator compatibility requires published format compliance and official-client round-trip tests. A proprietary encryption format must not be presented as compatible.

## Release gates

- Test every supported protocol against real servers, not only fixture servers.
- Network interruptions, conflicting edits, disk exhaustion, restart and large-file transfer tests.
- Verify >1 GiB hydration and upload with bounded memory.
- Verify credential changes, unknown/changed SSH keys and corrupt bookmark recovery.
- Verify all popup commands with keyboard, overflow menus, 100–200% display scaling and small work areas.
- Build macOS and Linux on their actual operating systems; do not mark those exit criteria complete based on Windows compilation.
