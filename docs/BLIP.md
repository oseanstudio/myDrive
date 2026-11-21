# Blip transfers in myDrive (experimental)

## Offline delivery between your devices

On current Windows and Mac builds, choose your destination in Send or Paste and Send as usual. If a desktop or laptop on your account is offline, myDrive checks other online desktops and laptops on the same account for relay support. A compatible relay stores the transfer and forwards it when the destination comes online. It removes its waiting copy only after Blip confirms delivery. Keep myDrive running on the relay. If no online candidate confirms support, myDrive sends directly.

Each participating computer needs the relay-capable myDrive build. Phones using the Blip share sheet and transfers sent from the official Blip app use their existing transfer flow. The destination uses its existing browser switch and approval for the forwarding device to open completed HTTP/HTTPS links. Relay control traffic never opens a file.

Waiting jobs survive reboot and resume when myDrive runs again. Send multiple files at once or queue separate sends over time. Folders keep their nested structure. Paste one web address per line to send up to 16 links together.

Open the popup's view menu → **Send & Receive**, or **＋ → Send with Blip…**. The same controls are available in the full window.

1. On Windows, open myDrive after signing in to Blip once. myDrive keeps the existing device available through a managed headless helper; the official Blip app can be fully quit. The helper uses Blip's own profile paths and native interprocess host election, so the two apps can open and close without concurrent profile writers. No account file or credential is copied, no additional device is registered, and no sign-in code is requested. **Connect… → Use this computer's Blip account → Connect** is also available. Mac uses the same background behavior with the supported installed Blip framework. See Mac/README.md for the build requirement.
2. For a separate headless device, choose **Connect… → Start separately → Connect**. This creates a separate local myDrive profile and starts the headless engine. Then choose **Connect Blip…**, enter an email, and explicitly choose **Send sign-in code**. Enter the code in the native password field. This separate mode requires its own sign-in; it is optional when reusing the existing Windows desktop device.
3. In separate mode, wait for receiving settings to verify. Choose **Send…**, add the files or folder, and click the recipient device to send. Desktop mode uses the same account/device shown in Blip.
4. Incoming invitations have **Receive**. Manual receives in myDrive use separate UUID folders under myDrive's profile downloads directory. In separate mode you can optionally allow future automatic receiving from the exact device. In desktop mode Blip retains its existing automatic receiving rules and download location; those downloads may appear only in desktop Blip's folder, outside myDrive's **Received files** folder.
5. **Refresh** reads real native state. A requested transfer is not a delivery confirmation. myDrive shows Completed only when both native completion fields agree and there is no reported error.

The popup can close while transfers run. **Disconnect** stops myDrive's managed helper and opts out of automatic background receiving. A separately open Blip app continues through the native election. **Stop** in separate mode stops only myDrive's separate engine. Quitting myDrive stops its Blip helper; receiving continues if desktop Blip is still open. Syncthing is preserved. Stopping/cancelling a UI request never claims to cancel an already dispatched transfer; refresh before retrying an uncertain request. Automatic background receiving defaults on, including older preference files. Explicit Disconnect or choosing a separate engine turns it off. Re-enable it from Transfers → gear → **Keep Blip available in the background**, or connect manually. Startup failures back off for 30 seconds. Receiving rules and existing account/device identity are preserved.

Syncthing runs independently of its GUI. The desktop apps refresh folder status more frequently while Sync is visible and about every two minutes in the background. Windows and macOS can verify an unresponsive managed engine between status refreshes. Active sync uses the selected Syncthing configuration and file watchers. The engine continues independently when myDrive quits.

Windows live testing confirmed both a file and a fresh link received from an approved device with the official Blip app fully closed, and the link opened automatically. The background host reuses the existing signed-in identity and saved sender approvals. An isolated native election test also confirms endpoint availability when either participant quits. Separate-profile registration, interrupted large transfers and final checksums still require testing; no new sign-in code was requested. The Mac runner exercises the installed framework, socket and two-host handoff with a new isolated profile. A signed-in live Mac transfer remains to be tested. Linux remains deferred.

After login, Blip manages its own account tokens and local logs in its separate profile directory, outside Windows Credential Manager. Keep that directory private; it is not included in source or runtime copies.

## Sender permissions and live receiving

In Send & Receive, choose **Senders…** (Windows) or expand **Sender permissions** (Mac). The list combines current Blip devices, exact senders from incoming transfer history and locally retained sender names. It refreshes every two seconds. A sender need not be online to remain selectable. Registered Blip names appear as supplied for each exact device and are remembered while that device is offline. If Blip supplies a contact name and device type, the send picker uses a label such as **Studio tester · Laptop**. Matching devices under one contact are numbered. Edit a label in Sender permissions on Windows or use the pencil beside it on Mac. Local nicknames survive refresh and remain scoped to the signed-in account. Approvals match exact user/device IDs and the signed-in account.

Devices are grouped under one sender heading. Auto-receive files and Auto-open links appear next to each device name. New devices need their own approval. The device label can be edited locally when Blip does not share a registered name. Exact IDs remain available in tooltips. Each sender has two independent approvals. **Auto-accept files** receives incoming file/folder invitations in Invited state. Native Pending means acceptance has already started; it does not execute/open files or grant browser opening. **Auto-open web links** permits new completed HTTP/HTTPS shortcuts to open, and also allows link-only incoming transfers to be accepted while the master browser switch is on. Both lists start empty; existing link approvals retain their previous link-only behavior. The master browser switch does not disable separately approved file receiving.

myDrive uses a separate native receive window/panel anchored beside the system-tray/menu icon, with sender, item names, native byte progress when available, Receive and sender-settings/Transfers actions. It stays open when the tray/menu popup is hidden or loses focus, updates as native state changes and dismisses completed notices after 30 seconds, pausing while hovered. A small transfer first seen completed after connection still gets a notice; initial completed history does not replay. Windows uses one consistent local poll for status, sender names and transfers. If desktop Blip is open, it retains its own independent notifications and receiving rules.

Sender names/IDs are cached only in the account-scoped local sender catalog, outside synchronized source. Tokens, file history and URLs are not written to that catalog. These controls and notification lifecycle require a fresh user-device test in addition to isolated fixtures; build/render tests alone do not prove a real automatic acceptance.

## Received links

### Cross-platform default

Automatic opening of received Blip web links defaults to **enabled** on Windows, macOS and the future Linux version. A missing preference means enabled, including when upgrading an older preferences file; an explicit saved `false` remains off. This is a product requirement for each native receiver, rather than an optional feature that starts disabled.

All ports must open new completed incoming root shortcut links from explicitly approved senders once in the system default browser, continue processing while their popup is hidden, and keep outgoing/pending/failed transfers, unsupported schemes and completed history from launching. Use the same opt-out and persistence behavior described below. Headless deployments can explicitly disable opening when no desktop browser is available.

| Platform | Current state |
| --- | --- |
| Windows | Implemented; `Preferences.BlipAutoOpenLinks` defaults to `true`, including when the field is missing from saved JSON. |
| macOS | The source preference `Preferences.blipAutoOpenLinks` defaults to `true`; `blip_auto_open_links` is optional in saved JSON so existing sync settings survive upgrades. Native desktop-session polling, manual receive, exact-sender approval and browser opening are implemented. CI exercises isolated native fixtures; a live Mac transfer is still required. |
| Linux | Future native port. Its receiver and preference loader must implement this same enabled-by-default behavior and preserve explicit opt-outs. No Linux app exists yet. |

**Transfers → gear → Open received links automatically** is enabled by default. While myDrive is connected to Blip, new completed incoming `.url` (InternetShortcut) and `.webloc` files shared as top-level transfer items open their HTTP/HTTPS address in the system's default browser. This works while the popup is hidden or another view is selected; polling runs every two seconds. In Send & Receive, approve exact sender devices using Sender permissions. The approval list starts empty and is scoped to the current account. myDrive accepts pending link-only requests from approved senders; other requests require Receive in its own popup. Desktop Blip receiving rules remain independently in effect.

Existing completed history is skipped on connection/reconnection. Each transfer/address is claimed once before browser launch; hashed local claims prevent replay on refresh or restart without storing URLs in the ledger. Turning the option off suppresses opening, and enabling it starts from current history. Outgoing, pending, failed, dismissed and inconsistent completion states are excluded. A missing shortcut may be checked again after it becomes readable. Browser-launch failures are shown when Transfers is refreshed and are not retried automatically.

The shortcut file itself is never executed. Only the InternetShortcut URL field or plist URL string is read, with a 64 KiB limit. Executable/custom schemes, local-file targets, network shortcut paths and filesystem links/junctions are excluded. Folder contents are not scanned. Normal files keep their existing receiving behavior. A desktop session with a default browser is required for opening; unattended servers can disable the option.

The parser, typed saved-transfer metadata mapping, sender policy, completion handling and duplicate prevention are covered by local fixtures. The user confirmed real Windows automatic acceptance and default-browser opening, including with desktop Blip fully closed. Actual Mac interoperability still requires a fresh approved-sender test on a Mac.

## Runtime preparation

The source adapter is under `Blip/`; it uses the reviewed private Blip 1.2.8.0 Java/JNI interface. It is not an official Blip CLI. `Blip/runtime-lock.json` pins the reviewed native library and wrapper hashes, and mismatched engines are refused.

Runtime binaries are kept outside the synchronized project, at `OSEAN_STUDIO_DATA/Runtimes/myDrive Blip`, or the `OseanStudio/storage.json` root followed by `Runtimes/myDrive Blip`. Without either setting, the root is `%LOCALAPPDATA%/OseanStudio`. That directory contains `node.exe`, `jdk-25…`, `blip/app/*.jar`, `blip/bin/blip-jni.dll` and compiled `classes/`. Source and published app scripts contain no vendor binaries or account tokens. The local profile defaults to `%LOCALAPPDATA%/myDrive/Blip`; its socket path must be under 108 UTF-8 bytes.

The Windows app compiles its bundled adapter source once per adapter revision using the prepared local JDK. Status checks use that managed host’s existing process. Older prepared adapters still work with separate status requests.

The development preparation script accepts an already verified proof-of-concept runtime:

```powershell
./tests/prepare-blip.ps1 -PreparedRuntime 'C:\path\to\blip-poc\.runtime'
```

It copies the runtime to the external local runtime root, verifies the reviewed Blip hashes (native library, wrapper and desktop path decoder), copies the local Node executable, and compiles this checkout's Java sources there. It does not copy `.profiles`, sign in, change preferences, or start an engine. Blip and JDK use remain subject to their respective licenses; their installation here does not grant redistribution rights. Blip account, discovery and relay services still depend on Blip's infrastructure and plans.

## Checks

`node --test Blip/test/cli.test.mjs` covers CLI safety and framing. The standalone C# service check is `tests/BlipServiceChecks/`; it uses a local fake CLI, not an account or network. `myDrive.exe --diagnose-blip OUTPUT_DIRECTORY` renders stopped, sign-in, pending/active/completed, long-list, error, light/dark and full-window fixtures. That mode skips normal startup and makes no account requests or transfers. Review the generated `blip-report.json` and screenshots. The default profile is not read by fixture diagnostics.

`tests/DesktopBlipChecks/` performs read-only IPC queries against running desktop Blip using a fresh myDrive metadata profile. It checks attachment, disconnect/reconnect, stable identity and absence of an owned host. Arguments: adapter bundle, prepared runtime, Node executable, fresh short profile path. Do not run it against another user's session. Its output omits identities, tokens, device names and transfer details. CLI users can supply `--socket PATH` for status/devices/transfers/send/accept; hosting, sign-in and trust operations are refused with that option.

To test real transfers later, use a second device on cellular or a different network with Tailscale disconnected, start with a generated harmless file, and compare its SHA-256 at both ends after native completion. Then test a folder and interruption/resume. Local fixture tests do not establish internet transfer performance or unattended receiver readiness.


## Windows link runtime repair

Completed shortcut path decoding uses Windows known-folder lookups through JNA. The prepared runtime must include the complete, matching JNA 5.19.1 artifact in its external support directory. Run `tests/prepare-blip-support.ps1` to download and verify the SHA-256 pinned in `Blip/runtime-lock.json`; the CLI verifies it before use and places it before the packaged JNA classes on its classpath. This fixes the missing `jnidispatch.dll` resource that a real incoming shortcut exposed. No vendor binaries are stored in synchronized source. JNA licensing and redistribution requirements apply; see [upstream JNA](https://github.com/java-native-access/jna).

## Clipboard shortcut (Windows and macOS)

**Send with Blip…** opens a scrollable recipient list. On Windows, add files or a folder and click a device to send. On macOS and Linux, clicking a device opens the system file picker when you still need to choose the content. Accepting the picker sends to that device.

Copy content before choosing **Paste and send…** or clicking the clipboard button. myDrive reads the clipboard and shows the recipient list. Click a device to send the clipboard contents or other ready items. Cancelling deletes only generated payload files and preserves copied originals.

Receive preserves the exact native transfer ID, including uppercase Apple UUIDs. It confirms native acknowledgement instead of reporting success when the request was merely dispatched. A failed request remains retryable in the receive popup without opening the main menu or disconnecting the desktop session. Machine-only last-receive status stays in local app data and is excluded from source.

## Received files on Windows and macOS

The native receive notice includes a local preview, Open and Copy controls, and a file picker for multiple received root items. The Open dropdown also provides Open With, Copy Path, Open Folder, Show in Folder/Finder, supported Print, and Properties/Get Info. macOS additionally offers Quick Look. Print and Open With availability depend on the file type and platform. Clipboard writes, application launches and printing require an explicit click.

Previews use received local files only: bounded plain text, safe web-shortcut text and supported system/image/PDF thumbnails, with a file/folder icon fallback. No web preview is fetched. Actions revalidate native incoming completion, the metadata's actual path, file existence and absence of symlink/reparse ancestors. Incomplete, errored, missing or remote paths are unavailable. Completed transfer rows reopen the notice; this does not replay automatic link handling or alter sender approvals.
