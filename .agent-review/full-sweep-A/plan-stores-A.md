# Plan — Full-Sweep A: Stores (Sub-batch A)

**Scope (5 files):**
- `apps/rishi-electron/src/renderer/src/stores/authStore.test.ts`
- `apps/rishi-electron/src/renderer/src/stores/chatStore.test.ts`
- `apps/rishi-electron/src/renderer/src/stores/indexingStore.test.ts`
- `apps/rishi-electron/src/renderer/src/stores/navStore.test.ts`
- `apps/rishi-electron/src/renderer/src/stores/playerStore.test.ts`

**Tester ID range:** A001–A010 (max 5 findings).

---

## 1. Skip list

No `.skip` / `.todo` / `.only` in any of the 5 files. All tests run.

---

## 2. Per-file audit checklist

### 2.1 `authStore.test.ts` (60 lines, 8 tests)

- **L6–12** — `beforeEach` uses hand-crafted `setState({...})` slice instead
  of the store's own `reset()` (if one exists). Pilot Q06 pattern: drift risk
  when new fields are added to `AuthState` (e.g. a token, a session expiry,
  a "remember me" flag). If `authStore.ts` exposes `reset()`, prefer it.
  **Practice violation.**
- **L21** — `setUser({ id: '123', email: 'a@b.com' })` is missing other
  production user fields (avatar, name, plan, premium flag). If production
  `User` type requires them, this is a `as User` cast somewhere or a
  partial-type leak. Check the production `setUser` signature for required
  fields not asserted here. **Possible parity gap.**
- **L26–30** — Asserts `welcomeSeen=true` after `hydrateAuth()` reads
  `'rishi:welcome-seen' === '1'`. Does NOT assert behavior for any value
  other than `'1'` (e.g. `'true'`, `'yes'`, `'0'`). The string-literal
  contract is implicit. **Coverage gap.**
- **L37–41** — `dismissWelcome` writes `'1'` and `welcomeSeen=true`, but
  no test for `bannerDismissed` persistence (L43-46 only asserts in-memory
  flag, not localStorage round-trip). Asymmetric persistence coverage.
  **Possible production bug**: is banner-dismissed supposed to persist
  across reloads? Check `authStore.ts` to confirm — if yes, this is a
  missing test for a real persistence path.
- **L48–51** — `setAuthHydrated(true)` but no `setAuthHydrated(false)` test
  (does anyone ever un-hydrate? if not, why is the setter polymorphic?).
  Low priority.
- **No test** that `hydrateAuth()` is idempotent. Calling it twice should
  not double-fire any side effects (analytics, IPC). **Coverage gap.**
- **No test** for `signInOpen` interaction with `setUser` (does signing in
  auto-close the modal?). If the production code does this, missing test.

### 2.2 `chatStore.test.ts` (165 lines, 10 tests)

- **L21–53** — Heavy `vi.mock(...)` use for `@/services`, `@/services/voice-chat`,
  `@/stores/playerStore`, `@/stores/epubStore`, `@/utils/sentry`,
  `@/modules/pageCapture`. The voice-chat-service mock is appropriate (real
  service hits network). The **store mocks** (`playerStore`, `epubStore`) are
  borderline — mocking sibling stores is mock-when-shouldn't if production
  code reads them directly. Pilot principle: don't mock at boundaries that
  are not real-only. Check whether the store-to-store call could be replaced
  with the actual store's `setState`. **Practice violation candidate.**
- **L66–74** — `beforeEach` hand-crafts only `isChatting`/`chatStatus` —
  omits any other ChatState fields. Drift risk (pilot Q06). **Practice
  violation.**
- **L61–63** — `onEndedByAgentHandler` is captured at module-init *before*
  `vi.clearAllMocks()`. Comment acknowledges this. Subtle ordering trap —
  if anyone reorders the file, the handler ref becomes undefined and tests
  silently no-op (the `!` assertion will throw, but only on the test that
  uses it). Defensible but fragile. **Practice observation.**
- **L88–101** — `startChat(42)` then `await Promise.resolve()` once. Pilot
  Q on timing: a single microtask flush is insufficient if `startChat`
  awaits more than one promise internally. **L160–161** uses two flushes
  for the rejection path — asymmetry. If production adds another `await`,
  L88–101 silently passes the wrong assertion order. **Practice violation
  (microtask brittleness).**
- **L83–86** — `setIsChatting(false)` asserts `deactivate` called once but
  does not assert the **order** of (deactivate → state change). If the
  production code sets `isChatting=false` *before* deactivating (a race
  where UI thinks chat is over but voice service still emits audio),
  test won't catch it. **Coverage gap / possible production bug.**
- **L126–132** — `stopConversation` asserts state + deactivate but does
  NOT assert `voice.dispose` or any teardown of `onChatStatus`/`onStateChange`
  subscriptions captured at module init. Subscription-leak risk. **Coverage
  gap.**
- **L146–153** — The handler captured at module-init only — if the store
  also `voice.onEndedByAgent` subscribes lazily (on `startChat`), only the
  module-init subscription is tested. Confirm with `chatStore.ts` whether
  subscription is module-scoped or per-session.
- **No test** for `chatStatus` transitions ('idle' → 'connecting' → 'listening'
  → 'speaking' → 'idle'). Only 'idle' and 'speaking' appear. **Coverage gap.**
- **No test** for the `OfflineError` branch (mock is defined L25–32 but
  never thrown). **Coverage gap.**

### 2.3 `indexingStore.test.ts` (60 lines, 7 tests)

- **L6** — `beforeEach` uses `reset()` (correct pattern, contrast with the
  other 4 files). Compliments the pilot Q06 guidance.
- **L17** — `expect(entry).toEqual({ done: 0, total: 100, status: 'running' })`
  asserts the full object shape — protects against silent field addition.
  Good practice (defend this pattern in the practices audit).
- **L28–35** — `finish()` asserts `done === total` but does NOT assert
  the `error` field is cleared/null. If a book errored and was retried,
  does `finish()` leave a stale error? **Coverage gap / possible production
  bug.** Verify with `indexingStore.ts`.
- **L37–43** — `error(7, 'embedding failed')` asserts `status='error'`
  and `error` message, but does NOT assert that `done`/`total` are
  preserved (so the UI can show "failed at 3/5"). If production zeroes
  them, UI loses context. **Coverage gap.**
- **L20–26** — `advance()` calls advance twice on `total: 3`. Never tests
  `advance(7)` past `total` (the "up to total" clause in the test name is
  not actually asserted — there is no `advance` past 3). **Coverage gap /
  possible production bug** (off-by-one when done > total).
- **L53–58** — `progress(7)` for unknown id returns 0 — but does it return
  0 or `NaN` when `total === 0`? Division-by-zero edge case not tested.
  **Coverage gap / possible production bug.**
- **No test** for concurrent `start(7,…)` calls on the same id (does it
  reset progress or merge?). Realistic case: user re-imports same book.
  **Coverage gap.**
- **No test** that `reset()` clears all books (only one book, id 7, is
  ever used; `reset()` correctness on multi-book state is implied not
  verified). **Coverage gap.**

### 2.4 `navStore.test.ts` (74 lines, 9 tests)

- **L6–10** — Hand-crafted `setState({ navState: 'idle', send: null })`
  fixture. Pilot Q06 pattern: if `NavState` grows a field, this fixture
  drifts. **Practice violation.**
- **L39** — `const states = ['idle', 'navigating', 'loading', 'error', 'ready']`
  is cast with `as any` (L42). The cast bypasses the actual union type —
  if production narrows the union (e.g. removes 'loading'), the test still
  passes. **Practice violation (type erasure).**
- **L56–65** — Asserts `sendFn!(event)` calls the mock with the event. But
  the event shape `{ type: 'DISPLAY', location: 'chapter-5' }` is also
  `as const` and unrelated to the actual `Send` signature in production.
  If production's `Send` expects a discriminated union, this test passes
  any object. **Practice violation (type erasure).**
- **L67–72** — "Rapid setState" loop (100 iterations) is a non-test —
  asserts `navState` is "defined" after the loop, which is trivially true
  for any non-throw. Tautology. **Practice violation (weak assertion).**
- **L31–36** — Asserts `setSend(null)` clears the function. Good. But
  no test for "what does calling `send` look like when it was never set"
  (does the consumer crash? does it no-op?). **Coverage gap.**
- **L21–23** — `setNavState('navigating')` but no test for transitioning
  *from* a non-idle state (does 'error' → 'navigating' allowed? what
  about 'error' → 'ready' without 'navigating' between?). The store is
  freely transitionable — if production has a state machine semantics,
  the test doesn't enforce it. **Coverage gap / possible production bug.**
- **No test** that `send` is invocable after a re-render (i.e., the
  stored function reference is stable across renders or correctly
  replaced). React-store interplay not covered. **Coverage gap.**

### 2.5 `playerStore.test.ts` (65 lines, 8 tests)

- **L6–15** — Hand-crafted `setState({ ... })` fixture lists 8 fields.
  Pilot Q06 high-risk pattern. If `PlayerState` adds, say, `currentBookId`,
  `volume`, `playbackRate`, the `beforeEach` won't reset them → cross-test
  leakage. **Practice violation (high-confidence finding candidate A001).**
- **L18–20** — Only asserts `playingState === 'idle'` after the fixture
  reset. Does not assert the other 7 fields the fixture sets — coverage
  gap for the reset contract itself. **Practice violation.**
- **L22–29** — `setCurrentParagraphs` assertion uses `.toEqual(paragraphs)`,
  asserting the array is stored as-is. Does not assert immutability /
  copy semantics — if production stores by reference and the caller mutates
  later, store is corrupted. **Coverage gap.**
- **L43–46** — `requestNextPage()` sets `pageRequest='next'` but does not
  assert the prior state of `pageRequest`. What if a 'prev' was pending?
  Does 'next' overwrite, queue, or throw? **Coverage gap / possible
  production bug.**
- **L48–51** — Same risk for `requestPrevPage()`. The interaction between
  the two is untested.
- **L59–63** — `setSend` parity with `navStore.test.ts:25-29` — same
  practice concerns (no test of `send(null)`, no test of stale-ref).
- **No test for `errors` array.** It's in the fixture (L11) but no `it`
  block exercises pushing/clearing errors. **Coverage gap.**
- **No test for `activeParagraph`.** Fixture sets it null (L8), no setter
  is exercised. If `setActiveParagraph` exists in production, untested.
  **Coverage gap.**
- **No test for playingState transitions** ('idle' → 'playing' → 'paused'
  → 'idle'). Only 'idle' default is asserted. The store is named "player"
  yet no actual play/pause coverage. **Major coverage gap.**

---

## 3. Tester ID range & high-confidence candidates

**Range:** A001–A010 (cap 5 findings).

Most likely real bug-finding candidates (in priority order, for the tester
to confirm against production code):

1. **A001** — `indexingStore.advance()` past `total` (L20–26 gap, §2.3).
   Off-by-one bug class; trivial to reproduce.
2. **A002** — `indexingStore.progress()` divide-by-zero when `total === 0`
   (L53–58 gap, §2.3).
3. **A003** — `indexingStore.finish()` does not clear stale `error` (L28–35
   gap, §2.3).
4. **A004** — `chatStore.setIsChatting(false)` ordering: state set before
   deactivate (L83–86 gap, §2.2).
5. **A005** — `authStore.bannerDismissed` persistence asymmetry (§2.1).

Findings A006–A010 reserved for surprises discovered while reproducing.

The rest are practice violations / coverage gaps and belong in
`practices-audit.md` / `parity-gaps.md`, NOT `findings/`.

---

## 4. Test commands

```bash
# Individual files
pnpm --filter rishi-electron test src/renderer/src/stores/authStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/chatStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/indexingStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/navStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/playerStore.test.ts

# Single it() block
pnpm --filter rishi-electron test src/renderer/src/stores/indexingStore.test.ts \
  -t "advance() increments done up to total"

# Flake check (3 runs) before filing a finding
for i in 1 2 3; do \
  pnpm --filter rishi-electron test src/renderer/src/stores/indexingStore.test.ts \
    -t "<name>" || echo "run $i FAIL"; \
done
```

