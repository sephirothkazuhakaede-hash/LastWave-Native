# CapyFlow 0.4.6 (build 13): coordinated update

The application bundle ID remains `com.seph.capyflow`. Existing Firebase identities, profiles, follows, playlists, application document storage, preferences, and offline lyric filenames remain in place. Installation must use the same bundle ID and compatible signing identity over the existing app; deleting the app before installing can remove local data. The app never claims to install an update itself.

## MSI lyrics resolver

`GET /v1/lyrics?title=...&artist=...&album=...&duration=200&videoId=...&explicit=true`

The existing `/v1` authentication policy applies. Title and artist are required; optional duration is seconds. Optional `isrc` and `recordingId` are supported by the backend for future catalog metadata. The current iOS catalog provides title, artist, album, duration, playable YouTube ID and explicit status, not ISRC. The resolver queries all available adapters concurrently, rejects conflicting editions/identities, and ranks genuine words/syllables above lines above plain text. Matching album and duration refine ties; provider ordering never overrides timestamp quality. Word arrays require source timing provenance and monotonic valid times. No timing estimation is performed.

Response fields: `schemaVersion`, `provider`, `providerID`, `synchronization` (`word`, `syllable`, `line`, `plain`), `timingOrigin`, `lines` (`time`, `text`, optional genuine `words`), `track`, `providers`, and `cached`. No result is HTTP 404; all providers failing is HTTP 503. Successes persist for seven days under the existing MSI cache directory's `lyrics` subdirectory, bounded to 2,000 entries. Concurrent identical requests coalesce. Disk failures do not stop lyric lookup. iOS reads current and legacy offline lyric files first, then the backend, then emergency direct LRCLIB. Its lyric-line files remain backward compatible and retain word arrays when supplied.

### Provider validation and unavailable adapters

- LRCLIB: documented public `https://lrclib.net/api/search`, tested with a live Coldplay/Yellow lookup and fixture tests. Current public adapter maps LRC line/plain content.
- NetEase: no authorized, documented public lyrics-search interface could be validated from its developer platform. Disabled adapter with an explicit reason.
- QQ Music: no authorized, documented public lyrics-search interface could be validated. Disabled adapter with an explicit reason.
- KuGou: `https://open.kugou.com/docs` exists, but a stable authorized lyrics-search contract was not established. Disabled adapter with an explicit reason.

The three unavailable adapters make no network requests, use no scraping or client impersonation, and return no invented data. Implement `available`, `name`, and `search(request)` using an authorized interface when one becomes available. A candidate needs title, artist, source ID, available album/duration/stable identifiers and lyrics; genuine word timings require `timingOrigin: 'provider'`. LRCLIB remains usable if every other adapter is unavailable. No Genius or LiriQo dependency is included.

## Firebase social and activity

Cached profile snapshots keep the current connection state. Metadata-only server snapshots are observed. Retry replaces listeners, ignores callbacks from old listeners, retains displayed cache data, and retries a server-backed profile operation. Actual Firebase errors retain the existing offline/permission/setup messages.

Follower/following destinations push on the existing native navigation stack. Edge pages contain up to 50 relationships; profile reads are batched in groups of 20 and cached for five minutes. Deleted profiles are skipped without breaking pagination. Loading, empty, saved-data, retry/error and load-more states are provided. Existing following counts and all followed IDs determine follow controls; the activity shelf uses the existing bounded 50-profile following subscription.

Deploy the updated `firebase/firestore.rules` through the existing Firebase project deployment process before testing activity against production. This repository change does not deploy rules to production. `activitySettings/{uid}` contains a private sharing preference; `listeningActivity/{uid}` contains only bounded song title, artist, playable video ID, artwork URL, playback state and timestamps. Activity metadata is readable by signed-in accounts; the app displays followed people. No audio, playback position, tokens, stream URLs or local file paths are published.

Sharing defaults OFF. Privacy OFF cancels pending publishing immediately and atomically writes OFF plus deletion of presence. An unsynced OFF persists locally across restarts and cannot be overridden by an old cache snapshot. While offline the deletion queues; other clients may retain their cache until reconnection, but active presence expires after five minutes. Opt-in must sync before publishing. Track/play state events coalesce for two seconds, writes are spaced at least 15 seconds apart, and a playing-only heartbeat runs every two minutes. Current activity becomes recent once paused/stale; the UI shows recent entries for one day. Followed-user activity uses batched listeners of up to 20 documents, with following-profile changes debounced to avoid startup listener churn.

## Stable updates

The app checks on launch/foreground no more often than every six hours, plus manual checks in Updates. The dedicated manifest source is:

`https://raw.githubusercontent.com/sephirothkazuhakaede-hash/LastWave-Native/stable-updates/capyflow-stable.json`

This is separate from `runtime/backend-discovery` and the Cloudflare tunnel. A second independent source reads GitHub releases; the newest valid candidate across both sources wins, so a stale branch manifest cannot mask a newer stable release. This source excludes drafts/prereleases, requiring a numeric `capyflow-vVERSION` tag and a `capyflow-stable.json` asset whose version matches the tag. Ordinary experimental commits, Android releases, test builds and prerelease labels cannot trigger stable notifications. Numeric version components are compared first, then numeric build. Equal/older versions are ignored. Later defers that particular version/build; a later stable build can prompt again.

After a validated build, prepare release notes in a text file and run:

```sh
node backend/scripts/stable-manifest.mjs --stable --version 0.4.6 --build 13 --notes-file release-notes.txt --install-url https://github.com/sephirothkazuhakaede-hash/LastWave-Native/releases/tag/capyflow-v0.4.6 --output capyflow-stable.json
```

Publish a non-prerelease GitHub release tagged `capyflow-v0.4.6`, attach the IPA and the generated `capyflow-stable.json`, or publish that manifest on the dedicated `stable-updates` branch. Do not publish the stable manifest for experimental builds. The Update action opens the configured HTTPS installation/release page; users install through their signing/distribution method. Account/cloud data is unchanged; existing local data requires installing over the app rather than deleting it.

## Validation

Backend tests cover existing media/cache/range/quality behavior, lyrics matching/ranking/timestamp provenance/cache persistence/coalescing/TTL/provider isolation, authenticated endpoint behavior and stable manifest validation. Firebase emulator tests include activity ownership, opt-in, metadata limits, private settings and privacy-off deletion. The existing iOS workflow adds focused lyrics, social connection and update policy tests, retains existing recording/download tests, builds Release for generic iOS, and packages/verifies an unsigned IPA. No new simulator/UI-testing infrastructure is added.

Release packaging and Swift typechecking require Xcode on macOS. Linux syntax parsing is not a substitute for that build. Before any final branch commit/push, those required checks must pass or the branch-push prerequisite must be explicitly authorized.

### Checks completed in this workspace (2026-10-03)

- Base branch commit: `5681c863c6c48fbd68bb46d56751665ce1ce714f`.
- `backend/npm test`: 19/19 passed, including existing media tests.
- Existing real yt-dlp 2026.8.19 format-selector check: passed (48 kbps data saver, 256 kbps best, 128 kbps single source; no transcoding).
- Firebase Java 21 emulator tests: 6/6 passed, including opt-in, ownership, size limits, private settings and atomic OFF deletion. Emulator tests do not deploy production rules.
- Live LRCLIB query: 20 candidates returned with title/artist metadata and synced content.
- Changed Swift files/new Swift tests parsed for syntax; this is not a Swift compiler/typecheck or device/UI validation.
- Diff review: no changes to Player, Catalog, CanonicalTrackResolver, MediaDuration, backend media/yt-dlp/cache-store implementations, bundle ID or user-storage paths. Existing purple palette retained.
- **Pending:** Xcode focused tests, Release compilation, app-icon/metadata validation and unsigned IPA packaging. The user authorized pushing the complete batch on 2026-10-03 so the existing macOS GitHub runner can perform the remaining Release validation; the workspace has no Xcode.
