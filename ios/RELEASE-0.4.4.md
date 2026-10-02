# CapyFlow 0.4.4 build 11 — album recording identity

The 0.4.3 album matcher required the exact same MPRE browse ID, exact artist/title
strings and a three-second duration difference. Real public catalog fixtures show
Snow On The Beach on Midnights resolving in Songs to the same-length recording on
Midnights (3am Edition); BLOOD. and DNA. similarly resolve to DAMN. COLLECTORS EDITION.
Different catalog releases are not sufficient grounds to reject the recording.

Playback mappings previously retained the album row's title/artist and were keyed
only by its row ID. ATV album rows skipped metadata enrichment. Lyrics used those
original fields and cached by row ID rather than playable recording ID. For the
reported RADWIMPS examples, the live Your Name. album and Songs results share IDs:
Nandemonaiya - movie ver. is n89SKAymNfA; Dream lantern is MtLHwqbE1eI. A successful
Songs lyrics request therefore primed the old lyrics[id] file for later album use.
Stale saved rows with missing artist metadata reproduce this behavior. We cannot
identify the exact fields in the user's previous on-device index without its logs.

CanonicalTrackResolver now owns the persisted recording index, row aliases,
in-flight matching and measured durations. Both Songs and Album use it. Matching
normalizes punctuation, featured credits and label decorations, preserves version
words/language, checks known explicitness and duration, and ranks album agreement.
Same playable IDs directly establish recording identity. Missing artists require
either the same media ID or corroborating album and duration. Wrong artist, live,
cover, remix, sped-up/slowed/extended and wrong-duration candidates remain rejected.

Every stream/download request, stream cache key, filename and lyrics key uses
playableID. The row ID remains stable for UI and collaborative playlist editing.
Canonical title/artist/duration travel with it. Successful legacy mappings and
Songs lyrics files migrate; failed lookups are not cached. Saved album playlists
repair metadata in the background, and playback/download repairs local saved rows.
Shared playlist payloads retain recording and album/version metadata; other devices
resolve legacy rows through the same layer. Verified saved mappings remain usable
when metadata refresh is offline. No stream transcoding or new MSI work is added.

Lyrics are requested after recording resolution, use canonical title/artist and
measured duration when available, share memory/disk/in-flight caches, select a
matching LRCLIB recording, reject wrong artist/duration, and retain plain lyrics
fallback. No existing per-track timing offset implementation was removed.

Now Playing uses a measured three-column SwiftUI Layout. It reserves the larger
control group symmetrically and anchors title/output on the full container center;
buttons retain their own frames without invisible placeholders or magic padding.
The native route picker and actual AVAudioSession output observer are preserved.

Regression coverage includes cold Album->Songs convergence; Songs->Album reuse;
canonical playback/download URL generation, duration/lyrics/cache keys; persistence
and album-playlist recovery; legacy mappings/offline recovery; version/explicitness
rejection; nine captured real catalog rows including both RADWIMPS songs; mocked
synced/plain lyrics, wrong-recording rejection, and legacy lyrics cache migration.
Existing backend/security/routing/safe-area/responsive tests are retained. Header
centering assertions run on every existing player fixture at all three screen sizes.

## Real-device acceptance

1. Start with an album track not previously played through Songs. Test Snow On The
   Beach on Midnights and Nandemonaiya/Dream lantern on Your Name.; verify correct
   recording/duration and lyrics before searching it manually.
2. Download the track/album, save it as a playlist, relaunch, and play offline.
   Return through Songs and verify the same recording and available lyrics.
3. Test an old saved album playlist; verify its first use repairs the row without
   losing playlist edits, download state or available offline files.
4. Check centered title/output and tappable dismiss/route/menu buttons. Change to
   AirPods/Bluetooth/AirPlay during playback; verify position and lock-screen controls.
5. Confirm profile/photo/username edits and collaboration still work on two phones.

An unsigned IPA still requires the user's usual signing/install process. The
physical-device checks above remain necessary; simulator tests are not hardware
routing or on-device stale-index verification.
