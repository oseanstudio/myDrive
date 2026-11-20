# Validation — 2026-11-15 (windowless engine and popup dismissal)

- Windows engine startup now uses `CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP` plus Syncthing's `--no-console` option. Fifteen isolated lifecycle checks pass, including argument propagation to both monitor/worker and a separate hidden helper checking their console visibility. Existing identity/config/file preservation, concurrency, restart and process-lifetime checks still pass.
- Rust's 21 unit/wire tests and Clippy `-D warnings` pass; release core and WinUI app publish successfully. The optional download test was not repeated because installer code is unchanged. Cached NuGet audit lookup still reports NU1900.
- Native Windows diagnostic passes for fixed bounds/position, existing layout/dialog fixtures and the actual dismissal handler. Inside clicks retain the popup; outside clicks hide it while busy without cancelling work; native picker depth prevents dismissal; embedded confirmations return Cancel; reopening reinstalls the monitor; the full window remains visible. The low-level mouse observer is registered only while the small popup is visible and never consumes input. No physical clicks in unrelated apps were injected during the diagnostic.
- Mac source uses outside mouse-down rather than mouse-up, also dismisses when the app resigns active status, and preserves native modal panels. Mac engine startup already bypasses Terminal. New Mac runtime testing remains deferred.

# Validation — 2026-11-15 (independent background engine)

- Both Windows and macOS shells now call the shared `engine.ensure` manager. Mac discovery includes the official Syncthing.app nested executable, user Applications, Homebrew and PATH; the Mac install supports Intel and Apple Silicon checksums.
- Rust: 21 unit/wire tests passed; Clippy `-D warnings` passed; release built. An additional explicit network test downloaded and extracted the official Windows v2.1.7 release, verified its pinned SHA-256, executed it and verified an existing executable is not overwritten. Modified archive bytes are rejected by a separate unit test.
- Thirteen isolated engine lifecycle checks passed: concurrent requests yield one startup, later calls reuse it, the engine outlives both request processes and releases the temporary caller directory, shutdown/restart preserves identity/config/files, installed binary discovery avoids downloads, and missing selected configs/occupied ports are refused. Windows startup uses CreateProcessW with handle inheritance disabled; this prevents Go's monitor from keeping request pipes open after the core exits.
- All 42 existing two-device integration checks passed, including Stop-folder, file selections, received history, offline divergent edits and recovery.
- Native Windows release diagnostic passed: authenticated live Syncthing v2.1.7 after automatic startup with SyncTrayzor closed; nine existing folders and three configured devices retained. Folder paths, modes, paused flags and device associations matched the pre-start baseline. No folder was added, stopped or reset by validation.
- Popup size/position stability, six visible rows, light/dark fixtures, native forms and Stop-folder Cancel passed again (328 × 412 DIPs inside the fixed outer footprint).
- macOS source includes lifecycle handling plus the previous Stop-folder and fixed-height updates. No new Mac build or runtime validation was performed; the user's Mac testing deferral remains in effect. Historical Mac results below describe earlier code.

# Validation — 2026-11-15 (stop folder sync and stable popup)

- Rust: 19 unit/wire tests passed; Clippy with `-D warnings` passed; release core built.
- Real Syncthing integration: 42 checks passed with two fresh, isolated loopback-only daemons. New checks cover stale-stop rejection, removal of only the selected local configuration, unrelated folders preserved, identical file contents on both devices, remote configuration preserved, archived versions retained, and a credential-redacted durable backup.
- Windows: release UI published. Corrected an existing four-argument `DefSubclassProc` declaration mismatch that blocked compilation; wake handling and tray-status features remain intact. Cached dependency build succeeds; NuGet vulnerability-audit lookup was unavailable (NU1900), so no new vulnerability-audit claim is made.
- Native popup diagnostic passed: position and size remain unchanged across redraw, repeated activation, file navigation, editor opening/closing, themes, sharing dialog and Stop confirmation. The test deliberately places the app away from its tray anchor so the old reposition-on-redraw behavior would fail.
- Native Stop confirmation opens and Cancel avoids the stop action. Both popup and editor measure 328 × 412 DIPs inside the fixed 344 × 420 outer footprint. Six complete folder rows fit; light/dark and form scrolling were inspected.
- Production Syncthing was unreachable during the new desktop diagnostic. Configuration mutations were tested only against the isolated daemons; no production folder was stopped or removed.
- macOS source gained the same Stop action/menu and fixed popover height, but these new Swift changes were not built or tested here. Prior macOS checks below refer to the earlier build. Linux remains unimplemented.

# Validation — 2026-11-14 (macOS preview 0.3.0)

Validated on the user's Mac (Apple silicon, macOS 27.2, Xcode 27.2, Rust 1.98) against the live setup: Syncthing v2.1.6 via Syncthing.app (19 folders, 3 remote devices), four SMB mounts from one server, seven synced folders on a removable SD card.

| Check | Result |
|---|---|
| Rust unit and local HTTP wire tests | 19 passed, 0 failed (adds the bounded `syncthing.events` fixture test) |
| Release core build on macOS | Passed; `cargo build --release --locked`, no OpenSSL dependency (rustls) |
| Swift shell build | Passed; `swiftc -O -swift-version 5`, ad-hoc signed bundle |
| `--diagnose` self-test | All checks passed: keychain roundtrip, bookmark persistence through the core, core-bridge listing, fix-request mailbox roundtrip (non-whitelisted kind refused), SMB mount discovery, popup layout |
| Live Syncthing snapshot | Passed: v2.1.6, 19 folders, 2 connected devices; attention preview derived from real folder errors |
| Attention cards with real error text | Verified live against 2 erroring folders ("delete dir … not empty" class): plain-language summary plus Delete-leftovers / Rescan / Show-all-errors / Request-a-different-fix actions |
| Fix-request mailbox | Temp-fixture roundtrip passed: send, scan, respond, pair, cancel; unsafe kinds refused on send and would be refused on accept |
| SMB mounts | All 4 live mounts discovered with correct host/share parsing; deadline-bounded health probe implemented (3 s) |
| Recent-updates feed | Live events poll advanced the persisted cursor; entry mapping verified by unit-testable mapping code |
| Popup density | 344 pt width; one-folder view 128 pt; eleven folders 417 pt under the 420 pt cap; 6 rows visible; light and dark captures rendered |
| Single instance | Second launch exits and activates the running copy |

Observed interactively: the status item appeared (with live tint/badge), the popover opened once via Accessibility click and showed the live sync view with real attention cards; popover windows are not listable by window-query tools, so interaction was re-verified by captures rather than automation.

Not exercised on macOS yet (recorded honestly, per the working requirements): clicking each fix against live folders (pause/resume, rescan, delete-leftovers, request send/accept on real shares), SMB remount/force-remount on a live mount, the full window, start-at-login, reboot persistence, Keychain prompts across rebuilds. The remote accept flow needs a peer running a myDrive build with this feature; the Windows 0.2 preview does not accept requests yet. A synthetic (Accessibility) click let the popover straddle a display boundary on this three-display setup; real pointer clicks use standard AppKit anchoring and were not reproducible for this case. FileProvider mounting is deferred by plan. Windows validation above does not certify macOS behavior.

# Validation — 2026-11-13

Validated on the development Windows machine from the final project folder.

| Check | Result |
|---|---|
| Release publish and requested-folder deployment | Passed; self-contained WinUI 3 app and release core published, final-folder runtime diagnostic passed |
| Rust unit and local HTTP wire tests | 18 passed, 0 failed |
| Rust Clippy with `-D warnings` | Passed |
| Native Cloud Files spike | Passed: register, connect, dataless placeholder, hydration on open, disconnect and unregister |
| Windows Credential Manager round-trip | Passed; temporary test credential removed |
| Bookmark persistence via shipped core process | Passed |
| Folder listing via shipped core bridge | Passed |
| Expanded window XAML render | Passed; content measured 1144 × 782 DIPs |
| Dense quick menu XAML render | Passed; one-connection content measured 328 × 142 DIPs |
| Quick menu file browser | Passed; fixture folder and file rendered |
| Connection editor inside quick menu | Passed; editor render and scrolling fields inspected |
| Running Syncthing discovery/status | Read-only check passed: v2.1.7, eleven folders, one connected remote device |
| Two-daemon Syncthing integration | 35 checks passed against the release core; fresh isolated loopback-only homes, no production mutation |
| Real file transfer and selections | Initial transfer, Stop blocking a peer edit, Sync resuming it, literal bracket names and nested folder overrides passed |
| Offline divergent edits | Both edits survived reconnection and reached both devices; alternative grouping passed |
| Received history and recovery | New-share protection, received archive, pre-restore backup, actual restore and preserving an existing policy passed |
| Sync popup/full-window XAML | Rendered and inspected; file controls and saved alternatives fit the scrolling popup |
| Simple SMB connection dialog | Rendered and inspected; actual server authentication/recovery validation remains |
| Second launch activation | Passed in the final folder; secondary launch exits and exactly one myDrive instance remains |

The popup's outer width is now 344 logical units with content-driven height capped at 420 for normal views. A one-folder sync view measures 328 × 162 DIPs inside the window; eleven folders measure 328 × 412, with six complete rows visible. The normal maximum area is about 45% smaller than the previous 430 × 610 popup. Native forms temporarily use up to 380 × 520; the editor measured 364 × 512 inside. Closing it restores the small popup. Native window borders account for the difference between outer and XAML content sizes.

Dense popup diagnostics cover short storage lists, local file browsing, per-file sync controls, long folder names, eleven folders, pending/errors, offline/paused status, light/dark appearance, sharing form and modal return sizing. The full window remains 1144 × 782 DIPs inside. This change reuses the already-tested release core; the Rust/Syncthing test results above are from that unchanged core. The UI build succeeded using cached dependencies; NuGet vulnerability-audit lookup was unavailable over the restricted network (NU1900), so that warning is not a completed vulnerability audit.

Layout images and a machine-readable diagnostic report are in `build/diagnostics/`. The images were rendered from this application's own XAML surface. Desktop capture through the Computer Use helper timed out, so this does not claim end-to-end automated clicking of every control.

The Syncthing integration uses the installed binary, two fresh identities, local TCP listeners, and private fixture paths. Discovery, relays, NAT and upgrades are disabled. Both fixture processes are shut down in cleanup; the production process is never stopped or changed. The test caught and verified fixes for explicit plain-sharing device records and same-second version restore collisions. Sanitized results are copied to `build/validation/syncthing.json`; fixture API keys and private certificates are not part of that report.

WebDAV and S3 tests used local HTTP fixture servers, not actual cloud accounts. SFTP, SMB recovery, real cloud-provider interoperability, disk exhaustion, large-file behavior and >1 GiB files still require server/environment testing. Two-daemon loopback tests do not certify WAN, relay or every network-loss condition. macOS/Linux and cloud-account testing are deferred at the user's request. The Cloud Files spike is not integrated remote mounting.

Credential Manager requires the interactive user's desktop logon session. The restricted runner returned Windows error 1312; the same diagnostic passed in the ordinary desktop session without changing production credentials. Layout checks are rendered XAML, not a claim that every native control was exercised by automated clicks. Concurrent live editors and application-specific merging/locking are not certified.


## 2026-11-16 native performance and branding update

Windows release compilation passed without warnings. Shared-core tests: 24 passed, one existing official-download test intentionally ignored. Connection-cache regression checks: six passed, covering concurrent reuse, config/certificate changes, invalidation, no mutation replay, and early cancellation. Isolated engine checks: 15 passed. Two-device Syncthing integration checks: 42 passed.

Native Windows diagnostics passed with 328 x 412 DIP content inside the unchanged 344 x 420 outer popup. Six complete folder rows fit in the clipped list viewport. A 10,000-file fixture realized 31 row containers; unchanged status refreshes retained the same list/container objects. Light/dark layouts, long names, errors, pending/offline/paused states, dialogs, full window, and outside-click dismissal passed. This is verification using the app's own rendered XAML diagnostics, not end-to-end mouse automation of every command.

Eight warm status-request samples per mode in the same Windows process measured median 129.2 ms with engine checking before each call versus 98.8 ms with the validated connection cached (about 24% lower request latency). This is a local status-query measurement, not a transfer-throughput or cold-start benchmark. The final diagnostic also created normal/pending/error native tray variants successfully, using the white cloud asset at 16 pixels for the current taskbar theme. Both foreground-color assets and a multi-resolution cloud-with-my app logo are generated from code; editable SVGs are included.

Diagnostic reports and screenshots are generated in the selected validation directory outside the source tree.

Mac source changes are reviewed but have not been compiled or run on macOS in this update. Mac/Tests/CoreBridgeSmoke.swift contains targeted cancellation, pipe-drain, timeout and early-cancellation checks for a future Mac run. No CUI migration was performed; native Windows and Mac controls remain in use.

The final Windows build also preserves the concurrently added Blip Transfers integration. Its existing fixture-only native diagnostic passed; no account sign-in or real transfer was performed during these checks.