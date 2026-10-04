# CapyFlow Android dev7

Native Android preview for Android 8.0 and newer, on all phone brands. Open this
folder in Android Studio; the repository root contains a different upstream app.

## Included in dev7

- Full-screen Now Playing with slide-in/slide-out animation, fixed artwork and
  a compact lyrics panel beneath the controls. Timed lyrics follow playback;
  untimed lyrics scroll only inside that panel.
- Vertical queue handle dragging and swipe-left to reveal Remove.
- Separate song/album search, album track lists, Add as playlist, and Download all
  for albums and playlists. Downloads run with at most two simultaneous jobs.
- Higher-resolution artwork in the player and notification, plus offline artwork
  and lyric caching when a provider returns lyrics.
- Manual server saves are retained; automatic discovery follows new tunnel
  addresses and cannot overwrite a later manual choice.
- Local downloads play without MSI. Playback errors preserve the saved file.
  Downloads are checked for complete transfers and a readable audio track.
- MSI is tried first for online music. A failed server uses local NewPipe YouTube
  extraction, including downloads. The direct URL is freshly resolved; no MSI
  credentials are attached to YouTube/Googlevideo requests.
- Best available and Data saver select highest/lowest compatible source bitrates.
  Settings changes apply to the next stream/download; existing files keep their
  downloaded quality. Now Playing displays reported format details and source.
- Controller startup is awaited; repeated taps do not restart a pending resolve.
- Standard audio playback with decoder fallback.

## Local build

Install JDK 17, Android SDK platform 36 and build-tools 35.0.0. Set ANDROID_HOME or
create local.properties with sdk.dir. From this directory run:

    ./gradlew clean testDebugUnitTest assembleDebug

Windows: use gradlew.bat. The APK is app/build/outputs/apk/debug/app-debug.apk.
No GitHub workflow is needed. Direct extraction requires Internet access and
can fail if YouTube changes, blocks requests, or restricts the upload.

## Preview signing

Dev8 uses the explicitly selected CI preview key, cached privately by GitHub Actions and checked against `.github/capyflow-signing-sha1.txt`. See the migration section below before updating an older preview. Local development builds may use a different certificate and cannot necessarily update CI builds in place.

## Accounts and lyrics

Android is registered in the existing `capyflow-aa6c5` project. The Android app configuration and retained CI signing fingerprints are configured for Google sign-in; client IDs are public configuration. Real-device sign-in still needs validation.

Lyrics use the shared backend, exact-media community timing, and matched LRCLIB fallbacks. Cached lyrics are available offline. Some recordings have no genuine synced lyrics; those remain plain text instead of showing invented timing.

## Validation and remaining limits

Unit tests cover playlist payload compatibility, duration/LRC parsing, song and
album-track parsing, lyric matching/cache round trips, signed artwork URLs,
manual/automatic server selection races, actual quality descriptions, direct
quality selection and Firebase RPC serialization with the extractor's runtime.
An opt-in DirectMusicIntegrationTest checks extraction and audio bytes without
MSI (CAPY_DIRECT_SMOKE=1). Regular tests skip this external-network check.

UI gestures and long playback need emulator/real-device testing. The user reported that a real Android phone did not reproduce the static;
the source review did not establish the exact emulator-side cause. No microphone capture
or audio effects are enabled. Emulator diagnostics and output resets are not included.

Remaining work includes related-song autoplay, full canonical recording matching, message pagination and in-app APK updating. Account profiles, following, collaborative playlists and Friend Activity are implemented in dev8; cross-platform device testing remains necessary.


## Dev7 changes

Local file URIs use Media3 DefaultDataSource instead of the HTTP-only loader.
Library has filters, sort, a Downloads entry and animated playlist/album detail
navigation, Play/Shuffle, song picker, download-all and local cover selection.
Song rows show explicit metadata and downloaded status across playlist/search views.
Play next prepends an entry; Add to queue appends. Queue entries have stable unique
identities, with viewport-preserving drag swaps and gradual edge scrolling.
The lyrics viewport grows from 152dp to 196dp. Shared/collaborative playlists still
require Android account integration. GitHub tests and lint run before APK upload.


### dev8 accounts and collaboration

Android uses the same Firebase project, Google sign-in identity, `profiles`, `usernames`, `follows`, `playlists`, account-private library blobs, conversations and listening activity records as iOS. Custom names, usernames, bios and compressed profile photos are stored in the existing cross-platform fields. Username reservations are transactional and follow the shared 14-day cooldown.

The creator UID identifies a playlist owner; the visible `By @username` label listens to that creator's CapyFlow profile. Linked shared documents are authoritative in both My Playlists and Shared Playlists. Song mutations use Firestore transactions to preserve concurrent additions. The owner can delete shared access while keeping the latest personal copy, or delete the playlist from both views. Collaborators can leave but cannot delete or rename the owner's playlist.

Private playlists and covers are backed up under the authenticated UID and restored on sign-in after reinstall. Local downloads remain device-local. Pending local-only changes require a successful cloud sync before uninstall. Collaboration requires a connection for transactions.

Android acknowledges message delivery using participant-private receipt documents; iOS already supplies read receipts for Seen. Older iOS builds do not acknowledge unseen delivery, so Android correctly shows Sent until Seen for those recipients. Friend Activity uses the existing opt-in sharing setting and expiring listening records on both platforms.

Google sign-in configuration uses the registered Android app and GitHub CI signing certificate; changing the signing key requires registering its fingerprint. Client Firebase identifiers are public app configuration, not service account credentials. Security and Android validation run on GitHub Actions. Real-device iOS/Android end-to-end testing remains necessary; CI does not substitute for that check.


### One-time dev7 signing migration

The older workflow cached a path that did not contain Gradle's actual debug key, so its disposable runners signed builds with different keys. Dev8 explicitly selects and caches its preview key. A public SHA-1 pin makes later builds stop if that key is missing or changed; a replacement is never silently published. For durable recovery, the owner can supply the same keystore through the `CAPYFLOW_ANDROID_KEYSTORE_BASE64` Actions secret. The signing key is never committed or uploaded as a public artifact.

The old dev7 private key was not retained and cannot be recovered from its APK. To preserve local data when switching to the corrected signer, connect one device with USB debugging, extract the new APK from the GitHub artifact, and run:

```sh
node capyflow-android/scripts/migrate-preview.mjs /path/to/app-debug.apk
```

The helper creates a streaming local backup of preferences, playlist artwork and downloaded files, then attempts a normal update. Only if Android reports an incompatible signer does it ask you to type `MIGRATE` before replacing the old preview and restoring the backup. Keep the `.tar` backup until the restored app has been checked. Set `CAPYFLOW_ADB` to the absolute `adb` executable path if it is not on PATH. No data is uploaded.


### Dev9 social navigation, output and updates

Social is a dedicated people-search/following page; Messages is a separate inbox. Blank queries clear results, superseded requests cannot overwrite the latest query, and the authenticated account is excluded from discovery. Chats use a full-screen animated route with status/navigation/keyboard insets and both toolbar and system Back support. New unread inbox messages and errors appear in dismissible top banners for 4.5 seconds. Existing inbox snapshots do not generate a flood of historical notifications.

Friend Activity displays genuine live presence only while the record is fresh, otherwise the time since the last published record. Paused playback does not keep refreshing the last-listened timestamp. The player has a themed output button: Android 14+ opens the system audio-output picker, and older versions open Bluetooth settings. Standard Bluetooth audio, headset transport controls and noisy-disconnect pause use the existing media session; device-specific routing needs real-device testing.

Updates are published as Android prereleases after both build and security jobs succeed. Settings → Updates discovers only this repository’s Android releases, downloads the APK, checks its SHA-256, package, higher version and exact installed signing certificate, then opens Android’s installer. The user must permit CapyFlow as an update source and confirm installation. Updates preserve local app data when signed with the retained dev8 key. This does not bypass the dev7 migration requirement.

Foreground message banners work with the current Firestore listeners. FCM receiving, private device registration and a trusted message-created server trigger are supplied. Background message pushes are NOT active until that trigger is deployed to an authorized server. See firebase/push/README.md; the current Spark billing plan is not changed automatically. iOS background receiving also requires its own APNs/FCM registration and Apple push entitlement.


Dev9 also marks fully downloaded playlists with a compact icon on Home and Library, while the playlist action shows Downloaded and a check when all tracks are present. Shared collections have a group badge on artwork and a Shared playlist label with collaborator count in details.

Playback starts no longer wait for an extra backend health request. The backend gets a four-second head start before direct resolution is tried concurrently; the first working resolver wins and the other is cancelled. Download resolution remains sequential. Resolution and buffering share one loading state, repeated taps do not restart an active startup, and an initial streaming stall can automatically retry once. Media3 requires 750 ms rather than 2.5 seconds of buffered audio to start, with a separate rebuffer threshold. Genuine extraction/network delays still vary; real-device playback testing remains necessary.
