# Phase A — Parity Gaps

Format-pair gaps and missing-counterpart gaps in renderer-core tests. Tracked for follow-up.

## Tester T1

- **chatStore.test.ts** — `chatStatus` transitions test covers only `'idle'` and
  `'speaking'`. Missing parity coverage for `'connecting'` and `'listening'`
  branches of the `ChatStatus` union from `@/services/voice-chat`.
- **chatStore.test.ts** — `OfflineError` branch of `startChat` (`chatStore.ts:84-87`)
  is mocked but never thrown in any test. The non-OfflineError branch (Sentry
  capture) IS exercised; the OfflineError branch (skip Sentry capture) is not.
- **playerStore.test.ts** — `PlayerStoreState` union has 10 states; only `'idle'`
  is asserted. No transition coverage for `'loading' | 'playing' | 'paused.clean'
  | 'paused.stale' | 'waitingForParagraphs' | 'pageNavigating' |
  'republishingParagraphs' | 'error'`. The store is the "player" store with
  no actual play/pause path.
- **playerStore.test.ts** — `errors: string[]` field is in the fixture (L11) but
  no push/clear path is exercised. No setter exists in production either —
  suggests `errors` is dead state OR is mutated by external code; both warrant
  follow-up.
- **playerStore.test.ts** — `activeParagraph` reset to `null` in fixture but
  never asserted, and no setter (`setActiveParagraph`) is exercised. Production
  has no `setActiveParagraph` action — the field is presumably written by the
  xstate machine via direct `setState`; that integration seam is uncovered here.
- **authStore.test.ts** — `hydrateAuth()` only tested for `localStorage` value
  `'1'`. No coverage for `'0'`, `null`, or the catch-branch fail-closed
  semantics (`welcomeSeen=true` on throw at `authStore.ts:44-47`).
- **authStore.test.ts** — No idempotency test for `hydrateAuth()` (calling it
  twice should not re-trigger any side effect; today it's pure-read so safe,
  but the contract is unasserted).
- **indexingStore.test.ts** — Multi-book `reset()` correctness: only id `7` is
  ever used. `reset()` clearing 2+ books is unasserted.
- **indexingStore.test.ts** — `start()` called twice on the same id: does it
  reset progress (current behavior, per L27-33 which always writes
  `{ done: 0, total, status: 'running' }`) or merge? Behavior is implicit;
  add a test to pin it.
- **navStore.test.ts** — No coverage for `send` being called when it was never
  set (`send: null`). Consumer crash vs no-op is unspecified.

## Tester T10 (reader-cache, plan-misc-services §2)

- **`pdf-cache.ts` and `epub-cache.ts` have zero unit-test files.** Filed as finding A092 (production-shape regressions) — also tracked here as a structural parity gap: the cache factory has a test file, the configured instances do not. Adding `pdf-cache.test.ts` / `epub-cache.test.ts` (~20 LOC each) would close the per-module parity.
- **`destroy()` Promise-rejection is swallowed** (`cache.ts:62-64` — `void opts.destroy(...)`). In production both `pdf-cache.ts:14` (`proxy.destroy()`) and `epub-cache.ts:23` (`book.destroy()`) return Promises that can reject. Currently no logging path, no error handler. Pilot called this design-by-discard; flagged here per plan §2.1 rather than as a finding because no test can demonstrate observable user breakage today. Worth a follow-up to either (a) add a `onDestroyError?: (err: unknown) => void` option to the factory, or (b) document the discard contract in the module header.
- **`evictOldest()` tie-breaking is non-deterministic** under shared `lastAccess` timestamps (`cache.ts:66-80`). Test-infra item — see test-infra-backlog.md.
- **Single-entry oversize-vs-total budget edge** (`cache.ts:136` — `&& entries().size > 1`): a single inserted entry larger than `maxTotalBytes` but smaller than `maxEntryBytes` survives, by the `> 1` guard. Production constants happen to satisfy `maxEntryBytes <= maxTotalBytes` (50MB vs 150MB), so this is theoretical — but if a future config swaps them, the behavior would silently change. One assertion in `cache.test.ts` would pin the contract.
