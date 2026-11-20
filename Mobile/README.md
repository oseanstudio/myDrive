# myDrive mobile preview 0.4.0

Native iPhone/iPad and Android clients with a device-first sharing layout inspired by Blip, plus direct SMB2/3 browsing over an existing Tailscale connection. This preview uses your installed Blip app for Blip-account transfers; it does not embed the Windows-only private Blip engine.

## What is implemented

| Capability | Android | iPhone/iPad source |
| --- | --- | --- |
| Device cards and saved SMB connections | Implemented | Implemented |
| Tailscale hostname/IP and custom SMB port | Implemented | Implemented |
| Browse a configured SMB share and subfolders | Implemented | Implemented |
| Upload/download files with progress and cancellation | Foreground transfer service | Async SMB with foreground use and a limited OS background task |
| New folder, rename, delete empty folder/file | Implemented | Implemented |
| Password storage | Android Keystore AES-GCM | Keychain |
| Send files/photos/links using existing Blip account | Android share intent restricted to installed `net.blip.android` | Native share sheet; choose Blip |
| Import from Blip's received folder | User-selected SAF folder | User-selected Files folder |
| Automatic opening of completed myDrive web-link downloads | Defaults on; opens when foregrounded | Defaults on; opens when foregrounded |
| Connection metadata import | JSON, new credential IDs | JSON, new credential IDs |

Source is implemented for both platforms. An Android APK has been built. iPhone compilation, signing and device execution require Xcode on the Mac and have not been completed here. See [validation](VALIDATION.md) for the exact checks and remaining gates.

### Blip behavior

Select files in myDrive, then **Send with Blip**. Android resolves the installed Blip app; iOS presents the share sheet, where you choose Blip. That app manages the signed-in account, recipients, acceptance, notifications and transport/resume. MyDrive records a **handoff**, not confirmed delivery. No Blip credentials are copied. On Android, other apps can share content into myDrive before choosing an SMB destination or Blip; the iOS preview selects items inside myDrive and does not yet provide its own share extension.

Receiving remains in the installed Blip app. Choose **More → Choose Blip received folder** and select its accessible folder in Files/Android's picker. Finished files can then be imported into myDrive and opened/shared. File presence alone is not evidence of Blip transport completion; wait for Blip to finish before importing. Blip's own receive/link settings remain authoritative.

This supplies Blip-account interoperability now. Embedded account login, an in-app Blip peer list and verified Blip transfer progress inside myDrive still need a supported mobile SDK/adapter; they are not represented by mock screens.

## Browse computers through Tailscale

1. Keep Tailscale signed in on the phone and computer and enable the existing connection.
2. In myDrive choose **Add SMB device**. Enter the computer's MagicDNS name (for example `studio-pc.example.ts.net`) or Tailscale IP, then the actual SMB share name. A Tailscale connection does not create an SMB share.
3. Enter the server account username/password and optional domain. A Windows Hello PIN is not the SMB account password. Use **Require SMB3 encryption** if the server requires it; signing is required by the Android client.
4. Choose **Browse**. Tap a folder to open it or a file to download. The file menu offers rename/delete; folders must be empty before deletion. Select files, navigate to a destination, and choose **Upload here**.
5. **Transfers** distinguishes active, completed, interrupted, cancelled, failed and handed-to-Blip states. Received files can be exported with the OS share sheet.

SMB still requires server permissions and tailnet reachability to TCP 445 (or your custom port). Connections use the phone's installed Tailscale VPN; no new VPN, port forwarding or tailnet rule is created by myDrive. Ordinary phone apps cannot enumerate Tailscale's privileged local device API; add/import known devices rather than relying on LAN broadcast discovery across the VPN.

Uploads stage under a unique `.mydrive-…partial` filename and rename without replacing an existing destination. Downloads commit from an app-owned partial file into a unique received directory. Cancellation checks between chunks; a blocked network call can take up to its timeout to unwind. A process/OS kill may leave its own partial file. No mutation is retried automatically.

Large file contents are streamed; Android uses a 128 KiB buffer. This is not a validated claim of unlimited size or resumable SMB transfers. Recursive folder upload/download, server/share enumeration, full on-demand sync and automatic resume remain open. A mobile app can access files selected through Files/SAF and its own storage, not the entire phone filesystem.

### Connection profiles

`tools/export-connections.ps1` produces a metadata-only profile for a known Windows share using the existing Tailscale hostname. It never includes passwords or modifies shares. Import that JSON from **More → Import connections**, then enter the account password on the phone. Imported connections get new local IDs, preventing a supplied ID from borrowing a saved credential.

```powershell
./Mobile/tools/export-connections.ps1 -Share 'Files' -Root 'Projects' -Name 'Studio PC'
```

For administrative shares such as `D$`, the account must already have the necessary access. The app does not enable administrative sharing or weaken Windows authentication.

## Android build

Install Android Studio/SDK with JDK 17 and Gradle 8.13, or use the checksum-verifying `tools/prepare-android.ps1` helper on Windows. It keeps tools under the existing OseanStudio storage root. Build with:

```powershell
./Mobile/Android/build.ps1 -Tests
```

The script builds a cache copy on the output drive (avoiding Android Gradle's cross-drive test limitation), runs checks if requested, and writes `Previews/myDrive Mobile/myDrive-android-debug.apk` beneath the configured app-data root. It uses a local debug signing key in the external Android user directory. Keep that key for upgrades; do not publish a debug APK as a store release.

For Android Studio on another machine, use SDK 36, JDK 17 and the included checksum-pinned Gradle wrapper. Set `MYDRIVE_ANDROID_BUILD` to an external path on the same volume as the source, and `GRADLE_USER_HOME` outside synchronized source. Run `bash gradlew :app:assembleDebug` inside `Mobile/Android`, or open that directory in Android Studio. `local.properties`, caches and signing keys must remain local.

## iPhone/iPad build

On the Mac with Xcode and XcodeGen installed:

```bash
bash Mobile/iOS/build.sh
# Build for an iPhone after selecting your own Apple signing team:
bash Mobile/iOS/build.sh --device DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

The script generates the Xcode project and DerivedData in the machine cache. Open the printed project path, choose your phone and signing team, then Run. Simulator builds skip code signing. XcodeGen resolves AMSMB2 4.0.3; the source contains no vendor Blip binaries. iOS must permit local-network access when requested by the app.

On iOS, keep myDrive foregrounded for long SMB transfers. The system can suspend/terminate background work; a short background-task allowance is not unlimited receiving. Sending through Blip uses Blip's own lifecycle. Open received links when myDrive becomes active; do not attempt to bypass OS background-launch restrictions.

## Existing desktop synchronization

Your MyDrive source is already inside the shared OSEAN STUDIO APPS folder. These `Mobile/` sources can reach the Mac through that existing Syncthing share when it reconnects. Blip account membership, SMB account credentials, and Syncthing device IDs remain separate. This preview does not embed Syncthing on either phone or automatically pair a phone from a Blip contact.

## Release gates

- Compile/test the iPhone project on the actual Mac and sign/install on the phone.
- Validate SMB credentials, permissions, large files, cancellation, interruption/retry and checksums against the actual laptop and PC.
- Exercise installed Blip share targets and received-folder permissions on both phones; do not infer acceptance/delivery from a share-sheet return.
- Check notification permissions and Android foreground-service timeout behavior on a physical phone.
- Check VoiceOver/TalkBack, large text, landscape/tablet layout, storage pressure and offline recovery.
- Implement recursive folders, resume, richer device pairing and any embedded mobile Blip adapter before claiming full parity.
- Review upstream license/notice packaging and production signing before public distribution.

References: [Blip iPhone](https://apps.apple.com/app/id6463305181), [Blip Android](https://play.google.com/store/apps/details?id=net.blip.android), [Tailscale file-server access](https://tailscale.com/docs/use-cases/personal-or-at-home-use/access-nas-media-file-servers), [SMBJ](https://github.com/hierynomus/smbj), [AMSMB2](https://github.com/amosavian/AMSMB2).
