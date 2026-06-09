# External Integrations

**Analysis Date:** 2026-06-09
**Target:** `apps/rishi-electron`

## APIs & External Services

### Rishi Worker / Cloudflare Worker (primary backend)
Single Worker host serves **all** authenticated APIs. Base URLs differ between processes:
- **Main process:** `RISHI_API_URL` env, default `https://api.fidexa.org` — `src/main/auth/auth-service.ts` line 5
- **Renderer:** `VITE_WORKER_URL` env, default `https://api.fidexa.org` — `src/renderer/src/config/worker-url.ts`
- Helpers: `workerFetch(path, init)` and `getRealtimeClientSecret`, `transcribeAudio` in `src/renderer/src/lib/api.ts`

**Endpoints called:**
| Endpoint | Method | Purpose | Wired in |
|---|---|---|---|
| `/desktop/start` | POST | Begin magic-link OR Google OAuth | `src/main/auth/auth-service.ts:71,94` |
| `/desktop/poll` | POST | Poll until web flow completes (2s interval, 10min timeout) | `src/main/auth/auth-service.ts:162` |
| `/desktop/cancel` | POST | Server-side cleanup of pending state on sign-out | `src/main/auth/auth-service.ts:267,296` |
| `/api/auth/sign-out` | POST (Bearer) | Better Auth sign-out | `src/main/auth/auth-service.ts:249` |
| `/api/auth/delete-user` | POST (Bearer) | Account deletion | `src/main/auth/auth-service.ts:286` |
| `/api/auth/get-session` | GET (Bearer) | Hydrate user profile from token | `src/main/auth/auth-service.ts:314` |
| `/api/realtime/client_secrets?language=...` | GET | Ephemeral OpenAI realtime client secret | `src/renderer/src/lib/api.ts:377` |
| `/api/audio/speech` | POST | TTS synthesis (proxied; provider opaque to client) | `src/renderer/src/config.json` → `@rishi/shared/tts` |
| `/api/audio/transcribe` | POST (audio/webm) | Deepgram-backed STT | `src/renderer/src/lib/api.ts:421`, `src/renderer/src/hooks/useVoiceInput.ts:104` |
| `/api/billing/portal` | POST | Stripe billing portal redirect URL | `src/renderer/src/routes/settings/account.tsx:41` |
| `/api/sync/upload-url` | POST | R2 presigned upload URL for book files | `src/renderer/src/modules/file-sync.ts:172` |
| `/api/sync/download-url` | POST | R2 presigned download URL | `src/renderer/src/modules/file-sync.ts:253` |
| `/api/realtime/usage` | POST (background) | Realtime billing usage report | `@rishi/shared/voice-chat` via `billing.apiFetch` (`src/renderer/src/services/index.ts:263`) |
| `/v1/users/search` | POST | Sharing invite user lookup | `src/renderer/src/components/sharing/searchUsersViaWorker.ts:17` |
| `/v1/sessions` | POST | Create sharing session | `src/renderer/src/hooks/useSessionMachine.ts:37` |
| `/v1/sessions/:id/redeem` | POST | Redeem join token | `src/renderer/src/hooks/useSessionMachine.ts:57` |

**Auth headers added per request** (`src/renderer/src/lib/api.ts` `workerFetch`, `src/renderer/src/services/sync/service.ts` `createApiFetch`):
- `Authorization: Bearer <token>` (from Better Auth, retrieved via IPC `auth:get-token`)
- Fallback `X-Dev-Bypass: <DEV_BYPASS_SECRET>` when no token AND env secret present
- On 401, ONE retry with a freshly-fetched token

### OpenAI Realtime API (voice chat)
- Direct WebRTC connection from renderer to `https://api.openai.com` using **ephemeral client secret** minted by the worker (no API key in client).
- SDK: `@openai/agents` `RealtimeSession` + `@openai/agents-realtime` `OpenAIRealtimeWebRTC` — `src/renderer/src/services/index.ts:265-311`
- Agent definition + tools in `src/renderer/src/modules/buildRealtimeAgent.ts` (tools: `bookContext` via RAG, `endConversation`, `inspectCurrentPage` via screenshot)
- Voice: `alloy`. Server VAD threshold 0.7, silence 700ms, prefix padding 300ms.
- Idempotent `<link rel="preconnect" href="https://api.openai.com" crossorigin="anonymous">` injected to warm TCP/TLS (`src/renderer/src/services/index.ts:370-378`).
- Inactivity auto-close at 3 minutes (`src/renderer/src/services/index.ts:383`).
- `process.mas` (Mac App Store builds) refuses Google OAuth (`auth-service.ts:92`) — same gating likely applies to realtime billing.

### HuggingFace Hub (model weights only, first-run download)
- `@xenova/transformers` lazily downloads `Xenova/all-MiniLM-L6-v2` (quantised, 384-dim) on first embed call.
- Caches locally per the library defaults (no auth, anonymous HTTPS). Wired in `src/main/vectordb/embeddings.ts:48`.

### Sharing Worker (P2P signalling)
- REST: `https://sharing.rishi.fidexa.org` (env `SHARING_WORKER_URL` / `RISHI_SHARING_WORKER_URL`)
- WebSocket: `wss://sharing.rishi.fidexa.org` (env `RISHI_SHARING_WS_URL`)
- Config served to renderer via IPC `sharing:getConfig` → `src/main/sharing/config.ts`
- ICE servers (returned with config):
  - `stun:stun.cloudflare.com:3478`
  - `stun:stun.l.google.com:19302`
- Wire types in `@rishi/sharing-protocol` workspace package.
- Session machine: `src/renderer/src/machines/sessionMachine.ts` (XState; ~1200 lines, handles host/viewer roles, reborn-host reconnect, role transfer).
- Peer wrappers: `src/renderer/src/actors/sharing/peerActor.ts`, `peerWrapperActor.ts`, `hostFileSenderActor.ts`, `viewerFileReceiverActor.ts` — wrap real `RTCPeerConnection`, can be replaced with `fakeRtcAdapter` for tests.

### Sentry (telemetry)
- Main: `@sentry/electron/main` in `src/main/utils/sentry.ts`. DSN: `https://37b935f34d09bb053baeff3a28d6b9d1@o4510586781958144.ingest.de.sentry.io/4511372584747088` (overridable via `SENTRY_DSN` env). Only inits when `app.isPackaged`. `tracesSampleRate: 0.1`.
- Renderer: `@sentry/electron/renderer` in `src/renderer/src/utils/sentry.ts`. Same DSN. Only when `import.meta.env.PROD`.
- Crashpad handler kept external (not bundled into main) so electron-builder can copy it.
- `captureError(err, { operation, step, ...context })` is the canonical call site (mirrored in both processes).

### GitHub Releases (auto-updater)
- Provider: `generic` is a dev-only stub in `dev-app-update.yml`. Real channel comes from `electron-builder.yml`:
  - `publish.provider: github`
  - `publish.owner: matovu-farid`
  - `publish.repo: rishi-monorepo`
- `electron-updater` `autoDownload = true`, `autoInstallOnAppQuit = true` (`src/main/ipc/updater.ts:19-20`)
- User opt-out persisted in `<userData>` via `readAutoUpdatePref` (`src/main/ipc/updaterPref.ts`)

## Data Storage

**SQLite (local):**
- File: `<app.getPath('userData')>/rishi.db` — `src/main/database/index.ts:35`
- Driver: `better-sqlite3` (native, synchronous)
- Schema: `src/main/database/schema.ts` (drizzle-orm SQLite tables)
- WAL journal, FK on, busy_timeout 5000
- Migrations: `src/main/database/migrations.ts`, repair pass `src/main/database/repair.ts`

**Vector index (local):**
- Directory: `<userData>/vectordb/` — `src/main/vectordb/index.ts:196`
- One file per book: `<bookId>-vectordb.hnsw`
- Driver: `hnswlib-node` (native), cosine, 384-dim
- Atomic writes via tmp+rename (`src/main/vectordb/index.ts:273-276`)
- Auto-recovery on corruption / dim mismatch: file unlinked, rebuilt from `chunk_data` SQLite rows on next pass.

**File storage:**
- Imported book files copied to `<userData>/books/` via `copyBookToAppData` (`src/renderer/src/modules/books.ts`)
- TTS audio cache (MP3) under `<userData>` with hardlink mirror via `fs:linkOrCopyFile` to save 2× disk. Max 500 MB (`src/renderer/src/services/index.ts:127`).
- Sharing-received books: `src/main/sharing/libraryWrite.ts` writes the transferred bytes, verifies SHA-256, registers in SQLite with `source='shared'`.
- Custom protocol `local-file://<path>` serves files to renderer via `protocol.handle` (`src/main/index.ts:141-146`) — Electron's equivalent of Tauri's `asset://`.

**Cloud storage (Cloudflare R2 via worker):**
- Book originals: presigned upload at `/api/sync/upload-url`, download at `/api/sync/download-url`. Driven by `src/renderer/src/modules/file-sync.ts` (`hashBookFile`, `uploadBookFile`).
- Book row fields: `fileR2Key`, `coverR2Key`, `fileHash`, `fileSize` (`src/main/database/schema.ts:18-21`).

**Secret storage:**
- Session token: `<userData>/session.enc`, mode 0o600, encrypted via Electron `safeStorage` (`src/main/auth/session-store.ts`). Linux without libsecret falls back to plaintext.
- Atomic write so crash mid-write doesn't corrupt the file.

**Caching:**
- React-Query in renderer (`src/renderer/src/components/queryClient.ts`)
- TTS audio cache (LRU by mtime; bounded at 500 MB)
- HNSW indices kept warm in an in-memory Map (`src/main/vectordb/index.ts:32`)

## Authentication & Identity

**Provider:** Better Auth on the Rishi worker. Desktop talks to it via two flows:

1. **Magic link** (`auth:start-magic-link` IPC → `POST /desktop/start { email, code_challenge, mode: 'magic-link' }`):
   - Worker emails the user a sign-in link.
   - User clicks it in the system browser → web app signs in → posts to `/desktop/start/complete`.
   - Desktop polls `/desktop/poll` every 2s until `session_token` returned.

2. **Google OAuth** (`auth:start-google` IPC → `POST /desktop/start { code_challenge, mode: 'oauth-google' }`):
   - **Blocked on Mac App Store builds** (`process.mas` check, `src/main/auth/auth-service.ts:92`).
   - Worker returns `web_url`. Desktop opens it via `shell.openExternal` (system browser, NOT in-app webview).
   - Same poll loop.

**PKCE:** `generatePkcePair()` in `src/main/auth/pkce.ts`. `code_challenge` sent up; `code_verifier` only revealed on `/desktop/poll`.

**Session lifecycle:**
- `authService` singleton (`src/main/auth/auth-service.ts:329`)
- `hydrate()` reads `session.enc` on app start
- `onChange(cb)` broadcasts to all renderer windows via `session-changed` IPC event (`src/main/auth/index.ts:11`)
- `signOut()` cancels in-flight polls, calls `/api/auth/sign-out`, cancels server-side states via `/desktop/cancel`, clears `session.enc`
- Sign-out ordering is load-bearing: cancel polls **before** clearing session to prevent a racing `/desktop/poll` 200 from un-signing-out the user

**Renderer-side helpers:**
- `getAuthToken()` in `src/renderer/src/modules/auth.ts` (IPC wrapper)
- `getAuthHeaders()` in `src/renderer/src/lib/api.ts` — returns `{ Authorization: 'Bearer ...' }` or `{}`

**Identity for sharing:**
- `getSigningJwt()` in `src/main/sharing/authToken.ts` returns the current session token as the signed JWT for sharing handshakes (5-min advisory expiresAt; worker is source of truth).

## Monitoring & Observability

**Error tracking:** Sentry (see above).

**Local error dump:**
- `<userData>/error-dump.json` — append-merged structured errors via `debug:dumpError` IPC
- `<userData>/state-dump.json` via `debug:dumpState`
- `<userData>/debug.log` — append-only NDJSON via `debug:appendLog` (used by renderer's `debugLog` helper for timeline tracing; atomic per-line via `fs.appendFile`)
- Wired in `src/main/ipc/debug.ts`

**Logs:**
- Console only in dev; Sentry in prod
- electron-vite forwards renderer console to `RISHI_DEBUG=1` host log when enabled (`src/main/index.ts:125-128`)

**Render-process crash recovery:** `handleRenderProcessGone` (`src/main/index.ts:184`) — crash-loop guard (3 crashes per 60s → "persistent crash" dialog instead of reload).

## CI/CD & Deployment

**Hosting:** End users install standalone desktop binaries; backend lives on Cloudflare Workers (`api.fidexa.org`, `sharing.rishi.fidexa.org`).

**CI pipeline:** Release Desktop CI (referenced in repo-level memory — `feedback_release_process.md`). Build commands in `package.json`:
- `build:mac` (dual-arch DMG+ZIP, notarised)
- `build:win` (NSIS x64, Azure Trusted Signing)
- `build:linux` (AppImage + deb x64)
- `build:mac:debug` (unsigned dev DMG with `CSC_IDENTITY_AUTO_DISCOVERY=false`)

**Code signing:**
- macOS: notarised; identity auto-discovered from keychain. `notarize: true`. See `project_apple_signing.md` memory.
- Windows: Azure Trusted Signing (`build/sign-windows.cjs`). Profile expires 2026-04-24 per memory.
- Linux: unsigned.

**Pre-test scripts:**
- `pretest`: rebuild better-sqlite3 + hnswlib-node for the current Node ABI (vitest runs against Node, not Electron)
- `pretest:e2e`: `scripts/ensure-native-abi.cjs` rebuilds for Electron ABI

## Environment Configuration

**Required for production runtime:** none — defaults shipped. All env vars are overrides.

**Required for E2E:**
- `VITE_WORKER_URL` (point renderer at local wrangler)
- `RISHI_API_URL` (point main at same wrangler)
- `SHARING_WORKER_URL` (sharing variant)
- `RISHI_E2E_SESSION_TOKEN` (E2E auth injection)
- `DEV_BYPASS_SECRET` (paywall bypass in dev)

**Secrets location:**
- Production: hardcoded defaults (Sentry DSN, worker URLs) — no secrets in the binary.
- Dev: env vars set at shell launch. `.env` files are not read by the app today.

## Webhooks & Callbacks

**Incoming:**
- **`rishi://sharing/join?t=<token>`** deep link — registered as default protocol client via `app.setAsDefaultProtocolClient('rishi')` (`src/main/sharing/deepLink.ts:23`). Routed via:
  - macOS `app.on('open-url')` event
  - Windows/Linux argv on first launch, and `app.on('second-instance')` on subsequent launches (`src/main/index.ts:540-552`)
  - Tokens received before the window is ready are buffered, drained on `did-finish-load` via `drainQueuedDeepLink()` (`src/main/index.ts:283-286`)
  - Forwarded to renderer via `sharing:deepLinkReceived` IPC event; renderer subscribes through `electronAPI.sharing.onDeepLink`
- **OS "Open With" file events** for `.epub`/`.pdf`/`.mobi`/`.azw3`:
  - macOS: `app.on('open-file')` (registered before `app.whenReady()` so first-launch files aren't dropped — `src/main/index.ts:52-55`)
  - Windows/Linux: argv on first launch + second-instance
  - Buffered via `pendingOpenFiles[]`, drained either after `did-finish-load` or on demand via `files:getPending` IPC (`src/main/index.ts:573-576`)

**Outgoing:**
- `shell.openExternal(url)` — only `http:`, `https:`, `mailto:` (`src/main/ipc/util.ts:13`)
- OAuth web URL opened in system browser (Google flow)
- Magic-link URL opened by user in their email client (no programmatic outbound)

## Local Protocols / IPC

**Custom URL schemes registered:**
- `local-file://` — serves arbitrary local file paths to the renderer through `protocol.handle` + `net.fetch(pathToFileURL(...))` (`src/main/index.ts:141-146`). Used by `convertFileSrc` (`src/renderer/src/lib/api.ts:465-470`) for PDFs, EPUBs, cover images. Bypasses CSP for `file:` while keeping web security on.
- `rishi://` — sharing deep links (above).

**IPC bridge (`contextBridge.exposeInMainWorld`):**
- `window.electron` — flat surface defined by `ElectronAPI` in `src/preload/types.ts`, derived from `IpcContract` in `src/preload/ipc-contract.ts`. Single source of truth — adding a channel here flows types to both processes.
- `window.api` — `auth` namespace only (`startMagicLink`, `startGoogle`, `getSession`, `signOut`, `deleteAccount`, `getToken`, `onSessionChange`, `isMacAppStore`)
- `window.electron.sharing` — sub-namespace (`getSigningJwt`, `saveTransferredBook`, `discardTransferredBook`, `hasBookFile`, `readBookBytes`, `getConfig`, `onDeepLink`, `readReconnect`, `writeReconnect`, `clearReconnect`)
- Helpers in `src/preload/index.ts` lines 164-176: generic `on(channel, cb) → unsubscribe`, `once`, `send`.
- Window identity passed via `process.argv` parser (`src/preload/windowIdentity.ts`).

## Payment / Billing Gates

**Provider:** Stripe (via the worker; client never sees a Stripe key).

**Surface:**
- `Manage billing` button in `src/renderer/src/routes/settings/account.tsx:41-67` calls `POST /api/billing/portal` → opens returned URL via `openExternal`.
- Errors handled with three UX states: not set up, transport failure, generic failure.

**Premium-feature gates:**
- Implemented in `src/renderer/src/components/auth/features.ts` + `useRequireAuth` hook (`src/renderer/src/hooks/useRequireAuth.tsx`)
- Gated features: voice chat, TTS, sync (per memory `reference_dev_bypass.md`)
- `PremiumFeatureDialog.tsx` and `SignInBanner.tsx` are the visible UI

**Dev-bypass mechanism:**
- `DEV_BYPASS_SECRET` env var read in `src/main/ipc/util.ts:30` (`util:getDevBypassSecret` IPC)
- Renderer attaches as `X-Dev-Bypass: <secret>` header when no Better Auth token is present
- Worker accepts it as a paywall override (dev/test only)
- Wired through every authenticated codepath:
  - `src/renderer/src/lib/api.ts:369` (`getRealtimeClientSecret`)
  - `src/renderer/src/lib/api.ts:413` (`transcribeAudio`)
  - `src/renderer/src/lib/api.ts:449` (`workerFetch`)
  - `src/renderer/src/services/sync/service.ts:41` (sync API)
  - `src/renderer/src/modules/embed-fallback.ts:30` (embed fallback)
  - `src/renderer/src/services/index.ts:103` (TTS auth resolver)
  - `src/renderer/src/hooks/useChat.ts:194` (chat completion)

## Cloud Services Summary

| Service | Role | Auth |
|---|---|---|
| Cloudflare Workers | All backend APIs (`api.fidexa.org`, `sharing.rishi.fidexa.org`) | Bearer token (Better Auth) |
| Cloudflare R2 | Book file + cover storage | Presigned URLs from worker |
| Cloudflare Workers Durable Objects | Sharing session state (inferred from `/v1/sessions` + WS pattern) | Bearer + per-session reconnect token |
| Stripe | Subscription billing | Worker holds Stripe keys; client uses portal redirect |
| OpenAI Realtime API | Voice chat WebRTC | Ephemeral client_secret from worker |
| Deepgram | Speech-to-text (proxied via `/api/audio/transcribe`) | Worker holds Deepgram key |
| Unknown TTS provider | Speech synthesis (proxied via `/api/audio/speech`) | Worker holds key |
| Sentry | Error telemetry | Hardcoded DSN (de.sentry.io) |
| HuggingFace Hub | One-time download of `Xenova/all-MiniLM-L6-v2` model | Anonymous |
| GitHub Releases | Auto-updater channel for desktop binaries | Public repo |
| Azure Trusted Signing | Windows code signing (build time only) | Service principal in CI |

---

*Integration audit: 2026-06-09*
