# OpenDrive → Mountain Duck Feature Parity Plan

## Context for the implementing agent

You are working inside the OpenDrive project folder — the directory containing
this `PLAN.md`, `README.md`, `build.sh`, and `Sources/`. **Do all work relative to
that directory.** The folder is portable: it may live at any path, on any macOS
computer (it might not even be a git repo yet — that's fine). Never assume or
hard-code an absolute path; use the project root as your working directory for
every command, and reference all files by paths relative to it. If you need the
project root at runtime, derive it from the location of `PLAN.md` or `build.sh`.

The project today is a
minimalist macOS menu bar app (single file `Sources/main.swift`, ~880 lines, AppKit,
no dependencies) that keeps existing SMB shares mounted and healthy:

- Health check every 12s + on wake from sleep, force-remount of wedged mounts using Keychain credentials
- Writes `~/Library/Preferences/nsmb.conf` (`dir_cache_*` keys) to fix Finder blank-folder bug
- Disables `.DS_Store` writes on network shares
- Built with `build.sh` (`swiftc`, ad-hoc signed) → `build/OpenDrive.app`

**Goal:** evolve this into a Mountain Duck-class client — mount server/cloud storage
as a disk in Finder, with smart sync, file locking, versioning, and encryption —
while **keeping the existing mount-health features working** (they are not in
Mountain Duck; do not delete them).

**Hard constraints:**
- **Cross-platform: macOS, Windows, and Linux are all in scope.** All protocol, sync, and business logic lives in a shared cross-platform core; all UI is fully native per platform (see "Architecture split" below). No cross-platform UI toolkit (no Electron, Flutter, Qt) — the Mac UI must be pure AppKit/SwiftUI, the Windows UI pure WinUI 3, the Linux UI pure GTK4/libadwaita.
- **The macOS app uses fully native Apple code**: AppKit + SwiftUI, the FileProvider framework for mounting, Keychain, native notifications, native Finder context menu. No third-party UI or FUSE layer.
- **The Windows app uses fully native Windows code**: WinUI 3 (Windows App SDK) for UI, the system tray, Windows Cloud Files API (cldflt) for mounting, Windows Credential Manager for secrets, native Explorer shell integration.
- **The Linux app uses fully native Linux code**: GTK4 + libadwaita UI, tray via StatusNotifier/AppIndicator, mounting via FUSE 3, secrets via libsecret (freedesktop Secret Service), native desktop notifications. **Packaged and distributed as a Flatpak** (flatpak-builder manifest included in the repo).
- Target platform's OS APIs only — never emulate the other platform's look.
- Keep the build simple per platform: `build.sh` (macOS), `build.ps1` (Windows), and `build-flatpak.sh` (Linux) each produce a runnable app relative to the project root, with no absolute paths anywhere in the scripts. No App Store signing required (ad-hoc is fine).
- Do not break the current SMB babysitter behavior at any phase; each phase must end with a working, buildable app.
- Prefer system frameworks over vendored C dependencies unless noted (libssh2, libwebdav via curl are acceptable exceptions, statically linked).

## Architecture split (decide up front, follow in every phase)

```
Core (shared, cross-platform, no UI):
  - Bookmark model + credential storage abstraction (Keychain on macOS, Credential Manager on Windows)
  - FileClient protocol + all protocol implementations (SFTP, WebDAV, S3, FTP, cloud APIs)
  - Smart Sync engine, sync state database, versioning, Cryptomator vaults, locking
  - Language: Swift (compiles on both macOS and Windows) or Rust — pick one and note the
    choice in README. All Core code must have zero AppKit/WinUI imports.

macOS app (native Apple):
  - Menu bar (NSStatusItem) + windows in AppKit/SwiftUI
  - FileProvider framework extension for mounting
  - Finder context menu via FileProvider actions / Services

Windows app (native Windows):
  - Tray app + windows in WinUI 3 (Windows App SDK)
  - Mounting via Cloud Files API (sync root registration, placeholder files, hydration/dehydration)
  - Explorer context menu via shell extension
```

- The Core exposes a small async API (list/read/write/mount/sync events). Each platform UI is a thin shell over it.
- Platform-specific mount layers are separate: `Mount/FileProvider` (macOS, Swift), `Mount/CloudFiles` (Windows, C++/C#), and `Mount/FUSE` (Linux) behind a common "MountBackend" concept.
- Keep directory structure platform-clean: `Core/`, `Mac/`, `Windows/`, `Linux/` — never import platform UI into Core, never import another platform's UI.

## Target feature matrix (Mountain Duck 5.x, macOS + Windows)

| Feature | Priority |
|---|---|
| Protocols: SFTP, WebDAV, S3 (+S3-compatible: Wasabi, B2), SMB | P0 |
| Protocols: FTP/FTPS, Google Drive, OneDrive, Dropbox, Box, Azure, Swift | P1 |
| Mounting: FileProvider (macOS) / Cloud Files API (Windows) / FUSE 3 (Linux) | P0 |
| Smart Sync: remote listing visible, download-on-open, "Keep Offline" | P0 |
| Background upload of local changes, sync status badges, Activity/History UI | P0 |
| File locking (WebDAV locks + lock-owner files; Office read-only) | P1 |
| Versioning (S3 versioned buckets + custom local version stash) | P1 |
| Cryptomator-compatible vaults (client-side encryption) | P1 |
| Sharing links (S3 presigned, Nextcloud/Dropbox/GDrive/OneDrive share API) | P2 |
| Spotlight (macOS) / Windows Search / GNOME Tracker search | P2 |
| Multiple bookmarks, status bar (macOS) / tray (Windows, Linux) management, Finder/Explorer/Files context menu | P0 |
| Native UI per platform: AppKit/SwiftUI on macOS, WinUI 3 on Windows, GTK4+libadwaita on Linux; Flatpak package for Linux | P0 |
| Localize (can defer; English-only acceptable initially) | P3 |

---

## Phase 0 — Restructure (do first)

The single 881-line `main.swift` cannot host this. Refactor into a package layout
without changing behavior. Verify `build.sh` still works after.

```
Package.swift
Sources/
  OpenDrive/                 (macOS menu bar UI target — pure AppKit/SwiftUI)
    main.swift
    StatusItem/ ...
  Core/                      (shared cross-platform core, no UI imports)
    Bookmarks/               Bookmark model, credential storage (Keychain on macOS)
    Protocols/               FileClient protocol (see Phase 1)
    Mount/                   mount backend abstraction
    Sync/                    Sync engine, cache DB
    Vault/                   Cryptomator
  Mac/                       macOS-only glue (FileProvider plumbing, Finder integration)
    Mac/                       macOS-only glue (FileProvider plumbing, Finder integration)
    FileProvider/            FileProviderExtension target code
Windows/                     Windows app (separate build, same Core)
  App/                       WinUI 3 tray + windows (native Windows UI)
  CloudFiles/                Cloud Files API (cldflt) sync-root/placeholder layer
  build.ps1
Linux/                       Linux app (same Core)
  App/                       GTK4 + libadwaita windows, tray (AppIndicator)
  Fuse/                      FUSE 3 mount backend
  packaging/flatpak/         Flatpak manifest, .desktop, appstream metainfo
  build-flatpak.sh
build.sh
```

- Extract the existing code into `Core/` services (SMBHealthService, NSMBConfService) and keep the AppKit status bar UI calling them. UI stays in `Sources/OpenDrive/`; everything reusable moves to `Core/` with zero AppKit imports so it can later compile on Windows.
- Introduce a `Bookmark` model now: `{ id, nickname, protocol, host, port, path, credentialsRef, mountPath, options }` persisted as JSON + Keychain. The existing SMB shares become bookmarks of protocol `.smb` managed mode.
- Add a Preferences window: bookmarks list, add/edit/delete, protocol picker.

**Exit criteria:** app builds, existing health/fix features work, bookmark CRUD works for SMB bookmarks.

## Phase 1 — Protocol abstraction + SFTP/WebDAV/S3 clients

Define one internal trait that all backends implement:

```swift
protocol FileClient {
  func list(_ path: String) async throws -> [RemoteFile]   // name, size, mtime, isDir, perms
  func read(_ path: String, offset: Int64?) async throws -> AsyncThrowingStream<Data>
  func write(_ path: String, from: URL, progress: ProgressHandler) async throws
  func mkdir / delete / move / copy / exists
  func stat(_ path: String) -> RemoteFile?
  var supportsLocking: Bool { get }         // WebDAV only
  var supportsVersioning: Bool { get }      // S3 only
}
```

Implement, in order (each independently testable against a real server):
1. **SFTP** — use `libssh2` via a small C shim, or SwiftNIO SSH (preferred if vendoring is acceptable). Support public key + password auth, read OpenSSH `~/.ssh/config` and `known_hosts`.
2. **WebDAV** — URLSession is sufficient (PROPFIND, GET, PUT, MKCOL, MOVE, COPY, LOCK/UNLOCK). Must interop with Nextcloud/ownCloud and IIS.
3. **S3** — implement SigV4 signing directly (no SDK): ListObjectsV2, GET/PUT/DELETE, multipart upload for >100 MB, presigned URLs (needed for sharing later). Bucket-region autodetect. Works for AWS, Wasabi, Backblaze B2, MinIO.
4. **FTP/FTPS** — P1; can use a Swift FTP lib or wrap `curl`'s library.

Add unit tests with a local docker-less approach where possible (e.g., `openssh` local server, local S3-compatible via `minio` binary if allowed; otherwise mock the wire protocol).

**Exit criteria:** each client can list/upload/download/move/delete against a real test server; credential entry via bookmark editor with Keychain storage.

## Phase 2 — Mounting (the core of Mountain Duck)

Platform-native mounting, two backends over the same Core:

### macOS — FileProvider framework (macOS 11+)

This is the hardest phase. Use Apple's **FileProvider framework**,
which is exactly what Mountain Duck v5's "Integrated connect mode" uses — no
kernel extension, no macFUSE.

- Create a `FileProviderExtension` app extension target (new extension in the app bundle). Build a `FileProviderExtension` subclass backed by a `FileClient` + local cache.
- Register one File Provider domain per bookmark. Mount/unmount = domain create/remove. The volume appears in Finder automatically under Locations.
- Enumeration: return cached listing instantly, then refresh from `FileClient` and report updates via `signalEnumerator`.
- Fetch contents on demand: download to the extension's local storage on `fetchContents`, honoring `FileProviderItem` metadata.
- Uploads: implement `createDirectory`, `importDocument`, `renameItem`, `deleteItem`, `moveItem` with conflict handling (`delete`/`keepBoth`).
- Errors must map to `NSFileProviderError` (.notAuthenticated, .serverUnreachable, .insufficientSpace, etc.) — this is what makes Finder show retry UI.
- Menu bar UI: list mounted domains, connect/disconnect per bookmark, show transfer progress (gathered from the extension via an XPC/app-group shared sync database).
- Keep legacy SMB bookmarks working: for `.smb` protocol, continue using native mounts (the existing babysitter), do NOT route through FileProvider.

Note: FileProvider extensions need `NSFileProviderExtension` entitlements and App Groups. Ad-hoc signing with `codesign` works for local dev; document any `pluginkit`/`fileproviderctl` debug steps in `build.sh` comments. Keep all build/signing paths relative to the project root so the folder stays portable.

**Exit criteria:** an SFTP bookmark mounts as a real Finder volume; files open in any app, download on open; changes save back; disconnect/reconnect works; app survives reboot.

### Windows — Cloud Files API (can be built in parallel or after macOS)

- Register a **sync root** per bookmark (`CloudFiles`/cldflt API) so the storage appears under Explorer's sidebar; use **placeholder files** for on-demand listing/hydration — this is Microsoft's equivalent of FileProvider.
- Implement hydration on open and dehydration (eviction) for "Free up space"; background upload via the sync-root callbacks.
- Explorer context menu (Keep offline / Free up space / Copy share link) via shell extension or the Cloud Files UI integrations.
- Tray app + all windows in **WinUI 3** (Windows App SDK): bookmarks editor, Activity, History — same features, native Windows controls, Mica styling, standard context menus. No macOS-inspired chrome; follow Windows HIG.
- Secrets in Windows Credential Manager; notifications via toast notifications.
- Dev/test on Windows 10 1809+ / Windows 11; `build.ps1` builds and registers the sync root without admin where possible.

**Windows exit criteria:** SFTP bookmark appears in Explorer; open file → hydrates; edit → uploads; dehydration frees space; tray UI manages connections.

### Linux — FUSE 3 + Flatpak (can be built in parallel or after macOS)

- Mount backend: **FUSE 3** (libfuse3). Each bookmark mounts as a directory under `~/OpenDrive/<nickname>` (no drive letters on Linux; this matches how GNOME/KDE present network locations). Implement on-demand read/write with a local page cache; placeholders are harder than on macOS/Windows, so a pragmatic P0 is full-listing + on-demand file download; defer true dataless files to P1 if needed.
- UI: **GTK4 + libadwaita** — a windowed app with a tray icon via **StatusNotifierItem/AppIndicator** (works in GNOME with the AppIndicator extension and in KDE natively). Bookmarks editor, Activity, History, Preferences as libadwaita windows; follow GNOME HIG exactly (header bars, libadwaita widgets). No Windows or macOS styling.
- Secrets: **libsecret** (Secret Service). Notifications: `libnotify`. File manager integration: Nautilus scripts/context actions where possible.
- **Packaging: Flatpak is the required distribution format.** Add a repo-local manifest (`packaging/flatpak/<app-id>.yml`, e.g. `io.github.opendrive.OpenDrive`), buildable with `flatpak-builder`, including required permissions (`--filesystem=home` or portal-based file access, `--talk-name=org.freedesktop.secrets`, network). Ship a `.desktop` file and appstream metadata (metainfo) with screenshots for Flathub. Use the Freedesktop/GNOME runtime SDKs; if the Core is Swift, build it inside the Flatpak SDK or prebuild via a module; document the choice in the manifest.
- Sandbox note: FUSE mounts inside the Flatpak sandbox have constraints (subuser/`--user` mounts, fuse permissions). If mounting outside the sandbox is required, split a small non-sandboxed mount helper binary installed on the host that the Flatpak app drives over D-Bus — decide and document during the spike.

**Linux exit criteria:** `flatpak-builder` builds and installs the app; an SFTP bookmark mounts under `~/OpenDrive/`; open file → downloads on demand; edit → uploads; tray icon works in GNOME and KDE; secrets stored via libsecret.

## Phase 3 — Smart Sync

- On-demand is largely free from FileProvider (dataless items). Build the control layer:
  - "Keep Offline" / "Free up space" on files & folders (Finder context menu via the extension's supported actions + a Sync menu in the status bar; Explorer context menu + Cloud Files actions on Windows; Files/Nautilus context actions + tray menu on Linux).
  - Selective sync: per-bookmark include/exclude paths (stored in the bookmark).
  - Eviction policy: purge local cache for items not opened in N days when volume pressure detected.
- **Status badges:** FileProvider supplies "download/upload in progress" natively; add your own sync-state DB (SQLite, in App Group container) recording `upToDate | syncing | offline | error` per item for the Activity panel.
- **Activity & History UI:** a window in the main app listing current transfers (cancel button) and a history of recent edits (item, direction, time, result). Feed from the sync DB. Native windows on each platform (AppKit/SwiftUI on macOS, WinUI 3 on Windows, GTK4/libadwaita on Linux) over the same sync DB.
- **Notifications:** post local notifications on remote-added/updated files (from enumerator refresh diffs), matching Mountain Duck's file-update badges — UserNotifications on macOS, toasts on Windows, libnotify on Linux.

**Exit criteria:** fresh mount shows full remote tree without downloading; open a 1 GB file → downloads on demand; "Keep Offline" survives disconnect; evictions free disk; activity/history visible and cancelable.

## Phase 4 — Teams features

1. **File locking** — WebDAV: real LOCK/UNLOCK with refresh + timeout. For protocols without locks: create `<filename>.~lock` owner files and honor others'. Open a locked file read-only; show lock owner in Activity. Integrate with the local file's write permissions so Office shows read-only.
2. **Versioning** — S3: list/retrieve/delete object versions when bucket is versioned; preview of old versions (Quick Look on macOS, Shell preview on Windows); restore. All protocols: **custom versioning** — before overwriting, stash the prior file to `<root>/.opendrive_versions/<path>/<timestamp>` (configurable retention count).
3. **Cryptomator vaults** — implement the Cryptomator vault format (AES-SIV + AES-CTR, scrypt KDF, masterkey.cryptomator / vault.cryptomator files). Interop goal: a vault created by the official Cryptomator app opens here and vice versa. Attach a vault to any bookmark (mounts the decrypted view). This is well-specified — follow the spec exactly; do not invent a format.
4. **Sharing** (P2) — S3 presigned GET with expiry; provider share APIs for Nextcloud, Dropbox, GDrive, OneDrive (P1 protocols). Copy link to clipboard from Finder/Explorer/Files context menu.

**Exit criteria:** two clients editing the same Office doc can't clobber each other; deleted file recoverable from versions; Cryptomator vault mounted over S3 round-trips with the official client.

## Phase 5 — Remaining P1/P2 protocols + polish

- Google Drive / OneDrive / Dropbox / Box via OAuth2 (their respective APIs; browser flow via `ASWebAuthenticationSession` on macOS, the OS browser flow on Windows, and xdg portal `OpenURI`/loopback redirect on Linux; store refresh tokens in Keychain / Credential Manager / libsecret). Map their file models onto `FileClient`; handle rate limits with backoff.
- Azure Blob, OpenStack Swift (S3-style object APIs).
- Google Docs: URL-reference files (`.gdoc` stubs opening the browser).
- Search: FileProvider indexing on macOS, Windows Search on Windows, GNOME Tracker/indexed directories on Linux; verify in Spotlight/Explorer/GNOME Shell search.
- Error UX: friendly error strings, retry with backoff, connection test button in bookmark editor.
- Performance pass: directory caching (SQLite), parallel transfers (4–8 concurrent), bandwidth throttling setting, resumed downloads/uploads.
- Preferences: default download behavior, versioning on/off + retention, proxy settings, debug log window.

## Phase 6 — Windows + Linux ports of remaining surface + polish

- Port everything from Phases 3–5 to the Windows UI (WinUI 3) and Linux UI (GTK4/libadwaita) on top of the shared Core: Smart Sync controls, locking, versions, vaults, sharing, Activity/History, preferences.
- Windows-specific polish: jump list, Explorer status-bar overlays, installer (MSIX), auto-start with login.
- Linux-specific polish: Flatpak auto-update, portal-based file dialogs, XDG autostart entry, .desktop actions, Flathub submission readiness (metainfo, screenshots, verification).
- Localization, app icons for each protocol, documentation site/README updates.

---

## Suggested order of attack & rough sizing

| Phase | Effort | Risk |
|---|---|---|
| 0 Restructure | small | low |
| 1 Protocol clients | large | medium (S3 SigV4, SSH) |
| 2 macOS FileProvider mount | large | **high** — extension sandboxing/entitlements; do spike first |
| 2b Windows Cloud Files mount | large | high (needs a Windows dev machine) |
| 2c Linux FUSE mount + Flatpak | medium | medium (FUSE-in-sandbox constraints; spike first) |
| 3 Smart Sync | medium | medium |
| 4 Teams features | large | medium (Cryptomator spec compliance) |
| 5 More protocols | medium | low |
| 6 Windows + Linux ports + polish | large | low-medium |

**Do a Phase 2 spike early** (day 1): get a trivial FileProvider extension showing a static file in Finder before investing in Phase 1 depth — if the extension can't be loaded/ad-hoc-signed in your environment, everything downstream changes. Same for Windows: get a placeholder file visible in Explorer via cldflt before building on it. Same for Linux: mount a trivial FUSE 3 filesystem that works from inside the Flatpak sandbox before building on it.

## Testing checklist per release

- Mount SFTP/WebDAV/S3 bookmark → volume appears (Finder on macOS, Explorer on Windows, `~/OpenDrive/` on Linux), tree lists, deep nesting works
- Open >1 GB file, edit, save → uploads in background, badge clears
- Kill network mid-transfer → error badge, auto-retry when back
- Two-machine conflict → lock or conflict-copy, no data loss
- Reboot → domains/sync roots remount automatically
- (macOS) Existing SMB health features: wedged-share remount and nsmb.conf fix still work
- (macOS) `build.sh` from a clean copy of the folder → running app; (Windows) `build.ps1` does the same; (Linux) `flatpak-builder` with the in-repo manifest installs and runs the app
- UI audit: macOS build uses only native AppKit/SwiftUI controls and conventions; Windows build uses only native WinUI 3 controls; Linux build uses only GTK4/libadwaita and follows GNOME HIG — no cross-platform look-alike widgets
