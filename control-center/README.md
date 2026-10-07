# CapyFlow Control Center 0.2

The Windows app includes the music/backend source, its dependencies, Cloudflared and yt-dlp. Firebase Authentication and Firestore remain on Spark; there is no Firebase Storage, Cloud Functions or paid cloud provisioning.

## Start using it

1. Close the old Control Center and open the new executable.
2. Connect with Google using the existing CapyFlow administrator account.
3. In **Backend & status**, the existing `CapyFlowBackend-dev11/backend` data folder is detected on this PC. If needed, choose it manually. Its `.env`, banners, music cache and service-account file remain external and are never packaged or displayed.
4. **Start backend** keeps an existing server running. **Restart with bundled backend** switches to the packaged version when music download jobs are idle. An existing Cloudflare tunnel is preserved. When no tunnel exists, the bundled Cloudflared starts one and uses your existing GitHub CLI sign-in to update mobile discovery.
5. Closing the window hides it in the system tray while it manages a server. Use the tray menu to stop the managed backend and quit. Keep the PC running for remote music and banners.

## Admin tools

- **Profile banners:** the existing GIF upload, preview, draft, publish, unpublish and delete flow is preserved. Recommended banner size: about 960 × 400 pixels, 12–15 fps and 1–3 MB.
- **Users:** browse accounts or search an exact email, UID or @username. Enable/disable preserves data. Disabling revokes refresh tokens; an existing mobile token may remain valid for up to an hour. Administrator accounts cannot be disabled here. This is not immediate room muting or account deletion.
- **Announcements:** draft privately, then publish to the existing Global Chat on both clients. First publication follows existing Android Global Chat push preferences. Withdrawal leaves a placeholder; republishing the same ID restores the message without sending another new-message push.
- **Global Chat:** hide or restore the latest 50 messages. Sender and timestamp are preserved. Original text is retained in a private moderation record. DMs are not exposed by this tool.
- **Notifications:** preview the registered audience and send to existing Android Global Chat push opt-ins. Your devices are excluded. Requests are idempotent during retries; acceptance by Firebase does not guarantee display on a phone. iOS push is not supported by the current client and requires a future iOS integration.
- **App updates:** view releases, edit Android release notes while preserving the APK/checksum, and enter a new Android version/build/release notes and request the existing stable workflow. GitHub CLI must already be signed in on the PC. The app safely commits the new version and release notes before starting the build; concurrent branch changes cannot be overwritten. iOS keeps its existing signing/distribution workflow.
- **Admin history:** account, moderation, announcement and notification actions are recorded in private Firestore collections.

## Security and compatibility

Remote admin endpoints still require a verified Firebase token and the server UID allowlist. New sensitive modules additionally check disabled/revoked admin sessions through Firebase Admin. The existing service-account credential stays on the backend; it is not distributed in the executable. Account administration needs Firebase Authentication Admin, and moderation/announcements/admin history need Cloud Datastore User on that backend account. No new client permissions or Firestore rule grants are required: the existing default-deny rules protect the new admin collections, and the server SDK uses its existing IAM permissions.

New public content works through the interfaces already implemented in the clients. New mobile screens, dedicated announcement feeds, notification behavior, or additional update sources still require client changes. Admin controls cannot add native features to an already installed IPA/APK.

For another PC, supply your existing backend data/settings and credentials securely, and sign into GitHub CLI once for tunnel discovery/update management. Credentials are intentionally not embedded. GitHub CLI is a local prerequisite; it is not bundled. A controlled stop/restart affects server availability; no background service is installed.

## Build and validation

`pnpm install --frozen-lockfile`, `pnpm test`, then `pnpm dist`. Packaging stages source/assets only, installs production backend dependencies, and downloads the official Cloudflare/yt-dlp release tools with GitHub-provided SHA-256 verification. No `.env`, uploaded catalog, cache or service-account files are copied. Tool provenance is included beside the runtime binaries.

The dedicated Control Center branch/workflow builds Windows and tests its backend without triggering either mobile build. The portable executable is unsigned.
