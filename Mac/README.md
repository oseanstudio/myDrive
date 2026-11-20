# myDrive for macOS

Preview 0.4.6 adds received-file previews and Open/Copy controls to the native receive panel. Its action menu includes Open With, Copy Path, Open Folder, Show in Finder, Quick Look, supported printing, and Get Info. Images, text, PDFs and supported Quick Look formats use local previews; other files show their native icon. Multiple received items have a picker. Missing or incomplete files cannot be opened or copied. Completed incoming rows can reopen the panel.

myDrive keeps Blip available through a background helper after you quit the Blip app. Install Blip and sign in once. The helper uses the engine from Blip 1.2.8 build 20261029214736 and keeps the same account and device. Allow access to Blip data if macOS asks. **Send & Receive** shows **Ready in the background** when connected. Use **Open Blip** from the gear menu when you need the desktop app. The DMG contains only myDrive and its dependencies.

Choose **Send…** in **Send & Receive** to select files or folders. The clipboard button or **+ → Paste and send…** works with copied files, folders, images, text, and links. Choose a recipient device and select **Send** to dispatch the transfer. Keep myDrive running for both Blip and Syncthing background checks.

In **Send & Receive → Sender permissions**, approve each sender device that may open web links. The master browser switch defaults on, with empty approval lists. Auto-accept files and Auto-open web links are independent per-device choices. Previous incoming senders remain listed through a local account-scoped catalog; addresses/device identifiers provide fallbacks when desktop Blip has no device name. A separate native receiving panel shows live state/progress while the menu popup is closed. File approval accepts new incoming files and folders from that exact device. Link approval accepts link-only root shortcut transfers up to 16 files of 64 KiB each while the master browser switch is on. Unknown senders appear in myDrive's own Send & Receive view with **Receive**. Completed, approved HTTP/HTTPS shortcuts open once in the default browser. Received files go under `~/Downloads/myDrive/<transfer-id>/`; old completed history is skipped. Existing desktop Blip receive rules remain in effect independently, and it may still show its own notification.

The GitHub workflow builds on an Apple Silicon macOS runner, runs native folder, preference, policy and local socket fixtures, checks signing and dynamic dependencies, and packages the app with the pinned Create macOS DMG action. This preview is ad-hoc signed, without Developer ID notarization. Actual Mac Blip interoperability and live browser/receive behavior need testing on your Mac; isolated tests do not establish a successful real transfer. The protocol is experimental and may change with Blip updates.

Subfolders can now have independent shares with different devices from their parents. Enter a subfolder in the file browser and choose **Sync this subfolder with another device…**, or choose it in **+ → Sync a folder…**. The shared core refuses common remote devices across overlapping roots. Parent devices and ignore rules stay unchanged. See [nested sharing rules](../docs/SYNCTHING.md#folder-and-file-controls).

Quit the previous myDrive before installing the preview to avoid activating the old running instance. Open the new app, check **Send & Receive** for background readiness, then approve a sender and quit Blip to test receiving. Folder rows show only devices configured for that folder, with full names and connection states in the folder menu.

A native status-item app over the shared Rust core (`Core/`): a compact menu
bar popup per [native UI requirements](../docs/NATIVE-UI.md), plus an optional
full window with the same views. It replaces everyday use of the Syncthing web
UI and watches SMB network drives.

Source update (2026-11-16): request-specific cancellation, coalesced status/events, validated connection caching, background/bounded SMB discovery, lazy browser rows, and batched activity writes are implemented in source. The app now uses the cloud logo. CI now checks Mac compilation and isolated native fixtures; live device testing is recorded separately.

Build output defaults to ~/Library/Caches/myDrive (or OSEAN_STUDIO_DATA). CARGO_TARGET_DIR and MYDRIVE_BUILD_DIR override the Rust cache and app output. The builder prints the finished bundle path; no build output needs to live in the synced source tree.

## Run

Build with Rust, Go, Node.js, and the macOS Swift toolchain.

```bash
Mac/build.sh          # builds Core (release) + Swift shell into the machine cache folder
Mac/build.sh --run    # build and launch
```

Keep the app folder together; the bundle carries the `mydrive-core` sidecar.
The app lives in the menu bar (no Dock icon). Left-click the cloud icon for
the popup; right-click for a menu with views and Quit.

## The popup

- **Sync** leads with status ("Local files up to date", "2 folders need
  attention"), then attention cards, then dense folder rows. Each card shows
  the real error in plain language with one-click fixes. Each folder row has
  pause/resume plus a menu: choose files, open the local folder, pending
  files, saved versions, rescan, show errors, protect version history.
- **Choose files** opens the per-file Sync/Stop browser. Sync and Stop apply
  immediately for every device sharing that folder.
- **Storage** lists SMB network drives with live health and free space,
  saved connections (local, SFTP, WebDAV, S3), and Syncthing devices.
- **Activity** shows a recent-updates feed from Syncthing events plus the
  local operation history (both capped at 200, both persisted).
- **Settings** holds connection settings, SMB options, start-at-login,
  appearance and Quit. Setup forms stay in dialogs.

## Errors and fixes

Attention cards say what is wrong, not just that something failed. The error
text from Syncthing is classified into a plain-language summary with fixes:

- "directory has been deleted on a remote device but is not empty" →
  **Delete leftovers here** (confirmation first) + rescan.
- Disk full, permissions, missing volumes, open-file limits → rescan-style
  fixes with an explanation of what to do first.
- Peer-side problems → **Ask the other device**.

### Fix requests between devices

Some fixes belong on the other computer. **Request a different fix…** sends a
request envelope (`.mydrive-requests/<id>.json`) into the shared folder;
Syncthing delivers it to every peer. A peer running myDrive shows
"Accept / Decline" with a description of the safe fix; accepting runs it and
writes a response that travels back. Only whitelisted fix kinds (currently
`rescan`, `unpause`) can be sent or accepted; both ends refuse anything else.
A peer without this feature (myDrive 0.2 for Windows) simply sees the small
hidden folder and never answers — the request can be canceled from here.

## SMB drives

Mounted SMB/AFP volumes are discovered from the OS and checked every 12
seconds (and on wake) with a deadline-bounded probe, so a wedged mount cannot
hang the app. One-click **Remount** uses the system mounter with the Keychain
credentials Finder saved; **Force remount** first force-unmounts. Shares
remembered from earlier passes are remounted automatically (on by default,
toggled in Settings) once the server answers on port 445, with a
one-attempt-per-minute, three-consecutive-failures backoff; disconnecting a
drive removes it from that memory. At launch myDrive writes the user-level
`~/Library/Preferences/nsmb.conf` that disables the SMB client's directory
enumeration cache — Apple's documented fix for Finder showing stale, partial,
or empty folder listings — backing up any existing file first. A one-click fix
also stops `.DS_Store` files on network drives. Problems color the menu bar
icon and the popup's status dot red (broken: folder errors, unavailable
drives, Syncthing down), orange (pending files, paused sync), or green.

## Connection details

The Syncthing connection is discovered from the running instance's config
(`~/Library/Application Support/Syncthing/config.xml` first); a manual
loopback address and API key can be set instead (stored in Keychain). myDrive
starts the installed engine in the background independently of Syncthing.app,
using its existing configuration and device identity. Discovery includes both
Applications locations (`Contents/Resources/syncthing/syncthing`), Homebrew and
PATH. If absent, the shared Rust manager installs the official SHA-256-verified
engine in myDrive's Application Support folder. Quitting myDrive leaves syncing
running. Manual endpoints bypass automatic startup. The lifecycle, Stop-folder
and fixed popup height changes still require a Mac rebuild and runtime validation.

Secrets for SFTP/WebDAV/S3 bookmarks live in
the Keychain (service `myDrive`, account `myDrive/<bookmark-id>`), never in
bookmark JSON. SFTP/WebDAV/S3 files open as downloaded copies; local and SMB
files open directly.

## Diagnose

```bash
Mac/build.sh --diagnose /tmp/mydrive-diagnose
```

Runs the self-test without user interaction: Keychain roundtrip, bookmark
persistence through the core, core bridge listing, live Syncthing snapshot
with an attention preview built from real errors, fix-request mailbox
roundtrip (including refusal of non-whitelisted kinds), SMB mount list, and
popup layout captures at 344 pt wide with the 420 pt height cap. Writes
`report.json` and PNGs.

## Status and limits (preview 0.3.0)

Implemented and verified on this Mac: live dashboard over the running daemon
(19 folders, 3 devices), error cards with real text and fixes, fix-request
mailbox roundtrip, SMB health over 4 live mounts, events feed, single
instance, diagnostics suite.

Implemented but not yet exercised interactively: clicking through each fix on
live folders, SMB remount/force-remount, the full window, start-at-login.
Not implemented: FileProvider Finder mounting (next milestone), remote
acceptance in the Windows 0.2 shell, per-device smart sync. File names
containing `:` (Finder-encoding artifacts) are refused by the core's path
rules. A crowded menu bar may push the icon into the hidden-items area.
