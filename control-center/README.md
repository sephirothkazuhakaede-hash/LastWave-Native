# CapyFlow Control Center

Separate Windows desktop admin app. Version 0.1 manages animated profile banners and reports backend status. Users, announcements, moderation, push and update management are future modules, not active controls.

## Architecture

- GIF files and complete metadata live on the existing Node backend in `BANNER_DIR` (default `backend/data/profile-banners`). This directory is durable content, separate from the evictable audio cache. Back it up and preserve it during backend updates.
- `GET /v1/profile-banners` returns schema version 1 and published entries: `id`, `name`, immutable SHA-256 `revision`, relative `path`, dimensions, frame count, byte size and update time.
- Public GIF routes serve only currently published entries. Admin preview routes also serve drafts. Publishing/unpublishing is serialized; metadata writes use atomic replacement. Deleted IDs are reserved by tombstones and never reused.
- Firestore holds only `profiles/{uid}.coverID` and `profileBannerPermissions/{id}.published`. The tiny permission mirror prevents a normal user selecting unpublished IDs through a forged profile update. There are no GIF bytes or remote media URLs in Firestore. This uses Spark-compatible Firestore and Firebase Authentication, without Storage, Functions or paid Google Cloud features.
- Both clients refresh while profile/banner views are open (about 60 seconds), cache the catalog and up to 20 downloaded GIFs on disk, and use versioned filenames to avoid repeated downloads. Existing chat/player/search features are unchanged.
- The existing parade GIF remains a bundled offline/default fallback. The backend seeds its first catalog from the same original asset on first startup. New banners come exclusively from the backend. Removed IDs render the default profile appearance after the next successful refresh; unrelated profile edits remain allowed. A disconnected device can retain a previously cached banner until it reconnects.

## One-time backend setup

1. Deploy the updated backend folder, including `assets/capy-parade-v1.gif`; preserve `data/profile-banners` and your existing `.env`/push settings. Node 24 is used by CI.
2. Add `FIREBASE_PROJECT_ID=capyflow-aa6c5`, `CAPYFLOW_ADMIN_UIDS=Q5bR8hqe3UXUHp09JSsZL1gMlj22` and optionally `BANNER_DIR=./data/profile-banners` to backend `.env`. Admin routes fail closed when the allowlist is empty. They require verified Firebase tokens even when music uses local/anonymous LAN mode.
3. Deploy the updated Firestore rules with `firebase deploy --only firestore:rules --project capyflow-aa6c5`. These grant only the existing owner account permission to change the published-ID mirror. Adding another admin requires deliberately updating both server allowlist and rules.
4. Ensure `localhost` is listed in Firebase Authentication → Settings → Authorized domains. Google sign-in runs in the PC's system browser, never inside an embedded Google login window. The app uses a random, one-use loopback nonce, validates origin/host, and keeps sign-in tokens in memory only. No service-account key is installed in Control Center.
5. Restart the backend and use your existing HTTPS/tunnel address. Only loopback HTTP is accepted by Control Center; credentials are never sent over plaintext LAN HTTP.
6. Install the new iOS/Android client build once. Later banner additions need no app releases.

## Use

Open the Windows executable, enter the backend address, then **Connect with Google** using the administrator account. Choose a GIF and enter a name and permanent lowercase ID. **Upload as draft** stores it privately; check its animated preview, then **Publish**. You can rename, unpublish, republish or delete entries. Deletion removes the GIF file and reserves its ID. Unpublish is the reversible option.

Uploads are limited to 5 MiB, 2048 × 2048, 300 frames and 200 million total frame pixels, with a 100-entry active library limit. The backend validates the complete GIF container, bounds request sizes, prevents path traversal, and does not fetch arbitrary remote URLs.

## Build

From this directory: `corepack pnpm install --frozen-lockfile`, `node node_modules/electron/install.js`, then `corepack pnpm dist`. The dedicated GitHub workflow uploads the portable Windows executable. `pnpm test` runs transport/ID security checks; backend tests exercise authorization, upload validation, draft visibility, publication, persistence and deletion. The Windows package is unsigned.

## Deployment boundary

Repository builds do not replace a running private backend automatically. Deploy the backend update and rules before expecting remote publication to work. Client offline fallback remains available while that setup is pending. No paid service is provisioned by this project.
