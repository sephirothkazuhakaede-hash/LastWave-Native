# CapyFlow 0.4.3, build 10

## Causes and fixes

- Production Firestore rules still accepted the old profile schema. They rejected the newer generated-name, rename timestamp and photo fields. The checked-in rules now include safe legacy/partial-profile repair, atomic username reservations and the 14-day rename cooldown. Save success is returned explicitly instead of inferred from a shared error that listeners could clear.
- Album browse rows can point to official music videos while their displayed durations describe the album recordings. For example, Midnights' Lavender Haze row points to `h8DLofLM7No`, while Songs search returns the same album's audio recording `GwNPBeWpI-0`. Album playback resolves an exact title/artist/album match with audio-recording provenance before requesting media. It preserves the logical library ID, caches the mapping and uses the resolved recording's actual duration. Duration clamping is removed.
- Inviting a collaborator used to publish an old local playlist twice, potentially replacing edits. Existing shared copies are reused; track mutations now use transactions and deduplicate by track ID. Membership remains UID based through username changes. Followed profile photos and names update through listeners.
- High and Automatic selected identical backend formats. Settings → Audio Quality now offers Data Saver and Best Available. The existing automatic/default selector is preserved. Original compatible audio is selected without transcoding. Backend caches, iOS stream caches and offline filenames include quality; offline records include the actual format metadata when available. Unknown legacy quality is not silently treated as the chosen quality.
- Now Playing has Apple's native audio-output picker and the current system output name. iOS reroutes the existing player; route selection does not reload, seek or resolve a track. Disconnecting the current output pauses playback. The playback session uses the long-form audio policy.
- Decorative backgrounds expand after compositing, a window-level backdrop covers the root, and navigation bars are transparent. Foreground content keeps safe-area positioning. Responsive tests check actual top/bottom screenshot pixels on the root tabs and primary screens. Decorative gradients stay hidden from accessibility; foreground controls retain the original bounds checks.

## Automated validation

The workflow runs backend tests, the real yt-dlp selector against offline multi-quality fixtures, Firestore emulator authorization tests, iOS media-policy unit tests and all responsive tests on the small phone, iPhone 13 and large phone. Release build, icon verification, version/build verification and IPA packaging remain required.

Physical Bluetooth/AirPlay behavior and two real iPhone accounts require device checks; simulator tests cannot establish those outcomes.

## Two-iPhone acceptance checks

1. Sign in on both phones. Confirm new and existing profiles become ready. Change display name, photo and first custom username; check the friend sees updates. Attempt a taken name and a second rename within 14 days; verify a visible explanation and retained edits.
2. Follow each other, publish a playlist and invite the other account. Add/remove songs on both phones; rename as owner, remove a collaborator or leave as a member. Confirm edits appear on both phones and access follows membership through username changes.
3. Play the same album recording from Songs search, the album page and an album-based playlist. Download it and compare duration/playback offline; confirm no music-video intro, outro or empty tail.
4. Change Audio Quality in Settings, play/download a source offering multiple compatible formats and check Audio Info. With a single usable source quality, confirm Best Available is reported. Confirm the other mode's cached file is not silently reused.
5. During playback, use the native picker to switch among iPhone speaker, AirPods, Bluetooth headphones/speaker and AirPlay speaker/TV. Confirm position and lock-screen controls are retained. Disconnect headphones and confirm playback pauses.
6. Check every screen, including lyrics and sheets, on iPhone 13: ambience continues behind the status bar/home indicator, while controls remain safely positioned.

## MSI deployment

The backend source changes must be deployed/restarted on the MSI server for backend Audio Info to be available. Older backends still accept the preserved `automatic`/`dataSaver` requests and stream normally, but missing metadata is displayed as unavailable. No source data is fabricated.
