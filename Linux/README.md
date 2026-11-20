# myDrive for Linux

The x86-64 AppImage launches the GTK desktop app with Sync, SMB Storage, Send & Receive, Activity and Settings. The same window can run compact or full screen. Desktops with a StatusNotifierItem host can open and hide it from the tray. Drop local files or folders into the window. Click an exact Blip recipient to send files, or choose Send, Sync or Share over SMB for a folder.

- **Sync** reuses the installed Syncthing engine and its configuration. Browse synced folders, set individual file rules, share folders with configured devices, pause/resume, rescan, inspect pending files and errors, and restore saved versions.
- **SMB Storage** saves local, SMB, SFTP, WebDAV and S3 connections. SMB uses the desktop's GIO/GVfs backend and native mount dialog. An existing kernel CIFS mount can be entered in an SMB connection for checkpointed uploads and downloads. Remote saved credentials use Secret Service.
- **Send & Receive** attaches to an installed Linux Blip 1.2.8 desktop session through the local socket and can keep its host available with Blip's window closed. The same native bridge handles recipient selection, file and folder sending, incoming acceptance and relay. Automatic file receipt and HTTP(S) opening require approval for the exact sender device. Older completed transfers are skipped when attaching.

Install GTK 4.6 or newer, Python 3.10 or newer with PyGObject, and Syncthing for the Sync view. Debian and Ubuntu provide `python3-gi`, `gir1.2-gtk-4.0`, `gvfs-backends` and `libsecret-tools`. To publish a read-only share, use a Samba host already bound to `tailscale0` on TCP 445 with `bind interfaces only = yes`, SMB 3 and `server smb encrypt = required`. myDrive checks the host and the live listeners before adding the usershare for the selected Samba account. Enable owner-only usershares, leave guest access and the usershare template disabled, and keep public Tailscale Funnel off on the SMB host.

For Blip, sign in in the official Linux distribution first. Use the extracted Blip 1.2.8 archive for x86-64 and Java 25. Set `MYDRIVE_BLIP_DIR` to the extracted directory if it is outside `/opt/blip`, `/usr/local/lib/blip` or `~/.local/opt/blip`. Set `MYDRIVE_JAVA` if Java 25 is outside PATH. myDrive starts the headless host automatically and waits for it when you send. Vendor binaries and profiles are separate from the AppImage.

Mark the AppImage executable and open it from the file manager. Where FUSE is unavailable, launch with `APPIMAGE_EXTRACT_AND_RUN=1`. State is kept under `$XDG_DATA_HOME/myDrive` (usually `~/.local/share/myDrive`). You can run the shared JSON interface through the AppImage with `--core`.

GitHub Actions packages the Linux build and runs the shared Rust tests, an isolated unauthenticated Blip host election check, and a GTK smoke test. Authenticated Linux transfers, real SMB servers and desktop-specific tray behavior require separate live validation.
