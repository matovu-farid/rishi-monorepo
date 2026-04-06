---
phase: 05-reading-progress-highlights
verified: 2026-04-06T05:30:00Z
status: human_needed
score: 15/15 must-haves verified
re_verification: true
  previous_status: gaps_found
  previous_score: 13/15
  gaps_closed:
    - "Double highlight creation via onSelected prop — onSelected removed from Reader component; menuItems exclusively handle highlight creation"
    - "Pull-side LWW guard missing — updatedAt comparison added at engine.ts lines 228-229; remote update skipped when remote is older than local"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "Tap 'Highlight Text' from context menu and verify no duplicate appears in highlights list"
    expected: "Exactly one highlight created per menu tap. Highlights list shows one entry, not two."
    why_human: "onSelected was removed from Reader props; only menuItems now create highlights. But the library's runtime behavior when the 'Highlight Text' menu item fires cannot be verified statically — need to observe that exactly one insertHighlight call happens per tap."
  - test: "Tap existing highlight annotation in the reader"
    expected: "AnnotationPopover appears visible and usable — centered top-area of screen, not hidden behind toolbar or off-screen"
    why_human: "Popover is positioned at (screenWidth/2, screenHeight*0.35) — visual verification needed to confirm this is ergonomic"
  - test: "Open highlights sheet, tap a highlight row"
    expected: "Reader navigates to that highlight's CFI position and the sheet closes"
    why_human: "goToLocation(cfiRange) behavior with CFI ranges from highlights needs runtime verification in the epub renderer"
  - test: "Sync highlights across two devices (or simulate with two installs)"
    expected: "Highlight created on device A appears on device B after sync. Editing note on B then syncing: the later updatedAt note wins."
    why_human: "Cross-device sync and LWW behavior requires two running devices or a simulated multi-device scenario"
---

# Phase 05: Reading Progress & Highlights Verification Report

**Phase Goal:** Users can create highlights and annotations in EPUB books, and reading progress and highlights sync across devices.
**Verified:** 2026-04-06T05:30:00Z
**Status:** human_needed
**Re-verification:** Yes — after gap closure (previous: gaps_found, 13/15)

## Re-verification Summary

Both gaps from the initial verification are confirmed closed:

**Gap 1 closed — Double highlight creation (was BLOCKER):** The `onSelected={handleSelected}` prop has been removed from the `<Reader>` component. The Reader JSX at `apps/mobile/app/reader/[id].tsx` lines 359-377 shows only `menuItems`, `initialAnnotations`, `onLocationChange`, `onSingleTap`, and `onPressAnnotation` — no `onSelected` prop. The `handleSelected` function still exists as the implementation called by the "Highlight Text" menu item action (line 254), which is the correct pattern.

**Gap 2 closed — Pull-side LWW guard (was WARNING):** Lines 227-229 in `apps/mobile/lib/sync/engine.ts` now contain an explicit `updatedAt` guard: `const remoteUpdatedAt = (r.updatedAt as number) ?? 0; if (remoteUpdatedAt < (local.updatedAt ?? 0)) continue`. This correctly skips remote updates that are older than the local record.

No regressions found — all 13 previously-passing truths remain verified.

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Highlights table exists in SQLite with all 13 columns from UI-SPEC | VERIFIED | `apps/mobile/lib/db.ts`: CREATE TABLE IF NOT EXISTS highlights confirmed present; `packages/shared/src/schema.ts` line 37: export const highlights with all 13 columns |
| 2 | Highlight CRUD functions are available: insert, getByBookId, update, softDelete | VERIFIED | `apps/mobile/lib/highlight-storage.ts`: 4 exported functions (grep returns count 4), 4 triggerSyncOnWrite calls |
| 3 | Shared schema exports highlights table for both mobile and Worker D1 | VERIFIED | `packages/shared/src/schema.ts` lines 37, 56-57: export const highlights, export type Highlight, export type NewHighlight |
| 4 | Sync types include highlights in push/pull payloads | VERIFIED | `packages/shared/src/sync-types.ts` lines 4 and 16: highlights?: Array<Record<string,unknown>> in both interfaces |
| 5 | Reading progress fields (currentCfi/currentPage) sync via books table | VERIFIED | engine.ts dirty books push currentCfi/currentPage; worker GET /pull returns these fields in changedBooks — unchanged from phase 04 |
| 6 | User can long-press text and tap Highlight Text to create a highlight | VERIFIED | onSelected removed from Reader props; menuItems exclusively handle creation; "Highlight Text" action calls handleSelected(text, cfiRange) which calls insertHighlight |
| 7 | User can tap Highlight & Note to create a highlight and open note editor | VERIFIED | menuItems[1].action at lines 260-276: insertHighlight, addAnnotation, setSelectedHighlight, setTimeout snapToIndex(0) — correct sequential flow |
| 8 | User can tap existing highlight to see annotation popover | VERIFIED | onPressAnnotation={handlePressAnnotation} at line 376; handler at lines 284-298 finds match, sets popoverPosition, sets popoverVisible=true |
| 9 | User can open highlights list from toolbar and navigate to a highlight | VERIFIED | onHighlightsPress in ReaderToolbar props and bookmark.fill button at line 77; HighlightsSheet wired at lines 415-421; handleNavigateToHighlight calls goToLocation and closes sheet |
| 10 | User can delete a highlight via annotation popover with confirmation | VERIFIED | handleDeleteHighlight at lines 327-336; AnnotationPopover has Alert.alert with destructive confirm (#DC2626 Delete button) |
| 11 | Highlights persist in SQLite and load when reopening a book | VERIFIED | useEffect at lines 99-103 calls getHighlightsByBookId(book.id) on mount; initialAnnotations built via useMemo at lines 106-120 |
| 12 | Dirty highlights are pushed to D1 alongside dirty books | VERIFIED | engine.ts lines 36-49: dirtyHighlights queried, included in changes.highlights, marked clean after push (lines 116-122) |
| 13 | Worker push endpoint handles highlights with userId scoping and LWW | VERIFIED | workers/worker/src/routes/sync.ts lines 80-120: highlights loop with and(eq(highlights.id,id), eq(highlights.userId,userId)), LWW by updatedAt; upsertedHighlightIds tracked separately |
| 14 | Worker pull returns highlights changed since client syncVersion | VERIFIED | sync.ts lines 186-205: changedHighlights query with gt(highlights.syncVersion, sinceVersion), included in PullResponse as changes.highlights |
| 15 | Highlights pull uses union merge with LWW guard — never loses a highlight | VERIFIED | engine.ts lines 211-267: new remote highlights always inserted; existing non-dirty highlights updated only when remoteUpdatedAt >= local.updatedAt (lines 227-229 guard added); locally dirty highlights skipped |

**Score:** 15/15 truths verified

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `packages/shared/src/schema.ts` | highlights Drizzle table definition | VERIFIED | All 13 columns present, Highlight and NewHighlight types exported (lines 37, 56-57) |
| `packages/shared/src/sync-types.ts` | PushRequest/PullResponse with highlights array | VERIFIED | highlights?: Array<Record<string,unknown>> in both interfaces |
| `apps/mobile/lib/highlight-storage.ts` | CRUD with dirty tracking | VERIFIED | 4 exported functions, 4 triggerSyncOnWrite calls |
| `apps/mobile/types/highlight.ts` | Highlight UI interface + color constants | VERIFIED | Highlight interface, HighlightColor, HIGHLIGHT_COLORS (4 entries), HIGHLIGHT_OPACITY=0.3 |
| `apps/mobile/lib/db.ts` | highlights SQLite migration | VERIFIED | CREATE TABLE IF NOT EXISTS highlights present |
| `apps/mobile/components/HighlightsSheet.tsx` | Bottom sheet listing highlights | VERIFIED | Exported at line 65, BottomSheetFlatList, 10px color circle, empty state, Alert.alert on long-press |
| `apps/mobile/components/NoteEditor.tsx` | Note add/edit bottom sheet | VERIFIED | Exported at line 15, snapPoints=[320], keyboardBehavior="interactive", Save Note (#0a7ea4) |
| `apps/mobile/components/AnnotationPopover.tsx` | Popover with edit/color/delete | VERIFIED | Exported at line 22, FadeIn.duration(150), accessibilityViewIsModal={true}, #DC2626 Delete |
| `apps/mobile/app/reader/[id].tsx` | Reader with full highlight integration | VERIFIED | All components wired, menuItems-only creation (no standalone onSelected), initialAnnotations, onPressAnnotation |
| `apps/mobile/components/ReaderToolbar.tsx` | Toolbar with highlights button | VERIFIED | onHighlightsPress in props interface (line 13), bookmark.fill icon button (line 77) |
| `apps/mobile/lib/sync/engine.ts` | Sync engine with highlights push/pull with LWW | VERIFIED | dirtyHighlights push, pull with updatedAt guard (lines 227-229), union merge insert |
| `workers/worker/src/routes/sync.ts` | Worker sync routes with highlights | VERIFIED | highlights imported, upsertedHighlightIds separate tracking, changedHighlights in pull response |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| highlight-storage.ts | @rishi/shared/schema | import { highlights } | WIRED | Confirmed present |
| highlight-storage.ts | sync/triggers.ts | triggerSyncOnWrite() | WIRED | 4 calls (insert, update, delete + helper) confirmed by grep count |
| reader/[id].tsx | highlight-storage.ts | insertHighlight etc. imports | WIRED | Line 11: all 4 CRUD functions imported and used |
| reader/[id].tsx | @epubjs-react-native/core | menuItems, onPressAnnotation | WIRED | Lines 372, 376; onSelected NOT present on Reader props — gap fixed |
| HighlightsSheet | reader/[id].tsx | onNavigateToHighlight calls goToLocation | WIRED | handleNavigateToHighlight at lines 349-355: goToLocation(cfiRange), highlightsSheetRef.current?.close() |
| engine.ts | @rishi/shared/schema | import { highlights } | WIRED | Line 2: import { books, highlights, syncMeta } |
| workers/sync.ts | @rishi/shared/schema | import { highlights } | WIRED | Confirmed by grep output |
| engine.ts | workers/sync.ts | changes.highlights in push body | WIRED | Line 49: highlights: dirtyHighlights |
| engine.ts pull | updatedAt LWW guard | if (remoteUpdatedAt < local.updatedAt) continue | WIRED | Lines 227-229: guard added and confirmed — gap fixed |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| HIGH-01 | 05-01, 05-02 | User can create text highlights in EPUB books | SATISFIED | menuItems-only highlight creation; onSelected removed from Reader; insertHighlight called from menu item action only |
| HIGH-02 | 05-01, 05-02 | User can add notes to highlights | SATISFIED | NoteEditor component wired; updateHighlight called from handleSaveNote (line 341) |
| HIGH-03 | 05-01, 05-02 | User can view list of all highlights for a book | SATISFIED | HighlightsSheet renders highlights array loaded from SQLite |
| HIGH-04 | 05-01, 05-02 | User can delete highlights | SATISFIED | AnnotationPopover and HighlightsSheet both wire delete with Alert confirmation |
| HIGH-05 | 05-01, 05-03 | Reading progress syncs across devices | SATISFIED | currentCfi/currentPage in books dirty tracking; syncs via existing books push/pull |
| HIGH-06 | 05-03 | Highlights sync with union merge (no highlight lost) | SATISFIED | New remote highlights always inserted; pull-side updatedAt LWW guard now prevents stale overwrites |
| HIGH-07 | 05-03 | Annotations sync with LWW per field | SATISFIED | Worker push enforces LWW by updatedAt; engine.ts applies server version on conflict (cfiRange detection at line 66); pull-side guard at lines 227-229 |

All 7 requirement IDs (HIGH-01 through HIGH-07) are accounted for. No orphaned requirements found.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| None found | — | — | — | Both fixed files pass anti-pattern scan. No TODOs, FIXMEs, empty handlers, or stub returns. |

---

### Human Verification Required

#### 1. Single Highlight Creation Per Menu Tap

**Test:** Open an EPUB. Long-press to select text. When the context menu appears, tap "Highlight Text". Open the highlights list from the toolbar.
**Expected:** Exactly one highlight entry appears in the list. No duplicate for the same text selection.
**Why human:** The `onSelected` prop has been removed and only `menuItems` creates highlights now. However, the epubjs-react-native library's runtime behavior when a menu item fires cannot be verified statically — need to observe in the running app that only one `insertHighlight` call occurs per explicit tap.

#### 2. Annotation Popover Position

**Test:** Create a highlight, then tap it in the reader.
**Expected:** AnnotationPopover appears visible and usable — centered near the top-third of the screen, not hidden behind the toolbar or cut off at screen edges.
**Why human:** Popover is positioned at `(screenWidth/2, screenHeight*0.35)` — visual ergonomics require runtime observation.

#### 3. Highlight Navigation from Sheet

**Test:** Create highlights in two different chapters. Open the highlights sheet from the toolbar. Tap the second highlight.
**Expected:** The EPUB reader navigates to that highlight's CFI position and the sheet closes.
**Why human:** `goToLocation(cfiRange)` with a CFI range (not a href) needs runtime verification in the epub renderer to confirm navigation lands at the correct location.

#### 4. Cross-Device Sync with LWW

**Test:** Create a highlight on device A, trigger sync, verify it appears on device B. Then edit the note on device B and sync again. Verify the device B note wins if its `updatedAt` is later.
**Expected:** Highlights appear on both devices after sync. The most-recently-edited note wins across sync cycles.
**Why human:** Requires two running devices or a simulated multi-device scenario to verify the full LWW round-trip including the new pull-side guard.

---

### Gaps Summary

No gaps remaining. All automated checks pass.

Both gaps from the initial verification are confirmed closed:
- The double highlight creation blocker is resolved: `onSelected` is no longer passed as a Reader prop. Only `menuItems` actions trigger `insertHighlight`.
- The pull-side LWW guard is now present: `engine.ts` lines 227-229 compare `remoteUpdatedAt` against `local.updatedAt` and skip the update when remote is older.

Phase goal is achieved at the code level. Human verification items remain for runtime behavior confirmation.

---

_Verified: 2026-04-06T05:30:00Z_
_Verifier: Claude (gsd-verifier)_
_Re-verification: Yes — gaps_found → human_needed_
