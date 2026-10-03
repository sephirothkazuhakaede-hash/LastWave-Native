# Playlist backups and activity permissions — 0.4.7 (14)

## Production prerequisite

Publish `firebase/firestore.rules` to the existing `capyflow-aa6c5` project.
The 0.4.6 repository update added activity rules but did not deploy them.
Production's older rules reject both `activitySettings` and `listeningActivity`.
An app rebuild or Retry alone cannot change server permissions.

From the repository root after authorized Firebase CLI sign-in:

```sh
npx firebase-tools deploy --only firestore:rules --project capyflow-aa6c5
```

This publishes rules, not user documents. Keep the existing profile, follows,
username and shared-playlist rules alongside the new sections. Never replace
the rules with public allow-all rules.

## Private account library

Regular playlists, imported playlists, saved albums and their song metadata
now back up automatically while signed in, separately from collaborative
playlists. `users/{uid}/library/{sha256(playlistID)}` is owner-only. It contains
the playlist ID, a bounded Codable payload, an optional compressed cover,
an explicit deletion tombstone and a server timestamp. No audio or stream
credentials are uploaded. Documents use last-acknowledged-write wins for
simultaneous edits to the same playlist, as in Firestore's offline model.

On sign-in, restore cloud documents into the account's local library. An
empty fresh installation never writes an empty replacement library. Existing
unscoped local playlists migrate once to the first signed-in account.
Account-local libraries and pending edits use separate persistence keys;
switching accounts does not upload the previous account's library. Signed-out
playlists stay in a guest library. Queued edits remain local until acknowledged.
The Library page displays backup status, errors and Retry. Users should verify
“Playlists backed up to your account” before uninstalling. Uninstalling before
a successful backup can still lose device-only data and offline audio.

The old device-only playlist already removed by uninstall cannot be recovered
from Firebase unless it had previously been published/shared or backed up.

## Profile bio

Followers and Following both use `SocialPersonRow` → `SocialPersonProfileView`.
That destination already displays a non-empty bio below the username,
including when reached through another person's Following list. No separate
preview omits it.

## Validation

Firebase emulator: 8 tests passed, including initial OFF batch, limited friend
feed query, private library reads with a new session, ownership, payload bounds
and synchronized deletion. Existing backend media/lyrics tests: 19 passed.
Focused Swift serialization tests run through the existing iOS Actions path;
Release compilation/IPA packaging must succeed before installing this build.
