# myDrive

Download the Windows installer, Linux AppImage, or Apple Silicon macOS DMG from [GitHub Releases](https://github.com/oseanstudio/myDrive/releases). The desktop workflow publishes the three packages together after their checks pass. Packages include their dependency notices. The optional Blip integration uses separately installed Blip software.

A native storage client, starting with Windows. The everyday interface is a compact **system tray popup**; **Open full window** provides more space with the same screens and actions.

The popup puts status and dense folder rows first in a stable 344 × 420 logical-unit footprint—about 45% less area than the previous busy popup. It anchors once when opened and keeps its position and size during refreshes, navigation and native dialogs. This compact native layout is a priority for every platform; see [native UI requirements](docs/NATIVE-UI.md).

On Windows and macOS, myDrive reuses a running Syncthing engine or starts the installed engine in the background with its existing configuration. The Syncthing GUI can stay closed. If no engine is installed, myDrive installs the official, checksum-verified core for the current user. See [engine management](docs/SYNCTHING.md).

## iPhone, iPad and Android preview

Native mobile clients are in [Mobile/](Mobile/README.md). The Android debug APK is built; the iPhone/iPad SwiftUI source still needs compilation, signing and testing in Xcode. Both clients implement SMB browsing and file operations over an existing network connection, including Tailscale, and use the installed Blip app's account through native sharing. Blip receives remain in Blip, with explicit import from a user-selected received folder. Embedded mobile Blip transport and phone Syncthing folder sync are not implemented. See [mobile validation](Mobile/VALIDATION.md).

The shared project reaches the Mac through the existing Syncthing folder. Tailscale is optional network routing for SMB; it is not required for project synchronization.

## Run on macOS

```bash
Mac/build.sh --run
```

Requires macOS 14 or newer and Rust stable (the Swift toolchain ships with Xcode). The app appears in the menu bar; left-click opens the compact popup, right-click the menu. See [Mac/README.md](Mac/README.md) for the full guide, including fix requests between devices.

## Run on Windows

Open `build/windows/myDrive.exe`, or run `./run.ps1`. The published build includes .NET and the Windows App SDK runtime. Keep the executable with the other files in its folder.

- Click the tray icon to open or hide the quick menu.
- Use the header's view menu for **Sync**, **Storage**, **Transfers**, **Activity** and **Settings**.
- **Transfers** provides experimental Blip sending and receiving over the internet. Start its separate engine, connect an account only when ready, choose a device and files, and accept incoming requests. Popup dismissal keeps transfers running; quitting myDrive stops its owned engine. See [Blip setup and test limits](docs/BLIP.md). Account and real cross-network tests remain deferred.
- **＋ → Sync a folder…** opens the native sharing form. Choose a folder and device, then **Start syncing**. **This project** selects this project folder. A new share may need acceptance on the other device.
- Click a synced folder name to choose files. **Sync** and **Stop** apply immediately. Stop keeps existing copies. Use the pause icon to pause/resume a folder and **…** for pending files, saved versions and recovery.
- **… → Stop syncing folder…** removes that folder from this computer's sync list after confirmation. Files and saved versions remain on every device; other folders and remote configurations are untouched. Add the folder again later to resume. The pause icon is the temporary alternative.
- **＋ → Share over SMB…** on Windows and macOS creates an SMB3-encrypted share using your existing Tailscale connection. Choose a folder or drop it into myDrive, then copy the address and generated password. Devices signed in as the same Tailscale user can connect. The share is read-only unless you enable **Allow changes to files**.
- **＋ → Tailscale SMB shares…** shows the active shares and can stop them. These shares stay active while myDrive runs, including when its menu is closed. Use a Tailscale version that supports raw TCP forwarding with PROXY protocol v2. If another Tailscale Serve route already uses TCP 445, myDrive stops setup and reports the conflict.
- **＋ → Open SMB share…** accepts `\\computer\share` or `smb://computer/share`. This opens the network copy directly; Sync keeps offline copies on both computers. **Add storage connection…** provides other connection types.
- Click a storage connection or file row to open it. Folder/file **…** menus provide upload, new folder, download, rename and delete as appropriate.
- Use the popup's **↗** button, or right-click the tray icon and choose **Open full window**, for the larger interface.
- Activity and settings are available in both views. Closing the window keeps the app in the tray. **Quit myDrive** exits.

## Current implementation — preview 0.2

| Area | Status |
|---|---|
| Native WinUI 3, tray popup, optional full window | Implemented; both layouts rendered and inspected on Windows |
| Bookmark add/edit/remove and JSON persistence | Implemented, with atomic replacement and corrupt-file protection |
| Windows Credential Manager | Implemented; passwords, key passphrases and session tokens stay outside bookmark JSON |
| Local folders / native SMB shares | Browse, upload, download, new folder, rename, delete |
| Resumable SMB copies | myDrive uploads and downloads checkpoint every 8 MiB and retry recognized network interruptions for up to five minutes. Retry with the same paths to continue after a longer interruption. Linux supports checkpoints for kernel CIFS mounts. Applications that open files directly manage their own SMB file handles. |
| SMB health | 12-second checks plus a recheck on wake from sleep; native reconnect runs in a cancellable sidecar with a 15-second deadline; drive-letter collisions are checked; tray icon and status text turn orange for pending work and red for problems |
| Existing Syncthing integration | Local instance discovery, connected devices, folder status, one-click sharing, pause/resume, rescan, pending files and errors |
| Blip internet transfers (experimental, Windows) | Native Transfers view, separate headless engine/profile, account/code controls, device selection, send dispatch, pending receive acceptance and exact-peer trust; local lifecycle/state tests pass, authenticated send/receive still requires validation |
| Per-file and per-folder sync controls | Immediate Sync/Stop, literal-name escaping, nested overrides, existing ignore preservation, stale-update detection and backups |
| Offline copies and competing edits | Syncthing handles automatic reconnect and saved changes; alternative edits are grouped in the popup; new shares retain conflict copies and 20 received versions |
| Saved version recovery | Lists Syncthing's received history; backs up the current local file before restore; tests cover actual transfer and divergent offline edits |
| Preferences and single instance | Theme and sync choices persist; launching again activates the existing popup |
| SFTP via libssh2 | Client implemented; OpenSSH known_hosts verification, password/private-key/agent authentication; real-server validation remains |
| WebDAV | PROPFIND, GET, PUT, MKCOL, MOVE, DELETE; local HTTP fixture tests pass |
| S3 / compatible endpoints | SigV4, paginated listing, download, upload up to 100 MiB, folder markers, delete, region response handling; local HTTP fixture tests pass |
| Transfer cancellation and local activity history | Implemented; cancellation kills the sidecar process; remote upload cleanup may be needed |
| Cloud Files mounting | Isolated native spike passes real registration, placeholder creation and hydration; remote provider integration is **not yet implemented** |
| macOS status-item app (preview 0.3.0) | Implemented on macOS 14+; see [Mac/README.md](Mac/README.md). Compact popup with status-first sync view, real error text on attention cards, one-click fixes, safe cross-device fix requests, SMB drive health/remount, Syncthing events feed, full window; nsmb.conf folder-listing fix (Apple's blank-folder remedy) applied at launch; shares that drop off the mount list are remounted automatically with backoff; status colors green/orange/red in the menu bar icon and popup header |
| Cloud Smart Sync, collaborative locks, cloud versions, Cryptomator and cloud links | Planned; unavailable in this preview |
| macOS FileProvider mounting; Linux app / Flatpak / FileProvider / FUSE | Planned; unavailable in this preview |

SFTP/WebDAV/S3 files opened from the app are **downloaded copies**; edits to those copies do not upload automatically. Local folders, SMB and Syncthing files open directly. Upload creates a new file and refuses an existing destination. S3 rename is unavailable until a safe copy/delete transaction is implemented. WebDAV deletion follows server semantics, so deleting a folder can recursively delete its contents after confirmation.

Syncthing saves ordinary changes and reconnects automatically. Two different offline edits to the same file are preserved as alternatives, rather than silently discarded or claimed to be safely merged. Received version history is separate from local editor undo. Existing folders keep their settings; **Protect version history** enables received history if absent and unlimited conflict-copy retention. Version settings apply separately on each computer. See [Sync and recovery](docs/SYNCTHING.md).

This is the first working Windows milestone of the supplied multi-phase plan, **not complete Mountain Duck feature parity**. See [ROADMAP.md](ROADMAP.md) and the supplied [docs/REFERENCE-PLAN.md](docs/REFERENCE-PLAN.md).

## Build

Requires Windows 10 2004 or newer, x64; Rust stable with MSVC tools; .NET 8 SDK; Windows SDK. Visual Studio Build Tools with the C++ workload supplies the native compiler. The builder uses a project-local `.tools/dotnet` SDK if present, otherwise the SDK on PATH.

```powershell
./build.ps1 -Run
```

Scripts derive paths from their own location. The shared core has no UI imports and uses **Rust**, selected for native cross-platform compilation and straightforward native interop. The Windows shell is C# / WinUI 3. All protocol and bookmark logic lives in `Core/`; the shell supplies OS credential access, native file dialogs and SMB connections.

```text
Core/                       Shared Rust CLI, protocol clients, bookmark store, tests
Windows/App/                Native WinUI 3 interface and Windows Credential Manager
Windows/CloudFiles/         Isolated C++ Cloud Files API feasibility experiment
Windows/Network/            Native Windows SMB sidecar adapter
Mac/                        Reserved platform boundary; see ROADMAP.md
Linux/                      Reserved platform boundary; see ROADMAP.md
docs/                       Reference specification, architecture and validation
build.ps1                   Windows build/test/publish
run.ps1                     Windows launcher
```

## Test

```powershell
cargo test --locked --manifest-path Core/Cargo.toml
./tests/syncthing-integration.ps1
./Windows/CloudFiles/build-spike.ps1 -Run
./build/windows/myDrive.exe --diagnose <an-output-directory>
```

The native spike owns a new temporary directory, registers a real sync root, verifies a real hydrated file, disconnects, and unregisters it. It does not touch existing sync roots. A sandbox can deny registration with `0x80070005`; an ordinary desktop execution passed on the development machine without an elevated administrator token.

The `--diagnose` development mode checks Windows Credential Manager round-trip, bookmark persistence, the core bridge, both XAML layouts and status of the current Syncthing (starting its background engine if needed). It writes screenshots of this app's own surface and a JSON report, then exits. Its sample connection is in memory only and its temporary credential is removed. The Syncthing integration script starts two isolated loopback-only test instances, disables discovery/relays/NAT/upgrades, and stops only those instances afterward. It never changes the production daemon.

## Connection details

- **SFTP:** verify the host first using OpenSSH, e.g. `ssh username@host` (with `-p` for a custom port). Unknown or changed server keys are rejected. The preview uses explicit host/port/user fields; it does not parse SSH config aliases yet.
- **WebDAV:** use an HTTPS URL for the server or DAV endpoint. HTTP is intended for trusted local test servers. HTTP redirects are rejected, avoiding forwarding credentials to another endpoint.
- **S3:** use a path-style endpoint such as `https://s3.us-east-1.amazonaws.com`, bucket, region, access key ID and secret access key. Temporary credentials can include a session token. Multipart upload, presigned links and real-provider compatibility certification remain on the roadmap.
- **SMB:** enter a server name without slashes and a share/root path. Leave credentials blank to use the current Windows session. A drive letter is optional.

Application data is in the current user's LocalApplicationData `myDrive` directory. This contains bookmarks, preferences, the latest 200 activity entries, opened file copies, touched Syncthing rule/config backups, and pre-restore file backups. Secrets are separate Windows generic credentials named `myDrive/<bookmark-id>`. Syncthing's API key is read locally from its config, or saved in Credential Manager for manual connections. Back up bookmark JSON separately from secrets.

The original plan described an existing 881-line macOS source file, but only the plan was supplied. No original implementation has been refactored or tested. Its macOS-specific health behavior must be reintroduced and verified on macOS before that platform is considered ready.
