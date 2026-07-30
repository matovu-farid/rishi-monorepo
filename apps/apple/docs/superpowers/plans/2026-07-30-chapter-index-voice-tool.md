# Chapter Index Voice Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Apple-owned `chapterIndex` voice tool that generates chapter summaries with an on-device model when available, falls back to an authenticated OpenAI proxy, persists results in SwiftData, and synchronizes completed indexes to the Worker for durable backup.

**Architecture:** Apple derives stable chapter records and full chapter text from its local book reader, then coordinates one generation task per `bookID + contentVersion`. A `ChapterSummarizer` abstraction selects the local model or OpenAI proxy; generation is persisted as an explicit SwiftData state machine and awaited by concurrent tool calls. The Worker receives the completed aggregate through a dedicated `chapter_index` sync change, persists it in first-class D1 tables, and returns it in pull changes.

**Tech Stack:** Swift 6, SwiftData, Readium, PDFKit, existing Apple realtime responder, Swift sync engine, TypeScript/Hono, Drizzle ORM, Cloudflare D1, Bun/Wrangler.

---

## Scope and data contract

- `chapterIndex` has no arguments and returns `{status, bookId, contentVersion, chapters:[{id,name,summary}]}`.
- `status` is `ready`, `building`, `unavailable`, or `failed`; a tool call waits on an existing/new generation task only until the existing voice timeout, then returns `building`.
- Chapter summaries are factual and concise; long chapters use section summaries followed by a final merge, never the top-three `bookContext` result set.
- `contentVersion` is a deterministic hash/version of the local book content plus the chapter-extraction algorithm version. It prevents stale summaries after replacement or parser changes.
- The Worker backup is a dedicated `chapter_index` sync change, first-class and idempotent. It is not stored as an assistant message and does not require a conversation.

## Files to create or modify

Apple:

- Create `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/ChapterIndex/ChapterIndexModels.swift` for Sendable domain/wire values and generation status.
- Create `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/ChapterIndex/ChapterSource.swift` for the format-neutral chapter extraction protocol and adapters.
- Create `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/ChapterIndex/ChapterSummarizer.swift` for provider selection and local/OpenAI implementations.
- Create `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/ChapterIndex/ChapterIndexCoordinator.swift` for actor-isolated single-flight generation, timeout-safe reads, and persistence orchestration.
- Modify `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/BookContextResponder.swift` to dispatch `chapterIndex` and return structured status/error payloads.
- Modify `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Service/RealtimeVoiceSession.swift` and `apps/apple/rishi/rishi/Voice/VoiceSessionPresenter.swift` to inject the coordinator without changing existing tool behavior.
- Modify `apps/apple/rishi/rishi/Modules/RishiReader/RishiReader/EPUB/PublicationLoader.swift`, `EPUBReadAloudCursor.swift`, and PDF reader/outline files only where needed to expose chapter source adapters; do not duplicate parsing logic.
- Modify `apps/apple/rishi/rishi/Modules/RishiDB/RishiDB/Persistence/Models.swift`, `RishiDB.swift`, `Book.swift`, and `SwiftDataBookStore.swift` for persisted index state and summaries.
- Modify `apps/apple/rishi/rishi/Modules/RishiSync/RishiSync/Inbound/SyncPayloadCodec.swift`, `BookUploader.swift`, `ChangeApplier.swift`, and `SyncEntityKind.swift` for forward-compatible book payload sync.
- Add focused Apple tests under `apps/apple/rishi/rishiTests/PackageTests/RishiVoice`, `RishiDB`, and `RishiSync`.

Worker:

- Create `workers/worker/src/db/migrations/` only if the repository’s existing Drizzle layout requires it; otherwise add the next numbered migration under `workers/worker/drizzle/migrations/` and update `meta/_journal.json` through Drizzle tooling.
- Modify `workers/worker/src/db/schema.ts`, `routes/sync.ts`, `routes/changes.ts`, and `src/index.ts` only for the chapter-index sync contract.
- Add Worker route tests in `workers/worker/src/routes/sync-push.test.ts` and `workers/worker/src/routes/sync-changes.test.ts` or the repository’s existing changes-test location.
- Modify shared/Worker voice contracts in `packages/shared/src/voice-chat/build-realtime-agent.ts` and its tests to advertise `chapterIndex`.

---

### Task 1: Lock the shared voice contract with failing tests

**Files:**
- Test: `packages/shared/src/voice-chat/build-realtime-agent.test.ts`
- Test: `workers/worker/src/realtime-client-secrets.test.ts`
- Modify: `packages/shared/src/voice-chat/build-realtime-agent.ts`
- Modify: `workers/worker/src/realtime/client-secrets.ts`

- [ ] Add a test asserting the `chapterIndex` function has an empty object schema and describes a complete cached chapter index, not a search query.
- [ ] Run the focused Bun/Vitest tests and verify they fail because `chapterIndex` is absent.
- [ ] Add the shared spec and include it in the Worker’s `session.tools` list with `tool_choice: "auto"`.
- [ ] Re-run the focused tests and confirm both shared-spec and Worker-session assertions pass.

### Task 2: Add the Apple chapter source abstraction

**Files:**
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/ChapterIndex/ChapterSourceTests.swift`
- Create/modify: the chapter-index source files listed above plus the minimal Readium/PDF adapters.

- [ ] Write tests for stable IDs, ordered chapter names, EPUB resource text, PDF outline page ranges, and an explicit fallback for outline-less PDFs.
- [ ] Run the focused Apple test target and verify the new tests fail for missing source types.
- [ ] Implement `ChapterSource` as an async Sendable boundary returning `ChapterSourceRecord { id, name, locator, text }`.
- [ ] Reuse Readium `readingOrder`/TOC and existing XHTML reading for EPUB; reuse PDF outline destinations and existing paragraph extraction for PDF.
- [ ] Keep extraction on background tasks and return an unavailable/empty result when no chapter structure exists rather than inventing chapter names.
- [ ] Re-run source tests and confirm they pass.

### Task 3: Add model providers and fallback policy

**Files:**
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/ChapterIndex/ChapterSummarizerTests.swift`
- Create: `ChapterSummarizer.swift` and provider-specific support files.
- Modify: existing authenticated Worker API client only where an OpenAI proxy request is missing.

- [ ] Write tests for local-provider selection, fallback when the local model is unavailable, fallback after local failure, deterministic prompt shape, and structured summary decoding.
- [ ] Run tests and verify the provider abstraction is missing.
- [ ] Define `ChapterSummarizer` with `summarize(chapter:)` and `merge(sectionSummaries:)` methods returning the same domain type for both providers.
- [ ] Use the Apple local-model availability API behind an injected adapter so tests do not depend on a device model.
- [ ] Route OpenAI fallback through an authenticated Worker endpoint using the existing bearer-token and AI-data-consent conventions; never embed a permanent OpenAI key in Apple.
- [ ] Use `store: false` on the Worker OpenAI request and preserve the existing request size limits by batching chapter sections.
- [ ] Re-run tests and confirm all provider-selection cases pass.

### Task 4: Add SwiftData persistence and the single-flight coordinator

**Files:**
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiDB/RishiDBTests/ChapterIndexPersistenceTests.swift`
- Test: `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/ChapterIndexCoordinatorTests.swift`
- Modify: `Book.swift`, `Models.swift`, `RishiDB.swift`, `SwiftDataBookStore.swift`
- Create: `ChapterIndexCoordinator.swift`, `ChapterIndexModels.swift`

- [ ] Write persistence tests for legacy books without an index, ready indexes, failed indexes, content-version replacement, and round-trip of all chapter summaries.
- [ ] Write coordinator tests proving concurrent callers share one generation task, an existing ready index avoids generation, missing indexes start generation, and timeout returns `building` without cancelling the background task.
- [ ] Run tests and confirm the new persistence/coordinator behavior fails.
- [ ] Add a parent index record and child summary records to the SwiftData model registry; keep summaries separate from the main `Book` value if that avoids oversized book sync payloads, but expose them through a stable book-index value.
- [ ] Add an explicit SwiftData migration plan or a safe versioned-container migration before shipping the new models; verify an existing store reopens.
- [ ] Implement an actor keyed by `bookID + contentVersion` with an atomic persisted transition `notStarted → building` and one in-memory task per key.
- [ ] Persist partial progress and terminal errors, but only mark `ready` after every chapter summary is saved.
- [ ] Schedule generation after normal text indexing and from a `BGProcessingTask`; keep lazy creation from the voice tool as a fallback.
- [ ] Re-run persistence and coordinator tests until green.

### Task 5: Wire `chapterIndex` into Apple voice chat

**Files:**
- Tests: `BookContextResponderTests.swift`, `BookContextResponderCancellationTests.swift`, `RealtimeVoiceSessionBookContextTests.swift`
- Modify: `BookContextResponder.swift`, `RealtimeVoiceSession.swift`, `VoiceSessionPresenter.swift`

- [ ] Add failing tests for ready response, building response after timeout, failed/unavailable response, unknown-tool behavior, and cancellation-before-send.
- [ ] Run the focused tests and verify the new tool dispatch fails.
- [ ] Decode `{}` arguments, call the coordinator, encode bounded JSON, and preserve the existing `sendToolResult` and response-creation path.
- [ ] Inject the coordinator through the current responder factory; do not introduce a second realtime event stream or alter existing `bookContext`/`currentPageContext` semantics.
- [ ] Re-run voice tests and confirm the full responder suite passes.

### Task 6: Add first-class Worker backup and pull sync

**Files:**
- Test: `workers/worker/src/routes/sync-push.test.ts`
- Test: `workers/worker/src/routes/sync-changes.test.ts` (or existing equivalent)
- Modify: `workers/worker/src/db/schema.ts`, `workers/worker/src/routes/sync.ts`, `workers/worker/src/routes/changes.ts`, Apple sync codec/uploader/applier files.

- [ ] Add failing Worker tests for authenticated chapter-index insert, idempotent retry, LWW/content-version replacement, ownership enforcement, and pull projection. Add Apple tests for encode/decode and legacy payload compatibility.
- [ ] Generate and inspect a Drizzle migration that adds a `book_chapter_indexes` parent and `book_chapter_summaries` child table (or the repository-approved equivalent), with unique `(user_id, book_id, content_version, chapter_id)` and updated timestamps.
- [ ] Run tests and confirm schema/route support is absent.
- [ ] Add the tables using Drizzle only; do not hand-write SQL in application/test code.
- [ ] Add a dedicated `chapter_index` sync kind and preserve legacy `.book` sync decoding. The payload carries the complete versioned index and is independently LWW/idempotent.
- [ ] Validate authenticated user ownership and AI-data consent, enforce bounded chapter count/summary size, and make retries idempotent by content version/chapter ID.
- [ ] Add pull support so another Apple device can restore the index into SwiftData.
- [ ] Re-run Worker and Apple sync tests until green.

### Task 7: Background scheduling and end-to-end verification

**Files:**
- Modify: `BackgroundTaskCoordinator.swift`, `BackgroundSyncLifecycle.swift`, `rishiApp.swift`, and service-graph wiring.
- Tests: background scheduling/coordinator tests and one end-to-end Apple sync contract test.

- [ ] Add a failing test proving a completed local chapter index is enqueued for sync and a pulled remote index is applied without replacing newer local content.
- [ ] Implement scheduling using the existing background-task framework; keep generation resumable and idempotent after process termination.
- [ ] Verify the complete path: voice tool → local coordinator → local/OpenAI provider → SwiftData → outbound sync → Worker D1 → pull changes → SwiftData.
- [ ] Run the Apple focused tests, Worker Bun tests, and Apple build.
- [ ] Apply the D1 migration explicitly against the correct database configured in `workers/worker/wrangler.jsonc`; resolve any `rishi`/`rishi-sync` mismatch before deployment.
- [ ] Deploy from `workers/worker` with `bun run deploy` and verify the deployed Worker’s health/route response.

---

## Adversarial review

Before implementation advances past each task group, independently check:

- **Critical:** no permanent OpenAI key in Apple; no duplicate generation task; no SwiftData store loss; no unowned cross-user sync writes; no raw SQL in Worker application/test code.
- **High:** tool contract exists in shared spec and Worker session; `chapterIndex` is actually dispatched by Apple; local fallback failure reaches OpenAI; content versions prevent stale summaries; D1 migration is journaled and applied; pull sync restores summaries.
- **Medium:** timeout returns a valid structured result; partial progress survives relaunch; oversized chapters are batched; PDF/EPUB IDs are stable.

Each review must log findings in the plan/task notes, close Critical/High findings, and re-review the changed artifact before proceeding.

## Verification checklist

- [ ] Focused Apple chapter-source/provider/coordinator/responder tests pass.
- [ ] SwiftData legacy-store reopen/migration test passes.
- [ ] Apple sync encode/decode, upload, pull, and conflict tests pass.
- [ ] Worker sync route and migration tests pass with Bun.
- [ ] Apple app build succeeds.
- [ ] D1 migration is explicitly applied to the configured database.
- [ ] `bun run deploy` succeeds from `workers/worker`.
- [ ] Deployed Worker health and authenticated sync contract are verified.
