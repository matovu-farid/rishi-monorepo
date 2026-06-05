# Mobile Import & Reader Polish — Design

**Date:** 2026-06-05
**Scope:** `apps/mobile`
**Status:** Draft for review
**Author:** brainstorming pass with @matovu-farid

## Goal

Land a single PR against `apps/mobile` that removes the padlock UI on
gated buttons, ships the existing 2-column library grid spec end-to-end
(including PDF cover extraction), rebuilds the PDF reader around a
single-page horizontal-swipe interaction (with the canvas DPR fix that
removes blur), and adds Maestro coverage that exercises both EPUB and
PDF import + reader navigation with screenshots.

## Non-goals

- Replacing pdfjs with `react-native-pdf` (the renderer). Investigated
  and rejected — Android PdfiumAndroid has no text layer, so we'd lose
  selection / highlights silently.
- Adding pinch-zoom inside a PDF page. Out of scope; can land separately.
- Migrating off the WebView container. Path D keeps the WebView; only
  the internal rendering / scroll model changes.
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
| 3 | PDF reader → Path D (horizontal pages, DPR fix) | medium | none |
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

## Stream 3 — PDF reader Path D

### Interaction model
- One page rendered at a time inside the existing WebView.
- Horizontal swipe (left → next, right → previous) handled by RN gesture
  in `PdfWebReader.tsx`. A short `Animated.View` translateX gives the
  page-turn feel; on release we post `renderPage(n+1)` (or n-1) to the
  WebView.
- No vertical scroll. Page is fit-to-width with letterboxing for short
  pages.
- A small page indicator ("47 / 312") in the reader chrome. Tap-to-jump
  via existing TOC unchanged.

### Renderer changes (`components/pdf/webview-template.ts`)
- Apply the canonical pdfjs HiDPI pattern:
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
- Replace `.page-canvas { width: 100%; height: auto }` with explicit px
  sizing (`style.width / style.height`).
- Rip out the `IntersectionObserver`-based lazy-render loop and the
  page-list scroll container.
- Expose a `renderPage(n)` message handler that clears the canvas,
  destroys the prior page object, and renders just page n.
- Keep paragraph extraction (`pageDataToParagraphs`), text-layer
  rendering, and highlight overlay logic untouched — they just run for a
  single page at a time now.

### RN-side changes (`components/pdf/PdfWebReader.tsx`)
- State: `currentPage: number`, `numPages: number`,
  `pageRenderState: 'idle' | 'pending' | 'ready'`.
- `react-native-gesture-handler` `PanGestureHandler` wrapping the
  WebView. On `onEnded` with horizontal velocity / translation past a
  threshold, dispatch `next` / `prev`.
- `next` / `prev` post `renderPage(n±1)` to the WebView via the existing
  bridge.
- Animated translateX during the gesture; springs back on cancel, jumps
  to ±100% on commit (with the WebView swapping page underneath as the
  animation completes).
- Optional follow-up (not in this PR unless perceived latency demands
  it): pre-render adjacent pages on an offscreen canvas inside the
  WebView.

### Bridge changes (`components/pdf/pdf-webview-bridge.ts`)
- Add `renderPage` outbound message.
- Inbound `pageRendered { pageNumber, durationMs }` event (used by RN to
  flip `pageRenderState`).
- Keep `textSelected`, `highlight`, `gotoPage`, `outline`.

### Tests
- Unit tests for the gesture-to-page-change logic (pure RN, no
  WebView).
- Bridge contract test: `renderPage` round-trips through the message
  protocol.
- Reader integration test asserting that calling `nextPage()` shifts
  `currentPage` by 1 and the bridge sends `renderPage(n+1)`.
- Visual A/B: a Maestro screenshot of a known PDF body-text page (e.g.
  *Crime and Punishment*) at iOS sim DPR 3, compared to a baseline
  capture before the change. Reviewer should see edge sharpness improve.

### Risks
- **Page-turn perceived latency.** First render of an unseen page is
  100-300ms in pdfjs. If swipe feels laggy in QA, we add adjacent-page
  pre-render. Mitigation is well-understood and reversible.
- **WebView state across page changes.** Highlights and text selections
  are page-scoped, so the existing highlight overlay re-renders per
  page. No regression expected.
- **Landscape PDFs (slides).** Fit-to-width letterboxes them. Acceptable.

## Stream 4 — Maestro import + screenshots

### Changes
- Extend `.maestro/07-epub-reader.yaml`:
  - `takeScreenshot library-pre-import`
  - import via URL
  - `takeScreenshot library-post-import` (asserts new cover visible)
  - open reader
  - `takeScreenshot reader-page-1`
  - `assertVisible` on body text (not just chrome)
  - swipe forward, `takeScreenshot reader-page-2`
- Extend `.maestro/08-pdf-reader.yaml`: same shape, with PDF URL.
- New `.maestro/13-library-grid.yaml`: launches app with seeded books
  (via the existing import flow), asserts grid layout (two columns
  visible), taps a cover, confirms reader opens.
- Register the new flow in `.maestro/config.yaml`.

### Out of scope
- Native file-picker / share-sheet import (Maestro can't drive picker
  reliably without simulator-side seeding).

## Agent team for execution

After this spec lands and the implementation plan is written:

- **Padlocks** → `team-tester` (red tests) → `team-coder` (green). Small
  and mechanical.
- **Grid + covers** → `team-architect` → `team-tester` → `team-coder`.
  Cover-extraction pipeline touches the data layer.
- **PDF Path D** → `team-architect` → `team-tester` → `team-coder`.
  Bridge protocol + gesture model both need design before code.
- **Maestro** → runs *after* Streams 2 and 3 land on the branch
  (depends on their UI being in place).
- **End** → `team-reviewer` over the full diff.

Streams 1 and 3 are independent and can run in parallel. Stream 2 blocks
Stream 4 (Maestro needs the grid + covers to assert on). Stream 3
partially blocks Stream 4 (swipe-page screenshots need the new reader).

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

## Open items / follow-ups

- Pre-render adjacent PDF pages if QA flags swipe latency.
- Pinch-zoom inside a PDF page — separate spec.
- C2 (native horizontal-swipe via `react-native-pdf` + headless pdfjs)
  remains an option for a future architecture upgrade; deferred until
  Path D is in production.
- Auto-submit MAS releases (per existing memory) unaffected by this work.
