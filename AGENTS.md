# myDrive working requirements

Compact native UI is a product priority on every platform. Follow [docs/NATIVE-UI.md](docs/NATIVE-UI.md) when implementing Windows, macOS or Linux interfaces.

- Make the everyday tray/menu popup small, dense and readable at a glance. Lead with current status and compact folder/file rows.
- Keep frequent file access, sync selection and pause/resume reachable in the popup. Put setup forms, full paths, detailed history and explanatory prose behind native menus or dialogs.
- Offer an optional full window with the same data and capabilities. Routine actions must work in the popup.
- Use each platform's native controls and accessibility conventions. Do not substitute a web UI for the native shell.
- Verify dimensions, overflow, long names, error/offline/paused states and light/dark appearance. Preserve sync configuration while checking layout.
- Use isolated profiles for CI builds and tests. Record signed-in device tests separately from CI results.
- Enable received web-link opening by default, but only for senders explicitly approved for the current Blip account. Unapproved senders require myDrive's own receive UI. Preserve explicit opt-outs, completed-incoming-only HTTP/HTTPS validation, background processing and no history replay. Do not label a port's Blip support as implemented until its receiver is wired up.
