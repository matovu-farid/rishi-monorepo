# Cross-Platform Book Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven development to implement this plan task-by-task.

**Goal:** Make EPUB and PDF imports and reading progress synchronize between iOS and Mac Catalyst through the authenticated user's D1/R2 data.

**Architecture:** Keep SwiftData as the offline local cache. Add an explicit book-metadata push beside the existing R2 byte upload, normalize the worker's pull/push wire DTOs, and add a download/materialization collaborator for inbound books. Route both EPUB and PDF position changes through the existing debounced position sync.

**Tech Stack:** Swift, SwiftData, existing RishiSync/RishiCore protocols, Cloudflare Worker, Hono, Drizzle D1, Bun/Vitest.

---

### Task 1: Worker wire contract

**Files:** `workers/worker/src/routes/sync.ts`, `workers/worker/src/routes/changes.ts`, related `sync-push.test.ts`/`changes.test.ts`.

- Add failing tests for normalized snake_case book payloads, server-side book creation from a position, and user-scoped updates.
- Run the focused Bun/Vitest tests and confirm the expected failures.
- Implement shared mapping helpers and make book and position writes upsert-safe with Drizzle.
- Emit the latest position fields in the normalized book pull payload and preserve R2 key metadata without local paths.
- Re-run focused tests.

### Task 2: Apple metadata and inbound file sync

**Files:** `BookUploader.swift`, `SyncPayloadCodec.swift`, `ChangeApplier.swift`, new downloader/materializer under `RishiSync`, `ServiceGraphFactory.swift`, Apple sync tests.

- Add failing tests proving import emits a `book` metadata change, inbound snake_case payloads decode, and a pulled EPUB/PDF is downloaded into local storage.
- Implement metadata push and an authenticated R2 download/materialization path using the existing endpoint and book key convention.
- Apply inbound metadata only after the file is available; keep failed items dirty/retryable.
- Re-run the focused Apple sync tests.

### Task 3: EPUB and PDF progress

**Files:** `PDFReaderViewModel.swift` or a shared position-sync adapter, `ReaderPositionSyncBinding.swift`, Apple reader tests.

- Add a failing PDF test that a persisted position also invokes `markPositionDirty`.
- Wire PDF changes through the existing debouncer and flush on reader close/background.
- Verify EPUB behavior remains unchanged and both formats use the same position payload.

### Task 4: Account isolation and lifecycle

**Files:** sync metadata store/bootstrap, sign-out/current-user lifecycle, local stores/tests.

- Add failing tests for switching users with an existing cursor and local cache.
- Partition or clear sync metadata and user-owned cached records on account transition, without deleting unrelated user data accidentally.
- Re-run account lifecycle tests.

### Task 5: Review, verification, deployment

- Run an independent adversarial review against the updated code and fix all Critical/High findings.
- Run Bun worker tests and Apple focused tests/build.
- Run `wrangler deploy` from `workers/worker` after verifying the production config and report the deployment result.

## Consumer / call-site audit

| Behavior | Consumers |
|---|---|
| Imported book dirty mark | `ImportCoordinator`, `ServiceGraphFactory`, `SyncEngine`, `OutboundDrainer` |
| Book wire payload | `SyncPayloadCodec`, `BookUploader`, worker `/api/sync/push`, `/api/sync/changes` |
| Inbound file materialization | `ChangeApplier`, `BookFileStorage`, library readers/prewarmer |
| Position dirty mark | EPUB reader binding, PDF reader view model, background flush |
| Account lifecycle | auth sign-out/current-user state, sync metadata store, SwiftData stores |

## Adversarial review loop

### Round 1 — Research review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | Import uploads R2 bytes but no D1 book metadata. | Task 2 adds explicit metadata push before clean state. |
| 2 | Critical | Worker pull fields do not match `WireBook`. | Task 1 adds normalized snake_case mapping and tests. |
| 3 | Critical | No inbound R2 download/materialization exists. | Task 2 adds downloader and retry semantics. |
| 4 | High | PDF positions are only locally persisted. | Task 3 adds PDF dirty-marking. |
| 5 | High | Position push updates zero rows when metadata is absent. | Task 1 makes position writes upsert-safe. |
| 6 | High | Account switching can reuse cursors/local state. | Task 4 adds lifecycle isolation. |

**Round 1 result:** Re-review required during implementation; all findings have assigned code and test coverage.

### Round 2 — Implemented-code re-review

The independent implementation review found four issues: account-switch queue
isolation, inbound progress LWW, single-cursor pagination safety, and arbitrary
R2 keys. The implementation added account-generation invalidation plus an
active-account guard at the inbound apply boundary, local progress LWW checks,
a bounded safe cursor cutoff, and authenticated-user/book-scoped R2 key
validation. A second review then found that boundary rows must be included to
allow the legacy timestamp cursor to advance, and that metadata-only books
must not trigger a guessed R2 download. Both were fixed and the worker was
redeployed.

**Round 2 result:** no open Critical/High findings in the reviewed paths.

## Explicitly out of scope

- Syncing extracted text/index files; those are regenerated locally after book materialization.
- Syncing reader preferences or audio caches.
- Changing authentication providers or database technology.
