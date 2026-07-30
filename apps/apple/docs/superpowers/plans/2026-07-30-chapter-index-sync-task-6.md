# Chapter Index Sync Task 6 Implementation Plan

> **Status:** Adversarial review loop complete — **PASS** (2 rounds, 0 open Critical/High issues)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add atomic `chapter_index` push/pull sync for ordered chapter summaries, normalized into Worker D1 parent/child rows and applied through the existing Apple SwiftData chapter-index store.

**Architecture:** The wire envelope remains one `SyncChange` with `kind: "chapter_index"`, `id` equal to the book ID, and a bounded payload containing the complete index/version and ordered `chapters` array. The Worker owns authenticated user scope and replaces the child set only when the envelope timestamp is newer; Apple queues one chapter-index entity and uses the existing `ChapterIndexPersistence` store for inbound/outbound materialization.

**Tech Stack:** Bun/Vitest, Hono, Drizzle ORM, Cloudflare D1, Swift 6, SwiftData, existing RishiSync engine.

---

## File map

Worker: `src/db/schema.ts`, generated `drizzle/migrations/0004_*.sql` plus Drizzle metadata, `src/routes/sync.ts`, `src/routes/changes.ts`, `src/routes/sync-push.test.ts`, and `src/routes/changes.test.ts`.

Apple: `SyncEntityKind.swift`, `SyncPayloadCodec.swift`, `ChapterIndexUploader.swift`, `OutboundDrainer.swift`, `ChangeApplier.swift`, `SyncEngine.swift`, `SyncAPI.swift`, and focused codec/uploader/applier tests. Existing `ChapterIndexEntity`, `ChapterSummaryEntity`, and `SwiftDataBookStore` remain the persistence boundary; no new SwiftData schema is needed.

## Wire contract

```json
{
  "kind": "chapter_index",
  "id": "book-uuid",
  "updated_at": 123.0,
  "deleted": false,
  "payload": {
    "id": "index-uuid",
    "book_id": "book-uuid",
    "content_version": "content-v1",
    "status": "ready",
    "model_identifier": "model",
    "model_version": "1",
    "progress": {"completed": 2, "total": 2},
    "error_message": null,
    "created_at": "2026-07-30T00:00:00Z",
    "updated_at": "2026-07-30T00:00:01Z",
    "chapters": [
      {"id": "c1", "name": "One", "summary": "...", "source_position": 0}
    ]
  }
}
```

`source_position` is required on new outbound payloads but decodes as `0` when absent for backward compatibility. The server limits one envelope to 500 chapters, 8 KiB per name, 32 KiB per summary, 256 bytes for IDs/versions, and 2 MiB for the serialized payload. The server validates `payload.book_id` against `change.id`, derives `user_id` from the bearer session, rejects another user's book/index, and requires the existing AI consent middleware.

## Task 1: Worker RED tests and schema contract

- [ ] Add mocked schema columns/stores and failing tests for insert, retry, ownership rejection, older LWW, newer content-version replacement, duplicate chapter IDs, bounds, and ordered pull projection.
- [ ] Run `bun test src/routes/sync-push.test.ts src/routes/changes.test.ts`; confirm failures are due to the missing kind/table.
- [ ] Add `chapterIndexes` and `chapterIndexChapters` Drizzle tables with parent key `(user_id, book_id, content_version)`, child key `(user_id, book_id, content_version, chapter_id)`, source position/order, model/status/progress metadata, timestamps, and indexes for `(user_id, updated_at)`.
- [ ] Generate the next migration with Bun Drizzle tooling, inspect the SQL, and update only generated migration metadata; do not hand-write SQL in application or tests.

## Task 2: Worker push/pull implementation

- [ ] Extend the push Zod enum with `chapter_index` and validate payload shape, bounded counts/sizes, integer non-negative positions, and unique chapter IDs.
- [ ] Implement parent ownership lookup and child replacement with sequential Drizzle statements because D1 does not support interactive transactions. Ignore equal/older envelopes; newer envelopes update parent metadata and delete/reinsert only that version's children.
- [ ] Extend `/api/sync/changes` to query chapter indexes by authenticated user and `since`, join children by version, order children by `source_position ASC`, and emit one envelope per parent. Preserve the existing safe cutoff across all kinds.
- [ ] Re-run Worker tests and type-check with `bun run type-check`.

## Task 3: Apple codec and outbound path

- [ ] Add failing codec tests for full encode/decode, source-position/order round-trip, optional error/progress fields, and old book payloads without chapter-index fields.
- [ ] Add `.chapterIndex`, wire snake_case `ChapterIndex` DTOs in `SyncPayloadCodec`, and preserve `ChapterIndex` identity/version/timestamps.
- [ ] Add `ChapterIndexUploader` using `ChapterIndexPersistence`, one atomic change per index, consent-gated existing client path, and mark-clean/forget behavior.
- [ ] Add the uploader to `OutboundDrainer` and `SyncEngine.Dependencies`; add `markChapterIndexDirty(_:)` with the coordinator's index ID and retain existing kind behavior.
- [ ] Run the focused Swift sync tests and fix compile/test failures before proceeding.

## Task 4: Apple inbound apply and final verification

- [ ] Add failing `ChangeApplier` tests for remote insert, stale local preservation, content-version coexistence/replacement, and source-position order.
- [ ] Inject `ChapterIndexPersistence` into `ChangeApplier`, decode `chapter_index`, compare `updatedAt` for LWW, upsert through `SwiftDataBookStore`, and mark the index clean without echoing it.
- [ ] Update `SyncChange` documentation/accepted kinds only; keep unknown-kind and old-book optional-field behavior unchanged.
- [ ] Run focused Bun tests, `bun run type-check`, focused Swift package tests, and the Apple build. Do not deploy or apply D1 remotely.

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Research review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | Existing Apple chapter-index persistence is already present; adding a second model/store would conflict with current voice changes. | Reuse `ChapterIndexPersistence`, `ChapterIndexEntity`, `ChapterSummaryEntity`, and `SwiftDataBookStore`; limit Apple work to sync codec/queue/applier. |
| 2 | High | D1 interactive transactions are unsupported in the existing sync route. | Plan sequential idempotent Drizzle statements and define replacement ordering/tests explicitly. |
| 3 | High | A single global timestamp cursor can skip rows when one type is truncated. | Include chapter indexes in the existing safe-cutoff calculation and preserve one envelope per parent. |
| 4 | Medium | The existing task-6 plan includes deployment, contrary to this request. | Explicitly make deployment and remote migration out of scope; verification is local only. |

**Round 1 result:** Re-review required; plan updated.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | Apple queue items are UUID-based while the chapter index has a distinct UUID from its book. | Use the index entity ID for the queue and envelope `id` as book ID only within the payload contract; uploader resolves by index ID. |
| 2 | Low | Legacy payloads may omit `source_position`. | Decode missing positions as `0`; server requires/validates new values. |

**Round 2 result:** PASS — 0 open Critical/High issues.

## Explicitly out of scope

- Voice generation, chapter extraction, model-provider behavior, ledger changes, and unrelated Apple voice files.
- Remote D1 migration execution, Worker deployment, or production verification.
- Reworking the existing timestamp cursor into a numeric page cursor.
