# CapyFlow media backend

This is CapyFlow's small, local-first audio service. It uses the official `yt-dlp` release to resolve an iPhone-compatible M4A/AAC stream, relays byte ranges immediately, and fills a persistent cache in the background. CapyFlow automatically falls back to its built-in resolver when this service is disabled or unavailable.

It is intended for personal/private use. You are responsible for the source service's terms and for only downloading media you are permitted to keep.

## Windows quick start

Requirements: Windows 10/11 and Node.js 20.12 or newer. Docker and FFmpeg are not required.

1. Open this `backend` folder.
2. Run `start.cmd`.

The first run downloads `yt-dlp.exe` from the official release, verifies its SHA-256 checksum, and stores it in the ignored `bin` folder. The server then listens only on `http://127.0.0.1:8787`.

Useful commands:

```powershell
npm test
npm run update:yt-dlp
npm run benchmark -- dQw4w9WgXcQ
```

## Stage 1: test from an iPhone on the same trusted Wi-Fi

Run `start-lan.cmd`. This explicitly changes the bind address for that process and permits unauthenticated devices on the local network. Windows may ask for firewall access; allow only **Private networks**.

Find the MSI's private IPv4 address with `ipconfig`, then enter this in CapyFlow's **Account → Streaming server** screen:

```text
http://192.168.x.x:8787
```

Local HTTP is accepted only for loopback and private IPv4 ranges. CapyFlow deliberately does not send a Firebase token over HTTP. Stop the server before joining an untrusted network.

## Stage 2: HTTPS tunnel

Do not expose `start-lan.cmd` directly to the internet. For a Cloudflare Tunnel deployment:

- configure the tunnel to reach `http://127.0.0.1:8787`;
- set `AUTH_MODE=firebase` and `FIREBASE_PROJECT_ID=capyflow-aa6c5` in a local `.env`;
- use the tunnel's `https://` address in CapyFlow;
- keep tunnel credentials outside this repository.

With HTTPS enabled, CapyFlow sends the signed-in user's short-lived Firebase ID token. The backend validates its signature, issuer, audience, timestamps, and project without storing a Google password or Firebase service-account key.

`cloudflared` installation and public tunnel creation are intentionally deferred until local playback is proven.

## API

- `GET /health` — public health and cache counters; no song data.
- `GET|HEAD /v1/audio/:videoID?quality=automatic` — range-capable audio.
- `GET|HEAD /v1/download/:videoID?quality=automatic` — the same audio with download disposition.
- `GET /v1/cache/:videoID` — cache status.
- `POST /v1/cache/:videoID` — pre-cache a track.
- `GET /v1/diagnostics/timings` — recent extraction/first-byte/transfer timings.

All `/v1` routes follow the selected authentication mode. Source URLs and upstream request headers are never returned to clients or diagnostics.

## Configuration

Copy `.env.example` to `.env` to override defaults. `.env`, cached audio, the `yt-dlp` binary, cookies, and tunnel credentials are ignored by Git.

Important settings:

- `CACHE_MAX_BYTES` defaults to 10 GiB.
- `CACHE_MAX_AGE_DAYS` defaults to 30 days.
- `CACHE_CONCURRENCY` controls background cache jobs.
- `AUTH_MODE=local` permits loopback, plus LAN only with the explicit LAN switches.
- `AUTH_MODE=firebase` requires a valid CapyFlow Firebase ID token.

No YouTube cookie support is enabled by default. If YouTube later requires a private session, add it only through a local ignored configuration; never commit a browser cookie file.

## Optional Docker run

Docker is not needed on the MSI. An optional image and loopback-only Compose setup are included so the same API can later move to Linux without changing the iOS client.

```powershell
docker compose up --build
```

The Compose port is published to host loopback only. Change authentication and tunnel routing deliberately before remote use.

## Message notifications in the same MSI backend

The main backend now includes an optional outbound Firebase message sender. Start your existing `start-cloudflare.cmd` or `start.cmd`: one Node process runs streaming and push. Cloudflare continues to expose music only; no notification HTTP endpoint, extra port or second tunnel is created. Firebase Cloud Functions and Blaze are not needed for this self-hosted worker. Firestore reads still use your project's normal quotas.

Requirements for push: Node.js 22 or newer, an Android device with Google Play services and notification permission, the published private device-token rules, and a server credential for **capyflow-aa6c5**. Use a dedicated service account limited to **Cloud Datastore Viewer** (`roles/datastore.viewer`) and **Firebase Cloud Messaging API Admin** (`roles/firebasecloudmessaging.admin`). The worker reads conversations/profiles/device tokens and sends FCM; it does not need permission to modify messages, accounts or playlists.

Keep the private JSON credential on the MSI, outside the repository/download folder, for example `C:/Users/Seph/.capyflow/private/message-sender.json`. Never upload it to GitHub, put it in an APK, share it in chat, or use Android's google-services.json as a server credential.

Add to your existing backend `.env`:

```dotenv
FIREBASE_PROJECT_ID=capyflow-aa6c5
PUSH_NOTIFICATIONS=true
PUSH_SERVICE_ACCOUNT=C:/Users/Seph/.capyflow/private/message-sender.json
PUSH_STATE_FILE=./state/message-push.json
```

The launcher installs the official Firebase Admin dependency when missing. On startup it prints `Message push worker started`. If credentials/configuration fail, it reports that push is unavailable and keeps music streaming online. Firestore reconnects are retried. Recent unread conversations from the last 24 hours are checked at startup/reconnect; already-read messages are skipped. Accepted device tokens are deduplicated and remembered privately under `state`, including partial-send retries. Keep that state directory when updating the backend.

FCM acceptance is not proof a phone displayed a notification. After starting the sender, background CapyFlow Android and send a real message from your other account. It should show a notification, and tapping it should open the correct conversation. A force-stopped app must be reopened before Android permits delivery again. Your MSI must remain running with Internet access. This sender targets Android FCM registrations; iOS background receiving still requires its own Apple push setup.

Updating an existing MSI backend: replace only source/scripts/package files from the backend ZIP, retain your `.env`, `cache`, `bin`, private credential and `state`, then restart the normal Cloudflare launcher. Music resolver/authentication settings remain yours.
