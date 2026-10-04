# CapyFlow Android dev5

Native Android preview for Android 8.0 and newer, on all phone brands. Open this
folder in Android Studio; the repository root contains a different upstream app.

## Included in dev5

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

The source backup includes signing/capyflow-preview.jks. This key signs dev5 and
must be reused for future previews to allow updates without uninstalling.
Alias: capyflow-preview. Store/key passwords: android.

SHA-1: 3E:E2:4B:A8:55:9C:74:8E:33:A0:CD:F5:69:4E:DB:FC:92:5B:68:1D
SHA-256: 94:AA:54:2A:E6:28:2C:C3:2A:E0:EF:EC:40:4E:C9:50:44:B7:D5:13:05:24:37:0C:AA:6A:7F:76:7D:C9:2B:63

The original dev4 signing key was lost when the earlier workspace was pruned.
Dev5 therefore cannot update dev4 in place. Keep dev4 until its data is backed
up; uninstalling removes local playlists, downloaded audio, lyrics and artwork.
See INSTALL-AND-BACKUP.md in the recovery kit for an optional emulator backup.

## Accounts and lyrics

Android google-services.json is still missing. Google login and social/cloud
features remain inactive until com.seph.capyflow is registered in the existing
capyflow-aa6c5 project, the preview fingerprints above are registered, and the
Android configuration is placed in app/google-services.json before rebuilding.
The iOS configuration is not an Android configuration.

Android follows the iOS lyric route: saved cache, shared backend resolver, then
emergency direct LRCLIB. The current backend enables LRCLIB; NetEase, QQ Music
and Kugou adapters are present but disabled. Not every song has lyrics or timing.

## Validation and remaining limits

Unit tests cover playlist payload compatibility, duration/LRC parsing, song and
album-track parsing, lyric matching/cache round trips, signed artwork URLs,
manual/automatic server selection races, actual quality descriptions, direct
quality selection and Firebase RPC serialization with the extractor's runtime.
An opt-in DirectMusicIntegrationTest checks extraction and audio bytes without
MSI (CAPY_DIRECT_SMOKE=1). Regular tests skip this external-network check.

UI gestures and long playback need emulator/real-device testing. The user reported that a real Android phone did not reproduce the static;
the source review did not establish the exact emulator-side cause. No microphone capture
or audio effects are enabled. Diagnostics record decoder, audio format, buffer
underruns, codec/sink errors and audio-output release; Reset audio output restarts
it while preserving the track and position. This is not a confirmed static fix.

Other iOS parity work remains: collaborative playlists, friend listening activity,
profile editing, followers/following drill-down, related-song autoplay, full
canonical recording matching, message pagination and in-app APK updating.
