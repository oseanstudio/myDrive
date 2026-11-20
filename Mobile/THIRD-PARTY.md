# Mobile dependencies

The mobile source uses public libraries; no packaged Blip engine, session database or credentials are redistributed. Blip remains a separately installed application.

| Component | Version | Upstream / license |
| --- | --- | --- |
| SMBJ (Android SMB2/3 client) | 0.15.0 | https://github.com/hierynomus/smbj — Apache-2.0 |
| AMSMB2 (iOS SMB client) | 4.0.3 | https://github.com/amosavian/AMSMB2 — see upstream LGPL-2.1 license and individual source notices, plus bundled libsmb2 |
| AndroidX / Jetpack Compose / Material | Pinned in Android Gradle files | https://android.googlesource.com/platform/frameworks/support/ — Apache-2.0 |
| Kotlin / kotlinx.coroutines | 2.2.21 / 1.10.2 | https://github.com/JetBrains/kotlin / https://github.com/Kotlin/kotlinx.coroutines — Apache-2.0 |
| SLF4J | 2.0.17 | https://www.slf4j.org/license.html — MIT |
| Robolectric / Roborazzi | 4.16 / 1.79.0 | Test-only; https://github.com/robolectric/robolectric / https://github.com/takahirom/roborazzi — MIT / Apache-2.0 |

Android merges dependency `META-INF/LICENSE*` and `META-INF/NOTICE*` resources into the APK. This inventory is not a complete transitive notice bundle. Before public distribution, audit resolved runtime dependencies, include all required copyright/license notices and satisfy AMSMB2/libsmb2 redistribution and relinking/source obligations. Use production signing and store-specific packaging; this debug preview is for local testing.
