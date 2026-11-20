# Mobile preview validation — 2026-11-18

## Verified on Windows

- Android Debug APK compiles against SDK 36 using AGP 8.13.2, Gradle 8.13, JDK 17 and Kotlin 2.2.21. SMB calls compile against SMBJ 0.15.0, rather than a mock networking interface.
- Android local checks: 14 discovered, 13 passed, 1 optional real-SMB integration test skipped. Checks cover path/filename and server-address validation, shortcut scheme restrictions, default link preference and opt-out, interrupted history, metadata exports and imported credential identities.
- Four native framework screen checks run with Robolectric 4.16, native graphics, SDK 35 and Roborazzi 1.79.0. Inspected Devices, SMB editor and long-name browser at 393 × 852 dp, plus dark Transfers at 320 × 640 dp. These renders use fixture data; they are not physical-device or network tests.
- iOS Info.plist XML parses; build.sh passes Bash syntax validation. Swift source, SwiftPM resolution, XcodeGen generation, iOS compilation and XCTest execution have not been verified on macOS.
- The Windows Android setup helper completed with official checksum-verified JDK/Gradle/SDK downloads. SDK/cache/APK/signing outputs remain outside synchronized source.

## Not verified

No Android phone is attached. Real SMB authentication and transfers against the user's computers, large files, remote rename/collision semantics, cancellation and network interruption still require device/server testing. An optional loopback SMB fixture dependency was blocked by Windows antivirus as potentially unwanted software; it was not executed or bypassed, and that test is explicitly skipped.

No Blip sign-in request was made. Native Blip share targets and received-folder permissions require testing on the actual phones. A share intent/sheet return indicates handoff, never confirmed delivery. The iPhone project needs Xcode, an Apple signing team for device installation, and a simulator/phone test run.

Existing Syncthing connects this PC with the MacBook and carries the project source. Tailscale status is not evidence of Syncthing connectivity. No Syncthing pairing, share configuration, firewall or tailnet rule was changed.

## Reproduce

```powershell
./Mobile/tools/prepare-android.ps1
./Mobile/Android/build.ps1 -Tests
```

The APK is written to `Previews/myDrive Mobile/myDrive-android-debug.apk` beneath the configured OseanStudio app-data root. Test reports are under `Build Cache/myDrive Mobile/android/reports/tests/testDebugUnitTest/`; generated screen captures are in the external build source copy's `app/screenshots/`.

On the Mac after Syncthing finishes:

```bash
bash Mobile/iOS/build.sh
# Build on an iPhone with your own signing team:
bash Mobile/iOS/build.sh --device DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

Open the generated project path printed by the script to run XCTest, select a simulator or phone, and inspect the actual UI. Do not mark iPhone support tested until that completes. Review [release gates](README.md#release-gates) and [third-party requirements](THIRD-PARTY.md) before distribution.
