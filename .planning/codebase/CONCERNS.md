# Codebase Concerns

**Analysis Date:** 2026-04-05

## Tech Debt

**Hardcoded Worker URL across all Rust modules:**
- Issue: The Cloudflare Worker base URL `https://rishi-worker.faridmato90.workers.dev` is hardcoded in 7 separate places with no single constant or config file
- Files: `apps/main/src-tauri/src/commands.rs` (lines 59, 101, 217, 245), `apps/main/src-tauri/src/api.rs` (line 3), `apps/main/src-tauri/src/llm.rs` (line 7), `apps/main/src-tauri/src/speach.rs` (line 13)
- Impact: Changing the worker URL (e.g., custom domain, staging env) requires finding and editing 7 locations. Missed occurrences will cause silent runtime failures.
- Fix approach: Extract to a single `const WORKER_BASE_URL: &str` in a shared module (e.g., `src-tauri/src/config.rs`) and import everywhere.

**reqwest::Client created per request:**
- Issue: `reqwest::Client::new()` is called once per HTTP request across `commands.rs`, `llm.rs`, `speach.rs`, and `api.rs` — 7 instantiation sites total
- Files: `apps/main/src-tauri/src/commands.rs`, `apps/main/src-tauri/src/llm.rs`, `apps/main/src-tauri/src/speach.rs`, `apps/main/src-tauri/src/api.rs`
- Impact: Each `reqwest::Client` creates its own connection pool. Creating one per request destroys connection reuse, increases memory churn, and slows TLS handshakes.
- Fix approach: Create a single `static REQWEST_CLIENT: OnceLock<reqwest::Client>` in a shared module (same pattern already used for `DB_POOL` and `VECTOR_STORE`).

**Duplicate `src/src/` directory in Tauri frontend:**
- Issue: `apps/main/src/src/` exists as a parallel directory alongside `apps/main/src/`, containing its own `routeTree.gen.ts` and `config.json`
- Files: `apps/main/src/src/routeTree.gen.ts`, `apps/main/src/src/config.json`
- Impact: Stale generated files in the wrong location can cause router mismatches in development. Confuses tooling and developers navigating the codebase.
- Fix approach: Delete `apps/main/src/src/` entirely and ensure TanStack Router's output path is configured to write only to `apps/main/src/`.

**Deprecated route left in worker with no removal plan:**
- Issue: `GET api/user/:state` is marked "Backwards-compatible state route (deprecated)" but remains active with no authentication guard
- Files: `workers/worker/src/index.ts` (line 110)
- Impact: The route exposes a Clerk user lookup via a Redis state key with no auth check. Any caller with a valid state UUID can retrieve user profile data (name, image URL, etc.).
- Fix approach: Add `requireWorkerAuth` guard if still needed, otherwise delete the route entirely.

**axios imported alongside fetch in Cloudflare Worker:**
- Issue: `axios` is imported and used only for the `GET /api/realtime/client_secrets` route. All other routes use native `fetch` via Hono/OpenAI SDK.
- Files: `workers/worker/src/index.ts` (lines 1, 202)
- Impact: Adds an unnecessary dependency to the Worker bundle. Cloudflare Workers have strict CPU/bundle size limits.
- Fix approach: Replace the `axios.post` call with native `fetch` and remove the `axios` import.

**Misspelled module name (`speach.rs`):**
- Issue: The speech/TTS module is named `speach.rs` (typo) in `apps/main/src-tauri/src/`
- Files: `apps/main/src-tauri/src/speach.rs`, `apps/main/src-tauri/src/lib.rs` (line 14: `pub mod speach`)
- Impact: Minor but creates confusion for new contributors. Any refactor or find-replace searching for "speech" will miss this file.
- Fix approach: Rename to `speech.rs` and update the `mod` declaration in `lib.rs`.

**Hardcoded OpenAI model names in worker:**
- Issue: Model names `"gpt-5-nano"` and `"gpt-realtime"` are hardcoded strings in the worker's route handlers
- Files: `workers/worker/src/index.ts` (lines 211, 261)
- Impact: Changing the model requires a redeploy. Non-existent or renamed models will produce runtime 400/404 errors with no compile-time check.
- Fix approach: Extract model names to constants at the top of `index.ts` or into Worker environment bindings/secrets.

## Known Bugs

**`maintainQueueSize` leaks a `setInterval` per `REQUEST_AUDIO` event:**
- Symptoms: Memory and timer leaks in the TTS queue. Over time, many overlapping intervals fire simultaneously and the queue degrades
- Files: `apps/main/src/modules/ttsQueue.ts` (line 49)
- Trigger: Every call to `ttsQueue.requestAudio(...)` emits `TTSQueueEvents.REQUEST_AUDIO` which registers a new `setInterval` via `this.maintainQueueSize`. The interval is never cleared.
- Workaround: None currently. The interval fires every 10ms and drains the queue, partly masking the bug in normal usage.

**Auth token expiry check uses `as_u64()` which silently returns `None` for negative values:**
- Symptoms: If `auth_expires_at` is stored as a negative number (e.g., clock issue), `as_u64()` returns `None`, the expiry check is skipped, and an expired token is used.
- Files: `apps/main/src-tauri/src/commands.rs` (line 113–116)
- Trigger: System clock drift, manual store corruption, or negative timestamp from server
- Workaround: Token validation at the worker via `jwt.verify` still catches truly invalid tokens.

**`hasRedirected` ref in `ClerkListener` is never reset on route change:**
- Symptoms: If the user navigates away and back to the auth page within the same session without a full page reload, the auth redirect does not fire again.
- Files: `apps/web/src/components/clerk-listener.tsx` (line 44)
- Trigger: SPA navigation back to a page with `?login=true&state=...`
- Workaround: Full page reload resets the ref.

## Security Considerations

**Deprecated unauthenticated user lookup route:**
- Risk: `GET api/user/:state` at `workers/worker/src/index.ts` (line 110) returns Clerk user profile data (first name, last name, image URL) for any valid `state` UUID without authentication
- Files: `workers/worker/src/index.ts`
- Current mitigation: State UUIDs expire after 10 minutes in Redis (TTL 600s in `apps/web/src/lib/redis.ts`). Requires guessing or obtaining a valid state UUID.
- Recommendations: Add `requireWorkerAuth` guard or delete the route immediately.

**Sentry `sendDefaultPii: true` in Worker:**
- Risk: `sendDefaultPii: true` causes Sentry to capture request headers (including `Authorization` with bearer tokens) and client IP addresses
- Files: `workers/worker/src/index.ts` (line 276)
- Current mitigation: JWTs are short-lived (7 days). Sentry data is stored in EU region (`ingest.de.sentry.io`).
- Recommendations: Set `sendDefaultPii: false` unless PII capture is intentional and audited. At minimum, scrub the `Authorization` header via `beforeSend`.

**Sentry DSN hardcoded in Rust source:**
- Risk: The Sentry DSN is embedded in `apps/main/src-tauri/src/lib.rs` (line 33) as a fallback string literal. DSNs are not secrets but exposing them in source allows third parties to send noise to your Sentry project.
- Files: `apps/main/src-tauri/src/lib.rs`
- Current mitigation: The primary DSN is loaded from the `SENTRY_DSN` env var at compile time via `option_env!`.
- Recommendations: Remove the hardcoded fallback; fail loudly in production if `SENTRY_DSN` is not set.

**No request body size limit or input validation on TTS and completions endpoints:**
- Risk: `POST /api/audio/speech` and `POST /api/text/completions` in `workers/worker/src/index.ts` accept unbounded JSON bodies. Zod validation is only used on `GET /api/realtime/client_secrets` response parsing.
- Files: `workers/worker/src/index.ts` (lines 186, 255)
- Current mitigation: Cloudflare Workers have a default 100MB request size limit. OpenAI API will reject absurdly large inputs.
- Recommendations: Add Zod schema validation for request bodies on all POST routes. Add `input` field length limits before forwarding to OpenAI.

**No rate limiting on worker endpoints:**
- Risk: Any authenticated user can call `/api/audio/speech` and `/api/text/completions` unlimited times, causing unbounded OpenAI API cost
- Files: `workers/worker/src/index.ts`
- Current mitigation: Auth is required (JWT). OpenAI account-level rate limits apply.
- Recommendations: Add per-user rate limiting using Cloudflare's Rate Limiting API or a Redis counter with per-`userId` keys.

## Performance Bottlenecks

**On-demand BERT model loading per `embed_text` call:**
- Problem: `embed_text` in `apps/main/src-tauri/src/embed.rs` (line 86) calls `EmbedderBuilder::new()...from_pretrained_hf()` on every invocation, which downloads/loads the `sentence-transformers/all-MiniLM-L6-v2` model each time.
- Files: `apps/main/src-tauri/src/embed.rs`
- Cause: No static/global singleton for the embedding model, unlike `DB_POOL` and `VECTOR_STORE`.
- Improvement path: Wrap the embedder in a `OnceLock<Arc<Embedder>>` static so the model is loaded once on first use and shared across all calls.

**HNSW index loaded from disk on every `save_vectors` and `search_vectors` call:**
- Problem: `VectorStore::with_hnsw_mut` in `apps/main/src-tauri/src/vectordb.rs` (lines 100–113) deserializes the full HNSW index from disk on every read or write. For a book with thousands of vectors this is a significant I/O and deserialization cost per query.
- Files: `apps/main/src-tauri/src/vectordb.rs`
- Cause: The HNSW index is not cached in memory between operations.
- Improvement path: Keep the loaded `Hnsw` index in memory inside `VectorStore` (wrapped in `Option`) and only reload from disk when the file has changed.

**TTS queue `maintainQueueSize` uses 10ms polling interval:**
- Problem: A `setInterval` fires every 10ms to check if the queue exceeds `MAX_QUEUE_SIZE = 15`, regardless of queue activity
- Files: `apps/main/src/modules/ttsQueue.ts` (line 49)
- Cause: Polling instead of event-driven size enforcement
- Improvement path: Check and trim queue size inline inside `requestAudio()` before enqueuing, eliminating the interval entirely.

**Prefetch spawns sequential awaited requests instead of parallel:**
- Problem: `prefetchAudio` in `apps/main/src/models/PlayerClass.ts` (line 697) uses `await this.requestAudio(...)` inside a `for` loop, serializing up to 3 prefetch requests
- Files: `apps/main/src/models/PlayerClass.ts`
- Cause: Sequential `await` in loop instead of `Promise.all`
- Improvement path: Collect promises and resolve with `Promise.allSettled`.

## Fragile Areas

**`VectorStore` global singleton parameterized by `(name, dim, directory)`:**
- Files: `apps/main/src-tauri/src/vectordb.rs` (lines 226–251)
- Why fragile: A single `VECTOR_STORE: OnceLock<Arc<Mutex<VectorStore>>>` is reused across books. `init_vector_store` re-initializes the store when parameters differ. If `save_vectors` and `search_vectors` are called concurrently with different `book_id` values (different `name` values), re-initialization of the shared singleton will affect in-flight operations.
- Safe modification: Avoid concurrent cross-book vector operations until the store is keyed by `name`.
- Test coverage: Integration tests in `apps/main/src-tauri/src/sql.rs` cover single-book scenarios only.

**`db.rs` startup uses panicking `.expect()` for critical paths:**
- Files: `apps/main/src-tauri/src/db.rs` (lines 20, 32, 36)
- Why fragile: `app_data_dir()` and `SqliteConnection::establish` use `.expect()` — a panic in app startup will crash the process entirely with no user-facing error recovery
- Safe modification: Replace with propagated `?` errors that Tauri's setup closure can handle gracefully (the setup closure already returns `anyhow::Result`).
- Test coverage: `init_test_database` does handle errors with `?`, so tests are not affected.

**`Player.cleanup()` does not unsubscribe from `eventBus`:**
- Files: `apps/main/src/models/PlayerClass.ts` (line 123)
- Why fragile: `initialize()` subscribes to `EventBusEvent.NEW_PARAGRAPHS_AVAILABLE`, `NEXT_VIEW_PARAGRAPHS_AVAILABLE`, `PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE`, and `PAGE_CHANGED`, but `cleanup()` only removes `audioElement` listeners. If `Player` is re-instantiated (e.g., book switch), old subscriptions accumulate.
- Safe modification: Store unsubscribe handles returned by `eventBus.subscribe()` and call them in `cleanup()`.
- Test coverage: `apps/main/src/models/Player.Class.test.ts` — extent of cleanup coverage unknown.

**`EpubPlayerControl` is instantiated as a module-level singleton at import time:**
- Files: `apps/main/src/models/epub_player_contol.ts` (line 151: `export const epubPlayerControl = new EpubPlayerControl()`)
- Why fragile: The constructor calls `this.initialize()` (async, fire-and-forget). If the module is imported before the Jotai store is ready, atom subscriptions may silently fail. There is no mechanism to detect or retry a failed initialization.
- Safe modification: Export a factory function and call it explicitly after app initialization, or add initialization state tracking.

## Scaling Limits

**SQLite with connection pool of 10 for a desktop app:**
- Current capacity: `Pool::builder().max_size(10)` in `apps/main/src-tauri/src/db.rs` (line 49)
- Limit: SQLite with WAL mode handles ~100 concurrent readers well but is not designed for high-write concurrency. Embedding jobs that write chunk data while the UI reads are the primary contention point.
- Scaling path: Not applicable for a single-user desktop app, but the `busy_timeout = 5000ms` should prevent deadlocks at current usage levels.

**Redis auth flow state stored in Upstash with 10-minute TTL:**
- Current capacity: Each auth flow stores two Redis keys (`auth:state:{state}` and `auth:log:{state}`)
- Limit: Upstash free tier has request limits. High auth flow volume (many users re-authenticating) could exhaust quotas.
- Scaling path: Auth state could be stored in a stateless signed cookie or JWT instead of Redis, eliminating the dependency.

## Missing Critical Features

**No token refresh mechanism:**
- Problem: JWT tokens issued by the worker have a 7-day expiry (`exp = iat + 60 * 60 * 24 * 7` in `workers/worker/src/index.ts` line 82). When the token expires, the user must repeat the full OAuth-like flow (open browser, log in, wait for deep link callback). There is no silent refresh.
- Blocks: Continuous session experience. Users are forced to re-authenticate weekly.

**No input length enforcement for TTS text:**
- Problem: The `tts()` function in `apps/main/src-tauri/src/speach.rs` and the TTS queue in `apps/main/src/modules/ttsQueue.ts` send arbitrary-length text to the worker. OpenAI TTS has a 4096-character input limit.
- Blocks: Long paragraphs will produce a 400 error from OpenAI with no user feedback.

## Test Coverage Gaps

**Worker endpoints have no tests:**
- What's not tested: All route handlers in `workers/worker/src/index.ts` — auth exchange, user lookup, TTS, completions, realtime client secrets
- Files: `workers/worker/src/index.ts`
- Risk: Breaking changes to auth flow, model names, or Zod parsing go undetected until production
- Priority: High

**Web app (`apps/web`) has no tests:**
- What's not tested: `apps/web/src/lib/redis.ts`, `apps/web/src/components/clerk-listener.tsx`, `apps/web/src/middleware.ts`
- Files: `apps/web/src/`
- Risk: Auth redirect logic, Redis key format, and middleware matcher changes are untested
- Priority: High

**`EpubPlayerControl` and `Player.cleanup()` lifecycle not covered:**
- What's not tested: Subscription accumulation on re-initialization, cleanup on book switch
- Files: `apps/main/src/models/PlayerClass.ts`, `apps/main/src/models/epub_player_contol.ts`
- Risk: Memory/listener leaks during repeated book open/close cycles
- Priority: Medium

---

*Concerns audit: 2026-04-05*
