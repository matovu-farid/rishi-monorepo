# Batch 6 — Settings, File Association, Onboarding

Date: 2026-05-21
Scope: G29 (settings) + G27 (file association) + G28 (onboarding).
Parallel with: Batch 7 (EPUB reader / TTS / bookmarks).

## Commits

| Gap | SHA | Title |
|-----|-----|-------|
| G29 | `af416148` | feat(mobile/G29): add Settings screen with account, voice, about sections |
| G27 | `38bf8025` | feat(mobile/G27): add OS file association for EPUB/PDF/MOBI/AZW3/DJVU |
| G28 | `dbdea5d5` | feat(mobile/G28): onboarding tutorial with spotlight overlay |

## Files added / modified

### G29 — Settings
- `apps/mobile/__tests__/settings/settings.test.tsx` (new — 10 tests)
- `apps/mobile/app/(tabs)/settings/index.tsx` (new)
- `apps/mobile/app/(tabs)/_layout.tsx` (modified — settings tab; explore hidden)
- `apps/mobile/components/settings/LanguagePicker.tsx` (new)
- `apps/mobile/jest.setup.ts` (new — IS_REACT_ACT_ENVIRONMENT)
- `apps/mobile/jest.config.js` (modified — points to tsconfig.jest.json)
- `apps/mobile/tsconfig.jest.json` (new — jsx: react-jsx for tests)
- `apps/mobile/package.json` / `package-lock.json` (add @testing-library/react-native + react-test-renderer)

### G27 — File association
- `apps/mobile/__tests__/file-handler.test.ts` (new — 15 tests)
- `apps/mobile/lib/file-handler.ts` (new)
- `apps/mobile/app/_layout.tsx` (modified — wire incoming-file URL handler)
- `apps/mobile/app.json` (modified — iOS CFBundleDocumentTypes + UT exports; Android intentFilters)

### G28 — Onboarding
- `apps/mobile/__tests__/onboarding/tour-state.test.ts` (new — 7 tests)
- `apps/mobile/__tests__/onboarding/tour-render.test.tsx` (new — 7 tests)
- `apps/mobile/lib/onboarding/registry.ts` (new)
- `apps/mobile/lib/onboarding/useTourTarget.ts` (new)
- `apps/mobile/components/onboarding/TourProvider.tsx` (new)
- `apps/mobile/components/onboarding/SpotlightOverlay.tsx` (new)
- `apps/mobile/components/onboarding/TourTooltip.tsx` (new)
- `apps/mobile/app/(tabs)/_layout.tsx` (modified — mount TourProvider; kick off first-launch tour)
- `apps/mobile/app/(tabs)/index.tsx` (modified — register `import-books` + `book-grid` targets)
- `apps/mobile/components/LibraryEmptyState.tsx` (modified — accept onLayout passthrough for tour targets)

## Test counts

| Gap | New tests | Status |
|-----|-----------|--------|
| G29 | 10 | all passing |
| G27 | 15 | all passing |
| G28 | 14 | all passing |
| **Total** | **39** | **all passing** |

Pre-existing failures (unchanged baseline):
- `__tests__/guardrails.test.ts` — 1 test failing (mock issue, pre-Batch-6)
- `__tests__/vector.test.ts` — 1 test failing (execSync expectation, pre-Batch-6)

## Verification gate results

1. `npx tsc --noEmit` in `apps/mobile`: clean for all Batch-6 files. Baseline pre-existing errors unchanged (10 files: 3 test files + 7 source files in `chunker.ts`, `tts-queue.ts`, `useVoiceInput.ts`, etc.). No new errors introduced by my work.
2. `npx jest` in `apps/mobile`: **50 suites pass, 2 fail (pre-existing)** — 360 tests pass, 2 fail. Up from baseline 40 passing suites; the +10 comes from my +3 suites and Batch-7's added suites.
3. `pnpm -C packages/shared test`: **474 / 474 passing**, unchanged.
4. `pnpm -C apps/rishi-electron typecheck`: clean.

## Packages installed

| Package | Version | Rationale |
|---------|---------|-----------|
| `@testing-library/react-native` | `^13.3.3` | Asked-for by the brief. Installed but NOT used yet — settings/onboarding tests use `react-test-renderer` directly (lighter, no jest-expo preset needed). Available for future render-style tests. |
| `react-test-renderer` | `^19.1.0` | Required peer for `@testing-library/react-native` AND used directly by the new tests to render `<SettingsScreen />` and `<TourProvider />` without needing a real RN host. Matches React 19.1.0 already in deps. |

**Did NOT install**:
- `react-native-copilot` — chose a custom Reanimated-free overlay instead. The tour has only 3 fixed steps; the existing `tutorialStore` already handles routing + completion. Custom impl is ~100 lines and avoids a JSI / native-module dependency for a tiny feature.
- `expo-application` — `expo-constants` (already in deps) exposes `expoConfig.version` which is enough for "what version am I running" in About. expo-application is needed only for native build numbers, which aren't surfaced in the UI yet.

## Design choices

### G29 — Settings

- **Language picker via `Alert.alert`.** Avoids pulling in `@react-native-picker/picker` (native module) for a one-off settings row. The picker exposes `value`, `options`, `onValueChange` via TouchableOpacity passthrough so tests can drive selection without going through the native Alert.
- **`tsconfig.jest.json` swap to `jsx: 'react-jsx'`.** The project tsconfig sets `jsx: 'react-native'` (Metro keeps JSX), which the Jest VM can't execute. The override only affects the test build — Metro / production are unchanged.
- **Settings tab replaces Explore.** Explore was the Expo template's boilerplate tab; per the gap-analysis recommendation it's hidden (`href: null`) but kept in the router tree so any persisted nav state referencing it doesn't 404.
- **Sign-out clears auth store optimistically.** The settings button calls `lib/auth.signOut()` (which deletes the secure-store bearer) and then `clearSession()` in a `finally` block so the user always ends up signed-out client-side, even if the secure-store delete throws.

### G27 — File association

- **Single `handleIncomingFile(url)` entry point for cold + warm starts.** `app/_layout.tsx` handles both `getInitialURL()` (cold start from Open With…) and `addEventListener('url')` (warm start). Auth deep links are filtered out by `isFileUrl()` so we never double-handle the sign-in callback.
- **MIME types + path patterns on Android.** Some file pickers omit MIME types; the second intent-filter group keys on `pathPattern` (`.*\.epub` etc.) to catch those.
- **iOS UTI strategy.** Uses Apple's system-wide UTIs where they exist (`org.idpf.epub-container`, `com.adobe.pdf`); declares `org.rishi.mobile.mobi/.azw3/.djvu` exports for the formats Apple doesn't ship UTIs for. `LSHandlerRank=Alternate` so Books.app / Quick Look stay as system defaults — users still need to "Open With… Rishi" to hand a file off.
- **Shared service handles the copy.** `handleIncomingFile` doesn't duplicate the FS plumbing in `file-import.ts`; it constructs `createMobileBookImportService(...)` with `(bookId, format, title)` and lets the shared FsPort copy bytes into `books/<bookId>/book.<ext>`.

### G28 — Onboarding

- **Reanimated-free overlay.** Four `<View>` rectangles arranged around the target produce the dimmed cut-out. Avoids needing `react-native-svg` (not installed) and keeps the tour code testable without faking SVG.
- **Tour-target registry over `data-tour` selectors.** RN has no DOM, so screens register their target rect via `onLayout` → `measureInWindow` → `registerTourTarget(id, layout)`. The provider subscribes via a tiny pub-sub and re-renders when a new layout comes in.
- **Layout-aware bail.** If the active step's target hasn't registered yet (screen is mid-mount or user navigated to the wrong route), the overlay renders `null` rather than painting over an unknown rect. Once the target registers, the provider wakes up via the subscribe callback.
- **`ai-chat` target deferred.** The third tour step targets the AI chat button on the reader screen. That screen is in Batch 7's file scope (`app/reader/**`) — I left the step in `TOUR_STEPS` (already there from Batch 1B) but did NOT add target registration code to the reader. The tour's existing `routePrefix: '/books'` logic will pause the tour until `ai-chat` registers, so Batch 7 can wire it up later by calling `useTourTargetLayout('ai-chat')` in the reader's chat button.

## Scope boundary deviations

None. All G29 / G27 / G28 work stayed within the Batch-6 file scope. The only "shared" file I touched (`app/(tabs)/_layout.tsx`) is explicitly listed in the Batch-6 scope. I did NOT touch any of Batch-7's file scopes (`app/reader/**`, `lib/tts/**`, EPUB components).

## Auto-fixed deviations during execution

None — each gap implemented cleanly off its TDD red-green-refactor cycle. No bug fixes, missing-functionality additions, or blocker fixes were necessary.

## Follow-up recommendations

1. **Wire `ai-chat` target in Batch 7's reader screen.** Add `useTourTargetLayout('ai-chat')` to the AI chat button (or floating orb if/when G31 lands). The tour will then complete properly on first launch.
2. **Add expo-application later if native version codes are needed.** App version is currently sourced from `expo-constants.expoConfig.version`. That's fine for v1 but won't expose iOS build number / Android versionCode.
3. **Consider `react-native-haptic-feedback` on tour Next/Skip taps.** Mirrors the electron experience but adds a dep — defer until UX feedback.
4. **Verify Open-With on Android 13+.** Newer Android requires `<queries>` declarations for `ACTION_VIEW` discovery — we may need to add those in `expo.android.queries` after a real-device test. iOS should be fine as-is.
