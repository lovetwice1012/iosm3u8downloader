# HLS Downloader for Android

The Android implementation lives entirely in this directory so that the iOS
project remains available beside it for behaviour and UI comparisons.

## Requirements

- Android Studio / Android SDK 35
- JDK 17
- Android 8.0 (API 26) or later

## Build and test

```bash
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:assembleRelease
# Optional: with a connected Android device, exercise the real FFmpeg JNI path.
./gradlew :app:connectedDebugAndroidTest
```

`assembleRelease` intentionally has no signing configuration. Its output is
`app/build/outputs/apk/release/app-release-unsigned.apk`, ready for a personal
keystore to sign with `apksigner` or Android Studio.

The GitHub Actions workflows **Build unsigned Android APK** and **Test Android
app** are independent. The first packages an unsigned release APK; the second
runs JVM tests and Android lint.

## Implemented features

- Direct media/master m3u8 input plus static HTML and bounded iframe discovery
- Visible alpha playback browser that observes DOM media elements, scripts,
  `fetch`, XHR, resource timing and navigations while the user starts playback
- Candidate thumbnails, redacted URL display, diagnostic log, file sharing
- Highest-bandwidth video variant and associated external audio rendition
- VOD MPEG-TS and fMP4, `EXT-X-MAP`, `EXT-X-BYTERANGE`, and identity AES-128
- Up to six parallel segment requests, constrained by a shared memory budget
- FFmpeg stream-copy remux of video/audio into a normal MP4 file
- A foreground-service notification with progress and cancellation while the
  app is backgrounded

The download operation is owned process-wide, so an Activity recreation or
reopening the app can reattach to its progress and completed output. This is
not a persistent download manager: force-stopping the app, process eviction,
or reboot interrupts the operation and it is not resumed automatically. The
visible WebView playback analysis itself is foreground-only.

## Pinned FFmpegKit binary

The build downloads a fixed LGPL shared-library AAR before compilation and
verifies it before use:

- Project: <https://github.com/akashskypatel/ffmpeg-kit-builders>
- Source tag/commit: `v0.10.5-android` / `b3355c9e16ff5288a7dae701c5d2bd27bd5da6fe`
- Artifact: `bundle-base-shared-small-lgpl-release.aar`
- Published size: `31,837,654` bytes
- SHA-256: `4edd40f4d6e5504c9bc8f523af01392ac2921e9901e621afaead6f694e2b286b`
- FFmpeg: 8.1.2

Only stream-copy remuxing (`-c copy`) is used. The AAR contains dynamically
loaded `libffmpegkit.so` builds for arm64-v8a, armeabi-v7a and x86_64. The
notices and license text shipped in `app/src/main/assets/licenses` explain how
to replace the shared library with an interface-compatible modified build.

## Network security

HTTP input is enabled to retain the iOS app's local/LAN support. The app also
trusts certificates deliberately installed by the device owner, which is
needed for the opt-in advanced-analysis path. This does not bypass certificate
pinning, DRM, application-layer encryption, or access controls.

Installing a user CA only establishes certificate trust. This app does not
create a local VPN or proxy and does not redirect device traffic by itself. A
separately configured proxy/VPN is required to route traffic through a
developer-controlled analyzer; certificate-pinned, QUIC, and custom-encrypted
traffic may still be unavailable. Use this only with content and systems you
are authorized to inspect.

## Current limits

- Only playlists terminated by `#EXT-X-ENDLIST` are accepted.
- FairPlay, Widevine, SAMPLE-AES and non-identity key formats are not decrypted.
- Playlists with gaps, discontinuities, or changing fMP4 initialization maps
  fail explicitly instead of producing a corrupt output.
- A single media segment is limited to 48 MiB to keep concurrent downloads
  within a practical Android heap budget.
- Output codecs must already be compatible with MP4 stream-copy and playback
  on the target device; the app does not re-encode them.
