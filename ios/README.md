# CapyFlow iOS — personal prototype 0.2.0

Native SwiftUI music app inspired by Clash-Projects/LastWave-Native.

Implemented: YouTube Music song search, local YouTubeKit audio extraction with
its maintained remote fallback, AVPlayer playback, queue, background audio
configuration, lock-screen commands, validated download-to-device, offline playback,
persistent download index, deletion, responsive layouts, draggable seeking, and
synced/plain LRCLIB lyrics.

Not yet implemented: Last.fm, YouTube account login, recommendations,
widgets and equalizer. This is not full upstream feature parity.

## Build

On macOS with Xcode, install XcodeGen (`brew install xcodegen`), run
`xcodegen generate`, then open CapyFlow.xcodeproj. Alternatively put this
directory's contents at the root of a GitHub repository and run the
“Build unsigned IPA” Actions workflow. Download the artifact and sign the IPA
using your own certificate/provisioning profile.

No Xcode compiler or iOS device is available in the development workspace.
The source has not yet passed an Xcode build or device playback test.
YouTube extraction is unofficial and may fail due to service changes, region,
or anti-bot requirements. Errors are displayed rather than pretending playback
worked. Local extraction is attempted first. If it fails, YouTubeKit may use its
documented Cloudflare-hosted remote extraction fallback; requests are executed from
the device so returned stream URLs remain usable.
Downloads run while the app is active; they are not resumable background jobs.

## Attribution

Original Android project: https://github.com/Clash-Projects/LastWave-Native
by its respective contributors, GPL-3.0. This derivative project uses GPL-3.0.
YouTubeKit by Alexander Eichhorn and contributors, MIT, retrieved by SwiftPM.
Retain its license and notices when distributing its compiled code.
