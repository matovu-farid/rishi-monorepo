# Phase 3 — Reader UI Redesign: REVIEW.md

Reviewer: Claude (Opus 4.7)
Date: 2026-05-22
Range: `520bbc61..HEAD` (9 commits)

---

## Verdict

**SHIP-WITH-FIXES**

The architecture is sound, all 12 red tests pass, the 4 readers all route through `<ReaderShell>`, `ReaderToolbar.tsx` is gone, mobile typecheck is clean, electron typecheck is clean, and 618/618 jest tests pass. R3 is correctly fixed for MOBI/DJVU. R2 (TTSControls z-fix) is correctly wired through context.

Two concrete issues to address before broad rollout — neither blocks the Phase 4 hand-off but both should be fixed in a follow-up before declaring "Done":

1. PDF reader is missing the same R3 TTS/realtime auto-hide pause that MOBI/DJVU got — net-new bug introduced by Phase 3.
2. PDF Detox `reader-next-page-btn` test now races a 3s auto-hide timer that didn't exist before.

---

## Critical findings

### 🟡 Important — PDF screen omits `ttsActive` / `realtimeActive` props to ReaderShell

**File:** `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/app/reader/pdf/[id].tsx:457-471`

The MOBI and DJVU screens were updated for R3 to pass `ttsActive={ttsActive}` and `realtimeActive={realtimeStatus !== 'idle'}` to `<ReaderShell>`, which gates ReaderShell's auto-hide timer. PDF does not — the `<ReaderShell ...>` block passes neither prop:

```tsx
<ReaderShell
  title={book.title}
  format="pdf"
  onBack={handleBack}
  progress={progressForShell}
  initialToolbarVisible={true}
  centerOverride={pdfNavCluster}
  sheets={{ noteEditor: true }}
  // ⛔ no ttsActive, no realtimeActive
  ...
>
```

`realtimeStatus` is already in scope at `pdf/[id].tsx:101`, and PDF mounts `<TTSControls/>` (`pdf/[id].tsx:599`), so the player state is observable. This means: start TTS on a PDF, wait 3s, the bottom bar hides regardless of TTS state — the same R3 bug ARCH §9 said is "FIXED" everywhere.

**Fix:** add `usePlayerStore((s) => s.playingState)` (or compute `ttsActive` from it), then pass both props to `<ReaderShell>`:

```tsx
const playingState = usePlayerStore((s) => s.playingState)
const ttsActive = playingState !== 'idle'
// ...
<ReaderShell
  ttsActive={ttsActive}
  realtimeActive={realtimeStatus !== 'idle'}
  // also wire onTTSPress + ttsButtonActive for consistency with MOBI/DJVU
  ...
>
```

### 🟡 Important — PDF Detox `reader-next-page-btn` now races a 3s auto-hide timer

**File:** `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/app/reader/pdf/[id].tsx:462` + `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/e2e/reader-pdf.test.ts:57-67`

Pre-Phase-3, the PDF reader had `useState(true)` for `toolbarVisible` with NO auto-hide timer (`git show 520bbc61:apps/mobile/app/reader/pdf/[id].tsx` confirms). The Detox test relies on this: it taps `reader-next-page-btn` directly without first revealing the toolbar.

Post-Phase-3, ReaderShell's auto-hide effect (`ReaderShell.tsx:198-214`) fires at mount when `initialToolbarVisible=true && !ttsActive && !realtimeActive && !anySheetOpen`. The timer arms immediately, and after 3000ms the bottom bar transitions to `pointerEvents='none'` (`ReaderBottomBar.tsx:73`). If the simulator pause between `waitFor(by.id('pdf-reader'))` and `element(by.id('reader-next-page-btn')).tap()` exceeds 3s on a slow CI runner, the tap silently lands on a non-interactive view and the assertion `expect(after).not.toBe(before)` fails.

The MOBI test compensates with an explicit `element(by.id('reader-toggle-toolbar')).tap()` + `setTimeout 2000` reveal step (`reader-mobi.test.ts:77-84`), but the PDF test doesn't. This is a latent flake that may not surface on a fast Mac but will on CI.

**Fix:** either (a) update `reader-pdf.test.ts` to tap `reader-toggle-toolbar` first like MOBI does, or (b) skip the auto-hide for `initialToolbarVisible=true` until the user has interacted at least once.

---

## Confirmed correct

- All 13 critical Detox testIDs preserved at locations enumerated in ARCH §9 R1. Verified:
  - `reader-epub` at `app/reader/[id].tsx:585`, `reader-position-indicator` at `:647`
  - `pdf-reader` at `pdf/[id].tsx:456`, `reader-toggle-toolbar` at `:668`, `reader-next-page-btn` at `:716`, `reader-position-indicator` at `:480`
  - `mobi-reader` at `mobi/[id].tsx:449`, `reader-toggle-toolbar` at `:508`, `reader-next-page-btn` at `:551`, `reader-position-indicator` at `:464`
  - `djvu-reader` at `djvu/[id].tsx:376`, `reader-toggle-toolbar` at `:438` (new), `reader-next-page-btn` at `:507`, `reader-position-indicator` at `:391`
  - `search-input` / `search-no-results` / `search-prompt` at `components/epub/SearchPanel.tsx:109/172/181`
  - `bookmarks-empty` / `bookmark-row-${id}` at `components/epub/BookmarksList.tsx:92/143`
- EPUB e2e (`e2e/reader-epub.test.ts`) does NOT target `reader-toggle-toolbar` → GREEN.md deviation #6 (deferred hidden EPUB accessory) is non-blocking. The only Detox specs using that testID are MOBI + PDF, both of which still find it.
- R3 auto-hide fix correctly applied: MOBI (`mobi/[id].tsx:456-457`) and DJVU (`djvu/[id].tsx:383-384`) both pass `ttsActive` and `realtimeActive={realtimeStatus !== 'idle'}`. Per-screen auto-hide useEffects are gone (`grep "setToolbar\|setTimeout.*toolbar" mobi/[id].tsx djvu/[id].tsx` returns empty).
- R2 TTSControls z-fix in place: `TTSControls.tsx:32` consumes `ReaderShellContext`, `BOTTOM_BAR_HEIGHT = 44` on line 12, `bottom: insets.bottom + 16 + (bottomBarVisible ? BOTTOM_BAR_HEIGHT : 0)` on line 72-73. Default context value `{ bottomBarVisible: false }` published in `ReaderShell.tsx:53-56`, so the component is safe outside reader screens.
- ReaderShell's `contextValue` is `useMemo`'d (`ReaderShell.tsx:220-226`) and `toggleToolbar` is `useCallback`'d → no re-render loop.
- All 6 sheet dual-API shims correctly branch on `typeof isOpen === 'boolean'` and fall back to legacy `sheetRef`/`theme` when the new API isn't supplied (AppearanceSheet:58-62, TocSheet:47-51, HighlightsSheet:105-109, NoteEditor:55-59, BookmarksList:50-54, SearchPanel:67-71). When `isOpen` is supplied, the legacy branch is suppressed via `index={typeof isOpen === 'boolean' ? (isOpen ? 0 : -1) : -1}` — new API wins, no ambiguity.
- Stage G ReaderToolbar deletion is complete: `grep -r "ReaderToolbar" apps/mobile --include="*.tsx" --include="*.ts"` returns zero hits, file no longer exists at `apps/mobile/components/ReaderToolbar.tsx`.
- EPUB inner `ReaderEngine` component (`app/reader/[id].tsx:723-758`) correctly lives inside `<ReaderShell>` children (line 652), consumes `useContext(ReaderShellContext)` (line 733), and wires the result to `onSingleTap`. Popover-first-dismiss semantics preserved (line 735).
- 12/12 new tests pass (`pnpm exec jest --testPathPatterns "components/reader"` → 12 passed).
- 618/618 mobile jest tests pass; 3 pre-existing module-load failures (book-import x2, vector) are baseline and unrelated.
- `pnpm exec tsc --noEmit -p apps/mobile` clean.
- `pnpm -C apps/rishi-electron typecheck` clean.
- Phase 2 PressableScale F2/F3 fixes not touched by Phase 3 — the new ReaderTopBar/ReaderBottomBar use `IconButton` (the Phase 2 primitive that already wraps PressableScale with the F2 accessibilityState branch).

---

## Style / nits (≤5)

1. The "Legacy API (deprecated)" comment on each shim is a plain `//` comment, not a `@deprecated` JSDoc tag. ESLint / IDE deprecation surfacing won't trigger. Quick win for Phase 6 cleanup — change to `/** @deprecated removed in Phase 6 */` above each legacy prop.

2. `ReaderShell.tsx:55` — `toggleToolbar: () => undefined` as the default context value is unusual; convention is `() => {}` or `() => void 0`. Not a bug, just inconsistent with the rest of the codebase.

3. `ReaderTopBar.tsx:42` and `ReaderBottomBar.tsx:73` use the legacy `pointerEvents="..."` prop on `Animated.View`. React Native ≥0.70 prefers `style={{ pointerEvents: ... }}`. Will emit a deprecation warning at runtime but functions correctly.

4. MOBI/DJVU `PressableToggleToolbar` covers only the inner 60%×40% region (`top:'30%', left:'20%', width:'60%', height:'40%'`). The old `ReaderToolbar` had a much larger tap target. Users might tap the edges of the page and get no toolbar reveal — slightly worse discoverability than before, though Detox specs use the testID so e2e is unaffected.

5. `ReaderShell.tsx:301` — `effectiveSettings = settings ?? NOOP_SETTINGS` quietly substitutes a default settings object when `settings` is undefined. If a parent screen forgot to pass `settings` while `sheets.appearance=true`, the AppearanceSheet would render with the noop default and the user's changes would silently fail to apply because the parent has no `onSettingsChange` handler attached. Consider warning when `sheets.appearance=true && (settings == null || onSettingsChange == null)`.

---

## Out of scope (Phase 4-6 notes)

- **Phase 5:** wire format-appropriate sheets to PDF/MOBI/DJVU; currently `sheets={{}}` or `sheets={{ noteEditor: true }}`. The right cluster on the bottom bar has no actions for these formats. GREEN.md open issue #2.
- **Phase 5:** replace the rgba blur fallback in `<Toolbar blur>` with a real `<BlurView>` once the expo-blur plugin lands in `app.json`. GREEN.md open issue #3.
- **Phase 5:** EPUB progress pill currently uses `kind: 'cfi'` with the chapter label. The "13 min left" / "%" labels from UI-SPEC §2.1 need WPM instrumentation. GREEN.md open issue #4.
- **Phase 5:** PDF outline + thumbnails buttons live as a legacy floating SafeAreaView overlay at `pdf/[id].tsx:500-527`. Phase 5 should move them into the bottom bar right cluster. GREEN.md open issue #5.
- **Phase 6:** remove the legacy `sheetRef`/`theme` API from all 6 sheets and drop `ReaderTheme.toolbarBg`/`toolbarText`. All callers in this repo use the new API. GREEN.md open issue #1.
- **Phase 6:** add hidden 0×0 `reader-toggle-toolbar` accessory to the EPUB screen if a future Detox spec needs it. No current spec uses it. GREEN.md open issue #6.

---

## Worth checking (below 80% confidence)

- ReaderShell's auto-hide timer dependency array (`ReaderShell.tsx:214`) includes `toolbarVisible`, `ttsActive`, `realtimeActive`, `anySheetOpen`. When the user toggles the toolbar OFF manually and then back ON, the timer correctly re-arms. But when `ttsActive` flips from true → false while the toolbar is visible, the timer arms at that moment and hides the toolbar 3s later — which may or may not be what users expect after pausing TTS. Worth a UX call.
- `ReaderShell.tsx:181-185` mirrors `noteEditorOpen` from props into local state via useEffect. If the parent rapidly toggles `noteEditorOpen` while the user is swiping the sheet closed, the local state may briefly disagree with the parent. Probably fine in practice (sheet animation duration ≈ 250ms) but a `useRef` to track the last parent value would be tighter.
