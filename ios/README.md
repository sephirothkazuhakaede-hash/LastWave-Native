# CapyFlow iOS 0.4.0

CapyFlow is a native SwiftUI music client with YouTube Music search, song and
album results, playlists, synchronized lyrics, background audio, lock-screen
artwork and controls, queue/autoplay, downloads with progress, and offline
playback. Google sign-in is configured through Firebase; Firestore adds public
usernames, following, shared playlists, and playlist collaboration.

The app normally resolves audio on the device through YouTubeKit. It can also
use the optional service in `../backend` for faster, cached M4A/AAC streaming.
If that private service is disabled or unavailable, CapyFlow automatically
returns to its built-in resolver.

## Build

On macOS with Xcode, install XcodeGen (`brew install xcodegen`), run
`xcodegen generate` in this directory, then open `CapyFlow.xcodeproj`.
The repository's **Build unsigned IPA** GitHub Actions workflow also compiles,
checks the app icon, packages an unsigned IPA, and publishes it as an artifact
for signing with Sideloadly, AltStore, or your own certificate.

The included Firebase plist is registered for `com.seph.capyflow`. Google sign-in
works in sideloaded builds as long as that bundle identifier and URL scheme are
preserved. Social features additionally require a Cloud Firestore database and
the rules in `../firebase/firestore.rules` to be deployed.

Downloads use an iOS background URL session, so active transfers can continue
while the app is suspended. iOS still controls execution time and may stop work
after the app is force-quit.

YouTube extraction is unofficial and can fail when an upload is private,
age-restricted, members-only, region-blocked, removed, or rejected by YouTube's
anti-bot controls. CapyFlow reports the per-song reason and retries through its
alternate resolver instead of silently skipping the track.

## Attribution

The iOS client began as a derivative of the
[LastWave Native](https://github.com/Clash-Projects/LastWave-Native) Android
project by its respective contributors. Both are GPL-3.0 projects. YouTubeKit by
Alexander Eichhorn and contributors is MIT licensed and fetched through SwiftPM.
Keep the relevant licenses and notices when distributing compiled builds.
