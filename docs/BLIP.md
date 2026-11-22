# Blip transfers in myDrive (experimental)

## Offline delivery between your devices

On current Windows and Mac builds, choose your destination in Send or Paste and Send as usual. If a desktop or laptop on your account is offline, myDrive checks other online desktops and laptops on the same account for relay support. A compatible relay stores the transfer and forwards it when the destination comes online. It removes its waiting copy only after Blip confirms delivery. Keep myDrive running on the relay. If no online candidate confirms support, myDrive sends directly.

Each participating computer needs the relay-capable myDrive build. Phones using the Blip share sheet and transfers sent from the official Blip app use their existing transfer flow. The destination uses its existing browser switch and approval for the forwarding device to open completed HTTP/HTTPS links. Relay control traffic never opens a file.

Waiting jobs survive reboot and resume when myDrive runs again. Send multiple files at once or queue separate sends over time. Folders keep their nested structure. Paste one web address per line to send up to 16 links together.

Open the popup's view menu → **Send**, or **＋ → Send with Blip…**. The same controls are available in the full window.

1. myDrive can reuse the existing Blip device on the computer when its saved profile is available. The native helper keeps it available while myDrive runs. If the engine is missing on macOS or Linux, choose **Set up Blip…**. Windows can copy a compatible installed engine or use **Blip options → Add Blip engine…**.
2. On a fresh profile, sign in from myDrive using your existing Blip email and the sign-in code. On Windows, select **Connect… → Start separately** to set up that profile. This creates a device in your Blip account.
3. In separate mode, wait for receiving settings to verify. Choose **Send…**, add the files or folder, and click the recipient device to send. Desktop mode uses the same account/device shown in Blip.
4. Incoming invitations have **Receive**. Manual receives in myDrive use separate UUID folders under myDrive's profile downloads directory. In separate mode you can optionally allow future automatic receiving from the exact device. In desktop mode Blip retains its existing automatic receiving rules and download location; those downloads may appear only in desktop Blip's folder, outside myDrive's **Received files** folder.
5. **Refresh** reads real native state. A requested transfer is not a delivery confirmation. myDrive shows Completed only when both native completion fields agree and there is no reported error.

The popup can close while transfers run. **Disconnect** stops myDrive's managed helper and opts out of automatic background receiving. A separately open Blip app can continue through the native host election. Quitting myDrive stops its Blip helper. Automatic background receiving defaults on and remembers explicit opt-outs. Re-enable it from **Send** → gear → **Keep Blip available in the background**.

If you move a synced folder, open the sync errors and select **Choose new location…**. Select the moved folder including its hidden Syncthing marker. myDrive updates the existing folder path, keeping the folder ID, peers, pause state and settings.

Windows live testing confirmed a received file and automatic link opening from an approved device while the Blip app was closed. Native test profiles exercise startup and local status separately from signed-in transfers.

After login, Blip manages its own account tokens and local logs in its separate profile directory, outside Windows Credential Manager. Keep that directory private; it is not included in source or runtime copies.

## Sender permissions and live receiving

In **Send**, type a name, email address or device name in **Find people & devices**. Known devices match as you type. Press Enter or click the search icon to look up a person through Blip, subject to their discovery settings. Recent recipients appear below the search field. Click one to choose files for that exact device, or use its menu for other send options. The **X** removes the shortcut from this account’s local recent list. A later send to that recipient adds it again.

In Send, choose **Senders…** (Windows) or expand **Sender permissions** (Mac). The list combines current Blip devices, exact senders from incoming transfer history and locally retained sender names. It refreshes every two seconds. A sender need not be online to remain selectable. Registered Blip names appear as supplied for each exact device and are remembered while that device is offline. If Blip supplies a contact name and device type, the send picker uses a label such as **Studio tester · Laptop**. Matching devices under one contact are numbered. Edit a label in Sender permissions on Windows or use the pencil beside it on Mac. Local nicknames survive refresh and remain scoped to the signed-in account. Approvals match exact user/device IDs and the signed-in account.

Devices are grouped under one sender heading. Auto-receive files and Auto-open links appear next to each device name. New devices need their own approval. The device label can be edited locally when Blip does not share a registered name. Exact IDs remain available in tooltips. Each sender has two independent approvals. **Auto-accept files** receives incoming file/folder invitations in Invited state. Native Pending means acceptance has already started; it does not execute/open files or grant browser opening. **Auto-open web links** permits new completed HTTP/HTTPS shortcuts to open, and also allows link-only incoming transfers to be accepted while the master browser switch is on. Both lists start empty; existing link approvals retain their previous link-only behavior. The master browser switch does not disable separately approved file receiving.

myDrive uses a separate native receive window/panel anchored beside the system-tray/menu icon, with sender, item names, native byte progress when available, Receive and sender-settings/Transfers actions. It stays open when the tray/menu popup is hidden or loses focus, updates as native state changes and dismisses completed notices after 30 seconds, pausing while hovered. A small transfer first seen completed after connection still gets a notice; initial completed history does not replay. Windows uses one consistent local poll for status, sender names and transfers. If desktop Blip is open, it retains its own independent notifications and receiving rules.

Sender names/IDs are cached only in the account-scoped local sender catalog, outside synchronized source. Tokens, file history and URLs are not written to that catalog. These controls and notification lifecycle require a fresh user-device test in addition to isolated fixtures; build/render tests alone do not prove a real automatic acceptance.

## Received links

### Cross-platform default

Automatic opening of received Blip web links defaults to **enabled** on Windows, macOS and Linux. A missing preference means enabled, including when upgrading. An explicit saved `false` stays off.

All ports must open new completed incoming root shortcut links from explicitly approved senders once in the system default browser, continue processing while their popup is hidden, and keep outgoing/pending/failed transfers, unsupported schemes and completed history from launching. Use the same opt-out and persistence behavior described below. Headless deployments can explicitly disable opening when no desktop browser is available.

| Platform | Current state |
| --- | --- |
| Windows | Implemented; `Preferences.BlipAutoOpenLinks` defaults to `true`, including when the field is missing from saved JSON. |
| macOS | The source preference `Preferences.blipAutoOpenLinks` defaults to `true`; `blip_auto_open_links` is optional in saved JSON so existing sync settings survive upgrades. Native desktop-session polling, manual receive, exact-sender approval and browser opening are implemented. CI exercises isolated native fixtures; a live Mac transfer is still required. |
| Linux | The GTK receiver uses the native backend and keeps the `blip_open` preference enabled by default. |

**Send → gear → Open received links automatically** is enabled by default. While myDrive is connected to Blip, new completed incoming `.url` (InternetShortcut) and `.webloc` files shared as top-level transfer items open their HTTP/HTTPS address in the system's default browser. This works while the popup is hidden or another view is selected; polling runs every two seconds. In Send, approve exact sender devices using Sender permissions. The approval list starts empty and is scoped to the current account. myDrive accepts pending link-only requests from approved senders; other requests require Receive in its own popup. Desktop Blip receiving rules remain independently in effect.

Existing completed history is skipped on connection/reconnection. Each transfer/address is claimed once before browser launch; hashed local claims prevent replay on refresh or restart without storing URLs in the ledger. Turning the option off suppresses opening, and enabling it starts from current history. Outgoing, pending, failed, dismissed and inconsistent completion states are excluded. A missing shortcut may be checked again after it becomes readable. Browser-launch failures are shown when Transfers is refreshed and are not retried automatically.

The shortcut file itself is never executed. Only the InternetShortcut URL field or plist URL string is read, with a 64 KiB limit. Executable/custom schemes, local-file targets, network shortcut paths and filesystem links/junctions are excluded. Folder contents are not scanned. Normal files keep their existing receiving behavior. A desktop session with a default browser is required for opening; unattended servers can disable the option.

The parser, typed saved-transfer metadata mapping, sender policy, completion handling and duplicate prevention are covered by local fixtures. The user confirmed real Windows automatic acceptance and default-browser opening, including with desktop Blip fully closed. Actual Mac interoperability still requires a fresh approved-sender test on a Mac.

## Background engine setup

The myDrive app, CLI and MCP use the same native transfer backend on desktop. The engine lives in myDrive's local data folder and is verified before use. The desktop installers contain the myDrive helper.

- Windows uses the verified x64 `blip-jni.dll` from Blip 1.2.8.0. myDrive can copy it from a compatible installed package, an existing prepared runtime or a DLL you select. Microsoft Store package downloads can require Microsoft Entra ID authentication, so a clean Windows setup needs the compatible file.
- macOS retains the verified native framework in myDrive's data folder. **Set up Blip** can fetch it directly from Blip when needed.
- Linux extracts only the native shared library from the verified Blip archive. It reuses the same state and transfer code as the Windows helper.

Status refreshes reuse the managed helper. myDrive preserves existing desktop account data, transfer state and sender permissions in place. Blip account, discovery and relay services still depend on Blip's infrastructure and plans.

## Checks

The C# service check in `tests/BlipServiceChecks/` uses a local fake CLI. `myDrive.exe --diagnose-blip OUTPUT_DIRECTORY` renders isolated UI fixtures.

`cargo test --manifest-path Core/Cargo.toml private_host_starts_without_java -- --ignored` exercises the native host using a temporary unsigned-in profile and a loopback address. Set `MYDRIVE_BLIP_DLL` on Windows or `MYDRIVE_BLIP_LIBRARY` on Linux to the verified engine before running it.

To test real transfers later, use a second device on cellular or a different network with Tailscale disconnected, start with a generated harmless file, and compare its SHA-256 at both ends after native completion. Then test a folder and interruption/resume. Local fixture tests do not establish internet transfer performance or unattended receiver readiness.


## Clipboard shortcut (Windows and macOS)

**Send with Blip…** opens a scrollable recipient list. On Windows, add files or a folder and click a device to send. On macOS and Linux, clicking a device opens the system file picker when you still need to choose the content. Accepting the picker sends to that device.

Copy content before choosing **Paste and send…** or clicking the clipboard button. myDrive reads the clipboard and shows the recipient list. Click a device to send the clipboard contents or other ready items. Cancelling deletes only generated payload files and preserves copied originals.

Receive preserves the exact native transfer ID, including uppercase Apple UUIDs. It confirms native acknowledgement instead of reporting success when the request was merely dispatched. A failed request remains retryable in the receive popup without opening the main menu or disconnecting the desktop session. Machine-only last-receive status stays in local app data and is excluded from source.

## Received files on Windows and macOS

The native receive notice includes a local preview, Open and Copy controls, and a file picker for multiple received root items. The Open dropdown also provides Open With, Copy Path, Open Folder, Show in Folder/Finder, supported Print, and Properties/Get Info. macOS additionally offers Quick Look. Print and Open With availability depend on the file type and platform. Clipboard writes, application launches and printing require an explicit click.

Previews use received local files only: bounded plain text, safe web-shortcut text and supported system/image/PDF thumbnails, with a file/folder icon fallback. No web preview is fetched. Actions revalidate native incoming completion, the metadata's actual path, file existence and absence of symlink/reparse ancestors. Incomplete, errored, missing or remote paths are unavailable. Completed transfer rows reopen the notice; this does not replay automatic link handling or alter sender approvals.
