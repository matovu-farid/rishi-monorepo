# Mobile Import & Reader Polish — Design

**Date:** 2026-06-05
**Scope:** `apps/mobile`
**Status:** Draft for review
**Author:** brainstorming pass with @matovu-farid

## Goal

Land a single PR against `apps/mobile` that removes the padlock UI on
gated buttons, ships the existing 2-column library grid spec end-to-end
(including PDF cover extraction), applies the pdfjs DPR fix so PDF
content stops looking blurry, and adds Maestro coverage that exercises
both EPUB and PDF import + reader navigation with screenshots.

The horizontal-swipe interaction + architectural overhaul of the PDF
reader (native rendering, native text extraction, SQLite-backed text
cache) is scoped into a follow-up spec — see "Follow-up: Path E" below.

## Non-goals

- Replacing the PDF rendering architecture in this PR. The renderer
  rewrite (`react-native-pdf` + native text extraction TurboModule +
  SQLite cache) is the right end state but is 1-2 weeks of work across
  several PRs. Tracked separately as **Path E** (see end of doc).
- Changing the reader interaction model in this PR. The vertical-scroll
  WebView stays. Horizontal swipe lands with Path E.
- Adding pinch-zoom inside a PDF page. Separate spec.
- File-picker / share-sheet Maestro flows. URL-import only — fast and
  deterministic.

## Background

Four user-facing requests motivate the work:

1. **Padlock icons are visual noise.** Buttons gated behind sign-in show
   a tiny grey lock chip via `components/auth/LockChip.tsx`. The
   underlying `useRequireAuth` already prompts on tap, so the chip is
   redundant.
2. **The library list is text-heavy.** Today the home tab is a vertical
   `FlatList` of horizontal `BookRow` cards (small cover + title +
   author + trash icon). A 2-column grid of covers is more book-shelf
   shaped.
3. **PDFs look blurry.** Confirmed root cause in
   `components/pdf/webview-template.ts` lines 244-247: the pdfjs canvas
   backing store is sized in CSS pixels (no `devicePixelRatio`
   multiplier) and then CSS-stretched to 100% width. On a DPR-3 iPhone
   that's a 3× upscale of a 1× bitmap.
4. **Maestro coverage for import + reader is thin on assertions.** The
   existing `07-epub-reader.yaml` / `08-pdf-reader.yaml` flows import via
   URL but don't capture screenshots or assert reader content
   visibility.

A prior spec at
`docs/superpowers/specs/2026-06-04-mobile-library-grid-pdf-covers-design.md`
already designs the 2-col grid + PDF cover extraction. We reuse it
wholesale.

## Architecture overview

Four work streams, all on one branch:

| # | Stream | Risk | Native dep change |
| - | - | - | - |
| 1 | Padlock removal | low | none |
| 2 | 2-col grid + PDF covers | medium | `react-native-pdf-thumbnail` → rebuild dev client |
| 3 | PDF crispness — Path A DPR fix only | low | none |
| 4 | Maestro import + screenshots | low | none |

A `team-reviewer` pass runs across the full diff at the end. All work is
TDD per repo convention — failing tests first in every stream.

## Stream 1 — Remove padlock chips

### Changes
- Delete `<LockChip>` usages from:
  - `app/(tabs)/chat.tsx:7,27` (new-conversation button)
  - `components/reader/ReaderBottomBar.tsx:15,53` (TTS / voice / AI-chat
    icons)
  - `components/reader/ReaderOverlay.tsx:7,163` (voice-chat launcher)
- Drop the `showLockChips` prop and any related auth-state plumbing in
  `components/reader/ReaderShell.tsx:192,426` that becomes dead.
- Delete `components/auth/LockChip.tsx` if no other consumers remain.
- Buttons retain their existing `useRequireAuth` tap handler — clicking
  while signed out still triggers the sign-in flow.

### Tests
- Flip any RTL queries that asserted presence of `*-lock-chip` test IDs
  to assert *absence*.
- New unit tests assert that tapping a gated button while signed out
  invokes the auth prompt.

### Out of scope
- Visual hint for signed-out state (dimmed buttons, etc.). The user
  chose "remove entirely; click triggers auth."

## Stream 2 — 2-col library grid + PDF cover extraction

Implements the existing spec
`2026-06-04-mobile-library-grid-pdf-covers-design.md` end-to-end (both
halves bundled per user choice).

### Changes
- New `components/library/BookGridCard.tsx`:
  - 5:7 aspect cover image on top, title (1 line, ellipsis) + author (1
    line, smaller, muted) beneath.
  - Long-press to surface delete.
- `app/(tabs)/index.tsx`:
  - `FlatList` → `numColumns={2}` with inter-column gap + safe-area
    horizontal padding.
  - Drop the "Reading Now" hero card.
  - Update `getItemLayout` for new row height (cover height + meta).
- New cover-size token `"grid"` in the cover-state surface (see
  `__tests__/book-import/cover-state-surface.test.ts`).
- Add `react-native-pdf-thumbnail` and wire into the cover-extraction
  pipeline for PDFs. EPUBs continue using their embedded cover.
- After install, run `npx expo prebuild` and rebuild the dev client:
  `eas build --platform ios --profile development --local`. Note this in
  the PR description.

### Tests
- Snapshot / RTL for `BookGridCard` (with and without cover).
- Library screen test (`__tests__/library-screen.test.tsx`) updated for
  grid layout.
- Cover-extraction test for PDF using a fixture PDF.

## Stream 3 — PDF crispness (Path A DPR fix)

### Scope

Smallest possible fix that makes PDFs stop looking blurry. No
interaction-model change, no architecture change. The reader keeps its
current vertical-scroll WebView layout. Reader rewrite is Path E.

### Root cause (verified)

`components/pdf/webview-template.ts` lines 244-247 set the pdfjs canvas
backing store in CSS pixels with no `devicePixelRatio` multiplier, then
CSS-stretches it to 100% width (line 40: `.page-canvas { width: 100%;
height: auto }`). On a DPR-3 iPhone the displayed bitmap is a 3× upscale
of a 1× render.

### Changes (`components/pdf/webview-template.ts`)

Apply the canonical pdfjs HiDPI pattern:

```js
const outputScale = window.devicePixelRatio || 1;
canvas.width  = Math.floor(viewport.width  * outputScale);
canvas.height = Math.floor(viewport.height * outputScale);
canvas.style.width  = Math.floor(viewport.width)  + 'px';
canvas.style.height = Math.floor(viewport.height) + 'px';
const transform =
  outputScale !== 1 ? [outputScale, 0, 0, outputScale, 0, 0] : null;
page.render({ canvasContext: ctx, transform, viewport });
```

Replace `.page-canvas { width: 100%; height: auto }` with explicit px
sizing on the canvas element so CSS no longer stretches the bitmap.

Keep everything else — `IntersectionObserver` lazy-render, paragraph
extraction, text-layer, highlights, TOC, TTS pipeline — untouched.

### Memory note

DPR-multiplied canvases use more memory (DPR 3 → 9× the backing-store
bytes). The existing `IntersectionObserver` lazy-render already evicts
off-viewport pages. Verify on a 500-page PDF on a low-RAM Android device
during QA; if memory pressure is a problem, add explicit canvas
backing-store free on off-screen.

### Tests
- Visual A/B via Maestro screenshot of a known PDF body-text page (e.g.
  *Crime and Punishment*) on iOS sim DPR 3, compared to a baseline
  capture before the change. Reviewer should see edge sharpness improve.
- Existing reader unit tests must continue passing — no behavior
  changes, only render fidelity.

### Risks
- **Memory on low-end Android.** Mitigated by existing lazy-render +
  explicit eviction if needed.
- **None to features** — text selection, highlights, TOC, TTS untouched.

## Stream 4 — Maestro import + screenshots

### Changes
- Extend `.maestro/07-epub-reader.yaml`:
  - `takeScreenshot library-pre-import`
  - import via URL
  - `takeScreenshot library-post-import` (asserts new cover visible)
  - open reader
  - `takeScreenshot reader-page-1`
  - `assertVisible` on body text (not just chrome)
  - scroll forward, `takeScreenshot reader-mid-document`
- Extend `.maestro/08-pdf-reader.yaml`: same shape, with PDF URL.
- New `.maestro/13-library-grid.yaml`: launches app with seeded books
  (via the existing import flow), asserts grid layout (two columns
  visible), taps a cover, confirms reader opens.
- Register the new flow in `.maestro/config.yaml`.

Note: navigation inside the PDF reader stays vertical-scroll in this PR.
Maestro asserts content visibility via scroll, not horizontal swipe.
Swipe-based assertions land with Path E.

### Out of scope
- Native file-picker / share-sheet import (Maestro can't drive picker
  reliably without simulator-side seeding).

## Agent team for execution

After this spec lands and the implementation plan is written:

- **Padlocks** → `team-tester` (red tests) → `team-coder` (green). Small
  and mechanical.
- **Grid + covers** → `team-architect` → `team-tester` → `team-coder`.
  Cover-extraction pipeline touches the data layer.
- **PDF DPR fix** → `team-coder` directly. ~30 lines + a screenshot
  assertion; doesn't need architect involvement.
- **Maestro** → runs *after* Stream 2 lands on the branch (needs the
  grid + covers to assert on).
- **End** → `team-reviewer` over the full diff.

Streams 1, 2, and 3 are independent and can run in parallel. Stream 4
blocks on Stream 2.

## TDD discipline

Per `feedback_tdd.md` in the user's memory, every stream is
red-green-refactor. The plan from `writing-plans` will spell out the
failing tests for each stream before any implementation begins.

## Build + verification

- After Stream 2's native dep lands, the next dev build is:
  `eas build --platform ios --profile development --local`. The PR
  description lists this as a required reviewer step.
- Maestro run command (existing): per `.maestro/config.yaml`.
- Jest unit tests: existing `pnpm test` from `apps/mobile`.

## Follow-up: Path E — native PDF reader

Tracked as a separate spec (to be written after this PR ships). Sketch:

| Layer | Tech |
| - | - |
| Rendering | `react-native-pdf` v7 with `horizontal` + `enablePaging`. Native swipe via UIKit's `PDFView.usePageViewController`. |
| Text extraction | TurboModule / JSI native module. iOS: PDFKit (`PDFPage.string`, `PDFSelection.selectionsByLine`). Android: Pdfium (`FPDFText_GetText`, `FPDFText_GetCharBox`). Runs **once at import time**. |
| Storage | New SQLite tables: `book_pages(book_id, page_number, text)` and `book_words(book_id, page_number, idx, text, x, y, w, h)`. |
| Highlights / search / TTS | Read paragraphs and word bounding boxes from SQLite. Render selection overlays as absolutely-positioned RN `<View>`s over `react-native-pdf`, with coords derived from stored PDF user-space + the library's reported scale. |
| pdfjs / WebView | Removed from the reader entirely. |

Estimated 1-2 weeks, 3-4 sequenced PRs:

1. Add the native text-extraction TurboModule (no consumers yet).
2. SQLite schema + import-time extraction job + backfill for existing
   books.
3. Swap the PDF reader to `react-native-pdf`, migrate TTS / highlights /
   search to read from SQLite.
4. Delete pdfjs WebView, `webview-template.ts`, `pdf-webview-bridge.ts`.

Throwaway from this PR when Path E lands: the DPR-fix lines in
`webview-template.ts`. Acceptable — they ship reader quality for the
1-2 weeks Path E takes to land.

## Open items / follow-ups

- Pinch-zoom inside a PDF page — defer; Path E will get it for free via
  PDFKit/Pdfium's native zoom.
- Auto-submit MAS releases (per existing memory) unaffected by this work.
