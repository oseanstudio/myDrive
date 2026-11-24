# Small native popup: priority for every platform

The user's priority is a much smaller popup with useful information clear at a glance, for every platform's native myDrive app. The full window provides optional extra space. Routine actions remain available in the popup.

## Shared requirements

- Use one compact header with view selection and window actions. Place the full-window icon at the right edge of the app toolbar. Keep idle controls out of the footer.
- Lead with sync state, folder count and device availability. Distinguish local up-to-date status, offline availability, pending work, paused folders and errors using text as well as color.
- Use short rows: name, one secondary status line, frequent actions. Prioritize errors and the current project. Truncate long names with tooltips/accessibility labels; show full paths on demand.
- Keep opening files, per-file Sync/Stop, pause/resume, refresh, pending items and version recovery in the popup. Put setup, device lists, build/cache options, history details and explanation in native menus/dialogs.
- Show progress/cancellation while busy. A persistent Ready footer must not take idle space.
- Keep the popup's position and full viewport stable while open. Long lists scroll within the cap. When the visible content uses less space, the unused bottom is clear and lets clicks reach the desktop underneath. Never widen the popup just to fit a path.
- Clicking outside dismisses the popup, including while background work runs; hiding never cancels that work. Embedded confirmations cancel on dismissal. Native file pickers retain their normal modal behavior, and the optional full window stays open.
- Use native fonts, themes, keyboard focus, accessible labels and practical desktop pointer targets. Reduce redundant layout before shrinking text.
- Switching to the full window preserves the active view, folder and operation. Popup dialogs provide the same capabilities.
- Automatic opening of newly received Blip web links is enabled by default for explicitly approved senders on every platform. Start with no approved senders. Use the system default browser, keep handling active while the popup is hidden, skip completed history on connection, and preserve an explicit opt-out. Apply the shared behavior in [Blip requirements](BLIP.md#cross-platform-default).

## Windows implementation

The popup uses a solid, fixed 344 × 420 logical-unit footprint, including native forms. The trailing header icon opens the full window. Long forms scroll within the fixed footprint. Position is chosen once on open from the tray anchor. Reopening can anchor again, and a changed monitor work area can clamp the popup back on-screen. Window sizes scale with monitor DPI.

Folder and sync-file rows have a 44-unit minimum height, about 50 including spacing. Icon targets are 28 × 28 with accessible labels. The compact header provides direct tabs for Blip, Syncthing, SMB Drives, Activity, and Settings. The + menu provides quick actions and Quit.

Folder and sync-file lists now use native ListView virtualization. Status polling updates stable folder models and the compact summary rather than recreating the page; hidden windows receive data/tray updates without rebuilding their controls. The normal Windows tray mark is a filled myDrive cloud with the wordmark cut out, following the system taskbar theme and contrast mode independently of the app theme. Pending/error states retain small colored badges and explicit tooltips. The separate app logo is a cloud containing “my”; editable SVG and multi-resolution ICO assets are in `Windows/App/Assets`, and the macOS build uses the matching PNG to produce its app icon.

The macOS source uses lazy lists, coalesced refreshes and cached engine connections. Cancellation owns one helper process per request; SMB discovery runs off the main queue and timed-out stat probes are bounded. Event history writes are batched on a serial background queue and flushed at quit. Build output defaults to the machine cache (`~/Library/Caches/myDrive` or `OSEAN_STUDIO_DATA`) and respects `CARGO_TARGET_DIR`; `MYDRIVE_BUILD_DIR` can override the app output directory. macOS execution/visual testing of these changes remains deferred. A targeted bridge regression harness is provided in `Mac/Tests/CoreBridgeSmoke.swift` for a later Mac run.

## Native ports

- **macOS:** AppKit status item and native popover/menu controls, with SwiftUI where appropriate; optional larger window sharing the same state. Apply these density requirements using macOS points and native typography. Implemented as preview 0.3.0 (`Mac/`): 344 pt popup width, 420 pt height cap, 44 pt-minimum rows, attention cards above folder rows; see [Mac/README.md](../Mac/README.md) and the 2026-11-14 validation notes for what is verified.
- **Linux:** GTK4/libadwaita widgets and StatusNotifierItem integration, with an appropriate native fallback for desktops without tray popovers. Apply the same hierarchy in logical pixels.
- The Linux port remains a future requirement. This macOS preview does not implement or validate it.

## Acceptance checks

### Mobile clients

iPhone/iPad use SwiftUI/UIKit and Android uses Kotlin/Jetpack Compose. Desktop tray dimensions do not apply: use adaptive phone screens, native tabs, device cards, file pickers and accessible touch targets. Keep device setup scrollable with Save/Cancel reachable around the keyboard. Long filenames truncate, while full names remain available to accessibility. Transfer states must distinguish verified SMB completion, interruption/failure and Blip share handoff. Honor mobile lifecycle limits for background SMB and browser launches. See [Mobile/AGENTS.md](../Mobile/AGENTS.md) and [mobile validation](../Mobile/VALIDATION.md) for scope and actual checks.

### Desktop clients

Check empty, one-item and long lists; long names/paths; pending/error/offline/paused states; light/dark themes; and return from native dialogs. Frequent actions must stay visible or one native menu away. Verify keyboard navigation, display scaling and small work areas on each actual OS before release. Rendered Windows fixtures verify layout, not complete cross-platform interaction.

## Consistent navigation and folder details

Use **SMB Drives** for the view tab, full-window navigation and file-browser Back action. Connection remains the term for an individual saved server or share.

**Show errors** and **Pending files** navigate to a regular Sync detail page inside the same popup or full window. Keep the main header, dimensions and native row style; provide Back and Refresh. Read-only folder details must not replace the app with a modal ContentDialog or separate dialog shell. Show loading and request-failure states distinctly from an empty error list. Outside-click dismissal retains the normal popup behavior. Windows native rendering checks cover this flow; matching Mac source changes require later Mac compilation/runtime checks.
