# Phase A — Practices Audit

Best-practice violations in renderer-core tests. Triaged in Wave 8 into Type A (fix this run) vs Type B (document only).

## Tester T1

- **authStore.test.ts:6-12** — `beforeEach` hand-crafts a `setState({...})`
  slice instead of using a store-provided `reset()`. Drift risk (pilot Q06):
  any new field on `AuthState` is silently un-reset. Either add `reset()` to
  the store and use it, or assert the fixture covers all `AuthState` keys.
- **chatStore.test.ts:66-74** — Same pattern: hand-crafted partial-state
  fixture only includes `isChatting` and `chatStatus`, omits `voiceState` and
  `voiceError`. Cross-test leakage hazard.
- **navStore.test.ts:6-10** — Same hand-crafted fixture pattern (`navState`,
  `send`).
- **playerStore.test.ts:6-15** — Same pattern across 8 fields. Highest-risk
  instance because the production `PlayerStore` interface has the largest
  surface (10-state union, multiple paragraph arrays, page-request signal).
- **navStore.test.ts:39-42** — Iterating `['idle', 'navigating', 'loading',
  'error', 'ready']` with `as any` cast bypasses the actual `NavState` union
  type. If production narrows the union, the test still passes. Replace
  `as any` with the actual union type so a deleted state breaks the test.
- **navStore.test.ts:56-65** — `{ type: 'DISPLAY', location: 'chapter-5' } as
  const` passed to a mocked `send` accepts any shape. If production's `Send`
  signature is a discriminated union, the test passes invalid events. Type
  the mock as `vi.fn<Parameters<typeof realSend>, void>()` or import the
  real event type.
- **navStore.test.ts:67-72** — "Rapid setState" 100-iteration loop only
  asserts `navState` is defined post-loop. Tautological — any non-throw
  satisfies it. Either delete the test or assert a meaningful invariant
  (e.g. final state equals last write).
- **chatStore.test.ts:88-101 vs 160-161** — Single `await Promise.resolve()`
  on happy path, double on rejection path. Asymmetric microtask-flush count
  is brittle: if production adds another `await` to the happy path, the
  assertion order silently breaks. Standardize on `vi.waitFor(() => ...)`
  for a behavioral wait, or document the exact awaited promise chain.
- **chatStore.test.ts:61-63** — `onEndedByAgentHandler` captured at
  module-init *before* `vi.clearAllMocks()`. Fragile to file-reorder.
  Recapture inside `beforeEach` after `vi.resetModules()` or assert the
  subscription invariant explicitly.
- **chatStore.test.ts:21-53** — Mocking sibling stores (`@/stores/playerStore`,
  `@/stores/epubStore`) is borderline "mock-when-shouldn't". Real stores are
  cheap and in-process; mocking them obscures the store-to-store contract.
  Consider replacing with real store `setState` calls (see pilot principle:
  don't mock at boundaries that aren't real-only).
- **playerStore.test.ts:22-29** — `setCurrentParagraphs` asserted via
  `toEqual(paragraphs)`. Does not verify whether the store copies or stores
  by reference. If by reference and caller mutates later, store is corrupted
  silently.
- **indexingStore.test.ts:6** — *Positive call-out*: uses
  `useIndexingStore.getState().reset()` instead of hand-crafted setState.
  Reference implementation; propagate this pattern to the other 4 store
  test files.
- **indexingStore.test.ts:17** — *Positive call-out*: full-shape
  `toEqual({ done: 0, total: 100, status: 'running' })` defends against
  silent field addition. Encourage this pattern over field-by-field
  `toBe(...)` cascades.

## Tester T10 (reader-cache)

- **B — LRU tests rely on real `setTimeout(... 2ms)` for `lastAccess` separation.** `cache.test.ts:74-90, 148-167, 178-203` interleave `await sleep(2)` between `set()` calls to force `Date.now()` deltas. Works today; brittle if vitest is ever globally configured for fake timers, or under future high-res monotonic-clock semantics. Design fix is to inject a `now: () => number` port into `ReaderCacheOptions` (see test-infra-backlog). No change for this run — current tests are reliable in CI.
- **B — `cache.test.ts` consistently asserts on observable outcomes (`destroy` mock, `get` round-trip) and avoids implementation details.** Positive call-out: the assertion style ("destroy was called with the evicted document, the entry is no longer reachable via get") is exactly the "what the user observes" model; other reader-core files should follow this pattern.
- **B — `cache.test.ts` does not assert the `stats` defensive-copy contract** (`cache.ts:157` returns `{ ...stats }`). A mutation that returns `stats` directly would not be caught. Captured in finding A093.
- **B — Asymmetric same-doc-ref handling.** `cache.ts:106-112` (oversize path) `delete()`s a stale entry even when `stale.document === document`; `cache.ts:117-127` (in-place replace) updates fields. Both paths are correct, but the asymmetry is unasserted. One test — "set(id, doc) under cap, then set(id, doc) over cap → cache is empty AND destroy not called with doc" — pins the contract.
