# Phase 3 — Reader UI tests (red phase)

Two failing test files written ahead of implementation, pinning the
observable behaviour the coder must satisfy in green.

## Files

- `apps/mobile/__tests__/components/reader/ReaderShell.test.tsx` (8 tests)
- `apps/mobile/__tests__/components/reader/ReaderProgressPill.test.tsx` (4 tests)

Total: **12 test cases.**

## Test cases

### ReaderShell (8)

1. **Hidden on initial render** — neither top nor bottom bar reports `visible=true`.
2. **`toggleToolbar` via context shows the toolbar** — a Consumer-style probe captures the context, invokes `toggleToolbar()`, and both bars become visible.
3. **Auto-hide after 3000ms** — `jest.useFakeTimers()` + `advanceTimersByTime(3000)`; bottom bar `visible=false` after.
4. **Auto-hide paused while `ttsActive=true`** — same fake-timer flow; bar remains visible at 3000ms.
5. **Auto-hide paused while `realtimeActive=true`** — same.
6. **TOC sheet opens on `onTocPress`** — fire the captured `onTocPress` prop on the mocked bottom bar; `toc-sheet-open` testID appears.
7. **`bottomBarVisible` context tracks `toolbarVisible`** — read context via probe before/after `toggleToolbar()`.
8. **`initialToolbarVisible={true}` starts visible** — both bars report `visible=true` on first render.

### ReaderProgressPill (4)

1. `progress={{kind:'page', current:5, total:100}}` renders the exact text `"5 / 100"`.
2. `progress={{kind:'chapter', current:3, total:10}}` renders `"Ch 3/10"`.
3. `progress={{kind:'cfi', label:'42%'}}` renders `"42%"` verbatim.
4. `progress={{kind:'none'}}` renders `"—"`.

## Mocks added

ReaderShell suite stubs the following so the shell can be tested in
isolation:

| Mocked module | Behaviour |
|---|---|
| `@/components/reader/ReaderTopBar` (virtual) | Host `View` carrying `visible` prop + `testID="reader-top-bar"` |
| `@/components/reader/ReaderBottomBar` (virtual) | Host `View` carrying `visible` prop + `testID="reader-bottom-bar"`; forwards `onTocPress` |
| `@/components/AppearanceSheet` | Returns `null` when `isOpen=false`; `testID="appearance-sheet-open"` when `true` |
| `@/components/TocSheet` | Returns `null` when `isOpen=false`; `testID="toc-sheet-open"` when `true` |
| `@/components/HighlightsSheet` | Returns `null` when `isOpen=false`; `testID="highlights-sheet-open"` when `true` |
| `@/components/epub/BookmarksList` | Returns `null` when `isOpen=false`; `testID="bookmarks-sheet-open"` when `true` |
| `@/components/epub/SearchPanel` | Returns `null` when `isOpen=false`; `testID="search-sheet-open"` when `true` |
| `@/components/NoteEditor` | Returns `null` when `isOpen=false`; `testID="note-editor-sheet-open"` when `true` |

Standard primitive mocks (`react-native`, `react-native-safe-area-context`,
`react-native-reanimated`, `expo-haptics`, `@expo/vector-icons`,
`@gorhom/bottom-sheet`) follow the Phase 2 pattern in
`__tests__/components/ui/Sheet.test.tsx` and
`__tests__/components/auth/PremiumFeatureSheet.test.tsx`.

## Red signal — confirmed

```
pnpm exec jest --testPathPatterns "components/reader"

FAIL __tests__/components/reader/ReaderShell.test.tsx
  Configuration error:
    Could not locate module @/components/reader/ReaderTopBar mapped as:
    /Users/faridmatovu/projects/rishi-monorepo/apps/mobile/$1.

FAIL __tests__/components/reader/ReaderProgressPill.test.tsx
  Configuration error:
    Could not locate module @/components/reader/ReaderProgressPill mapped as:
    /Users/faridmatovu/projects/rishi-monorepo/apps/mobile/$1.

Test Suites: 2 failed, 2 total
```

Both suites fail at import because the target modules
(`apps/mobile/components/reader/ReaderShell.tsx`,
`apps/mobile/components/reader/ReaderTopBar.tsx`,
`apps/mobile/components/reader/ReaderBottomBar.tsx`,
`apps/mobile/components/reader/ReaderProgressPill.tsx`) do not yet
exist on disk. This is the expected red signal — once the coder lands
Stage A from ARCH §8 (the four `reader/*` component files), both suites
will progress past import and the 12 test cases will run and gate the
green phase.

## Consumed by

- Stage A coder follow-up (`feat(mobile/reader): ReaderShell with new toolbar layout` — ARCH §8).
- Stage B sheet-refactor mocks may need re-checking once the real sheet
  APIs land — the mocks here key on `isOpen`, which is the new contract
  ARCH §2 mandates.
