# Worker Contract — Chat Sync (Phase 16)

Status: Live (deployed 2026-06-12)
Owners: iOS (apps/apple), Worker (workers/worker)
Related plans: 16-01 schema, 16-02 RishiAPI endpoints, 16-03 worker routes, 16-04 iOS outbound, 16-05 iOS inbound

> This is the cross-team contract for the four `/api/sync/{conversations,messages}` routes that power cross-device chat history sync. The same routes also carry voice transcripts — `RishiVoice.VoiceTranscriptBridge` writes through `markConversationDirty` + `markMessageDirty`, which `SyncEngine` now uploads via these endpoints.
>
> **Owned by:** iOS team (`apps/apple/Packages/RishiSync/`, `apps/apple/Packages/RishiAPI/`).
> **Implemented by:** worker team (`workers/worker/src/routes/conversations.ts`, `workers/worker/src/routes/messages.ts`).
> **Last updated:** Phase 16 Plan 06.

Companion to [`RUNBOOK-BILLING-WORKER.md`](./RUNBOOK-BILLING-WORKER.md) Section 1.5 — that doc tells the operator how to deploy + smoke; this doc tells the worker dev (and downstream platform devs) what the deployed wire shape is.

---

## 1. Overview

Phase 16 closes the gap audited at `apps/apple/Packages/RishiSync/Sources/RishiSync/Engine/SyncEngine.swift:198-203`, where `SyncEngine.runOnce` had previously dispatched `.conversation` and `.message` dirty items into `metadataStore.forget(...)` — an explicit no-op despite Phase 7 and Phase 9 both promising conversation sync end-to-end. Phase 9 shipped the producer side (`markConversationDirty`, `markMessageDirty`, `AppChatDirtyHook`); Phase 16 fills in the uploader + worker route + iOS inbound merge.

Voice transcripts inherit the wiring automatically: `RishiVoice.VoiceTranscriptBridge` persists transcript snippets through the same `conversations` + `messages` Core Data tables, so closing the chat-sync gap closes the voice-transcript gap in one stroke.

Four endpoints, all behind Better Auth's `requireAuth` middleware:

```
POST /api/sync/conversations     # iOS uploader push
GET  /api/sync/conversations     # iOS inbound pull (?since=<ms_epoch>)
POST /api/sync/messages          # iOS uploader push
GET  /api/sync/messages          # iOS inbound pull (?since=<ms_epoch>)
```

Storage is D1 (SQLite), not R2 — the rows are small JSON, and D1 with Drizzle matches the existing `apple_subscriptions` (Phase 14) and `devices` (quick-vpx) patterns. R2 stays reserved for book file blobs.

Conflict resolution is **Last-Writer-Wins on `(id, updated_at)`** for v1. The server upserts keyed by `id`; iOS inbound merges into Core Data using the same LWW pattern position + highlight inbound already uses. Acceptable for v1 single-user-multi-device.

---

## 2. Auth

All four endpoints sit behind the `requireAuth` Hono middleware exported from `workers/worker/src/index.ts:185`. The middleware accepts either:

- **Bearer token:** `Authorization: Bearer <better-auth-token>` — iOS persists this in the Keychain after sign-in (see `WORKER-CONTRACT-AUTH.md` Section 2.4) and sends it on every request.
- **Session cookie:** `Cookie: rishi.session_token=<...>` — used by web / electron clients. iOS does not send this.

Both paths resolve to a `users.id` string row. The middleware then sets `c.set("userId", <users.id>)`, and every handler reads `c.get("userId")` as the authoritative caller identity.

A `401 {"error":"Unauthorized"}` here means the session lookup failed — token expired, revoked, or never minted. iOS should treat 401 as a re-sign-in trigger (existing `AuthError.unauthenticated` surface from Phase 3).

`DEV_BYPASS_SECRET` fallback is honored by the same middleware for local + dev-bypass headers — exists for vitest fixtures (`workers/worker/src/routes/devices.test.ts` proved the pattern). Production builds NEVER ship a non-empty `DEV_BYPASS_SECRET` env var.

---

## 3. Endpoint shapes

All paths are relative to `https://api.fidexa.org`.

### 3.1 POST /api/sync/conversations

Request body (zod-validated at `workers/worker/src/routes/conversations.ts:28-40`):

```json
{
  "conversations": [
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "user_id": "ignored-server-overrides-this",
      "book_id": "00000000-0000-0000-0000-000000000000",
      "title": "First conversation",
      "archived": false,
      "created_at": 1781193600000,
      "updated_at": 1781193600000
    }
  ]
}
```

| Field        | Type           | Notes                                                                                                                          |
| ------------ | -------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `id`         | UUID string    | Stable per-conversation id; idempotency key.                                                                                   |
| `user_id`    | string         | **SERVER-OVERRIDDEN.** Accepted by the schema for backward compatibility but discarded — the row's `user_id` is the session `userId`. |
| `book_id`    | string         | UUID of the parent book. The literal `"00000000-0000-0000-0000-000000000000"` is the sentinel meaning "no book attached" (a free-standing chat). iOS maps `nil bookId` to the sentinel on upload and back to `nil` on download. |
| `title`      | string (1-500) | User-visible title; updated on conflict (LWW).                                                                                 |
| `archived`   | bool           | Always `false` in v1 (archive UX deferred). Future-compat field.                                                                |
| `created_at` | int64 ms epoch | Wall-clock ms; immutable after first write.                                                                                    |
| `updated_at` | int64 ms epoch | Wall-clock ms; LWW key.                                                                                                        |

Array length: `1 .. 500` (zod `.min(1).max(500)`).

Successful response (HTTP 200):

```json
{ "applied_count": 1 }
```

Curl example (successful POST with Better Auth bearer):

```bash
curl -sS https://api.fidexa.org/api/sync/conversations \
  -X POST \
  -H 'Authorization: Bearer <better-auth-token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "conversations": [
      {
        "id": "11111111-1111-1111-1111-111111111111",
        "user_id": "ignored",
        "book_id": "00000000-0000-0000-0000-000000000000",
        "title": "First conversation",
        "archived": false,
        "created_at": 1781193600000,
        "updated_at": 1781193600000
      }
    ]
  }'
# {"applied_count":1}
```

Unauthenticated curl (the canonical "did the route mount?" smoke):

```bash
curl -sS -w '\n%{http_code}\n' https://api.fidexa.org/api/sync/conversations \
  -X POST -H 'Content-Type: application/json' -d '{}'
# {"error":"Unauthorized"}
# 401
```

Error responses:

| Status | Body                                          | Cause                                                              |
| ------ | --------------------------------------------- | ------------------------------------------------------------------ |
| `401`  | `{"error":"Unauthorized"}`                    | No / invalid session token; `requireAuth` middleware rejected.     |
| `400`  | `{"error":"bad_request","detail":"<zod>"}`    | Body failed zod parse — wrong field, wrong type, array empty, etc.  |
| `500`  | (worker generic)                              | D1 write failure. Surfaced in Sentry; iOS keeps the dirty marker and retries. |

### 3.2 GET /api/sync/conversations

Query parameter:

- `since` (optional int64 ms): return only rows whose `updated_at > since`. Omit on first sync to fetch all.

Successful response (HTTP 200):

```json
{
  "rows": [
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "user_id": "001234.abcdef.5678",
      "book_id": "00000000-0000-0000-0000-000000000000",
      "title": "First conversation",
      "archived": false,
      "created_at": 1781193600000,
      "updated_at": 1781193600000
    }
  ]
}
```

`user_id` in the response is the *server-known* owner (the caller's own user id, since we filter by `userId == callerId`). `archived` is always `false` in v1 (the schema does not yet carry an archived column — the wire field is preserved as a v1.1 forward-compat slot).

### 3.3 POST /api/sync/messages

Request body (zod-validated at `workers/worker/src/routes/messages.ts:30-41`):

```json
{
  "messages": [
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "conversation_id": "11111111-1111-1111-1111-111111111111",
      "role": "user",
      "content": "Hi.",
      "created_at": 1781193601000,
      "updated_at": 1781193601000
    }
  ]
}
```

| Field             | Type                                       | Notes                                                                                          |
| ----------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| `id`              | UUID string                                | Stable per-message id; idempotency key.                                                        |
| `conversation_id` | string                                     | UUID of parent conversation. Server checks parent ownership — see Section 6 cross-user isolation.|
| `role`            | enum `"user" \| "assistant" \| "system"`   | LLM role; voice transcripts use `"user"` for the spoken side and `"assistant"` for the model.   |
| `content`         | string (1-50_000)                          | Plaintext message content; updated on conflict (LWW).                                          |
| `created_at`      | int64 ms epoch                             | Wall-clock ms; immutable after first write.                                                    |
| `updated_at`      | int64 ms epoch                             | Wall-clock ms; LWW key. iOS uploader synthesizes from `created_at` because messages are append-only (never edited in-place by the user) — value is always `>= created_at`. |

Array length: `1 .. 500`.

Successful response (HTTP 200):

```json
{ "applied_count": 1 }
```

Note: `applied_count` may be **less than** the inbound array length when rows whose `conversation_id` is owned by a different user are silently dropped (see Section 6). It is NOT an error — `applied_count` is the truthful count of rows that landed in D1.

Unauthenticated curl:

```bash
curl -sS -w '\n%{http_code}\n' https://api.fidexa.org/api/sync/messages \
  -X POST -H 'Content-Type: application/json' -d '{}'
# {"error":"Unauthorized"}
# 401
```

### 3.4 GET /api/sync/messages

Query parameter:

- `since` (optional int64 ms): return only rows whose `updated_at > since`. Omit on first sync.

Successful response (HTTP 200):

```json
{
  "rows": [
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "conversation_id": "11111111-1111-1111-1111-111111111111",
      "role": "user",
      "content": "Hi.",
      "created_at": 1781193601000,
      "updated_at": 1781193601000
    }
  ]
}
```

The GET path joins through the caller's owned conversations — see Section 6.

---

## 4. Idempotency semantics

Both POST endpoints are idempotent on `id`.

- **Conversations.** Re-sending the same conversation row results in an `onConflictDoUpdate` against `conversations.id`. The server overwrites `title` + `updated_at` only; `book_id` stays immutable in v1 (book attachment is a property of conversation creation, not editing). `created_at` is preserved (the original insert wins).
- **Messages.** Re-sending the same message row updates `content` + `updated_at`. `conversation_id`, `role`, and `created_at` are preserved from the original insert.

Replaying a full upload batch produces the same end-state — `applied_count` reflects the number of rows that the upsert touched, not whether any rows were inserted vs updated. Callers do NOT need an `Idempotency-Key` header; the row `id` IS the key.

Test coverage: `workers/worker/src/routes/conversations.test.ts::idempotentOnId` and `messages.test.ts::idempotentOnId` (Phase 16-03).

---

## 5. Conflict resolution

**Last-Writer-Wins on `(id, updated_at)`** for v1.

### 5.1 Server upsert

The server treats every POST as the latest truth — it overwrites `title` (conversations) or `content` (messages) plus `updated_at` unconditionally on conflict. There is no `updated_at` comparison gate on the worker side; the row written by the most recent POST always wins. Clients are expected to source `updated_at` from a monotonic wall-clock at the moment of edit.

### 5.2 iOS inbound merge

The iOS `SyncEngine` inbound branch (Phase 16-05) pulls via `GET /api/sync/conversations?since=<ms>` and `GET /api/sync/messages?since=<ms>`, then merges into Core Data:

- **Conversations.** LWW on `(id, updated_at)`: if the incoming row's `updated_at` > the local row's, overwrite locally; otherwise keep local. Matches the existing position / highlight inbound merge pattern.
- **Messages.** Append-only upsert: if the row doesn't exist locally, insert; otherwise overwrite `content` (messages are append-only by user UX — edits are not exposed — but the worker DB allows updates so the merge tolerates them defensively).

Watermark is per-resource: `metadataStore.setLastSyncedAt(resource: .conversation)` and `.message` are tracked separately from the existing book / position / highlight watermarks.

### 5.3 Acceptable trade-offs

v1 LWW will lose mid-air collisions where two devices edit the same conversation title within the same sync cycle — the later POST wins, the earlier edit is silently dropped. This is the same posture position + highlight sync ships, and acceptable for v1 single-user-multi-device. Advanced conflict resolution (vector clocks, manual-merge UI) is deferred to v1.1 if user-visible conflicts become a real problem.

---

## 6. Cross-user isolation

### 6.1 Conversations

The POST handler at `workers/worker/src/routes/conversations.ts:60-73` sets the row's `userId` column from `c.get("userId")` — the session-resolved caller — **overriding** whatever the client sent in the body's `user_id` field. A malicious client cannot impersonate another user by setting that field; the schema accepts it (for backward compatibility) but it is discarded at the write site.

The GET handler at `workers/worker/src/routes/conversations.ts:88-102` filters strictly on `eq(conversations.userId, callerId)`. Cross-user reads are physically impossible without a session swap.

### 6.2 Messages

Messages have no direct `user_id` column — ownership is scoped through the parent conversation's `userId`. The POST handler at `workers/worker/src/routes/messages.ts:61-70` therefore performs a parent-ownership pre-check per row:

```ts
const parent = await db
  .select({ userId: conversations.userId })
  .from(conversations)
  .where(eq(conversations.id, row.conversation_id))
  .get()
if (!parent || parent.userId !== userId) continue
```

When the parent conversation is owned by a different user (or doesn't exist), the row is **silently dropped** — NOT rejected with a 403. The truthful `applied_count` in the response reflects only the rows that landed.

The silent-drop is deliberate: a 403 (or any per-row error) would leak the existence of someone else's conversation id to the caller (an attacker could enumerate ids by watching for 403 vs 200). Silent drop closes that leak. Support team note: a message that "didn't sync" because its parent was owned by another user is NOT a bug — it is the documented forbidden cross-user push behavior.

The GET handler at `workers/worker/src/routes/messages.ts:106-120` does the same in reverse: two-step fetch — get the caller's owned conversation ids, then `inArray(messages.conversationId, ids)`. Drizzle's native join is avoided so the in-memory test mock stays trivial.

### 6.3 Cross-user test coverage

`workers/worker/src/routes/conversations.test.ts::userBExcludedFromUserA` and `messages.test.ts::userBMessagesDroppedForUserAConversation` exercise the two paths (Phase 16-03 task 1-2).

---

## 7. Error codes

| Status | Body shape                                    | Source                                                                                  | iOS behavior                                                                |
| ------ | --------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `200`  | `{"applied_count":<int>}` or `{"rows":[...]}` | Happy path.                                                                              | Forget dirty markers (POST) or persist rows + watermark (GET).               |
| `400`  | `{"error":"bad_request","detail":"<zod>"}`    | Body failed zod parse — empty array, wrong type, oversized content, etc.                | Treated as a programming bug; iOS surfaces a Sentry warning and stops retrying that batch. |
| `401`  | `{"error":"Unauthorized"}`                    | `requireAuth` middleware — no session or expired token.                                  | Surface `AuthError.unauthenticated`; iOS prompts re-sign-in.                 |
| `500`  | (generic)                                     | Worker-side D1 write failure or unexpected exception. **Never thrown silently** — surface in Sentry. | Transient. iOS keeps the dirty marker and retries on next sync cycle.       |

500-class errors are NOT swallowed by the worker — they propagate out of the Hono handler and become real Sentry events. Operators see them in `pnpm exec wrangler tail rishi-worker --format pretty`.

---

## 8. Sample curl invocations

### 8.1 Successful POST with Better Auth bearer

```bash
curl -sS https://api.fidexa.org/api/sync/conversations \
  -X POST \
  -H 'Authorization: Bearer eyJhbGciOi...' \
  -H 'Content-Type: application/json' \
  -d '{
    "conversations": [
      {
        "id": "11111111-1111-1111-1111-111111111111",
        "user_id": "ignored",
        "book_id": "00000000-0000-0000-0000-000000000000",
        "title": "Hello from device A",
        "archived": false,
        "created_at": 1781193600000,
        "updated_at": 1781193600000
      }
    ]
  }'
# {"applied_count":1}
```

### 8.2 Unauth POST returning 401

```bash
curl -sS -w '\n%{http_code}\n' https://api.fidexa.org/api/sync/conversations \
  -X POST -H 'Content-Type: application/json' -d '{}'
# {"error":"Unauthorized"}
# 401
```

```bash
curl -sS -w '\n%{http_code}\n' https://api.fidexa.org/api/sync/messages \
  -X POST -H 'Content-Type: application/json' -d '{}'
# {"error":"Unauthorized"}
# 401
```

The 401 envelope is the cross-team contract for "the route is mounted and the auth middleware is wired" — the canonical smoke check called out in `RUNBOOK-BILLING-WORKER.md` Section 1.5.

---

## 9. Cross-Team Checklist

Tick before any platform's chat-sync build ships to production.

### Worker team confirms:

- [ ] Drizzle migration `0009_chat_sync.sql` is applied on remote D1 (`pnpm exec wrangler d1 migrations apply rishi-sync --remote` shows 0009 in the applied list).
- [ ] Both routes are mounted in `workers/worker/src/index.ts` (`app.route("/api/sync/conversations", conversationsRoutes)` and `messages` likewise).
- [ ] All four endpoints sit behind `requireAuth` — unauth curl to each POST returns 401.
- [ ] Sentry breadcrumbs include `sync.conversations.*` and `sync.messages.*` for triage; sustained 500 rate alerts the on-call.

### iOS team confirms:

- [ ] `ConversationUploader` + `MessageUploader` tests in `apps/apple/Packages/RishiSync/Tests/RishiSyncTests/` are green (happy 200, 401 -> AuthError, 5xx leaves marker).
- [ ] `SyncEngine.runOnce` switch arms `.conversation` / `.message` route into the new uploaders (no more `metadataStore.forget(...)` short-circuit at SyncEngine.swift:198-203).
- [ ] `ConversationsListViewModel.refreshAfterSync` fires on inbound merge — `ChatSyncRefreshDelegate` is wired from `SyncEngine` per 16-05.
- [ ] Voice transcripts (`RishiVoice.VoiceTranscriptBridge`) sync end-to-end without code changes — the bridge already marks dirty.

### Support team confirms:

- [ ] Knows that a message can be "silently dropped" by the server if its parent conversation is owned by a different user — this is the documented cross-user isolation behavior (Section 6), NOT a sync bug.
- [ ] Runbook for "user signed in on Device B doesn't see chats from Device A" includes: confirm both devices are signed into the same Better Auth user (`GET /api/auth/get-session` returns the same `user.id` string); confirm Device A pushed at least once (`SELECT count(*) FROM conversations WHERE user_id = '<uid>'` on remote D1); ask user to background + foreground Device B to force a `SyncEngine.runOnce` cycle.

---

## /api/chat — Streaming Chat

Status: Live (deployed 2026-06-12, quick task 260612-f7p)
Source: `workers/worker/src/routes/chat.ts` mounted at `workers/worker/src/index.ts:218`.
iOS caller: `apps/apple/Packages/RishiChat/Sources/RishiChat/Service/ChatStreamEndpoint.swift`.

The four `/api/sync/*` routes above carry persisted chat history between devices. This route is the live LLM stream that PRODUCES new chat tokens. The two surfaces are intentionally separate: history sync is durable and idempotent, the LLM stream is ephemeral and one-shot.

### Method + Path

```
POST /api/chat
```

Auth: Better Auth session (Bearer token or `rishi.session_token` cookie). Active subscription required (`requireActiveSubscription` middleware — same gate as `/api/text/completions`).

### Request body

JSON, validated by zod at `workers/worker/src/routes/chat.ts:42-46`. Shape mirrors `apps/apple/Packages/RishiChat/Sources/RishiChat/Models/ChatRequest.swift` exactly:

```json
{
  "book_id": "11111111-2222-3333-4444-555555555555",
  "query": "What is the protagonist's name?"
}
```

| Field     | Type                   | Notes                                                                                                              |
| --------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `book_id` | UUID string (optional) | Lowercase canonical form (`/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/`). iOS encodes UUIDs lowercase; uppercased values surface as 400. Omit when the chat is not tied to a book. |
| `query`   | string (required)      | User prompt. Length 1..50000. Empty / over-cap rejected with 400 before the LLM call.                              |

### Response

`200 OK`. Headers:

```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

Body is a stream of SSE frames terminated by `\n\n`. Each frame body is single-line JSON that decodes as `ChatResponseChunk` (`apps/apple/Packages/RishiChat/Sources/RishiChat/Models/ChatResponseChunk.swift`):

```
data: {"delta":"Hello"}

data: {"delta":" world"}

data: {"done":true}

```

Recognised payload keys (all snake_case, matching iOS `CodingKeys`):

| Key         | Type          | Meaning                                                                                                                                  |
| ----------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `delta`     | string        | Next chunk of assistant text. Emitted once per non-empty token from the ai SDK `streamText` text stream.                                 |
| `tool_call` | string (JSON) | Opaque JSON-encoded tool invocation payload. Reserved; the v1 handler never emits this (no tools wired). Decoder tolerates it.            |
| `done`      | bool          | Terminal sentinel. Emitted exactly once at end-of-stream. iOS `SSEParser` also accepts the literal `data: [DONE]\n\n`; the worker emits `{"done":true}` for clarity. |

A delta frame, then more delta frames, then a single done frame — that is the only ordering the iOS decoder expects. The worker invokes OpenAI through `ai` SDK `streamText` against `openai.responses("gpt-5-nano")` with `providerOptions.openai.store = false`, mirroring `/api/text/completions`.

### Error codes

| Status | Body                                                                                                                       | When                                                                                                                                |
| ------ | -------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `401`  | `{ "error": "Unauthorized" }`                                                                                              | Missing / invalid Better Auth session. From `requireAuth` (`workers/worker/src/index.ts:188`).                                      |
| `402`  | `{ "error": "Active subscription required to use this feature", "code": "BILLING_INACTIVE", "subscriptionStatus": "..." }` | Authenticated but no active or trialing subscription. From `requireActiveSubscription` (`workers/worker/src/billing/sub-gate.ts`). |
| `400`  | `{ "error": "bad_request", "detail": "<zod error>" }`                                                                      | Body fails schema: missing/empty `query`, `query.length > 50000`, or non-lowercase-uuid `book_id`.                                  |

`401` is intentionally indistinguishable from "session expired" on the wire — iOS treats both as `AuthError.unauthenticated` and triggers a re-sign-in.

### Deferred (v1.1)

RAG, embeddings, and vector retrieval are NOT implemented in v1. `book_id` is forwarded to the model as a single system-message context hint:

```
The user is currently reading a book with ID <uuid>. Use this as context if relevant.
```

…and that is the entire effect of `book_id` on the prompt. No paragraph lookup, no `book_chunks` table, no semantic search. When embeddings infrastructure ships (own quick task / phase), this section will be revised to describe the retrieval pipeline. The request and response wire shapes documented above are stable across that change — only the server-side prompt construction will gain a retrieval step.

### Live smoke

```bash
# Unauthenticated -> 401 proves the route is mounted in production.
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://api.fidexa.org/api/chat \
  -H 'content-type: application/json' \
  -d '{}'
# expected: 401
```

Reference deployed version: `23209ea6-3446-4da8-93b6-b7b8cadc9864` (2026-06-12).

---

## 9.5. /api/sync/changes — Inbound Book + Highlight Pull

Status: Live (deployed 2026-06-12, version `df4d9cfe-8983-4e1f-a946-b5e88e7bce75`).
Related plan: quick-task `260612-g89`.

Closes the Phase-7 audit gap where `apps/apple/Packages/RishiSync/Sources/RishiSync/Inbound/RemoteChangeFetcher.swift` posted to a route the worker never shipped (live probe was 404). Before this section the call site fired on every sync tick and got HTTP 404 — every user re-installing the app or signing in on a fresh device pulled zero server-side state and saw an empty library. With this route mounted, iOS now pulls the caller's books + highlights back from D1 with zero iOS code changes (the endpoint, decoder, and caller all already shipped).

This is **separate** from the Phase 16 `/api/sync/conversations` and `/api/sync/messages` routes documented in Sections 3–7. Those are chat-only; `/api/sync/changes` is book + highlight only. They share the same `requireAuth` middleware and the same D1 database, but the wire shape is different (see §9.5.4 below).

### 9.5.1. Method + Path

```
GET /api/sync/changes[?since=<ISO8601>]
```

Source: `workers/worker/src/routes/changes.ts`.
Mount: `workers/worker/src/index.ts` — `app.route("/api/sync/changes", changesRoutes)` inserted BEFORE the broader `app.route("/api/sync", syncRoutes)` mount so the more-specific prefix wins regardless of Hono's match order.

### 9.5.2. Auth

Same `requireAuth` middleware as every other authenticated route in this contract (see Section 2). Bearer token OR session cookie; dev-bypass header honored in non-production builds. Unauthenticated -> `401 {"error":"Unauthorized"}`, no DB read.

### 9.5.3. Since cursor

Optional `?since=<ISO8601>` query parameter.

| Case                        | Behavior                                                                                                           |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Absent                      | Full-pull semantics: returns every non-tombstoned + every tombstoned row the user owns (subject to `PULL_LIMIT`).  |
| Valid ISO8601               | Server filters rows where `row.updated_at (ms) > Date.parse(since)`. Both strict and inclusive bounds documented in code. |
| Malformed                   | `400 {"error":"since must be a valid ISO8601 timestamp"}`. The parser is `Date.parse(rawSince)`; `Number.isNaN` triggers the 400. |

The comparison happens on the server-side `updated_at` column (ms-since-1970, the canonical SQLite shape). The cursor is `Date.parse(<iso>)` so iOS callers can pass any ISO8601 string the standard library produces.

### 9.5.4. Response envelope

```json
{
  "changes": [
    { "kind": "book",      "id": "<uuid>", "payload": { ... }, "updated_at": 825100800.0, "deleted": false },
    { "kind": "highlight", "id": "<uuid>", "payload": { ... }, "updated_at": 825100900.5, "deleted": false }
  ]
}
```

NO `syncVersion` field. NO `hasMore` field. The iOS decoder for this route is `SyncChangesResponse` at `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/SyncAPI.swift:212-216`; it expects exactly `{ changes: [SyncChange] }` and will fail-loud on any extra envelope keys via `JSONDecoder` strict matching. (Other routes in this contract DO emit `syncVersion` + `hasMore`; this one deliberately does not, because the iOS `SyncChange` model is a flat per-row envelope and the caller treats every batch as the full delta since the cursor.)

### 9.5.5. SyncChange shape

| key          | JSON type        | notes                                                                                                                                                                                                                                                       |
| ------------ | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kind`       | string           | `"book"` or `"highlight"` in v1. Future kinds (see §9.5.8) MAY appear; iOS treats unknown kinds as ignorable.                                                                                                                                                |
| `id`         | string (uuid)    | Row id of the book or highlight.                                                                                                                                                                                                                            |
| `payload`    | object           | For `kind="book"`: D1 row JSON MINUS `file_path` and `cover_path` (local-only paths stripped server-side, same rule as the `/api/sync/pull` handler at `workers/worker/src/routes/sync.ts:396-400`). For `kind="highlight"`: D1 row JSON with every column.   |
| `updated_at` | **number**       | Seconds since reference date 2001-01-01T00:00:00Z. **NOT** seconds-since-1970, **NOT** ms-epoch, **NOT** an ISO8601 string. See §9.5.6 for the rationale and conversion constant.                                                                            |
| `deleted`    | boolean          | `true` when `row.is_deleted = true`. Soft-deleted rows ARE included in the response so the iOS `ChangeApplier` can mirror tombstones; iOS-side `RemoteChangeFetcher` is the seam that converts tombstones into local deletions.                              |

### 9.5.6. Date format rationale (LOAD-BEARING)

`updated_at` is emitted as a JSON number equal to `(row.updated_at - 978_307_200_000) / 1000`.

Why: The iOS `WorkerClient` at `apps/apple/Packages/RishiAPI/Sources/RishiAPI/WorkerClient.swift:96` decodes every response through a bare `JSONDecoder()` with NO custom `dateDecodingStrategy`:

```swift
case 200..<300:
    do {
        return try JSONDecoder().decode(E.Response.self, from: data)
        // ^^ bare JSONDecoder() — NO custom dateDecodingStrategy.
        // For Date fields this means .deferredToDate ==
        // "JSON number = seconds since 2001-01-01T00:00:00Z (reference date)"
    } catch { ... }
```

For `Date` fields the default strategy is `.deferredToDate`, which reads the JSON value as `Double` and feeds it to `Date(timeIntervalSinceReferenceDate:)`. Apple's reference date is 2001-01-01T00:00:00Z = 978_307_200 unix seconds after the 1970 epoch. Confirmed by two existing in-tree assertions:

- `apps/apple/Packages/RishiSync/Tests/RishiSyncTests/SyncEngineTests.swift:309` — *"Date wire = seconds since reference date (2001-01-01) — matches default JSONDecoder."*
- `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/VerifyReceiptAPI.swift:22` — *"Default JSONDecoder() strategy (.deferredToDate) would otherwise misinterpret the number as seconds-since Apple's reference date (2001-01-01)."*

Rejected alternatives:

| Alternative                | Why rejected                                                                  |
| -------------------------- | ----------------------------------------------------------------------------- |
| Raw `row.updated_at` (ms-epoch)        | Decodes to year ~57220. Wrong.                                                |
| `row.updated_at / 1000` (seconds-since-1970) | Decodes to year ~2057 (off by exactly the 1970->2001 gap, 31 years). Wrong.   |
| ISO8601 string             | `.deferredToDate` decodes Date from a Double, not a String. Would throw at decode time. Wrong. |
| Change iOS `JSONDecoder` strategy | Out of scope: iOS code is locked, this route must conform to the existing decoder. |

Conversion constant in `workers/worker/src/routes/changes.ts`:

```typescript
const REFERENCE_DATE_OFFSET_MS = 978_307_200_000;
function toSecondsSinceRefDate(msEpoch: number): number {
  return (msEpoch - REFERENCE_DATE_OFFSET_MS) / 1000;
}
```

A row with `updated_at = 978_307_201_000` (1 second after the reference date in ms) wires as `1.0`. The vitest case `"updated_at encoded as seconds-since-reference-date (2001-01-01)"` in `changes.test.ts` is the load-bearing regression check for this rule.

### 9.5.7. Ordering

ASC by `row.updated_at`. Books and highlights are interleaved across the two kinds so the iOS `ChangeApplier` sees a stable, monotonically-increasing iteration order across the whole batch. This matches the `since-cursor + LWW` semantics every other route in this contract uses.

### 9.5.8. Kinds covered in v1

Covered:

- `"book"` — every row from the `books` table the caller owns (Drizzle column shape MINUS `file_path` + `cover_path`).
- `"highlight"` — every row from the `highlights` table the caller owns (every column passes through).

Deferred to v1.1 (not emitted by this route — see the kind-by-kind routing below):

| Future kind        | Where it actually rides today                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"position"`       | Inside the book payload via `current_cfi` / `current_page` / `last_progress_percent` columns. The iOS `ChangeApplier` projects these back into the position store. |
| `"conversation"`   | The Phase 16 route `/api/sync/conversations` handles this end-to-end (Section 3 above). NOT emitted by `/api/sync/changes`.                                    |
| `"message"`        | The Phase 16 route `/api/sync/messages` handles this end-to-end (Section 5 above). NOT emitted by `/api/sync/changes`.                                          |

Adding new kinds in v1.1 is additive: the iOS `SyncChange.kind` decoder treats unknown kinds as ignorable, so introducing `"bookmark"` or `"annotation"` later is non-breaking on the iOS side.

### 9.5.9. Error codes

| status | when                                                                                                |
| ------ | --------------------------------------------------------------------------------------------------- |
| 200    | Success — even when `changes: []`.                                                                  |
| 400    | Malformed `since` query parameter.                                                                  |
| 401    | No Better Auth session AND no dev-bypass header. The 401 happens BEFORE the `since` parser runs.    |

There is no 5xx-on-empty path: an unauthenticated user with a garbage cursor sees 401, not 400.

### 9.5.10. Example response

```json
{
  "changes": [
    {
      "kind": "book",
      "id": "11111111-1111-4111-8111-111111111111",
      "payload": {
        "id": "11111111-1111-4111-8111-111111111111",
        "userId": "user_alice",
        "title": "The Brothers Karamazov",
        "author": "Dostoevsky",
        "format": "epub",
        "currentCfi": "epubcfi(/6/4!/4/10/1:0)",
        "currentPage": null,
        "lastProgressPercent": 0.42,
        "fileHash": "sha256-abcd",
        "fileR2Key": "books/user_alice/11111111.epub",
        "coverR2Key": "covers/user_alice/11111111.jpg",
        "fileSize": 1872391,
        "createdAt": 1781193600000,
        "updatedAt": 1781193600000,
        "syncVersion": 3,
        "isDirty": false,
        "extractionStatus": "extracted",
        "extractedPages": 824,
        "totalPages": 824,
        "extractionError": null
      },
      "updated_at": 802886400.0,
      "deleted": false
    },
    {
      "kind": "highlight",
      "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "payload": {
        "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "bookId": "11111111-1111-4111-8111-111111111111",
        "userId": "user_alice",
        "cfiRange": "epubcfi(/6/4!/4/10/1:0,/4/10/1:48)",
        "text": "It's life that matters, nothing but life",
        "color": "yellow",
        "note": null,
        "chapter": "Book V — Pro and Contra",
        "createdAt": 1781193700000,
        "updatedAt": 1781193700000,
        "syncVersion": 1,
        "isDirty": false,
        "isDeleted": false
      },
      "updated_at": 802886500.0,
      "deleted": false
    }
  ]
}
```

Note: `payload.file_path` and `payload.cover_path` are absent from the book row above by design — they are local-only and must never overwrite the iOS-side paths. The `updated_at` value `802886400.0` is what `(1781193600000 - 978307200000) / 1000` produces; pasted verbatim so future engineers can verify the conversion without reaching for a calculator.

---

## Phase 17 — Reconciled Endpoints

**Status:** All eight endpoints below were reconciled in Phase 17 (Plans 17-01..17-09). Wire shapes match iOS expectations verbatim as of 2026-06-12. Deployed via `npx wrangler deploy --minify` from `workers/worker/` — the deployed version id is recorded in `apps/apple/.planning/phases/17-wire-contract-reconciliation-ios-worker-shape-gaps-has-pro-entitlement-projection/17-10-date-audit-deploy-smoke-SUMMARY.md`.

**Why this section exists:** a deep audit on 2026-06-12 found eight wire-contract gaps between iOS `Endpoint.path` literals and the deployed worker — paths matched, bodies/responses diverged. Phase 7/8/10/11 SUMMARYs had over-claimed completion because the iOS and worker halves were built independently and never reconciled. Phase 17 closes those gaps; this section documents the reconciled shapes so future agents (and future humans) can ship downstream features without redoing the audit.

**LOAD-BEARING date convention:** Every iOS-Date-decoded field on the wire is a JSON number representing `(msEpoch - 978_307_200_000) / 1000` — i.e. seconds since 2001-01-01T00:00:00Z. This matches `Date(timeIntervalSinceReferenceDate:)` so the bare `JSONDecoder()` at `apps/apple/Packages/RishiAPI/Sources/RishiAPI/WorkerClient.swift:96` (`.deferredToDate` strategy) round-trips cleanly. The static + behavioural regression guard is `workers/worker/src/date-wire-audit.test.ts` (Plan 17-10).

The Phase 16 `/api/sync/conversations` and `/api/sync/messages` routes (Sections 3 + 9.5) keep their pre-existing Int64 ms-epoch shape — they are decoded as `Int64`, NOT Swift `Date`, and are deliberately excluded from the Phase 17 sweep.

### P17.1 GET /api/auth/get-session (Plan 17-01)

**Auth:** Better Auth session (Bearer or cookie). Better Auth's documented behaviour for unauthenticated callers is `200 null` (no error envelope).
**Source:** `workers/worker/src/auth.ts` — `customSession` plugin block + `deriveHasPro({ userId, db })` helper.
**iOS caller:** `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift:75` (every signed-in launch).

Request: none — bare GET.

Response (authenticated):

```json
{
  "user":    { "id": "...", "email": "...", "name": "..." },
  "session": { "token": "...", "expiresAt": "..." },
  "has_pro": true
}
```

Response (unauthenticated): literal `null` with HTTP 200 (NOT 401 — Better Auth convention).

`has_pro` precedence: Apple `active|in_grace` > Stripe `active|trialing` > false. See `RUNBOOK-BILLING-WORKER.md` §1.6 for the operator-facing description and the drift-by-construction guarantee with `/api/billing/me`.

Date wire format: N/A — no Date fields. `session.expiresAt` is the Better Auth default (ISO8601 string decoded by iOS as String, not Date — Better Auth's own shape, locked).

Curl smoke:

```bash
curl -i https://api.fidexa.org/api/auth/get-session
# HTTP/1.1 200 OK
# null
```

### P17.2 POST /api/devices/register (Plan 17-02)

**Auth:** `requireAuth`. No active-subscription gate — APNs registration is a free-tier capability so silent-push sync works for free users.
**Source:** `workers/worker/src/routes/devices.ts`.
**iOS caller:** `apps/apple/Packages/RishiSync/Sources/RishiSync/Background/APNsDeviceRegistrar.swift`.

Request body (zod-validated):

```json
{
  "device_token": "<64-hex-chars APNs token>",
  "platform": "ios",
  "app_version": "1.0.0",
  "bundle_id": "org.fidexa.rishi",
  "topic": "org.fidexa.rishi"
}
```

Response (HTTP 200):

```json
{
  "device_id":     "<uuid>",
  "registered_at": 802886400.0
}
```

Date wire format: `registered_at` is a JSON number = `(msEpoch - 978_307_200_000) / 1000`. iOS `DevicesRegisterResponse.registeredAt: Date` decodes via `.deferredToDate`.

Idempotency: `onConflictDoUpdate` on `(userId, deviceToken)` — re-registration of the same token by the same user upserts in place, never throws a UNIQUE violation.

Curl smoke (unauth — proves route is mounted):

```bash
curl -i -X POST https://api.fidexa.org/api/devices/register \
  -H 'Content-Type: application/json' -d '{}'
# HTTP/1.1 401 Unauthorized
# {"error":"Unauthorized"}
```

### P17.3 POST /api/audio/speech (Plan 17-03)

**Auth:** `requireAuth` + `requireActiveSubscription` (TTS is a paid feature).
**Source:** `workers/worker/src/index.ts` — inline `app.post("/api/audio/speech", ...)` handler.
**iOS caller:** `apps/apple/Packages/RishiVoice/Sources/RishiVoice/TTS/TTSStreamer.swift:21`.

Request body:

```json
{
  "text":  "<utterance to synthesize>",
  "voice": "alloy",
  "speed": 1.0
}
```

| Field   | Type                           | Notes                                                                          |
| ------- | ------------------------------ | ------------------------------------------------------------------------------ |
| `text`  | string (1..4096)               | UTF-8 utterance. OpenAI imposes the upper bound; iOS chunks larger content.    |
| `voice` | string (OpenAI voice id)       | `alloy`, `echo`, `fable`, `onyx`, `nova`, `shimmer`. Validated against the OpenAI list. |
| `speed` | number (0.25..4.0)             | Passed straight to OpenAI's `speed` parameter. iOS default is `1.0`.            |

Response: streaming `audio/mpeg` (MP3 frames). Headers:

```
Content-Type: audio/mpeg
Transfer-Encoding: chunked
```

iOS streams the body straight into `AVAudioEngine` via `TTSStreamer` (no JSON decode — binary body).

Date wire format: N/A — binary audio response.

Curl smoke (unauth):

```bash
curl -i -X POST https://api.fidexa.org/api/audio/speech \
  -H 'Content-Type: application/json' -d '{}'
# HTTP/1.1 401 Unauthorized
```

### P17.4 POST /api/audio/transcribe (Plan 17-04)

**Auth:** `requireAuth` + `requireActiveSubscription` (STT is a paid feature).
**Source:** `workers/worker/src/index.ts` — inline `app.post("/api/audio/transcribe", ...)` handler.
**iOS caller:** `apps/apple/Packages/RishiVoice/Sources/RishiVoice/STT/SpeechTranscriber.swift`.

Request body — JSON with base64-encoded audio (v1 chosen over multipart for parity with iOS's `URLSession` JSON encoder; multipart deferred to v1.1):

```json
{
  "audio":     "<base64-encoded audio bytes>",
  "mime_type": "audio/wav"
}
```

| Field       | Type                  | Notes                                                                                                              |
| ----------- | --------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `audio`     | base64 string         | Caller MUST NOT include a `data:` prefix — raw base64 only. Decoded server-side via `atob`.                        |
| `mime_type` | string (audio MIME)   | Forwarded to OpenAI Whisper as the audio container hint. iOS sends `audio/wav` for the in-app recorder.            |

Response (HTTP 200):

```json
{
  "transcript": "Hello world."
}
```

Date wire format: N/A — no Date fields.

Curl smoke (unauth):

```bash
curl -i -X POST https://api.fidexa.org/api/audio/transcribe \
  -H 'Content-Type: application/json' -d '{}'
# HTTP/1.1 401 Unauthorized
```

### P17.5 GET /api/realtime/client_secrets (Plan 17-05)

**Auth:** `requireAuth` + `requireActiveSubscription` (voice chat is a paid feature).
**Source:** `workers/worker/src/index.ts` — inline `app.get("/api/realtime/client_secrets", ...)` handler.
**iOS caller:** `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Realtime/EphemeralKeyFetcher.swift:57`.

Request: none — bare GET. The handler internally mints an ephemeral OpenAI Realtime API session and projects the response.

Response (HTTP 200):

```json
{
  "client_secret": "ek_...",
  "session_id":    "sess_..."
}
```

The worker projects the raw OpenAI shape `{ "client_secret": { "value": "ek_..." }, "id": "sess_..." }` down to the flat iOS shape (`client_secret.value` -> `client_secret`, `id` -> `session_id`). Plan 17-05 GREEN commit.

Date wire format: N/A — no Date fields. Ephemeral key TTL is enforced server-side and not surfaced to iOS in v1.

Curl smoke (unauth):

```bash
curl -i https://api.fidexa.org/api/realtime/client_secrets
# HTTP/1.1 401 Unauthorized
```

### P17.6 POST /api/sync/push (Plan 17-07)

**Auth:** `requireAuth`.
**Source:** `workers/worker/src/routes/sync.ts` — `syncRoutes.post("/push", ...)`.
**iOS callers:** `HighlightUploader.swift:73`, `PositionUploader.swift:79`, `ConversationUploader.swift`, `MessageUploader.swift` (via the same shared `SyncPushEndpoint`).

Request body — flat array of typed `SyncChange` rows (matches `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/SyncAPI.swift:89`):

```json
{
  "changes": [
    {
      "kind":       "highlight",
      "id":         "<uuid>",
      "payload":    { "...": "opaque per-kind JSON" },
      "updated_at": 802886400.0,
      "deleted":    false
    }
  ]
}
```

| Field        | Type                                                                  | Notes                                                                                                |
| ------------ | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `kind`       | enum `"book" \| "position" \| "highlight" \| "conversation" \| "message"` | Per-kind dispatch — see `sync.ts` for the table mapping and per-kind LWW rules.                       |
| `id`         | string                                                                | Row primary key. Per-kind authoritative shape — usually a UUID.                                       |
| `payload`    | opaque JSON object                                                    | Snake_case `WirePayloads` from `SyncPayloadCodec.swift`. For `book`, `file_url` + `cover_path` are STRIPPED server-side (local-only paths). |
| `updated_at` | number (seconds-since-2001)                                           | LWW key. Server passes through unchanged into the high-water-mark response.                          |
| `deleted`    | boolean                                                               | Soft-delete tombstone flag.                                                                          |

Array length: 0..5000.

Response (HTTP 200):

```json
{
  "accepted_at": 802886400.0
}
```

`accepted_at` = `max(updated_at)` across all changes in the batch. It is the high-water-mark cursor iOS persists into `sync_metadata.last_synced_at` so the next push has a known starting point. Already in seconds-since-2001 — pass-through, no conversion needed.

Date wire format: both `updated_at` (request) and `accepted_at` (response) are JSON numbers in seconds-since-2001. The Phase 16 conversations + messages routes use a DIFFERENT envelope (`{ conversations: [...] }` + `{ messages: [...] }` with ms-epoch `updated_at`); `POST /api/sync/push` is the per-kind dispatcher for the typed `SyncChange` shape and is the iOS-Date-decoded route. See § P17.6.3 below for the dispatch rules.

Curl smoke (unauth):

```bash
curl -i -X POST https://api.fidexa.org/api/sync/push \
  -H 'Content-Type: application/json' -d '{}'
# HTTP/1.1 401 Unauthorized
```

### P17.7 POST /api/sync/upload-url (Plan 17-08)

**Auth:** `requireAuth` + `requireActiveSubscription` (book sync is a paid feature).
**Source:** `workers/worker/src/routes/upload.ts` — `uploadRoutes.post("/upload-url", ...)`.
**iOS caller:** `apps/apple/Packages/RishiSync/Sources/RishiSync/Upload/BookUploader.swift:54`.

Request body:

```json
{
  "key":          "books/<user_id>/<book_id>.epub",
  "content_type": "application/epub+zip"
}
```

| Field          | Type                                       | Notes                                                                                                 |
| -------------- | ------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `key`          | string (`books/<userId>/<bookId>.<ext>`)   | Server validates the prefix matches the caller's userId — cross-user key writes return 403.            |
| `content_type` | string (MIME)                              | Echoed back into the R2 presigned PUT signature. iOS sends `application/epub+zip` or `application/pdf`. |

Response (HTTP 200):

```json
{
  "url":        "https://<r2-account>.r2.cloudflarestorage.com/...?X-Amz-...",
  "expires_at": 802886700.0
}
```

`expires_at` = `(Date.now() + 300_000 - 978_307_200_000) / 1000`. The presigned URL is valid for 5 minutes from issue; the `X-Amz-Expires=300` query parameter inside `url` matches.

Date wire format: `expires_at` is a JSON number in seconds-since-2001. iOS `PresignedURLResponse.expiresAt: Date` decodes via `.deferredToDate`.

The legacy keys `uploadUrl`, `r2Key`, `expiresIn`, `exists` are NO LONGER emitted — Plan 17-08 reconciled the response to match iOS verbatim.

Curl smoke (unauth):

```bash
curl -i -X POST https://api.fidexa.org/api/sync/upload-url \
  -H 'Content-Type: application/json' -d '{}'
# HTTP/1.1 401 Unauthorized
```

### P17.8 POST /api/sync/download-url (Plan 17-09)

**Auth:** `requireAuth` + `requireActiveSubscription` (book sync is a paid feature).
**Source:** `workers/worker/src/routes/upload.ts` — `uploadRoutes.post("/download-url", ...)`.
**iOS caller:** `apps/apple/Packages/RishiSync/Sources/RishiSync/Download/BookDownloader.swift`.

Request body:

```json
{
  "key": "books/<user_id>/<book_id>.epub"
}
```

Server validates the prefix matches the caller's userId — cross-user key reads return 403.

Response (HTTP 200):

```json
{
  "url":        "https://<r2-account>.r2.cloudflarestorage.com/...?X-Amz-...",
  "expires_at": 802887000.0
}
```

`expires_at` = `(Date.now() + 600_000 - 978_307_200_000) / 1000`. The presigned URL is valid for 10 minutes from issue; the `X-Amz-Expires=600` query parameter inside `url` matches.

Date wire format: `expires_at` is a JSON number in seconds-since-2001. iOS `PresignedURLResponse.expiresAt: Date` decodes via `.deferredToDate`.

The legacy keys `downloadUrl`, `expiresIn` are NO LONGER emitted — Plan 17-09 reconciled the response to match iOS verbatim.

Curl smoke (unauth):

```bash
curl -i -X POST https://api.fidexa.org/api/sync/download-url \
  -H 'Content-Type: application/json' -d '{}'
# HTTP/1.1 401 Unauthorized
```

### P17.9 has_pro — operator hand-off to Billing runbook

For the `has_pro` projection lifecycle (precedence, drift-by-construction guarantee with `/api/billing/me`, operator troubleshooting), see `RUNBOOK-BILLING-WORKER.md` §1.6. That doc is the authoritative operator reference; this contract doc only documents the wire shape.

---

## 10. References

- `16-CONTEXT.md` — Phase 16 locked decisions (this doc's source of authority).
- `16-01-SUMMARY.md` — D1 schema + migration 0009.
- `16-02-SUMMARY.md` — `RishiAPI` endpoints (`ConversationsSyncEndpoint`, `MessagesSyncEndpoint`).
- `16-03-SUMMARY.md` — worker routes + vitest coverage.
- `16-04-SUMMARY.md` — iOS `ConversationUploader` + `MessageUploader` + `SyncEngine` switch arms.
- `16-05-SUMMARY.md` — iOS inbound fetchers + UI refresh delegate.
- `workers/worker/src/routes/conversations.ts` — POST + GET conversations handlers.
- `workers/worker/src/routes/messages.ts` — POST + GET messages handlers.
- `workers/worker/drizzle/migrations/0009_chat_sync.sql` — the canonical schema.
- `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/ConversationsSyncEndpoint.swift` — iOS wire shape Codable definitions.
- `apps/apple/Packages/RishiSync/Sources/RishiSync/Engine/SyncEngine.swift` — the dispatch loop that calls the uploaders.
- `apps/apple/Packages/RishiSync/Sources/RishiSync/Engine/ConversationUploader.swift` — outbound POST + `metadataStore.forget` on 200.
- `apps/apple/Packages/RishiSync/Sources/RishiSync/Engine/MessageUploader.swift` — same pattern for messages.

---

*Phase: 16-conversation-and-message-r2-sync-chat-voice-transcripts-cross-device / Plan: 06 / Owner: matovu90@gmail.com / Last reviewed: 2026-06-12*
