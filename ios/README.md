# LastWave iOS — personal prototype 0.1.0

Native SwiftUI reimplementation inspired by Clash-Projects/LastWave-Native.

Implemented: YouTube Music song search, local YouTubeKit audio extraction,
AVPlayer playback, queue, background audio configuration, lock-screen commands,
download-to-device, offline playback, persistent download index, deletion.

Not yet implemented: synced lyrics, Last.fm, YouTube account login, recommendations,
playlist imports, widgets, equalizer. This is not full LastWave feature parity.

## Build

On macOS with Xcode, install XcodeGen (`brew install xcodegen`), run
`xcodegen generate`, then open LastWave.xcodeproj. Alternatively put this
directory's contents at the root of a GitHub repository and run the
“Build unsigned IPA” Actions workflow. Download the artifact and sign the IPA
using your own certificate/provisioning profile.

No Xcode compiler or iOS device is available in the development workspace.
The source has not yet passed an Xcode build or device playback test.
YouTube extraction is unofficial and may fail due to service changes, region,
or anti-bot requirements. Errors are displayed rather than pretending playback
worked. Only local extraction is enabled; no third-party extraction server.
Downloads run while the app is active; they are not resumable background jobs.

## Attribution

Original Android project: https://github.com/Clash-Projects/LastWave-Native
by its respective contributors, GPL-3.0. This derivative project uses GPL-3.0.
YouTubeKit by Alexander Eichhorn and contributors, MIT, retrieved by SwiftPM.
Retain its license and notices when distributing its compiled code.
