# CapyFlow Android

A separate native Android implementation of the current CapyFlow iOS app. Open **this folder** in Android Studio; the repository root still contains the original upstream Android application and is not this project.

This first development build establishes CapyFlow's violet palette (#DC95FF / #D78FEE), dark translucent surfaces, app icon, Home/Search/Library/Social navigation, mini-player and full player. It implements song search, streaming from the same discovered MSI/Cloudflare server, Media3 background/notification controls, seeking, queue editing, basic matched lyrics, offline downloads, local playlists, and account-scoped playlist backups. Social code uses the existing profiles, follows, conversations and messages schemas, including profile bios and atomic send batches.

## Run

1. Open `capyflow-android` in Android Studio and allow Gradle sync.
2. Select the Pixel 8 emulator and press Run.
3. Alternatively download the `CapyFlow-Android-dev1` APK artifact from the **Build CapyFlow Android** GitHub Actions workflow, extract it, and drag the APK onto the emulator.

Search and local library are available without Firebase configuration. Playback requires the streaming server to be running; discovery uses the same `runtime/backend-discovery/backend.json` as iOS. You can also enter an HTTPS server address in Settings. Downloads are stored privately and are removed by uninstalling the app.

## Firebase setup for the existing iOS account

In the existing **capyflow-aa6c5** project, register an Android app with package **com.seph.capyflow**. Do not create a second Firebase project. Add the debug signing SHA-1 and SHA-256 (`./gradlew :app:signingReport`), enable Google sign-in, then download the Android `google-services.json` into `app/`. The file is intentionally ignored by git. For CI, put its complete JSON in the repository Actions secret `CAPYFLOW_ANDROID_FIREBASE_JSON`. Each signing certificate used to build/install the app needs its own registered fingerprint.

Without that Android registration, the build shows an explicit setup message and does not pretend that sign-in or cross-platform messaging works. With it, use the same Google account on Android and iOS. Deploy the repository's existing Firestore rules; this project does not weaken or replace them.

## Current limits / remaining parity work

This is dev1, not a feature-complete iOS port. Google/Firebase integration, real playback and Android-to-iOS messaging require runtime testing after configuration. Collaborative playlist editing/invitations, friend listening activity, profile editing, followers/following drill-down, albums and canonical album/song resolution, related-song autoplay, older-message pagination/read-status presentation, automatic lyric scrolling, audio routing/details, and Android update installation are not yet ported. Basic lyrics search preserves duration matching but does not yet reproduce the full iOS canonical lyrics resolver. Previous currently restarts the song. No real-device battery/background testing has been performed.

The original Android app and all iOS sources are unchanged. Work is isolated on `feature/capyflow-android`.

## Validation

`./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug`

Compatibility tests cover iOS playlist payloads and media IDs, deterministic conversation IDs, audio-only search selection, hour-long duration parsing, and timestamped lyric seeking.
