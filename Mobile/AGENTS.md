# Mobile implementation requirements

- Keep native SwiftUI/UIKit on iPhone/iPad and Kotlin/Jetpack Compose on Android. Use device cards, native file pickers and a real SMB browser; no embedded web application or fabricated transfer/device status.
- Mobile layouts adapt to phones/tablets, safe areas, keyboard, dynamic text, light/dark appearance and screen readers. Desktop popup dimensions do not apply to phones.
- SMB2/3 connects directly through the existing OS network and Tailscale client. Do not change the tailnet, desktop shares or firewall rules during app startup.
- Keep passwords in Keychain/Android Keystore. Connection exports contain metadata only. Import connections with new credential identities; never bind imported IDs to existing saved passwords.
- Blip-account transfers currently use the installed Blip app through OS sharing. Display handoff status, not delivery confirmation. Received Blip files require a user-selected Files/SAF folder and explicit import; do not bypass another app's sandbox.
- New completed incoming myDrive web-link downloads default to automatic opening in the system default browser when foregrounded. Preserve explicit opt-outs and skip historical or unconfirmed/handed-off transfers.
- Store SDKs, caches, signing keys and APK/IPA output outside synchronized source. Never commit passwords, user tailnet addresses, signing identities, generated project/cache directories or vendor Blip binaries.
- Record real device/SMB/iPhone build results separately from JVM fixtures. Native embedded Blip transport, phone folder synchronization, recursive folder transfer and indefinite iOS background SMB transfers are not implemented in this preview.
