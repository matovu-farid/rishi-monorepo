# Batch 9 — final test-cleanup pass

Closes out the parity orchestration after Batch 8. Goal: take the two
known-bad mobile tests to green, modernize the deprecated test surfaces
that were emitting console.error spam on every run, and drive
`apps/mobile`'s `tsc --noEmit` from 20 errors to 0.

The Electron app was explicitly **not** modified during this batch.

## Verification-gate snapshot

| Gate                                              | Before batch        | After batch     |
| ------------------------------------------------- | ------------------- | --------------- |
| `npx tsc --noEmit` (apps/mobile)                  | 20 errors           | **0 errors**    |
| `npx jest` (apps/mobile)                          | 532/534 (2 fail)    | **534/534**     |
| `pnpm -C packages/shared test`                    | 482/482             | 482/482         |
| `pnpm -C apps/rishi-electron typecheck`           | clean               | clean (no edit) |
| `pnpm -C workers/worker test`                     | 22/22               | 22/22           |

## Target-by-target summary

### 1. Two baseline jest failures → fixed

**`__tests__/vector.test.ts` — `deleteBookChunks` calls execSync for DELETE on both tables**

- **Failure:** Test asserted `mockExecSync.toHaveBeenCalledTimes(2)`; received `0`.
- **Root cause:** Commit `756a1e2c` ("fix: use parameterized SQL queries
  in mobile vector store") hardened `deleteBookChunks` to use
  `runSync(sql, [bookId])` instead of `execSync(\`...${bookId}...\`)` —
  preventing SQL injection. The implementation was correct; the test was
  still asserting the old (vulnerable) contract.
- **Fix:** Re-assert against `mockRunSync`, verify the bookId travels via
  the params array (`expect(firstSql).not.toContain('book-1')` plus
  `expect(firstParams).toEqual(['book-1'])`). Also re-typed the mocks
  (`jest.Mock<R, unknown[]>`) so the existing `as string` assertions
  stop tripping TS strict mode (8 TS2352/TS2493 errors gone in the same
  file).
- **Files:** `apps/mobile/__tests__/vector.test.ts`
- **Commit:** `8d52162f` — *test(mobile): update vector test to match parameterized runSync contract*

**`__tests__/guardrails.test.ts` — returns true when output is off-topic**

- **Failure:** Test expected `true` (tripwire fires); received `false`. Test #3 in the off-topic scenario.
- **Root cause:** Commit `f3381fc0` switched `guardrails.ts` from
  `response.text()` to `response.json() as string` because the worker
  wraps the LLM output in `c.json(text)`. The test mocks were still
  providing a `.text()` method but not `.json()`, so `await
  response.json()` threw and the catch-block fail-open returned `false`
  for every call. All five tests were silently routing through the
  catch — the only one that observed a wrong outcome was the off-topic
  test (which expects `true` instead of the fail-open `false`).
- **Fix:** Introduced `mockLlmJsonResponse({ isRelevantToBook,
  isSmallTalk })` that returns `{ ok: true, json: async () =>
  JSON.stringify(...) }`, mirroring the worker's actual envelope. All
  five tests now exercise the real classification branch.
- **Files:** `apps/mobile/__tests__/guardrails.test.ts`
- **Commit:** `f74afd75` — *test(mobile): align guardrails mocks with worker c.json(text) envelope*

### 2. Deprecated xstate v5 snapshot helpers → modernized

**`packages/shared/src/machines/playerMachine.recovery.test.ts`**

- **Issue:** File imported `getInitialSnapshot` and `getNextSnapshot`
  from `xstate` — both `@deprecated` in v5. The unit tests at the
  bottom of the file already used `createActor + send` (the supported
  v5 API), but the BFS proof at the top still used the deprecated
  helpers.
- **Fix:** Dropped the deprecated imports. Added two file-local helpers
  (`getInitialSnapshot()` and `getNextSnapshotFor(prev, evt)`) that
  rehydrate an actor at the given snapshot via `createActor(machine,
  { snapshot: prev })`, start it, send the event, capture the resulting
  snapshot, then stop the actor synchronously. Stopping is important:
  it prevents actors with `after` timers from leaking across BFS
  steps. Bulk-replaced every call site. All 9 tests in the file still
  pass.
- **Files:** `packages/shared/src/machines/playerMachine.recovery.test.ts`
- **Commit:** `f594cade` — *test(shared): replace deprecated xstate v5 snapshot helpers with createActor*

### 3. Deprecated `react-test-renderer` → noise suppressed

**Investigation:** RTR is `@deprecated` as a whole package in React 19.
`@testing-library/react-native` depends on RTR internally (verified in
`node_modules/@testing-library/react-native/build/render-act.js`), so
swapping to RNTL doesn't avoid the warning either. The jest config uses
`testEnvironment: 'node'` (not `jest-expo`), and there is no first-party
React 19 RN test renderer replacement yet.

**Fix:**
- Imported `act` from `react` (not from `react-test-renderer`) in the
  three eagerly-imported RTR test files. At runtime `RTR.act ===
  React.act` is provably true (verified via `node -e
  "console.log(require('react-test-renderer').act ===
  require('react').act)"`), but importing from `react` removes the
  deprecation-tagged identifier from the call site.
- Added a focused console.error filter in `apps/mobile/jest.setup.ts`
  that drops the package-level `react-test-renderer is deprecated`
  banner emitted by RTR's `create()` / `unmount()` host wrappers. The
  filter is intentionally narrow: it only matches that one specific
  string; every other console.error continues to flow so real failures
  stay visible.
- Did **not** rewrite `settings.test.tsx` / `tour-render.test.tsx` to
  use a different `act` import — both consume `TestRenderer.act` lazily
  via `require('react-test-renderer')`, which evaluates to the same
  function as `React.act`. Rewriting would be pure churn.

**Files:**
- `apps/mobile/__tests__/voice-chat/page-capture-refs.test.tsx`
- `apps/mobile/__tests__/tts/visual-cue.test.tsx`
- `apps/mobile/__tests__/highlights/undo-snackbar.test.tsx`
- `apps/mobile/jest.setup.ts`

**Commit:** `c9bf958f` — *test(mobile): silence react-test-renderer package deprecation banner*

### 4. SDK 54 surface changes — expo-file-system + expo-audio

**`lib/rag/chunker.ts` (and 5 chunker tests)**

- **Issue:** `expo-file-system` v19 (SDK 54) dropped the top-level
  `readAsStringAsync` + `EncodingType` exports. They now live under
  `expo-file-system/legacy`. The new `File` / `Paths` API doesn't yet
  expose a base64-as-string read mode that we can plumb into jszip
  (EPUB) or the shared MOBI parser, so the migration is "switch to the
  /legacy subpath" rather than "rewrite to the new File API".
- **Fix:** Switched `chunker.ts` to `import * as FileSystem from
  'expo-file-system/legacy'`. Updated `__tests__/chunker.test.ts` plus
  the five `__tests__/rag/chunker-*.test.ts` files to mock both
  `expo-file-system/legacy` (the production import path) AND
  `expo-file-system` (in case any transitive caller still touches the
  top-level). Each `jest.mock` factory had to be inlined because
  `jest.mock` is hoisted above any local `const`.
- **Files:**
  - `apps/mobile/lib/rag/chunker.ts`
  - `apps/mobile/__tests__/chunker.test.ts`
  - `apps/mobile/__tests__/rag/chunker-{azw3,djvu,epub,mobi,pdf}.test.ts`
- **Commit:** `f243d1c6` — *fix(mobile): import expo-file-system/legacy in chunker for SDK 54*

**`hooks/useVoiceInput.ts` (and matching test)**

- **Issue:** Two SDK 54 changes hit this file:
  1. `expo-audio` renamed the recording-permission helper from
     `requestPermissionsAsync` → `requestRecordingPermissionsAsync`.
     The old name no longer exists (`getRecordingPermissionsAsync` +
     `requestRecordingPermissionsAsync` are the new pair).
  2. `expo-file-system` legacy migration as above.
- **Fix:** Updated the hook to use `requestRecordingPermissionsAsync`
  from `expo-audio` and import FileSystem from `expo-file-system/legacy`.
  Updated `__tests__/tts/voice-input.test.ts` to mock the new symbol
  name and both legacy + top-level file-system paths.
- **Files:**
  - `apps/mobile/hooks/useVoiceInput.ts`
  - `apps/mobile/__tests__/tts/voice-input.test.ts`
- **Commit:** `f4295c4c` — *fix(mobile): use SDK 54 expo-audio + expo-file-system/legacy in useVoiceInput*

### 5. Residual tsc errors → fixed

All five remaining tsc errors after the SDK 54 work were resolved in one
commit:

| File                                          | Issue                                                                                                                                     | Fix                                                                                                          |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `lib/reader-settings.ts`                      | Imported `getDb` from `@/lib/db`, which only exports `rawDb` plus `db` (drizzle).                                                         | Use `rawDb` directly (matches every other raw-SQL caller in the app). The pre-drizzle `settings` table is unaffected. |
| `hooks/useEmbeddingModel.ts`                  | `react-native-executorch.forward()` now returns `Float32Array`; previous `as number[]` was a no-overlap cast.                             | Cast through `unknown` and materialize via `Array.from(result as Float32Array)`, with an `Array.isArray` fast-path. |
| `components/ChatInput.tsx`                    | `maxNumberOfLines={4}` — `TextInput` has no such prop.                                                                                    | Replace with the supported `numberOfLines={4}`.                                                              |
| `components/UrlImportSheet.tsx`               | `onPress={handleDownload}` where `handleDownload` accepts `(textOverride?: string)`. TS rejected because `GestureResponderEvent` is not `string`. | Wrap in a no-arg lambda: `onPress={() => void handleDownload()}`. The override is still used by `onSubmitEditing`. |
| `__tests__/conversation.test.ts`              | `(convs[0] as Record<string, unknown>).isDirty` — Conversation has no string index sig.                                                   | Cast through `unknown` first.                                                                                |

**Commit:** `8e595b44` — *fix(mobile): resolve residual tsc errors after SDK 54 surfaces*

## Items considered but **not** addressed (deferred / out-of-scope)

The user's plan mentioned a few items that didn't appear in the current
tsc output, indicating they were already resolved by an earlier batch.
Documented here so the next pass doesn't re-investigate them:

- **`apps/mobile/app/_layout.tsx:12` — `TourProvider` declared but
  never read.** No `TourProvider` import exists in the current
  `_layout.tsx`. The onboarding tour is mounted from
  `(tabs)/_layout.tsx` instead. Nothing to do.
- **`apps/mobile/app/(tabs)/settings/index.tsx:141` — `next` parameter
  implicit any.** Current code has `onValueChange={(next) => void
  setVoiceChatLanguage(next as AllowedLanguage)}` and tsc doesn't flag
  it (the surrounding `options: { value: AllowedLanguage }[]` narrows
  `next` correctly). No error in the current run.
- **`apps/mobile/components/LibraryEmptyState` props mismatch with
  `index.tsx:137`.** The component already declares `importButtonProps`
  plus `containerProps` in its `LibraryEmptyStateProps` interface and
  the index uses them correctly. No error.
- **`@/components/settings/LanguagePicker` import.** The file exists at
  the path tsc resolves; `tsconfig.json` already maps `@/*` to project
  root and jest agrees. No error in the current run.

## Files modified

```
apps/mobile/jest.setup.ts
apps/mobile/components/ChatInput.tsx
apps/mobile/components/UrlImportSheet.tsx
apps/mobile/hooks/useEmbeddingModel.ts
apps/mobile/hooks/useVoiceInput.ts
apps/mobile/lib/rag/chunker.ts
apps/mobile/lib/reader-settings.ts
apps/mobile/__tests__/chunker.test.ts
apps/mobile/__tests__/conversation.test.ts
apps/mobile/__tests__/guardrails.test.ts
apps/mobile/__tests__/highlights/undo-snackbar.test.tsx
apps/mobile/__tests__/rag/chunker-azw3.test.ts
apps/mobile/__tests__/rag/chunker-djvu.test.ts
apps/mobile/__tests__/rag/chunker-epub.test.ts
apps/mobile/__tests__/rag/chunker-mobi.test.ts
apps/mobile/__tests__/rag/chunker-pdf.test.ts
apps/mobile/__tests__/tts/visual-cue.test.tsx
apps/mobile/__tests__/tts/voice-input.test.ts
apps/mobile/__tests__/vector.test.ts
apps/mobile/__tests__/voice-chat/page-capture-refs.test.tsx
packages/shared/src/machines/playerMachine.recovery.test.ts
```

## Commit log (oldest → newest)

```
8d52162f test(mobile): update vector test to match parameterized runSync contract
f74afd75 test(mobile): align guardrails mocks with worker c.json(text) envelope
f594cade test(shared): replace deprecated xstate v5 snapshot helpers with createActor
c9bf958f test(mobile): silence react-test-renderer package deprecation banner
f243d1c6 fix(mobile): import expo-file-system/legacy in chunker for SDK 54
f4295c4c fix(mobile): use SDK 54 expo-audio + expo-file-system/legacy in useVoiceInput
8e595b44 fix(mobile): resolve residual tsc errors after SDK 54 surfaces
```

## Residual concerns / future work

- **`jest` reports "A worker process has failed to exit gracefully"**
  at the end of the mobile suite. The cause is the existing
  `useUndoSnackbar` H2-02 fake-timers test holding a small handle past
  `afterEach`; it has been there since Batch 7. Not introduced by this
  batch; out of scope.
- **`react-test-renderer` is still in the dep tree.** No first-party RN
  replacement exists today. We track this as a watch-item: when
  `@testing-library/react-native` ships a non-RTR renderer (or when
  Expo lands an RN React 19-compatible test renderer), the 5 RTR test
  files should migrate together. Until then, the deprecation banner is
  suppressed and the underlying `act` API used in tests is sourced
  from `react` so it is forward-compatible.
- **`expo-file-system` legacy migration.** The mobile app still uses
  the deprecated `/legacy` subpath for base64 reads in chunker plus
  voice-input. Migrating to the new `File` / `Paths` API requires
  either (a) jszip accepting Uint8Array directly (it does — but the
  chunker code paths assume a base64 string today), or (b) plumbing
  typed arrays through the worker audio transcribe path. Both are
  non-trivial and were not in scope for this cleanup batch.
