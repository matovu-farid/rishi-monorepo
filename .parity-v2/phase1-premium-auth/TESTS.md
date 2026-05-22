# Phase 1 Premium Auth Gating — TESTS (TDD red)

Date: 2026-05-22
Author: tester agent
Status: red — all 5 test files written, all fail at the import step (modules
don't yet exist or shared package export is missing). Coder follows next.

---

## 1. Files written

| # | Path | Suite | New tests | First-failure mode |
|---|---|---|---|---|
| 1 | `packages/shared/src/auth-gating/__tests__/should-gate.test.ts` | vitest | 4 | `Cannot find module '../shouldGate'` |
| 2 | `packages/shared/src/auth-gating/__tests__/feature-copy.test.ts` | vitest | 6 | `Cannot find module '../featureCopy'` |
| 3 | `apps/mobile/__tests__/hooks/useRequireAuth.test.ts` | jest | 4 | `Could not locate module @/components/auth/useRequireAuth` |
| 4 | `apps/mobile/__tests__/components/auth/PremiumFeatureSheet.test.tsx` | jest | 8 | `Could not locate module @/components/auth/PremiumFeatureSheet` |
| 5 | `apps/rishi-electron/src/renderer/src/components/auth/__tests__/PremiumFeatureDialog.test.tsx` | vitest | 5 | `Missing "./auth-gating" specifier in "@rishi/shared"` |

All five tests fail at the IMPORT step. None use `.skip()`.

---

## 2. Suite outputs (raw tail captured)

### 2.1 `pnpm -C packages/shared test` (red)

```
 ❯ src/auth-gating/__tests__/should-gate.test.ts (0 test)
 ❯ src/auth-gating/__tests__/feature-copy.test.ts (0 test)

⎯⎯⎯⎯⎯⎯ Failed Suites 2 ⎯⎯⎯⎯⎯⎯⎯

 FAIL  src/auth-gating/__tests__/feature-copy.test.ts
Error: Cannot find module '../featureCopy' …
 FAIL  src/auth-gating/__tests__/should-gate.test.ts
Error: Cannot find module '../shouldGate' …

 Test Files  2 failed | 33 passed (35)
      Tests  482 passed (482)
```

- Expected behaviour at red: 2 new failing suites; 482 prior passes intact.
- Pre-existing baseline still green (`482/482` of the suites that DO run).

### 2.2 mobile `jest` (red)

```
FAIL __tests__/components/auth/PremiumFeatureSheet.test.tsx
  ● Test suite failed to run
    Could not locate module @/components/auth/PremiumFeatureSheet …
FAIL __tests__/hooks/useRequireAuth.test.ts
  ● Test suite failed to run
    Could not locate module @/components/auth/useRequireAuth …

Test Suites: 5 failed, 76 passed, 81 total
Tests:       536 passed, 536 total
```

- Expected at red: 2 new failing suites (ours).
- The other 3 failing suites — `book-import/file-import.test.ts`,
  `book-import/url-import.test.ts`, and `vector.test.ts` — are
  pre-existing v1 baseline failures (expo-sqlite ESM transform issue,
  unrelated to this phase). Documented in the parity-v2 design note.

### 2.3 `pnpm -C apps/rishi-electron test` (red)

```
 ❯ src/renderer/src/components/auth/__tests__/PremiumFeatureDialog.test.tsx (0 test)
 FAIL  src/renderer/src/components/auth/__tests__/PremiumFeatureDialog.test.tsx
Error: Missing "./auth-gating" specifier in "@rishi/shared" package
```

- Expected at red: this suite is dead until the architect's coder pass adds
  the `"./auth-gating": "./src/auth-gating/index.ts"` entry to
  `packages/shared/package.json` AND replaces electron's `features.ts`
  with the shim that sources copy from `FEATURE_COPY`. Both items are
  in ARCH.md sections 1.6 and 2.1.
- Electron's other unrelated failures (localStorage undefined in
  `authStore.test.ts`, `tutorialStore.test.ts`,
  `WelcomeModal.test.tsx`, `ContextualHint.test.tsx`) are pre-existing
  baseline issues that pre-date Phase 1. They will be addressed by the
  ongoing electron stabilization track — not this phase.

---

## 3. Expected pass after implementation

After coder finishes ARCH.md's build order:

| Suite | New tests passing | Notes |
|---|---|---|
| shared `should-gate.test.ts` | 4/4 | Pure-function predicate; should never flake. |
| shared `feature-copy.test.ts` | 6/6 | Strings come from `FEATURE_COPY` which the coder ships in the same commit. |
| mobile `useRequireAuth.test.ts` | 4/4 | Hook becomes a `useCallback` over store selectors. The stable-ref test depends on `useCallback`'s memoization — if the implementation accidentally drops `useCallback`, the test catches it. |
| mobile `PremiumFeatureSheet.test.tsx` | 8/8 | Bottom sheet is stubbed; we assert on visible text + Pressable handlers. |
| electron `PremiumFeatureDialog.test.tsx` | 5/5 | Dialog component itself doesn't change — only the copy source via `features.ts` shim. |

Expected final totals after coder green:
- Shared: 488 passing (482 prior + 4 + 6 new — minus the 2 prior suite shells that ran 0 tests but counted as failures).
- Mobile: 540 passing on the new tests' two suites + 536 prior = 548 total tests (the 3 pre-existing suite failures remain on the baseline list).
- Electron: 5 new passing tests on the dialog suite; the prior 6 co-located `PremiumFeatureDialog.test.tsx` tests will likely need a rewrite by the coder because they assert on the OLD copy strings ("Listen to your books"); ARCH.md §2.1 changes those strings via `FEATURE_COPY`.

---

## 4. Test infrastructure adjustments

### 4.1 New mocks introduced

The `PremiumFeatureSheet.test.tsx` introduces 5 new mocks. None of them
modify existing mock setups; they are scoped to the test file.

| Mock target | Reason | File-scope |
|---|---|---|
| `@gorhom/bottom-sheet` | Pulls Reanimated worklets and GestureHandler; we render children inline so we can assert on `<Pressable>` handlers. | Single file. |
| `@expo/vector-icons/Ionicons` | The real package imports `expo-font` which expects an Expo runtime. We render a stub host node with `testID="ion-<name>"`. | Single file. |
| `expo-haptics` | Noop. The component fires haptics in side effects — we don't assert on them in Phase 1. | Single file. |
| `react-native-safe-area-context` | Returns zero insets so the sheet's layout math doesn't throw. | Single file. |
| Extended `react-native` mock | Adds `Platform.OS` (toggled via `__platformOS` module variable), `useColorScheme`, `AccessibilityInfo`, `ActivityIndicator`. Existing tests' `react-native` mocks don't include these — we re-declare in this file. | Single file. |

### 4.2 Selector-based store mock pattern

Both mobile tests mock `@/lib/stores/authStore` with a selector-call:

```ts
jest.mock('@/lib/stores/authStore', () => ({
  useAuthStore: <T,>(selector: (s: StoreShape) => T) => selector(storeState),
}))
```

This matches the real Zustand store's call signature and lets a per-test
`storeState` mutation flow into selector-based hook reads (the hook calls
`useAuthStore((s) => s.isAuthenticated)`). The component under test does
not need to know it's being mocked.

### 4.3 File naming

- `useRequireAuth.test.ts` is intentionally `.ts` (no JSX), per the
  prompt's spec. The Harness component is constructed via
  `React.createElement` so the file compiles under
  `tsconfig.jest.json`'s `jsx: 'react'` without requiring TSX.
- `PremiumFeatureSheet.test.tsx` uses TSX because it asserts on
  rendered JSX trees and benefits from inline element syntax.

### 4.4 Electron test placement

`PremiumFeatureDialog.test.tsx` goes under
`apps/rishi-electron/src/renderer/src/components/auth/__tests__/`
(matching the existing convention in
`components/reader/__tests__`, `components/epub/__tests__`, etc.).

The existing co-located `PremiumFeatureDialog.test.tsx` next to the
component remains untouched in this phase; the coder will either delete
it or rewrite it to consume `FEATURE_COPY` as part of the green commit
that ships the new copy.

---

## 5. Verification gate

Before the coder moves on, all three of:

1. `pnpm -C packages/shared test` — green (488+ passing).
2. `pnpm -C apps/mobile test` — green on the two new suites
   (`__tests__/hooks/useRequireAuth.test.ts`,
   `__tests__/components/auth/PremiumFeatureSheet.test.tsx`). The
   3 pre-existing book-import / vector failures stay on the baseline.
3. `pnpm -C apps/rishi-electron typecheck` — green. (The electron test
   suite already has pre-existing failures unrelated to this phase;
   the PHASE-1 acceptance bar is typecheck-clean + our new dialog
   test passing once `auth-gating` is wired.)

The TDD pinch-point this file enforces: a coder who tries to ship the
gate without the shared FEATURE_COPY, or without the optimistic
cold-start branch in `useRequireAuth`, will fail at least one of the
specific tests above and cannot move on.
