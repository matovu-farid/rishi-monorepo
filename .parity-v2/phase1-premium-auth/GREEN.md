# Phase 1 Premium Auth Gating — GREEN (TDD done)

Date: 2026-05-22
Author: coder agent
Status: green — all 5 new test files pass; baselines preserved.

---

## 1. Final test counts

### `pnpm -C packages/shared test`

```
 Test Files  35 passed (35)
      Tests  492 passed (492)
```

Baseline: 482/482. Phase 1 added 10 new tests (4 in `should-gate.test.ts`,
6 in `feature-copy.test.ts`). Final: 492/492.

### `pnpm -C apps/mobile test`

```
Test Suites: 3 failed, 78 passed, 81 total
Tests:       548 passed, 548 total
```

Baseline: 536/536 (with 3 pre-existing module-level suite errors:
`book-import/file-import.test.ts`, `book-import/url-import.test.ts`,
`vector.test.ts` — all the expo-sqlite ESM-transform issue documented in
the parity-v2 design notes). Phase 1 added 12 new tests (4 in
`useRequireAuth.test.ts`, 8 in `PremiumFeatureSheet.test.tsx`).
Final: 548/548 passing, same 3 pre-existing module-load failures.

### `pnpm -C apps/rishi-electron typecheck`

Clean (both `typecheck:node` and `typecheck:web`).

### `pnpm -C apps/rishi-electron test src/renderer/src/components/auth/__tests__/PremiumFeatureDialog.test.tsx src/renderer/src/components/auth/features.test.ts`

```
 Test Files  2 passed (2)
      Tests  19 passed (19)
```

Phase 1's new electron dialog suite (5 tests) plus the rewritten features
config suite (14 tests after the key rename). The pre-existing WelcomeModal
suite failure (localStorage undefined) is pre-Phase-1 baseline noise.

---

## 2. Commits

| # | SHA | Subject |
|---|---|---|
| A | `0b473f05` | feat(shared): auth-gating package — PremiumFeature, FEATURE_COPY, shouldGate |
| B | `369af9cc` | refactor(electron): wire features.ts to shared auth-gating, rename feature keys |
| C | `26d55f46` | feat(mobile): premiumGate slice in authStore |
| D | `79fa41e0` | feat(mobile): useRequireAuth hook + PremiumFeatureSheet component |
| E | `8a4e30fb` | feat(mobile): wire premium gate to TTS, voice, AI chat call sites |

Five stages, atomic commits, no `--no-verify`, no hook bypasses.

---

## 3. Files created (8)

- `packages/shared/src/auth-gating/types.ts`
- `packages/shared/src/auth-gating/featureCopy.ts`
- `packages/shared/src/auth-gating/shouldGate.ts`
- `packages/shared/src/auth-gating/index.ts`
- `apps/mobile/components/auth/useRequireAuth.ts`
- `apps/mobile/components/auth/PremiumFeatureSheet.tsx`

## 4. Files modified (9)

- `packages/shared/src/index.ts`
- `packages/shared/package.json`
- `apps/rishi-electron/src/renderer/src/components/auth/features.ts`
- `apps/rishi-electron/src/renderer/src/components/auth/features.test.ts`
- `apps/rishi-electron/src/renderer/src/hooks/reader/useCommonMenuHandlers.ts`
- `apps/rishi-electron/src/renderer/src/components/chat/VoiceChatLauncher.tsx`
- `apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx`
- `apps/mobile/lib/stores/authStore.ts`
- `apps/mobile/app/_layout.tsx`
- `apps/mobile/components/TTSControls.tsx`
- `apps/mobile/app/reader/[id].tsx`
- `apps/mobile/app/chat/[bookId].tsx`
- `apps/mobile/app/(tabs)/chat.tsx`
- `apps/mobile/__tests__/components/auth/PremiumFeatureSheet.test.tsx` (red-phase TS-error fixes per prompt)

## 5. Files deleted (1)

- `apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.test.tsx` — the
  co-located test asserted on the old `'chat'` key + old copy strings; superseded by
  `apps/rishi-electron/src/renderer/src/components/auth/__tests__/PremiumFeatureDialog.test.tsx`
  (the new red-phase suite). Documented in TESTS.md §4.4 as either-delete-or-rewrite.

---

## 6. Deviations from ARCH.md

None functional. Three minor deltas worth noting:

1. **PremiumFeatureSheet early-return.** ARCH §9's skeleton returns the
   BottomSheet unconditionally (with `index={-1}`) and relied on the
   sheet's own visibility for the closed state. The new
   `PremiumFeatureSheet.test.tsx` test "renders no visible feature copy
   when premiumGateOpen is false" requires the title NOT to be in the
   render tree when `open === false` (the test's `@gorhom/bottom-sheet`
   mock renders children inline). So the implementation does an
   `if (!open || !feature) return null` early-exit before rendering the
   BottomSheet. Functionally identical in the real app since the sheet
   is animated open/closed by the store-driven `useEffect` either way.

2. **`features.test.ts` rewritten.** ARCH did not list it among files to
   touch, but it was asserting on the old `'chat'` key, the old title
   `'Listen to your books'`, and the old description copy. After the
   rename + copy change in Stage B it would fail. Rewrote to pin against
   the new shape + FEATURE_COPY references. Net coverage change: same
   surface area on the new key set.

3. **Co-located dialog test deleted.** Per TESTS.md §4.4 (coder may delete
   or rewrite). Deletion is the cleaner choice since the new
   `__tests__/PremiumFeatureDialog.test.tsx` covers the same surface with
   the updated copy contract.

No behavioural drift introduced. Mobile UX is now wired exactly as ARCH §3
and §4 spec'd; electron renders the same dialog with the same flow,
sourcing copy from the shared package.
