# External Integrations

**Analysis Date:** 2026-04-05

## APIs & External Services

**AI / LLM:**
- OpenAI — Text completions, TTS, and Realtime API
  - SDK/Client (Worker): `openai` ^6.9 in `workers/worker/src/index.ts`
  - SDK/Client (Desktop): `@openai/agents` ^0.3.4 in `apps/main`
  - Auth: `OPENAI_API_KEY` (Cloudflare Worker binding)
  - Endpoints proxied by Worker:
    - `POST /api/audio/speech` — TTS using `tts-1` model
    - `GET /api/realtime/client_secrets` — Realtime session token (model: `gpt-realtime`)
    - `POST /api/text/completions` — Text completions using `gpt-5-nano`
  - Desktop Tauri calls worker; desktop never holds OpenAI key directly

**Speech Recognition (STT):**
- Deepgram — Speech-to-text (key stored in Worker, not yet wired to an endpoint in current index.ts)
  - Auth: `DEEPGRAM_KEY` (Cloudflare Worker binding)

**On-Device Embedding (no external call):**
- `embed_anything` 0.6.5 (Rust crate) — Local embedding inference inside Tauri process
  - Code: `apps/main/src-tauri/src/embed.rs`
  - No API key required; runs fully offline

## Data Storage

**Databases:**
- SQLite (local, desktop only)
  - Location: OS app data directory (`rishi.db`)
  - ORM: Diesel 2.3.4 with r2d2 connection pool (max 10 conns)
  - Migrations: Diesel migrations at `apps/main/src-tauri/migrations/`
    - `2025-12-01-135707-0000_create_books`
    - `2025-12-01-140457-0000_create_chunkdata`
  - TypeScript access: `kysely` + `kysely-dialect-tauri` via `tauri-plugin-sql`
  - Rust access: `apps/main/src-tauri/src/db.rs`, `apps/main/src-tauri/src/sql.rs`

**Vector Store (local, desktop only):**
- HNSW (Hierarchical Navigable Small World) via `hnsw_rs` 0.3.3
  - Code: `apps/main/src-tauri/src/vectordb.rs`
  - Persisted to app data directory alongside SQLite
  - No external vector DB; fully in-process

**Caching / Auth State Relay:**
- Upstash Redis — Used as short-lived auth state relay between web app and Tauri
  - SDK (Web): `@upstash/redis` ^1.36 in `apps/web/src/lib/redis.ts`
  - SDK (Worker): `@upstash/redis/cloudflare` ^1.36 in `workers/worker/src/index.ts`
  - Auth env vars: `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN`
  - TTL: auth state keys expire after 600 seconds (10 min); auth logs after 3600 seconds
  - Key pattern: `auth:state:{state}` (JSON blob with userId, status, codeChallenge)
  - Key pattern: `auth:log:{state}` (list of step timestamps)

**File Storage:**
- Local filesystem only — Books (EPUB, PDF) stored in Tauri app data directory
- No cloud file storage detected

## Authentication & Identity

**Auth Provider:**
- Clerk — Primary auth provider
  - Web SDK: `@clerk/nextjs` ^6.36 (`apps/web`)
    - Middleware: `apps/web/src/middleware.ts` (clerkMiddleware on all routes)
    - Components: `apps/web/src/components/clerk-listener.tsx`
    - Server actions: `apps/web/src/lib/redis.ts` (verifies Clerk session before writing Redis)
  - Worker SDK: `@clerk/backend` ^2.29 + `@hono/clerk-auth` ^3.0.3 (`workers/worker`)
    - Used to verify Clerk session tokens and fetch user profiles from Worker
  - Env vars: `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`
  - Clerk does NOT run inside the Tauri desktop app directly

**Auth Flow (Tauri <-> Web <-> Worker):**
1. Desktop generates UUID `state` + PKCE `code_verifier`, stores in Tauri Store (`store.json`)
2. Desktop opens `https://rishi.fidexa.org?login=true&state=...&code_challenge=...` in browser
3. Web app (Clerk) authenticates user; `ClerkListener` saves `{userId, state, codeChallenge}` to Redis
4. Web redirects to deep link `rishi://auth/callback?state=...`
5. Desktop deep-link handler calls `POST /api/auth/exchange` on Worker with Clerk session token
6. Worker verifies Clerk token, looks up userId from Redis, returns signed JWT (7-day expiry)
7. JWT stored in Tauri Store; used as Bearer token for all subsequent Worker API calls
- Code: `apps/main/src/components/LoginButton.tsx`, `apps/main/src-tauri/src/commands.rs`

**JWT:**
- Custom JWT issued by Worker using `@tsndr/cloudflare-worker-jwt` ^3.2.1
  - Secret: `JWT_SECRET` (Cloudflare Worker binding)
  - Expiry: 7 days
  - Payload: `{ sub: userId, iat, exp }`
  - All protected Worker routes validated by `requireWorkerAuth` middleware in `workers/worker/src/index.ts`

## Monitoring & Observability

**Error Tracking:**
- Sentry — Deployed across all three runtimes
  - Tauri (Rust): `sentry` 0.42 + `tauri-plugin-sentry` 0.5; DSN hardcoded in `apps/main/src-tauri/src/lib.rs`; minidump crash reporting enabled
  - Next.js: `@sentry/nextjs` ^10; config in `apps/web/sentry.server.config.ts`, `apps/web/sentry.edge.config.ts`, `apps/web/next.config.ts`; Sentry tunnel route `/monitoring`
  - Cloudflare Worker: `@sentry/cloudflare` ^10.32; DSN hardcoded in `workers/worker/src/index.ts`; wraps the entire Hono app via `Sentry.withSentry`

**Analytics:**
- Vercel Analytics — `@vercel/analytics` 1.3.1 in `apps/web`

**Logs:**
- Sentry structured logs (`enable_logs: true`) in Tauri backend
- Sentry `enableLogs: true` in Worker
- Redis append-only auth logs per auth flow (`auth:log:{state}`)

## CI/CD & Deployment

**Hosting:**
- Web (`apps/web`): Vercel (inferred from `@vercel/analytics`, Sentry `automaticVercelMonitors`, Sentry org `farid-org` project `javascript-nextjs`)
- Worker (`workers/worker`): Cloudflare Workers via `wrangler deploy --minify`
- Desktop (`apps/main`): Tauri bundler; auto-update via `tauri-plugin-updater`
- Mobile (`apps/mobile`): Expo (EAS Build assumed; no CI config detected)

**CI Pipeline:**
- Not detected (no GitHub Actions, CircleCI, or similar config files found)

## Webhooks & Callbacks

**Incoming:**
- `rishi://auth/callback` — Custom URL scheme deep link handled by Tauri desktop app (`tauri-plugin-deep-link`); carries `state` parameter from OAuth flow

**Outgoing:**
- Worker → Clerk API: User profile fetch (`clerkClient.users.getUser`)
- Worker → OpenAI API: TTS, text completions, Realtime session tokens
- Tauri → Worker: All AI and auth endpoints via Bearer JWT token
  - Base URL: `https://rishi-worker.faridmato90.workers.dev`
  - Referenced in: `apps/main/src-tauri/src/llm.rs`, `apps/main/src-tauri/src/speach.rs`, `apps/main/src-tauri/src/api.rs`, `apps/main/src-tauri/src/commands.rs`

## Environment Configuration

**Required env vars (Cloudflare Worker bindings):**
- `OPENAI_API_KEY` — OpenAI API access
- `DEEPGRAM_KEY` — Deepgram STT access
- `CLERK_SECRET_KEY` — Clerk backend verification
- `CLERK_PUBLISHABLE_KEY` — Clerk token validation
- `UPSTASH_REDIS_REST_URL` — Redis endpoint
- `UPSTASH_REDIS_REST_TOKEN` — Redis auth
- `JWT_SECRET` — Worker JWT signing secret

**Required env vars (Next.js / Vercel):**
- Clerk public and secret keys (consumed by `@clerk/nextjs`)
- Upstash Redis URL and token (consumed by `@upstash/redis`)

**Desktop app:**
- No runtime env vars; secrets never stored in the Tauri app
- `SENTRY_DSN` build-time optional env var; fallback DSN hardcoded in `apps/main/src-tauri/src/lib.rs`

**Secrets location:**
- Worker secrets: Cloudflare Workers environment (set via Wrangler or Cloudflare dashboard)
- Web secrets: Vercel environment variables
- Desktop: No secrets; JWT token stored in Tauri persistent store (`store.json`) on user's machine

---

*Integration audit: 2026-04-05*
