---
id: B001
spec: e2e/azw3-parity.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`useBookSyncId` (shared by EPUB / MOBI / AZW3 readers) fetches `booksGetSyncId(bookId)` exactly once on mount and stores the result in `bookSyncIdRef.current`. If the book row is imported without a syncId and opened in the same session (the syncId is assigned later by background sync), the ref stays `null` forever for that reader window. `Azw3View`'s bookmark handler at `Azw3View.tsx:130` short-circuits with `if (!syncId) return`, so the native menu's "Add Bookmark" action becomes a silent no-op for the entire lifetime of that window. Expected: bookmark handler should resolve the latest syncId at the time of the click, or the hook should refetch / subscribe when the row's syncId is filled in. Actual: ref is permanently null and bookmarks cannot be added.

## Reproduction
- Test file: `apps/rishi-electron/e2e/azw3-parity.spec.ts` lines `L88-L174` (the "Add Bookmark" test)
- Test workaround: lines `L98-L113` pre-seed `syncId` via direct `saveBook` IPC *before* `openBook` runs, specifically because the production hook would otherwise cache `null`. The in-spec comment (L100-103) documents the bug verbatim.
- Failing assertion (without the workaround): `expect(after).toBe(before + 1)` at `L170` — `after` stays equal to `before`.
- How to run: `cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron && pnpm test:e2e e2e/azw3-parity.spec.ts -g "Add Bookmark"`

## Tester Analysis
Production code:
- `src/renderer/src/hooks/reader/useBookSyncId.ts:25-32` — single `useEffect` keyed only on `bookId`. No refetch when row updates; no IPC subscription to "syncId assigned" events.
- `src/renderer/src/components/azw3/Azw3View.tsx:104, 130` — bookmark handler reads `bookSyncIdRef.current`; returns early on null.
- Same pattern applies to `EpubView.tsx:192` and `MobiView.tsx:37`, so the bug class is wider than AZW3.

The test explicitly seeds syncId pre-mount to *hide* the bug, which is a tell-tale TDD workaround. A real user importing then immediately opening a fresh AZW3 (or any format) before the syncId backfill IPC fires will be unable to bookmark until they restart the window.

Fix direction (for Wave 6, not implementation now): either (a) re-run the IPC fetch when `null` is encountered inside the bookmark handler, or (b) have `useBookSyncId` subscribe to a `book-updated` IPC event and refresh the ref/state, or (c) wait for `bookSyncId !== ''` before mounting the reader.

## Reviewer-1 Verdict: BUG
**Agent type:** team-reviewer
**Flake check:** N/A (deterministic logic bug, not a flake)
**Reasoning:** Verified the production code path end-to-end. `useBookSyncId.ts:25-32` runs the IPC fetch inside a single `useEffect` keyed only on `bookId`; the result is written to `bookSyncIdRef.current` unconditionally, and `setBookSyncId` is guarded by `if (syncId)` (line 28). There is no IPC subscription, no refetch, and no re-render path that would observe a later syncId assignment for the same `bookId`. Confirmed via `main/database/queries.ts:202-234` that `saveBook` inserts with `syncId: input.syncId ?? null` and does not auto-generate one, and the e2e import helper (`e2e/helpers/electron-app.ts:89-126`) calls `saveBook` without a `syncId`, so any freshly imported book starts at `null`. `main/ipc/books-extra.ts:7-11` returns that `null` from `books:getSyncId`. The `Azw3View.tsx:130-131` bookmark handler then captures `null` in `bookSyncIdRef.current` for the lifetime of the window and silently no-ops on every native-menu "Add Bookmark" click — same shape in `MobiView.tsx:55-68` (state-based, but `bookSyncId` state is also never updated past mount when initial fetch returned null) and `EpubView.tsx:292-303`. The e2e spec at `e2e/azw3-parity.spec.ts:98-113` openly documents the workaround: it pre-seeds `syncId` via `saveBook` *before* `openBook` runs and explains in the comment that the production hook caches `null` otherwise — a textbook "test edited to match buggy code". Corroborating evidence that the team already recognized this bug class elsewhere: `useChat.ts:43-62` does exactly the right thing — when `booksGetSyncId` returns null, it generates a UUID with `crypto.randomUUID()` and persists it via `saveBook`. The bookmark surface was never given the same treatment.
**Suggested fix scope (if A/B):** N/A — this is a production bug; Wave 6 should add a generate-and-persist fallback in `useBookSyncId` (or in each bookmark handler) mirroring the `useChat.ts:54-61` pattern, and remove the e2e pre-seed workaround so the test fails red first.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
<append after wave 4, only if rejected>

## Tiebreaker Verdict: CONFIRM | REJECT
<append after wave 5, only if rebutted; binding>

## Fix Plan
**Status:** fixed
**Commit:** 80e19a13
**Notes:** Adopted approach (c) from the reviewer's suggested-fix list, mirroring `useChat.ts:43-62`. Inside `useBookSyncId`'s mount effect, when `booksGetSyncId(bookId)` returns `null/''`, the hook now fetches the book row via `getBook`, generates a UUID with `crypto.randomUUID()`, persists it via `saveBook({...book, syncId, isDirty: 1})`, and only then sets state/ref. Wrapped the effect body in an async IIFE with a `cancelled` flag so bookId changes / unmounts don't write stale syncIds. Red phase: added a new test `generates and persists a syncId when the initial fetch returns null` to `useBookSyncId.test.ts`; confirmed failing against the original implementation. Green phase: all 5 hook tests pass; full renderer unit suite stays green (124 files / 1109 tests). The pre-existing "does not publish bookmarks when the sync id is null/empty" test was tightened to block the fallback by pre-mocking `getBook` to `null` so the original semantics (no publish on a book that truly has no row) are preserved. E2e `azw3-parity.spec.ts` could not be verified in this sandbox — all three tests time out at `launchApp()` (60s test timeout exceeded before the worker even produces a page), which reproduces on the suite as a whole and is unrelated to this change. The e2e's pre-seed workaround (lines 102-113) remains in place and is still effective; the reviewer's suggested follow-up to remove it should be done in a separate change once the e2e harness is unblocked.

## Code Review
<append after coder commits; approve / request changes>

## Coder Rebuttal
<append if review requested changes; ACCEPT or REBUT>

## Code-Review Tiebreaker
<append if rebut; binding>

## Mutation Check
**Result:** PASSED
**Method:** Main thread reverse-applied fix commit `8cada209` to production file only (`useBookSyncId.ts`), kept test file intact, ran `pnpm --filter rishi-electron test useBookSyncId`. Then restored and re-ran.
**Test failed without fix:** YES — 1/5 failed: "generates and persists a syncId when the initial fetch returns null" (the red-first test)
**Test passed with fix restored:** YES — 5/5

## Final Verdict
Fix commit: `8cada209`. Test pass: 5/5 unit. Mutation: PASSED.
**Verdict:** APPROVE
**Findings:**
- Scope is minimal: only `useBookSyncId.ts` + its test changed; no unrelated refactors.
- `cancelled` flag is wired correctly after each `await` (booksGetSyncId, getBook, saveBook) — bookId change or unmount cannot publish a stale syncId to ref/state. Mirrors `useChat.ts:40-61` faithfully.
- Generated syncId is persisted via `saveBook({...book, syncId, isDirty: 1})` before being written to ref/state, so a window restart will see the same id (no orphan UUIDs held only in memory).
- All 3 production consumers (`Azw3View.tsx:104`, `EpubView.tsx:192`, `MobiView.tsx:37`) destructure the same shape `{bookSyncId, bookSyncIdRef}` — no breakage. `ChatPanel`/`useChat` is a downstream consumer of `bookSyncId` and benefits from the fix (no longer needs to mint on its own when the reader has already mounted).
- Tightened "null/empty" test (mocks `getBook` to null) correctly preserves the original "do not publish on a truly absent row" semantics so the new fallback doesn't silently swallow that case.
- New red-first test (`generates and persists a syncId when the initial fetch returns null`) asserts saveBook is called with `{id, syncId, isDirty: 1}` and that ref === state — would fail against the old single-`then` implementation. 5/5 hook tests pass locally.

Worth checking (low-confidence, do not block):
- Concurrent-mint race: if two components calling `useBookSyncId(sameBookId)` mount in the same tick before either `saveBook` completes, both will mint different UUIDs and the later write wins; the earlier hook instance keeps the losing UUID in its ref/state and would publish bookmarks under a syncId no longer present in the books row. In practice the only other minting site is `useChat.ts` and `ChatPanel` is mounted lazily (closed by default) and takes `bookSyncId` as a prop, so the window is narrow — but the same race exists across two reader windows opened on the same book back-to-back. Not a regression vs. the prior behavior (which was strictly worse: no bookmarks ever), and matches the existing `useChat` pattern, so acceptable for this fix. If you want to eliminate it later, the minting should move to a single main-process IPC like `books:ensureSyncId(bookId)` that is idempotent under SQLite's row lock.
