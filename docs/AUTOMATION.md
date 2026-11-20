# myDrive CLI and MCP

Both interfaces use your existing myDrive and Syncthing settings under your desktop user account. They run without the myDrive window or tray app.

## Start the CLI

| Platform | Command |
| --- | --- |
| Windows | `& "$env:LOCALAPPDATA/Programs/myDrive/mydrive-cli.exe" --help` in PowerShell |
| macOS | `/Applications/myDrive.app/Contents/MacOS/mydrive-cli --help` |
| Linux | `./myDrive-Linux-x86_64.AppImage --cli --help` |

Use the same prefix in place of `mydrive-cli` in these examples. Commands return JSON. Errors go to stderr and return a nonzero exit code.

```text
mydrive-cli blip serve
mydrive-cli blip devices
mydrive-cli blip send USER_UUID:DEVICE_UUID "Project files"
mydrive-cli blip transfers
mydrive-cli blip receive TRANSFER_UUID

mydrive-cli sync status
mydrive-cli sync share-preview "Project files" DEVICE_ID
mydrive-cli sync share "Project files" DEVICE_ID
mydrive-cli sync pause FOLDER_ID
mydrive-cli sync resume FOLDER_ID

mydrive-cli smb devices
mydrive-cli smb shares DEVICE_NAME
mydrive-cli smb browse DEVICE_NAME SHARE_NAME "Projects/2026"
```

Sign in to the official Blip app once. Keep `blip serve` running in one terminal and send or accept files in another. `blip transfers` reports delivery and received file locations. Windows uses the [prepared Blip runtime](BLIP.md#runtime-preparation). Linux uses the [installed Blip backend and Java](../Linux/README.md). macOS uses the [supported installed framework](../Mac/README.md). No new Blip sign-in is requested by the CLI or MCP.

Set `MYDRIVE_SMB_USERNAME` and `MYDRIVE_SMB_PASSWORD` in your shell or your MCP client's local environment before browsing. Use the share's own account. Credentials stay out of tool arguments and command output. When a server hides its share list, `smb browse` can still open a known share by name. SMB connections use your personal Tailscale device addresses and signed SMB 3.1.1 sessions. In the desktop app, open **SMB Storage** to see locally shared folders, browse Tailscale devices, or open saved SMB shares.

## Connect an MCP client

Configure a local stdio server with the full path to `mydrive-cli.exe` on Windows or `mydrive-cli` inside the Mac app and use `mcp` as its argument. On Linux, use the full path to the AppImage with arguments `--cli`, `mcp`.

```json
{
  "mcpServers": {
    "mydrive": {
      "command": "/Applications/myDrive.app/Contents/MacOS/mydrive-cli",
      "args": ["mcp"]
    }
  }
}
```

The server exposes the same operations under names such as `blip_devices`, `blip_send`, `blip_receive`, `sync_share`, and `smb_browse`. It starts the Blip helper on the first Blip request if you have already signed in and no session is available. The helper lasts for the MCP session. Keep `blip serve` running separately if you want transfers to continue after the client closes. The MCP server uses local stdin and stdout and does not listen on a network port.

## Start before sign-in

**Settings → Start at boot** is on by default. Choose **Set up before-sign-in startup** once, or run `mydrive-cli startup setup` from the installed package. `startup status` reports your preference and whether the operating system has a startup job registered.

- On Windows, approve admin access and enter the account password in Windows Task Scheduler. The scheduler stores the credential and runs the job as that user.
- On macOS, place myDrive in Applications and approve the administrator prompt for the LaunchDaemon. The service runs as your usual user.
- On Linux, keep the AppImage at a permanent path. Setup enables your systemd user service and asks logind to keep it active between logins.

The boot service keeps Syncthing and the signed-in Blip backend available. Encrypted home folders, an inaccessible Blip profile or a locked credential store can delay a service until its data is available. The desktop window and browser actions run in the signed-in session. Hosted SMB shares follow their current host-session lifetime.
