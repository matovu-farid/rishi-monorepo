# Phase A — Plan: Machines + Hooks (Planner 2)

**Scope:** 4 XState machine specs + 12 hook specs under
`apps/rishi-electron/src/renderer/src/{machines,hooks}/`.
**ID range:** A021–A050 (A021–A030 machines, A031–A040 hooks-A, A041–A050 hooks-B).
**Pilot lessons honoured:** skip-list pre-screen, vitest-config check
before claiming spec-level impact, no findings produced here.

References (pilot model):
`/Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/plan.md`,
`/Users/faridmatovu/projects/rishi-monorepo/.agent-review/FINDING-TEMPLATE.md`,
`/Users/faridmatovu/projects/rishi-monorepo/docs/superpowers/specs/2026-05-20-multi-agent-test-review-design.md`.

---

## 1. Skip list (PILOT LESSON 1)

**Result: 0 skipped tests in this batch.** Confirmed by
`grep -nE "test\.skip|it\.skip|describe\.skip|test\.todo|it\.todo|xdescribe|xit"`
across all 16 files (the only `skip` substring hit was
`wantsAutoResumeAfterChat` in `playerMachine.test.ts:1170`, a context-field
name — false positive).

Two structural observations that look skip-adjacent but are not:

- `playerMachine.recovery.test.ts:229-235` calls `console.warn` and treats
  documented "soft exception" states as non-failing. This is a deliberate
  not-yet-fully-tested escape hatch — testers should record it in
  `practices-audit.md` as **soft-skip via warning** rather than treating it as
  a finding.
- Multiple hook tests use `await import(/* @vite-ignore */ HOOK_PATH)` with a
  dynamic path (see `useBookEmbeddings`, `useBookSyncId`,
  `useChapterParagraphPrefetch`, `useCommonMenuHandlers`,
  `usePageRequestSubscription`, `useReaderMenuSync`). Inline comments say
  "Wave 3 will create …". Verify the production file actually exists today;
  if it doesn't, the test silently degrades to a module-not-found rejection
  — Vitest reports it as a *failure*, not a skip, but the failure mode is
  identical from a coverage standpoint. **Action for testers:** for each
  such file, `ls` the corresponding production hook path; if missing, write
  the gap to `parity-gaps.md` not `findings/`.

---

## 2. Machine-state-coverage matrix

States and events were derived from the production files
(`playerMachine.ts`, `pdfReaderMachine.ts`, `connectivityMachine.ts`,
`navMachine.ts`). `navMachine` is unassigned to this batch — flag.

### 2.1 `connectivityMachine` (4 tests, 30 lines)

| State / event | Covered? | Notes |
|---|---|---|
| `online` initial | ✓ | line 7 |
| `online → OFFLINE → offline` | ✓ | line 11 |
| `offline → ONLINE → online` | ✓ | line 17 |
| `offline → OFFLINE` (idempotent) | ✓ | line 24 |
| `online → ONLINE` (idempotent) | ✗ | mirror gap |
| Entry/exit actions (if any) | ✗ | none asserted |

**Gap:** symmetry test for `ONLINE` while already online; production code
read needed to confirm no side-effect actions are emitted (e.g. logging
or store sync).

### 2.2 `pdfReaderMachine` (22 tests, ~333 lines)

Parallel states: `seek` {idle, seeking, viewing} × `persist` {clean, dirty,
saving}.

| State / event | Covered? | Notes |
|---|---|---|
| seek.idle initial | ✓ | line 37 |
| DOC_LOADED → seek.seeking, clamps to numPages | ✓ | line 54, 64 |
| SEEK_LANDED commits pendingOffset | ✓ | line 82 |
| SEEK_REQUESTED clears pendingOffset (jump-to-top) | ✓ | line 92 |
| PAGE_CHANGED during seeking is a no-op | ✓ (regression-named) | line 102 |
| PAGE_CHANGED during viewing dirties persist | ✓ | line 113 |
| Offset-only PAGE_CHANGED with same page dirties | ✓ | line 124 |
| Threshold quiet-window (same page, tiny offset) | ✓ | line 135 |
| persist.dirty → persist.saving via after-debounce | ✓ | line 155 |
| Debounce timer resets on subsequent change | ✓ | line 176 |
| saving → dirty on intervening change | ✓ | line 204 |
| FLUSH on dirty fires `flushSave` action | ✓ | line 228 |
| FLUSH on clean is no-op | ✓ | line 252 |
| Initial restore does NOT save | ✓ | line 300 |
| TOC/thumbnail-style SEEK_REQUESTED+LANDED triggers save | ✓ | line 277 |
| save error → dirty (retry) | ✓ | line 315 |
| **Gap: save error during second attempt is also retried** | ✗ | only first-error path tested |
| **Gap: invoke cancellation semantics** | ✗ | when saving cancels mid-flight on actor stop |
| **Gap: numPages = 0 / undefined edge** | ✗ | what if DOC_LOADED never arrives or numPages=0? |
| **Gap: FLUSH while saving** | ✗ | does it queue or no-op? |
| **Gap: bookId mismatch / restart** | ✗ | no test that input.bookId is carried through saves |

### 2.3 `playerMachine` (~58 tests across .test + .recovery, ~1700 lines)

Top-level states (from `playerMachine.ts`): `idle, stopped, loading, playing,
paused.{clean,stale}, waitingForParagraphs, pageNavigating,
republishingParagraphs, error`. Events: `INITIALIZE, PARAGRAPHS_UPDATED,
NEXT_PARAGRAPHS_UPDATED, PREV_PARAGRAPHS_UPDATED, PLAY, PLAY_FROM, RESUME,
PAUSE, STOP, NEXT, PREV, REPEAT, AUDIO_LOADED, AUDIO_ENDED, AUDIO_ERROR,
PAGE_NAVIGATING, CHAT_STARTED, CHAT_ENDED, CLEANUP`.

| Area | Covered? | Notes |
|---|---|---|
| All listed states reached at least once | ✓ | BFS in `playerMachine.recovery.test.ts` |
| Every event from every state | partial | BFS is recovery-focused; per-state event table NOT exhaustive |
| `after` timers (10s pageNavigating → stopped; 10s republishingParagraphs → stopped) | ✗ | recovery test acknowledges it cannot fast-forward without `vi.useFakeTimers()`; the `pdfReaderMachine` test does use fake timers — gap is real |
| Retry counter (`retryCount`, MAX_RETRIES=3) | ✓ | playerMachine.test.ts:448 |
| PLAY_FROM full surface | ✓ | line 902–1046 |
| CHAT_STARTED / CHAT_ENDED per state | ✓ | line 1048–1254 |
| REPEAT per state | ✓ | line 747–898 |
| Entry/exit actions (`clearCurrentParagraphs`, `setNavDirection`, `resetIndexByDirection`) | partial | observed via context after-state, not asserted as discrete entry/exit calls |
| `nextPageParagraphs` / `prevPageParagraphs` lifecycle on full chapter swap | ✓ | line 689 |
| AUDIO_ERROR in `loading` vs `playing` vs `paused.*` | partial | loading + playing tested; paused not |
| `CLEANUP` from every state | partial | only from playing tested |
| **Gap: `error → REPEAT`** | ✗ | not in REPEAT no-op cases (idle/stopped/loading/paused.*/waitingFor/pageNav/republishing/error) — verify |
| **Gap: PAUSE from `waitingForParagraphs` / `pageNavigating` / `republishingParagraphs`** | ✗ | only PAUSE-from-playing/loading paths exercised |
| **Gap: STOP/PAUSE during `loading` before AUDIO_LOADED arrives** | partial | line 551 covers loading → PAUSE only |
| **Gap: `after` timers** | ✗ | requires `vi.useFakeTimers()` + `actor.start()` — feasible, missing |

### 2.4 `navMachine` — UNASSIGNED, BUT REFERENCED

`navMachine.ts` exists with states `idle | navigating | curling | settling
| undoing` and event surface. **No test file exists.** Record in
`parity-gaps.md` (not findings) — out of this batch's audit surface but
worth flagging for full-sweep tracking.

---

## 3. Hook-pair parity

Hook concerns clustering — asymmetric coverage signals to look for:

| Pair / cluster | Concern | Parity check |
|---|---|---|
| `usePdfTextSelection` ↔ `usePdfHighlights` | PDF selection-to-highlight flow | Selection hook tests fire `mouseup`, cross-page guard, collapse-clear; Highlights hook tests load + refresh + empty-syncId guard. **Missing:** end-to-end flow (select → highlight → list) is not unit-tested anywhere; the EPUB sibling has no counterpart in this batch (defer to e2e). Asymmetry: highlight save/delete *path* not covered by either hook test. |
| `usePdfReadAloudFromSelection` ↔ EPUB read-aloud-from-selection | TTS from selection | EPUB equivalent likely lives outside this batch. **Parity gap** for the planner to flag: the test cites "mirrors EpubView guard" (line 94) — confirm the EPUB-side guard exists and is symmetric, otherwise it's a parity gap. |
| `useTtsHighlightReconciler` ↔ `useBookEmbeddings` | Mount-time reconciliation/re-fetch | Reconciler tests focus, visibility, iframe events; embeddings hook tests ready-gate + dedupe ref. **Asymmetry:** reconciler tests unmount cleanup, embeddings hook does not assert "stops issuing index calls if unmounted mid-flight" — race-condition gap. |
| `useUndoableHighlightShortcut` ↔ `useMenuCommands` | Keyboard / IPC command dispatch | Both run `renderHook`. Keyboard test covers Cmd/Ctrl/Shift/expiry/contentEditable/input — strong. Menu commands test covers only 3 cases (dispatch, ignore unknown, unmount). **Asymmetry:** `useMenuCommands` is much weaker; no coverage of `windowIdentity.kind` filtering, multiple-handler dispatch ordering, error in handler doesn't kill listener. |
| `useReaderMenuSync` ↔ `useCommonMenuHandlers` | Bridge between renderer state and main-process menu | Sync hook tests title publish, tocOpen mirror, isReading derivation, unmount unsubscribe. Common-handlers tests requireAuth gating, toggler functions, stable identity. **Symmetric and good.** |
| `useBookSyncId` ↔ `useBookEmbeddings` | One-shot async work tied to bookId mount | Both correctly use `waitFor`. **Asymmetry:** `useBookSyncId` tests null/empty path; `useBookEmbeddings` does not test "what if `hasIndexedBookData` rejects" — error path missing. |
| `usePageRequestSubscription` ↔ `useChapterParagraphPrefetch` | Subscription stability across re-render | Page-request test asserts no-resubscribe and latest-callback-after-rerender — strong. Prefetch test does NOT assert that a `chapterIndex` change cancels in-flight prefetch — race gap. |

---

## 4. Per-file audit checklist

General anti-patterns testers MUST scan for in every file:
- **Mock-the-renderer**: hooks tested without `@testing-library/react`'s
  `renderHook`. Verified all 12 hook specs DO use `renderHook` — no
  violations of this kind in this batch.
- **`as any` / `as unknown as ...` casts on mocks that bypass type
  contracts.** Pilot Q05 flagged `epubStore.test.ts` for this. Look for the
  pattern below in each file.
- **Machine transition asserted in isolation without entry/exit assertion.**
  Default xstate transitions can pass with wrong actions; assert *context*
  after the transition (or use spies on `actions:`/`actors:`) to catch them.
- **`setTimeout(0)` flushes instead of `waitFor`** — non-deterministic.
- **Tautological assertions** (e.g. `expect(x).toBe(x.current)`).

### Machines (A021–A030)

**`machines/__tests__/connectivityMachine.test.ts`**
- L3: imports from `../connectivityMachine` — file lives in `machines/`, tests in `machines/__tests__/`. The other 3 machine tests live in `machines/` directly. **Convention drift** — `practices-audit.md`.
- All 4 tests are happy-path transitions; no action / context inspection. Confirm production `connectivityMachine` has no actions to assert; if it has them (e.g. logging, store sync), file as **coverage gap**.

**`machines/pdfReaderMachine.test.ts`**
- Uses `vi.useFakeTimers()` correctly (line 31) — good model for the player machine to copy.
- L17 provides `saveLocation` actor via `machine.provide({actors:…})` — proper xstate v5 pattern; defend it.
- L230-249: `flushSave` is overridden via `.provide({actions:…})`. Only `flushSave` is overridden — other actions are NOT spied. If production adds a side-effect action to the same transition, the test won't catch it. **Practice violation** (over-narrow mock).
- L156, L177, L301, L320: `saveSpy` mocks `saveLocation`. Note its signature: `async ({page, offset}) => ({savedPage,savedOffset})`. If production changes its return shape (e.g. adds `error?: string`), the test won't notice. **Practice violation** (loose contract).
- L168 / L296: hard-coded `bookId: 42` — only one bookId-pass-through path is asserted. **Gap**, not violation.

**`machines/playerMachine.test.ts`** (1254 lines, the largest spec in this batch)
- L4: `import type { ParagraphWithIndex } from '@/stores/playerStore'`. Cross-checking: prefetch test (line 4) imports from `@/models/player_control`. **Type-source drift** — `practices-audit.md`.
- L14 uses `ReturnType<typeof createActor<typeof playerMachine>>` — typed actor; good. But every test reassigns `actor` and never `actor.stop()` in afterEach (line 16 only `.start()`). Long suite — if a transition installs an `after` timer that fires post-test, you get test pollution. **Practice violation** (lifecycle hygiene).
- Multiple `describe` blocks share `beforeEach` only by file-level redeclaration (lines 13, 902, 1048, 1188). The inner describes create their own actors via `createActor(playerMachine).start()` — fine, but the outer `actor` is leaked. **Practice observation**.
- No `vi.useFakeTimers()` anywhere — direct consequence: `after` timers in pageNavigating (10s) and republishingParagraphs (10s) are NOT tested. The recovery file admits this at line 343. **Major coverage gap**.
- L1170: test description `exiting paused.clean via RESUME clears wantsAutoResumeAfterChat` — assertion at 1183 (`CHAT_ENDED` → still playing). Title says exit-via-RESUME but checks CHAT_ENDED after; assertion is correct but **misleading test name** — practice violation.

**`machines/playerMachine.recovery.test.ts`**
- L29 imports `getInitialSnapshot, getNextSnapshot`. **DEPRECATED in xstate v5.** L373 confirms: "These tests use createActor + actor.send (the supported API in xstate v5) rather than the deprecated getNextSnapshot." Mixing both styles in the same file — **practice violation**, `practices-audit.md`.
- L37-58: custom `snapshotKey` ignores `wantsAutoResumeAfterChat`, `paragraphIndex` (only `index`), `nextPageParagraphs/prevPageParagraphs`. BFS state-space therefore COLLAPSES distinct contexts into identical keys → false "already visited" → missed dead-ends. **Practice violation** (BFS soundness).
- L229-235: soft-exception classes (pageNavigating, republishingParagraphs, stopped-empty, waitingForParagraphs-empty) emit `console.warn` then `continue`. This is **defensive skipping**. Test should assert the documented external recovery (timer or hook-driven republish) instead — a separate dedicated test per soft-exception state.
- L131 `maxNodes = 800` — silent BFS truncation. If state space ever explodes past 800, the test prints nothing but reports green. **Practice violation** — add an explicit failure when truncated.
- L298-339 ("FIXED: …") test title indicates a fixed bug. Confirm: production code path `republishingParagraphs` exists; otherwise this test will green-light pre-fix. **Verify against current production code.**

### Hooks-A (A031–A040): `hooks/*.test.{ts,tsx}`

**`hooks/useMenuCommands.test.ts`**
- L10, L37: `globalThis as unknown as { window: { electron: object } }).window.electron = ...` rewrites `window.electron` per test. The setup file at `test-setup.ts:104-107` makes `window.electron` non-writable via `Object.defineProperty(...{writable: true})`. The pattern works but does NOT restore the original — **test independence violation**: subsequent tests get the *last* mock. Verify execution order has no leak.
- Only 3 tests for 4 listed `MenuCommandHandlers`-related concerns. **Coverage gap.**

**`hooks/usePdfHighlights.test.tsx`**
- L11 `window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>` — same `as unknown as` cast pattern flagged by pilot Q05. Acceptable here (`vi.fn` defined in setup), but document in `practices-audit.md`.
- No test for the **error path** (`highlightsList` rejects). Real production: IPC can fail; hook should not crash. **Coverage gap.**
- No test for the **multi-rerender** case (e.g. bookSyncId changes from 'a' to 'b'). Verify hook re-fetches not duplicates.

**`hooks/usePdfReadAloudFromSelection.test.tsx`**
- L21: `Object.defineProperty(window.electron, 'on', { value: onSpy, configurable: true })` — overrides only the `on` key while reusing the rest of `mockElectronAPI`. Good pattern.
- L34: `onSpy.mock.calls.find(([ch]) => ch === 'reader:readAloudFromSelection')` — fragile to call order if hook subscribes to more channels in the future. **Practice observation.**
- L80-92: asserts `partialFirstKey` exactly equals `'10000'`. This is **implementation-detail**-ish — the contract is "partial first key derived from paragraph index". If the format changes (e.g. `'p-10000'`), test breaks but behavior is fine. **Practice violation** (over-tight assertion).
- No assertion that the previously-cached audio for that key is reused (the comment at L88-89 hints at it but doesn't test it). **Gap.**

**`hooks/usePdfTextSelection.test.tsx`**
- 3 tests; production hook likely supports more options. No test for: drag selection across columns, RTL text, scale != 1 with rotation, scroll-during-selection. **Significant gap** vs. `useUndoableHighlightShortcut`'s 7 tests for its keyboard surface.
- L36-38: `eslint-disable @typescript-eslint/no-explicit-any` next to typed mock declarations — **practice observation** (escape hatch in a test that otherwise emphasizes types).
- L69 `Object.defineProperty(range, 'getClientRects', …)` overrides a Range method — fine in happy-dom but if upstream happy-dom adds a real impl, the override may silently no-op. **Brittle.**

**`hooks/useTtsHighlightReconciler.test.ts`**
- L16-20 afterEach restores `document.visibilityState` — *good defensive pattern*; document this as a positive example.
- 8 tests covering mount, change, visibilitychange-visible, visibilitychange-hidden, focus, iframe.load, unmount, plus integration. **Strong coverage.**
- No test for **iframe replacement during lifetime** (caller swaps iframe ref). Production: hook re-subscribes on iframe ref change?

**`hooks/useUndoableHighlightShortcut.test.tsx`**
- 7 tests, exemplary breadth (Cmd, Ctrl, expiry, input-focus, contentEditable, Shift modifier, explicit clear). **Use as model** for `useMenuCommands` weak spot.
- L7 `vi.useFakeTimers()` globally — pairs with L60 advanceTimersByTime. Good.
- No test for **rapid double-undo within the window** — second press silently no-ops? L36 asserts undo called once, but only after a same-press. **Gap.**

### Hooks-B (A041–A050): `hooks/reader/__tests__/*.test.ts`

Shared pattern observation: 5 of the 6 reader/__tests__ files use the
`const HOOK_PATH = '@/hooks/' + 'reader/...'` string-concatenation trick to
defeat Vite's static import-analysis. Inline comments say "Wave 3 will
create …" — this implies a TDD red phase. **Action item:** confirm the
production hook files exist now (audit step 5 below). If they don't, all
five files fail as red tests waiting for an implementation that may never
come — **architectural gap**.

**`hooks/reader/__tests__/useBookEmbeddings.test.ts`**
- L11-14 `vi.hoisted` for mocks — proper xstate-v5-era / vitest pattern.
- L61-63, L88-90 `setTimeout(resolve, 0)` to flush microtasks. Prefer `waitFor` with the negative assertion (poll asserts the value stays unchanged). **Practice violation** (timing flush).
- No test for `hasIndexedBookData` rejection / `indexBook` rejection.
- No test for `bookId` change mid-flight (the dedupe ref logic).

**`hooks/reader/__tests__/useBookSyncId.test.ts`**
- L73-75 `setTimeout(resolve, 0)` — same comment as above.
- Asserts `result.current.bookSyncId === ''` for null path. Confirm production normalizes `null → ''`; otherwise contract drift.
- No test for re-mount with new bookId (does it re-publish to menu?).

**`hooks/reader/__tests__/useChapterParagraphPrefetch.test.ts`**
- L30 `vi.useFakeTimers()` — required because the hook debounces 300ms. Good.
- L47-51 hand-rolled microtask flush (`await Promise.resolve(); await Promise.resolve()`). Magic number 2. **Fragile** — if production adds a third `.then`, tests intermittently fail. Replace with a `waitFor` loop. **Practice violation.**
- No test for **`chapterIndex` change during the 300ms debounce** — does the in-flight prefetch get cancelled or does it race?

**`hooks/reader/__tests__/useCommonMenuHandlers.test.ts`**
- 7 tests, well-structured `makeParams(...)` factory. Use as model.
- L99 / L143: `requireAuth` parameter contract is checked. Good.
- No test for the **`isChatting` and `playingState` cross-product** — what if user is playing AND chatting? Should both PAUSE and stop chat? Currently `voiceChat` does not check `playingState`, `readAloudToggle` does not check `isChatting`. **Possible coverage gap / possible bug.**

**`hooks/reader/__tests__/usePageRequestSubscription.test.ts`**
- L29-36: monkey-patches `usePlayerStore.subscribe` to count subscriptions, restored in afterEach. **Excellent** test-isolation pattern.
- 6 tests, including the all-important "stable across rerender" assertion. **Strong.**
- No test for the **boundary case `pageRequest` transitions `'next' → 'next'`** without an intervening `null`. Production likely treats it as a no-op; assert it.

**`hooks/reader/__tests__/useReaderMenuSync.test.ts`**
- L33-34 `electron().send.mockReset()` correctly resets between tests.
- 4 tests. Title-publish, tocOpen, isReading, unmount.
- **Gap:** what if `book.id` changes mid-mount? The hook should re-publish.
- L82 `playingState: 'paused.clean'` → `isReading: false` — assert this is the *only* false case; what about `'idle' | 'stopped' | 'error' | 'loading'`?

---

## 5. TDD guidance

- **Hooks:** `renderHook` from `@testing-library/react` with `act` for state
  changes; environment is `happy-dom` (vitest.config.ts:7). Setup file
  `src/renderer/src/test-setup.ts` installs `window.electron` and
  `window.api` mocks — use them, don't re-mock the whole surface inside
  a test. To stub a single method, `Object.defineProperty(window.electron,
  'method', { value: spy, configurable: true })` is the established pattern
  (`usePdfReadAloudFromSelection.test.tsx:21`).
- **Microtask flushing:** prefer `await waitFor(() => …)` over
  `await new Promise(r => setTimeout(r, 0))`. The latter is fragile and is
  currently present in 3 of the reader hook tests.
- **Fake timers:** `vi.useFakeTimers()` + `vi.advanceTimersByTimeAsync(N)`
  is the right pair for debounced hooks (`useChapterParagraphPrefetch`,
  `useUndoableHighlightShortcut`) and machines with `after` (`pdfReaderMachine`).
  Use `actor.start()`-ed instances, not `getNextSnapshot`, when timers matter.
- **Machines:** xstate v5 idioms — `createActor(machine, { input })`,
  `actor.send(event)`, `actor.getSnapshot()`. `machine.provide({ actors, actions })`
  to inject test doubles. AVOID `getInitialSnapshot/getNextSnapshot`
  (deprecated; the recovery file admits this at line 373). For BFS over the
  state space, prefer building reachable graphs via `actor.start()` runs.
- **Assert context AND state value** on every transition test. A transition
  that "passes" with the right state value but missing entry actions is a
  silent regression risk (pilot model §3.5 / pilot Q05 lesson).
- **Where a red test belongs** (mirrors pilot §3.3):
  - Reducer/store change → `src/renderer/src/stores/<store>.test.ts`
  - Hook behaviour → `src/renderer/src/hooks/<hook>.test.{ts,tsx}` or
    `hooks/reader/__tests__/<hook>.test.ts` (collocated convention varies;
    both are fine — note in `practices-audit.md`)
  - Machine transition → `<machine>.test.ts` next to the machine file
  - User-visible behaviour requiring real renderer → Playwright in `e2e/`
- **Mocking philosophy:** electron IPC mocked at the bridge surface only
  (already done by `test-setup.ts`). Do NOT introduce `vi.mock('xstate')`
  or mock the player store internals beyond what the per-test scaffold
  installs via `setState`. Stores ARE the boundary for machine + hook tests.

---

## 6. Finding-file rules

- Template: copy `/Users/faridmatovu/projects/rishi-monorepo/.agent-review/FINDING-TEMPLATE.md`
  to `.agent-review/full-sweep-A/findings/AXXX-<short-slug>.md` where AXXX
  is in this batch's range.
- **ID range A021–A050,** split:
  - **A021–A030:** machines (4 specs × ≤5 findings cap; expect <10 total).
    Odd IDs (A021, A023, A025, A027, A029) → `team-reviewer`.
    Even IDs (A022, A024, A026, A028, A030) → `feature-dev:code-reviewer`.
  - **A031–A040:** hooks-A (the 6 top-level `hooks/*.test.{ts,tsx}` files).
    Same odd/even alternation.
  - **A041–A050:** hooks-B (the 6 `hooks/reader/__tests__/*.test.ts` files).
    Same odd/even alternation.
- **Cap: 5 findings per spec.** 16 specs × 5 cap = 80 worst-case; the
  allocated range is 30 IDs — testers MUST stay well under cap. If the
  honest count exceeds 30, route the surplus to `parity-gaps.md` or
  `practices-audit.md` per pilot §4.3.
- **What is NOT a finding** (pilot §4.3 re-applied here):
  - Pre-existing parity asymmetry between hook pairs → `parity-gaps.md`.
  - Missing `after`-timer tests in `playerMachine` → `parity-gaps.md`
    (coverage gap), unless a real bug is exposed.
  - `as unknown as` casts that bypass type contracts → `practices-audit.md`.
  - Hooks whose production file doesn't exist yet (TDD-red pre-Wave-3)
    → `parity-gaps.md` with note "production file missing — verify intent".
  - Soft-skip-via-warning in `playerMachine.recovery.test.ts` → `practices-audit.md`.
- **What IS a finding** in this area: an active test whose assertion would
  pass against incorrect production behavior (false-positive test), or
  one whose assertion fails against current production with a reproducer
  pointing at a production code path. The mutation check (pilot §wave 7)
  will catch fake fixes.

---

## 7. Test commands

All Vitest, no e2e in this batch. From repo root:

```bash
# Machine specs (4)
pnpm --filter rishi-electron test src/renderer/src/machines/__tests__/connectivityMachine.test.ts
pnpm --filter rishi-electron test src/renderer/src/machines/pdfReaderMachine.test.ts
pnpm --filter rishi-electron test src/renderer/src/machines/playerMachine.test.ts
pnpm --filter rishi-electron test src/renderer/src/machines/playerMachine.recovery.test.ts

# Hooks A (top-level hooks)
pnpm --filter rishi-electron test src/renderer/src/hooks/useMenuCommands.test.ts
pnpm --filter rishi-electron test src/renderer/src/hooks/usePdfHighlights.test.tsx
pnpm --filter rishi-electron test src/renderer/src/hooks/usePdfReadAloudFromSelection.test.tsx
pnpm --filter rishi-electron test src/renderer/src/hooks/usePdfTextSelection.test.tsx
pnpm --filter rishi-electron test src/renderer/src/hooks/useTtsHighlightReconciler.test.ts
pnpm --filter rishi-electron test src/renderer/src/hooks/useUndoableHighlightShortcut.test.tsx

# Hooks B (reader hooks)
pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/useBookEmbeddings.test.ts
pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/useBookSyncId.test.ts
pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/useChapterParagraphPrefetch.test.ts
pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/useCommonMenuHandlers.test.ts
pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/usePageRequestSubscription.test.ts
pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/useReaderMenuSync.test.ts
```

Single `it` block: append `-t "<name>"`. Flake check (reviewer-1, ≥3):

```bash
for i in 1 2 3; do pnpm --filter rishi-electron test <path> -t "<name>" || echo "run $i: FAIL"; done
```

Hooks B note: ALL 6 reader hook tests use dynamic `await import(HOOK_PATH)`.
Before running, verify production exists:

```bash
ls -1 /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/src/renderer/src/hooks/reader/{useBookEmbeddings,useBookSyncId,useChapterParagraphPrefetch,useCommonMenuHandlers,usePageRequestSubscription,useReaderMenuSync}.ts
```

If any returns "No such file", the test is in TDD-red waiting on Wave 3 —
do NOT file a finding; record in `parity-gaps.md`.

---

## 8. Project-config check (PILOT LESSON 2)

Read of `apps/rishi-electron/vitest.config.ts`:

- `globals: true` — no need to import `describe/it/expect/vi`. All 16
  specs do import them anyway; not a violation but noise.
- `environment: 'happy-dom'` (NOT jsdom). Implications:
  - `window`, `document`, `localStorage`, `getSelection` exist.
  - `MouseEvent`, `KeyboardEvent`, `Event` work; `selectionchange` event
    fires (used by `usePdfTextSelection.test.tsx`).
  - Some browser APIs are stubs — if a finding alleges a missing API
    surface, verify it's not just a happy-dom limitation. Pilot Q05 had a
    near-miss on this.
  - `Range.getClientRects` is replaceable via `Object.defineProperty`
    (used in `usePdfTextSelection`) — happy-dom impl is a stub.
- `setupFiles: ['./src/renderer/src/test-setup.ts']` — installs
  `window.electron` and `window.api`. Tests that re-define keys on
  `window.electron` MUST use `Object.defineProperty(...{configurable:true})`
  to allow other tests to redefine the same key. Verified pattern in
  `usePdfReadAloudFromSelection.test.tsx:21`.
- **No `pool` / `poolOptions` set** — vitest default is `threads`, with
  per-test-file isolation. Multiple specs that mutate `window.electron.*`
  CAN interfere within the same file if not restored; the setup file is
  per-file, not per-test. The pilot's Q03-equivalent here would be: a test
  modifies `window.electron.X` without restoration, the next test in the
  same file gets the mutated version. **Audit step**: for each finding
  alleging "test bleeds state", confirm against this default behaviour
  before claiming a project-config bug.
- **No `test.testTimeout` override** — vitest default of 5000ms applies.
  Tests in this batch using fake timers (pdfReaderMachine, prefetch,
  undoable shortcut) are well under that. If a finding cites "timeout",
  check whether real-timer leakage is occurring.
- **No `setupFiles` reset between files** — happy-dom recreates window
  per file by default; verify in `getEnvironment` source if necessary.
- `include: ['src/**/*.test.{ts,tsx}']` — `e2e/` is correctly excluded.

**Conclusion of config check:** the vitest config is sane. Findings in
this batch should NOT cite vitest infrastructure as the root cause without
first confirming the per-file isolation behaviour.

---

## Closing notes for testers (machines + hooks)

- The most likely real-bug yield in this batch:
  1. `playerMachine` `after`-timer paths (pageNavigating, republishingParagraphs)
     are NOT exercised. Either the timers don't fire (production bug) or
     they fire but the resulting state is wrong — write a fake-timers test
     to find out.
  2. `usePdfReadAloudFromSelection` cache-key contract (line 91, exact `'10000'`)
     — if production drifted from this format, paragraph-key caching breaks
     silently and TTS re-synthesizes audio. Verify against production.
  3. `useCommonMenuHandlers` does not cross-check `isChatting` against
     `playingState`. There may be a real-world deadlock (PLAY+chat=both
     active) the test doesn't catch.
- Lowest-yield expected: `connectivityMachine` (tiny surface, all
  transitions covered) and the 4 simplest reader hooks (Sync, MenuSync,
  PageRequestSubscription, CommonMenuHandlers — these have strong tests
  already).
- Soft-exception classes in `playerMachine.recovery.test.ts` are
  deliberately tolerated by `console.warn`. Convert each to a positive
  test of the documented external recovery — that work belongs in
  `practices-audit.md` Type A.
