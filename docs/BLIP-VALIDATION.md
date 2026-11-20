# Blip integration validation — November 16, 2026

## Automatic received-link opening — November 17, 2026

- Added **Transfers → gear → Open received links automatically**, enabled by default. New completed incoming root `.url`/`.webloc` files open HTTP/HTTPS targets using the OS default browser. The five-second poll keeps running while the popup is hidden or a different view is selected. It retrieves fresh authentication/device identity and transfer state together in one native query.
- Native metadata mapping checks pass with typed Blip saved-transfer fixtures: incoming/completed only, root files only, archive symlinks and nested folder contents excluded. Blip's shared URL writer emits `.url` InternetShortcut files (Craft evidence `ev_e24e35c34be6d66cc292f0199fb910c2bdcd975bfbba59760b4e2211e9ff2b98`, `ev_5425419a1f72d120fd86b2fea013036bfad97799dcec2d088b7230bc1e096e36`). Saved locations use the reviewed desktop path decoder, now hash-pinned alongside the native library/wrapper.
- Twenty-one link checks pass using generated shortcut files and an injected browser callback: old history skipped, completed-only launch, concurrent poll deduplication, persistence across restart, intentional new transfer allowed, no disabled backlog, delayed file availability, HTTP/HTTPS validation, unsupported schemes and network paths rejected, XML DTD not resolved, and failed launch not replayed. The shortcut files themselves are never executed. Claims store hashes rather than URLs or transfer IDs.
- Fourteen service checks and ten CLI checks pass. Read-only polling against the existing authenticated desktop session succeeds without account changes or opening links. Existing history had no undismissed completed transfers suitable for a live link-receive test.
- Native fixture rendering passes with stable 344 × 420 compact bounds; the added gear control fits alongside Refresh. Build succeeds. Fixture screenshots were visually reviewed.
- Actual receipt from another device and OS default-browser launch remain untested. No files/links were sent, no sign-in codes requested, and no historical links opened. macOS/Linux and session-zero execution remain deferred.

Reports and staging: this chat's workspace `blip-links/`.

## Desktop session reuse — November 17, 2026

- Added native **Transfers → Connect… → Use desktop Blip → Connect**, plus **Start separately** for an independent headless device.
- Verified the real C# service connects through local IPC to already authenticated Blip 1.2.8.0, reads typed state, disconnects and reconnects with the same device identity. No sign-in code, file transfer, global preference change or credential-file access was requested. No desktop host is started, stopped or adopted. Craft evidence: `ev_e33eaea6eb38eebfc45e00d43920ca0829697a32d7ce97022c02cb1026e7706e`.
- Ten CLI checks and thirteen fake-service checks pass, including refusing desktop hosting/login/trust changes and disconnecting without sending STOP. The separate headless-engine startup/state/shutdown regression also passes with an empty unauthenticated test profile.
- Native fixture rendering passes for the connection chooser, attached authenticated/signed-out states, incoming/outgoing rows, errors, light/dark themes and full window. Compact bounds remain 344 × 420. Screenshots were visually reviewed. Reports: this chat's workspace `blip-session/ui-check-native/`.
- WinUI publishes successfully. NuGet vulnerability-feed lookup was unavailable during restore (NU1900); build and local checks completed.
- Desktop Blip must remain running. Its automatic receiving policy and download folder remain authoritative; manual receives in myDrive use myDrive's own per-transfer directory. No automatic trust control is offered in attached mode. The connection choice is made again after restarting myDrive, without another sign-in for desktop reuse.
- Real sending/receiving, cross-network throughput, separate-profile registration, receiving-policy confirmation after separate login and service/session-zero operation remain untested. macOS/Linux tests remain deferred.

The November 16 results below describe the original separate-profile implementation.

Implemented in the current Windows myDrive project, `C:\Projects\myDrive`. The earlier workspace source snapshot was not used as the base; current source was copied, edited in staging, checked for concurrent changes, then applied with backups.

Verified:

- Nine CLI checks pass: exact peer identifiers, filenames separated from options, base64 stdin framing, JSON response framing, socket-path bound, process timeout ownership, shell-expression literal handling and refusing profile reuse.
- Nine C# service checks pass with a local fake CLI: owned host startup/shutdown, typed state, no false delivery from dispatch/inconsistent completion fields, explicit peer validation, no mutation retries and cancellation isolation between requests and the host.
- The actual C# service starts the prepared native engine using a fresh unauthenticated profile, reads zero devices/transfers with `authenticated: false`, then stops cleanly. No sign-in code request or file transfer occurs.
- The native WinUI app publishes successfully. Synced AppleDouble `._*` metadata sidecars are excluded from compilation/XAML discovery; source files and sidecars were otherwise preserved.
- Fixture-only native diagnostics pass from both the preview and installed app. Stopped, sign-in, pending, active, completed, paused, long-list and error states render in light/dark themes and the full window. Compact dimensions remain 344 × 420 with stable bounds. Sign-in actions fit within the popup. Completion requires matching native fields.
- Runtime/JDK/Node copies live under the existing external local app-data root, `C:\myDriveData\Runtimes\myDrive Blip`, outside synced source. Account profiles were not copied. The app does not start Blip automatically.
- The installed source and next-launch build include the adapter. Existing MyDrive PID 211848, desktop Blip PID 100692 and existing Syncthing processes were preserved during installation. All test hosts and Java processes were stopped.

Native desktop automation could read the current popup's accessibility tree, but interaction geometry/capture failed (`coordinate input geometry is unavailable`, `FrameArrived timed out`). No further app input was attempted. The build was installed using backed-up file replacement without terminating the running app. The old process retains its loaded code; quit myDrive through its tray menu and reopen to use Transfers.

Not tested: actual Blip login, receiving policy after login, real sending/receiving, exact receive file metadata, automatic acceptance after trust, cross-network throughput, interruption/resume, checksums, service/session-zero operation, macOS or Linux. The UI does not claim that a queued request proves delivery. Run signed-in device tests separately from the isolated fixtures.

Source backup: `C:\myDriveData\Recovery\myDrive-Blip-20261116-142233`.
Initial next-launch build backup: `C:\myDriveData\Recovery\myDrive-Blip-build-20261116-142437`.
Local render reports and screenshots: this chat's workspace, `blip-integration/installed-ui-check/`.
