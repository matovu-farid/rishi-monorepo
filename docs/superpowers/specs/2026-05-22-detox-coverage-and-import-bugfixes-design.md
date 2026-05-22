# Detox Coverage Expansion + Import-Path Bug Fixes

**Date:** 2026-05-22
**App:** `apps/mobile`
**Branch:** `main` (work mixed with existing in-flight changes per user choice)

## Background

User reported that PDF import "fails" when manually testing with a dev build (`npx expo start` against an EAS-uploaded development client). Two errors surfaced in the runtime trace:

1. `[file-import] indexBook failed: [Error: Unable to obtain Worker session token. User must sign in.]`
2. `[Error: GestureDetector must be used as a descendant of GestureHandlerRootView.]` thrown from `NoteEditor.tsx:53` (`@gorhom/bottom-sheet`) inside `PdfReaderScreen` (`app/reader/pdf/[id].tsx:634`).

Investigation findings:

- **(1) is a noise warning, not the import failure.** `indexBook` is a fire-and-forget call in `lib/file-import.ts:80`. The import itself returns the `Book` row successfully.
- **(2) is the real symptom.** `app/_layout.tsx:202` renders children via `<Slot />` without wrapping them in `<GestureHandlerRootView>`. Only `app/reader/[id].tsx:91` (the EPUB dispatcher) wraps its subtree. The PDF route renders `NoteEditor` (a bottom sheet whose internals call `GestureDetector`) and crashes on mount because there is no gesture-handler ancestor.
- **Existing Detox suite did not catch this.** `e2e/reader-pdf.test.ts` taps a seeded PDF BookRow and asserts the `pdf-reader` testID appears. Either the test wasn't being run, or the crash mode in Release-mode Detox is silent enough that the testID still attaches before tear-down. Either way, the suite needs a stronger render-proof signal that would surface this class of regression.

## Goals

1. Fix the two bugs from the user's trace.
2. Extend the Detox suite from "reader screen mounts" assertions to **functional reading**: open → assert position indicator → navigate one page → assert position changed.
3. Add format coverage for `azw3`. Stub `djvu` (no fixture available; deferred).

## Non-Goals

- Android Detox configuration (already a TODO in `.detoxrc.js`).
- CI integration.
- E2E coverage for `UIDocumentPickerView` (genuinely undriveable from Detox per existing notes in `library.test.ts`).
- Highlights, TTS playback, or voice-chat E2E coverage (separate concerns).
- Sourcing or generating a DJVU fixture file.

## Bug Fixes

### Fix 1 — `app/_layout.tsx` GestureHandlerRootView

Wrap the root layout's rendered children in `<GestureHandlerRootView style={{ flex: 1 }}>`. This is the canonical fix per `react-native-gesture-handler` docs and removes the need for the per-route wrapper in `app/reader/[id].tsx` (though that one can stay as a defensive no-op for now; removing it is out of scope).

Impact: any bottom-sheet, swipeable, or gesture-detecting component (`@gorhom/bottom-sheet`, `react-native-reanimated` gesture handlers, swipe-to-dismiss patterns) becomes valid anywhere in the app.

### Fix 2 — `lib/file-import.ts` indexBook gating

In E2E mode (`IS_E2E_TEST`) OR when no session token is present, skip the `indexBook()` fire-and-forget call entirely. Log once at info level instead of warning every time.

Rationale: the `indexBook` call requires a session token to hit the Worker; calling it without a token produces noisy warnings and pointless network retries. In E2E mode we deliberately bypass auth, so this call is guaranteed to fail. In production when the user is unauthenticated (rare but possible), we should defer indexing until they sign in rather than spam logs.

Both call sites need the gate:
- `lib/file-import.ts:80` (real user import path)
- `lib/file-import.ts:312` (E2E fixture seed path — also fires `indexBook`)

## Test Architecture

### Format coverage matrix

| Format | Fixture | Seed bridge | Functional reader test |
|--------|---------|-------------|------------------------|
| epub   | exists  | exists      | extend                 |
| pdf    | exists  | exists      | extend                 |
| mobi   | exists  | exists      | extend                 |
| azw3   | **copy from `apps/rishi-electron/e2e/fixtures/test-book.azw3`** | **add to format union** | **NEW** |
| djvu   | deferred | exists in code | `describe.skip` stub |

### Functional reader test pattern

Each reader test follows this pattern:

```
1. seedBook(format)                       // existing: pushes fixture, deep-links import, awaits BookRow
2. tap BookRow                            // assert reader root testID (catches GestureHandlerRootView class)
3. read `reader-position-indicator` label // capture starting position
4. swipe / tap "next page"                // trigger navigation
5. read `reader-position-indicator` again // assert value changed
```

The position-indicator step is what distinguishes this from the current "reader mounted" smoke test and is what would have caught the GestureHandlerRootView bug (the screen would have unmounted, indicator would never have appeared).

### Reader instrumentation

Each reader screen exposes one new testID:

- `testID="reader-position-indicator"` with `accessibilityLabel` exposing the current position as a string:
  - **PDF:** `"<currentPage>/<totalPages>"` — already in state via `pageNumber` / `pageCount`
  - **EPUB:** current CFI string — already tracked via `onLocationChange`
  - **MOBI:** current spine index or location — depends on reader impl (to verify during implementation)
  - **AZW3:** same as MOBI (shares the converted-to-epub pipeline) or same as EPUB depending on which reader handles it
  - **DJVU:** current page number (deferred along with fixture)

The indicator can be invisible (e.g., a zero-size `<View>`) — Detox reads `accessibilityLabel` regardless. Keeping it invisible avoids any UI churn.

### Navigation affordance

Where readers don't already expose a tappable "next page" button with a testID, tests use Detox's `swipe()` API on the reader root. Swipes can be flaky in WebView-backed readers (EPUB/MOBI/AZW3); the fallback if `swipe()` is unreliable is to add a `testID="reader-next-page-btn"` that calls the reader's existing next-page handler. This decision is per-format and made during implementation when we see actual behavior.

## Files to Create / Modify

### Bug fixes (JS-only — no Detox rebuild required)
- `app/_layout.tsx` — wrap children in `<GestureHandlerRootView>`
- `lib/file-import.ts` — gate `indexBook` on `IS_E2E_TEST || !sessionToken`

### Test fixtures
- `apps/mobile/e2e/fixtures/test-book.azw3` — copied from `apps/rishi-electron/e2e/fixtures/`

### Seed bridge — add `azw3` to format unions
- `apps/mobile/e2e/helpers/seed-book.ts` — `SeedFormat` union
- `apps/mobile/app/_layout.tsx` `handleE2ESeedLink` — accepted format list
- `apps/mobile/lib/test-fixtures/seed.ts` — `seedBookFromFixture` switch / map

### Reader instrumentation
- `apps/mobile/app/reader/pdf/[id].tsx` — add position-indicator View
- `apps/mobile/app/reader/[id].tsx` (EPUB) — same
- `apps/mobile/app/reader/mobi/[id].tsx` — same
- `apps/mobile/app/reader/djvu/[id].tsx` — same (lands but unused until djvu fixture exists)

### Tests
- `apps/mobile/e2e/library.test.ts` — extend the format loop to include `azw3` (and `djvu` as `.skip`)
- `apps/mobile/e2e/reader-pdf.test.ts` — extend with navigation + indicator-change assertion
- `apps/mobile/e2e/reader-epub.test.ts` — same
- `apps/mobile/e2e/reader-mobi.test.ts` — same
- `apps/mobile/e2e/reader-azw3.test.ts` — NEW, mirrors reader-epub
- `apps/mobile/e2e/reader-djvu.test.ts` — NEW, `describe.skip` stub with TODO referencing missing fixture

## Test Strategy (TDD per `feedback_tdd.md`)

1. **Red phase** — write the new/extended Detox tests first; run; they fail because:
   - Bug fixes haven't landed (PDF reader crashes on `<NoteEditor>` mount → no position indicator)
   - Position-indicator testIDs don't exist yet
   - New fixtures / seed-bridge entries don't exist yet

2. **Green phase** — apply bug fixes, add testIDs, add fixtures, extend seed bridge. Run suite, get to green.

3. **Refactor** — verify all pre-existing tests (smoke, library, auth, chat, settings, cross-platform-sync) still pass. No structural refactor expected; this is additive work.

### Build / run cadence

- `npm run e2e:build` — required once (xcodebuild Release). Required again only if any native code changes or any `EXPO_PUBLIC_*` env var changes. None of this work touches either, so a single build suffices.
- `npm run e2e:test` — iterative.

## Open Risks

- **WebView readers (EPUB/MOBI/AZW3) and `accessibilityLabel` updates.** Whether the indicator's accessibilityLabel re-reads on every render is a Detox/RN-bridge question. If Detox caches it, we need to use a different mechanism (e.g., a hidden `<Text>` child whose content changes). Decided during implementation.
- **AZW3 reader path.** It's unclear whether AZW3 uses the EPUB reader (post-conversion) or has its own route. To verify when wiring `seedBookFromFixture('azw3')`. May affect which file gets the instrumentation.
- **Swipe-based navigation flakiness.** If `swipe()` proves unreliable on WebView readers, fall back to a tappable next-page button with testID. Adds a small UI affordance, but invisible to users (zero-size or `accessibilityElementsHidden`).
- **`indexBook` skip in E2E may mask real bugs.** Acceptable trade-off — RAG indexing has its own unit tests; E2E shouldn't depend on the Worker being reachable.
