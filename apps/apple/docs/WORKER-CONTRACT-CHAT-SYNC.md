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
