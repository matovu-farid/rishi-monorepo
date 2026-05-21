# Plan: Store Unit Tests — Sweep B (companion to plan-stores-A.md)

**Scope:** 5 store test files. Same anti-pattern hunt as plan-stores-A.md
(hand-crafted setState drift, incomplete reset assertions, mock-when-shouldn't,
impl-detail assertions). Tester IDs A011-A020. Pilot already touched
epubStore (Q05: bookOutline reset preservation) and pdfStore (Q04: paragraph
reset fields; Q06: switched beforeEach to `getInitialState()`). DO NOT re-file
those.

---

## 1. Skip list

- `epubStore.test.ts` L63-81 — reset assertion **already covered by Q05**
  (bookOutline preservation now asserted). Do not file another "reset is
  incomplete" finding tied to bookOutline.
- `pdfStore.test.ts` L5-9 — beforeEach now uses
  `usePdfStore.setState(getInitialState(), true)` (Q06). Do not file
  "hand-crafted reset drift" against pdfStore.
- `pdfStore.test.ts` L92-106 — `resetParagraphState` now asserts all 5
  fields (Q04). Do not file a "incomplete reset assertion" finding here.
- Anything that pretends a unit reducer test should cover the
  `setRendition` / `initEpubSubscriptions` side-effect chain — that's an
  integration boundary; file as a parity gap, not a finding.

---

## 2. Per-file audit checklist

### 2.1 `src/renderer/src/stores/epubStore.test.ts`

Already-covered (Q05): bookOutline reset contract. Focus testers on:

- **L51-55, L57-61, L68, L129** — `{ display: () => {} } as any` mock for
  `Rendition`. Reducer-level use is acceptable per pilot §3.5. The hidden
  risk: production `setRendition` (epubStore.ts:174-207) wires
  subscriptions; the inline stub silently masks any breakage of that
  wiring. **Parity gap** (no integration test exercises the subscription),
  not a finding.
- **L106-115** — "preserve theme across reset" — comment block admits
  the author wasn't sure of the contract; test asserts current behavior
  rather than declared contract. Same characterization-vs-contract issue
  the pilot flagged. **Practice violation** if no spec docs the intent;
  borderline finding only if production theme persistence is actually
  broken (unlikely — `setTheme` is trivial).
- **No test for `publishCurrentEpubParagraphs`, `initEpubSubscriptions`,
  `cleanupEpubSubscriptions`** despite being exported. **Parity gap**.
- **No test for the side-effect that `setBookId` change triggers
  `bookOutline` clear** (epubStore.ts:218-230 per Q05's comment).
  Behavior is asserted indirectly via the L78-80 comment, never directly.
  **Parity gap**.
- **L43-49 (`incrementRenditionCount`)** — asserts the counter
  increments but never asserts what consumers do with it (it is the
  re-mount key). Borderline impl-detail; record as **practice
  observation** only.

### 2.2 `src/renderer/src/stores/pdfStore.test.ts`

Already-covered (Q04, Q06). Focus testers on:

- **L17-21, L27-31, L37-41, L47-51, L57-62, L93-99** — six `setState({...})`
  calls in the test bodies (not in `beforeEach`) that hand-pick a partial
  slice. Q06 fixed the beforeEach drift, but these in-body partials still
  drift if `nextPage`/`previousPage`/`resetParagraphState` start depending
  on a new field. **Practice violation** — convert to either
  `setState(getInitialState(), true)` followed by targeted overrides or to
  small focused factory helpers. Not a finding.
- **No test for the scrollPageNumber → pageNumber sync subscription**
  (pilot called this out at pdfStore.ts:201-208). **Parity gap**.
- **L67-71 `thumbnailSidebarOpen`** — toggles but never asserts it
  survives an unrelated `setPageNumber`/`nextPage`. Low value; do not
  file unless production actually clobbers it.
- **L73-79 `addBook`/`removeBook`** — no test for removing a
  non-existent id, removing the last id, or ordering when re-adding.
  **Practice observation**, only file if production has an off-by-one.
- **No restore-flow test** — `BookNavigationState` enum is imported but
  only used as a setup field, never asserted as a transition. **Parity
  gap** vs. e2e warm-restore.

### 2.3 `src/renderer/src/stores/prefsStore.test.ts`

Cite production: `prefsStore.ts` initial state (L37+) includes
`voiceChatLanguage`, `voiceChatVisionEnabled`, `ttsVisualCueEnabled`;
`hydrate()` reads all three (L42, L44, L45); `setStoreValue` is also
called for vision (L65) and TTS cue (L71). Test file only covers
`voiceChatLanguage`.

- **L11-17 `beforeEach`** — resets the two `electron` IPC mocks and
  the `invalidateKey` mock, but **does not reset the store's state
  between tests** (no `usePrefsStore.setState(...)` reset). The
  `vi.resetModules()` + dynamic `import('./prefsStore')` is the only
  isolation mechanism — works only because each test re-imports.
  Fragile: any test that forgets the dynamic import will bleed state.
  **Practice violation** — consider an explicit reset.
- **L19-22 default test** — only asserts `voiceChatLanguage`, not the
  other two preference flags. Missing default assertions for
  `voiceChatVisionEnabled` and `ttsVisualCueEnabled`. **Coverage gap /
  practice violation**.
- **L24-30 hydrate** — only checks the `voiceChatLanguage` IPC call.
  Production `hydrate()` also reads `voiceChatVisionEnabled` and
  `ttsVisualCueEnabled` (prefsStore.ts:44-45). If those calls regress
  (e.g. wrong key string), this test will not catch it. **Coverage
  gap** — borderline **bug finding** if you can demonstrate a real
  regression path.
- **L46-52 `setVoiceChatLanguage`** — no companion test for
  `setVoiceChatVisionEnabled` / `setTtsVisualCueEnabled`. The latter
  two do NOT call `invalidateKey()`; absence of test means a future
  refactor could silently add or remove an invalidation. **Coverage
  gap**.
- **L4-8 `vi.mock('@/services', ...)`** — mocks the entire `@/services`
  barrel. If unrelated symbols are imported transitively, the mock
  silently returns undefined. Acceptable; just confirm no helper from
  `@/services` is imported elsewhere in `prefsStore.ts`. **Practice
  observation**.
- **L54-60 unknown-code rejection** — uses `'xx' as never`. Confirm
  production rejects via a whitelist (not by length / casing); if
  whitelist isn't centralized, this is a fragile assertion.

### 2.4 `src/renderer/src/stores/selectionStore.test.ts`

Cite production: `selectionStore.ts` L4 `format: 'epub'`, L9 comment
"Future formats (PDF/AZW3/MOBI) will add discriminated variants here",
L14 only `setEpubSelection` exists.

- **L5-7 `beforeEach`** — calls `clear()` which sets `current: null`.
  Fine for the current 1-field state, but follows the same drift
  pattern flagged in plan-stores-A.md: if a new field is added (e.g.
  `lastClearedAt`), `clear()` is the production reset, so this is
  actually OK — keep as-is.
- **L13-23 EPUB selection** — asserts `format`, `cfiRange`, `text`.
  Good. **Parity gap**: no PDF / AZW3 / MOBI setter exists in
  production (L9 comment). When they're added, mirror tests should
  exist. Not a finding today; record in parity gaps if relevant to
  Sweep A's scope.
- **L34-39 replace-overwrites** — asserts `text` but not that
  `cfiRange` and `format` also updated. **Practice violation** —
  partial assertion. Borderline finding only if production diverges
  (would require `setEpubSelection` to spread instead of replace).
- **No test that `setEpubSelection` followed by `clear()` followed by
  `setEpubSelection` produces a fresh object** (object identity). Low
  value; record only if subscribers rely on identity.
- **No `as any` / no mocking** — clean. No mock-when-shouldn't issue.

### 2.5 `src/renderer/src/stores/tutorialStore.test.ts`

Cite production: `tutorialStore.ts` has `resetTour()` at L137-143 that
correctly resets to `{tourCompleted:false, tourStep:0, tourPaused:false,
tourActive:false, hintsShown:{}}`. The test file does NOT use it.

- **L5-14 `beforeEach`** — **hand-crafted setState drift**. Uses a
  literal `{tourActive, tourStep, tourCompleted, tourPaused,
  hintsShown}` object instead of calling `useTutorialStore.getState()
  .resetTour()` or `setState(getInitialState(), true)`. Exactly the
  anti-pattern plan-stores-A flagged for pdfStore (now fixed by Q06).
  If a new state field is added (e.g. `tourVariant`, `lastShownAt`),
  this fixture won't reset it. **Practice violation** — high priority,
  file as a practice-audit entry. Borderline finding if the missed
  field would cause an actual user-visible regression.
- **L23-26 `should not start tour if completed`** — sets
  `tourCompleted: true` via raw `setState` (slice merge). Production
  `startTour()` short-circuits on `get().tourCompleted` (L103). OK,
  but ALSO consider: production reads `tourCompleted` from
  `readHintsShown()`-adjacent localStorage at init (L95-99). The test
  clears localStorage at L6 but doesn't re-instantiate the store —
  the persisted check happened at module-load. **Practice violation**
  (test relies on cross-test module state).
- **L34-39 `should complete tour at last step`** — asserts
  `tourCompleted=true` and `tourActive=false`. Production also sets
  `tourStep:0` and `tourPaused:false` (L124). **Coverage gap /
  incomplete reset assertion**, same pattern as pdfStore Q04 fixed.
- **L41-45 `should skip tour and persist`** — only asserts
  `localStorage.getItem('rishi:tour-completed') === '1'`. Production
  may also clear `hintsShown` or update other persisted keys; test
  doesn't pin contract. **Practice observation**.
- **L47-52 `should reset tour`** — uses `resetTour()` (good!) but
  only asserts two fields. `resetTour()` sets 5 fields (L138-143).
  **Coverage gap / incomplete reset assertion** — same anti-pattern.
- **L54-57 `should dismiss hints`** — single hint id; no test that
  dismissing two hints accumulates (L154 spreads previous state).
  Borderline; **practice observation**.

---

## 3. Tester ID range

- **A011-A020** (10 IDs across 5 files = ~2 per file cap; in practice
  most testers will file 0-1 finding plus parity/practice notes).
- Reviewer-1 alternation per pilot §4.4: odd IDs (A011, A013, A015,
  A017, A019) → `team-reviewer`; even IDs (A012, A014, A016, A018,
  A020) → `feature-dev:code-reviewer`.

---

## 4. Test commands

From repo root:

```bash
pnpm --filter rishi-electron test src/renderer/src/stores/epubStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/pdfStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/prefsStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/selectionStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/tutorialStore.test.ts
```

Single test by name:

```bash
pnpm --filter rishi-electron test src/renderer/src/stores/tutorialStore.test.ts -t "should reset tour"
```

Flake check (≥3 runs) per pilot §5.6:

```bash
for i in 1 2 3; do pnpm --filter rishi-electron test <path> -t "<name>" || echo "run $i: FAIL"; done
```
