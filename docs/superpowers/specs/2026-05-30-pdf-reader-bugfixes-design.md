# PDF Reader Bugfixes — Design Spec

Three user-reported bugs in the Rishi Electron PDF reader (`apps/rishi-electron`), addressed together because they all live in the same subsystem.

## Bugs

1. **Scroll resistance** — when the user scrolls **up**, the page feels like it pushes back, producing a janky experience.
2. **Footer read aloud** — TTS reads page chrome like `"2 | Chapter 1: Introduction"` that the existing footer mask fails to catch.
3. **Sentence split across chunks** — a single sentence is sometimes broken across two TTS chunks, producing an unnatural pause mid-sentence.

## Bug 1 — Scroll resistance: pre-measure page heights

### Root cause

`apps/rishi-electron/src/renderer/src/components/pdf/hooks/useVirualization.tsx:82` configures TanStack Virtual with `estimateSize: () => estimatedPageHeight` — a single constant for every page. PDF pages have widely varying rendered heights (cover, TOC, text, image-heavy pages), so when the user scrolls past a page TanStack measures the real height and silently issues an `adjustments` value to keep visual position stable. Scrolling **up** is worst because just-measured pages above the viewport trigger adjustments that pull against the user's scroll direction.

The fix is to give TanStack the true height for each page index, so it never needs to fire adjustments.

### Approach

PDF pages expose their geometry before render via pdf.js's `page.view`. A page's rendered CSS height is derivable from `view[3] - view[1]` and the reader's render scale.

A new `usePdfStore` slice — `pageHeights: Map<number, number>` (keyed by book id, value is `number[]` indexed by 0-based page) — holds the per-page heights once measured. `useVirualization` reads from this slice via `estimateSize: (i) => pageHeights[i] ?? FALLBACK_HEIGHT`.

Pre-measurement extends the book-open page walk in `pdf.tsx:732-744` that already calls `loadedDoc.getPage(n)`. The walk is hoisted above the footer-detection conditional so it runs unconditionally — heights are needed regardless of whether the footer-mask pref is on or the book meets `MIN_PAGES_FOR_DETECTION`. The same loop pushes `{pageNumber, baseHeight}` (where `baseHeight = view[3] - view[1]`, in PDF user-space units) into the new store slice, and — if footer detection is enabled — also collects `TextContent` for the existing mask build. The pass is async and runs in the background; the virtualizer falls back to a constant `FALLBACK_HEIGHT` until measurement arrives, then re-reads. Because pre-measured heights are *exact* (derived from the same `getViewport` call the renderer uses), TanStack never needs to apply adjustments once the slice is populated.

### Edge cases

- **Book just opened, slice empty**: virtualizer estimates with the old constant. Adjustments may still fire briefly; behavior is no worse than today.
- **Page measurement still in progress**: `estimateSize` returns `FALLBACK_HEIGHT` for unmeasured indices. As pages are measured the virtualizer's `measureElement` continues to refine; the goal is to seed accurate estimates ASAP, not to eliminate measurement.
- **User changes render scale**: rendered CSS height = `baseHeight * currentScale`. The store slice holds `baseHeight` only; `estimateSize` reads `currentScale` from the existing scale source and multiplies. Scale changes invalidate nothing in the slice and don't require remeasurement.

## Bug 2 — Footer read aloud: strategy-based detection

### Root cause

`apps/rishi-electron/src/renderer/src/components/pdf/utils/buildFooterMask.ts` uses a single heuristic: items with the same `(yBin, normalizedText)` appearing on ≥30% of pages get masked. Chapter-title footers like `"Chapter 1: Introduction"` appear only on pages within that chapter — typically under 30% of the book — and slip through. The page number `"2"` on the same baseline *does* get masked (via the `__NUM__` normalization), but the rest of the footer line does not.

### Approach: pluggable strategy framework

Replace the monolithic `buildFooterMask` with a strategy framework:

```ts
type FooterStrategy = (pages: PageScanInput[], opts) => FooterMask
type FooterPostProcessor = (mask: FooterMask, pages: PageScanInput[]) => FooterMask

function buildFooterMask(pages, opts) {
  const partials = STRATEGIES.map(s => s(pages, opts))
  const merged = unionMasks(partials)
  return POST_PROCESSORS.reduce((m, p) => p(m, pages), merged)
}
```

Each strategy returns a `FooterMask` independently. The orchestrator unions them: **if any strategy flags an item, it is treated as footer chrome**. Post-processors run after the union to refine the merged result.

### Strategies shipped in v1

**`repetitionStrategy`** — Existing behavior, extracted unchanged. Items with the same `(yBin, normalizedText)` on ≥30% of pages. Catches page numbers, running titles, copyright lines.

**`bottomBandPositionStrategy`** — *New.* For each y-bin in the bottom band, count how many pages have **any** text-bearing item at that y-bin (regardless of content). If ≥30% of pages do, flag every item at that y-bin on the pages where it appears. Catches footer baselines where text varies per chapter but the position is stable across the book.

### Post-processor shipped in v1

**`expandToLineMates`** — For each already-flagged item, also flag its baseline-mates on the same page (items whose y-bin matches within tolerance). Pulls in separators, chapter titles, and other co-located chrome that no strategy flagged directly but which sit on a confirmed footer line.

### Why both `bottomBandPositionStrategy` and `expandToLineMates`?

They overlap but neither subsumes the other:

- `bottomBandPositionStrategy` works when a footer line has **multiple** text-bearing items across the book at the same y-bin (e.g., `"2"`, `"|"`, `"Chapter 1"` on chapter pages; `"3"`, `"|"`, `"Chapter 2"` on later pages — same y-bin, varying text).
- `expandToLineMates` works when **only one** item per line got flagged (e.g., the page number caught by `repetitionStrategy`) and others need to be pulled in by adjacency.

For the screenshot bug, `expandToLineMates` is the proximate fix; `bottomBandPositionStrategy` is the durable one for footers without an embedded number.

### Existing `findRepeatingPageSuffix`

The suffix detector currently called after `buildFooterMask` in `pdf.tsx:747` becomes a third strategy in the framework. Its output is merged via the same union path, eliminating the bespoke merge loop at `pdf.tsx:748-755`.

## Bug 3 — Sentence split across chunks: sentence-aware paragraph break

### Root cause

`apps/rishi-electron/src/renderer/src/components/pdf/utils/getPageParagraphs.ts:92` forces a hard paragraph break whenever `lineCount >= 5 && item.hasEOL` — *regardless of where the sentence is*. A long paragraph that wraps to 6+ lines is sliced at line 6, mid-sentence. The 5-line cap exists to prevent runaway paragraphs when Y-gap detection misses a real boundary, but its current implementation has no awareness of sentence structure.

### Approach

Make the 5-line break sentence-aware. The line-count signal is preserved (it represents "we want to break here"), but the actual break is deferred until the current item ends with a sentence terminator.

```ts
const SENTENCE_END_RE = /[.!?][)"']?\s*$/

const wantsBreak = lineCount >= 5 && item.hasEOL
const endsAtSentence = SENTENCE_END_RE.test(item.str)
const hasAtLeastFiveLines = wantsBreak && endsAtSentence
```

If `wantsBreak` is true but the sentence has not ended, no break is emitted; `lineCount` keeps incrementing. The break fires on the next EOL item that *does* end a sentence. A safety cap (e.g., `lineCount >= 12`) forces a break unconditionally to prevent unbounded paragraphs when the heuristic fails (e.g., a page with no detectable sentence terminators).

Vertical-spacing detection (`isVerticallySpaced`) is unchanged — real paragraph boundaries from layout always win, regardless of sentence state.

### Edge cases

- **Quoted sentence** (`said "Hello."`): regex tolerates a trailing quote or apostrophe.
- **Abbreviations** (`e.g.`, `Mr.`): may cause a slightly-early break. Acceptable; the result is still natural reading.
- **No sentence terminator on the page** (e.g., math-heavy section): safety cap at 12 lines forces a break.
- **Cross-paragraph effects on resume bookmarks**: paragraph indices are `pageNumber * 10000 + slot`. Changing where breaks happen changes the slot count per page, which would invalidate existing resume bookmarks for users with PDFs in progress. **Mitigation**: index assignment is unchanged; only the *content* of each paragraph slot shifts. Resume snaps to the nearest slot on next open. Documented as a one-time, low-impact regression.

## Files Touched

| File | Change |
|---|---|
| `src/renderer/src/components/pdf/hooks/useVirualization.tsx` | `estimateSize` reads from store; scale-aware |
| `src/renderer/src/stores/pdfStore.ts` | Add `pageHeights` slice and setters |
| `src/renderer/src/components/pdf/components/pdf.tsx` | Pre-measurement pass populates `pageHeights` during existing book-open loop; remove bespoke suffix-mask merge |
| `src/renderer/src/components/pdf/utils/buildFooterMask.ts` | Refactor into orchestrator + extracted `repetitionStrategy` |
| `src/renderer/src/components/pdf/utils/footerStrategies/bottomBandPositionStrategy.ts` | **New** |
| `src/renderer/src/components/pdf/utils/footerStrategies/expandToLineMates.ts` | **New** |
| `src/renderer/src/components/pdf/utils/footerStrategies/repetitionStrategy.ts` | **New** (extracted from current `buildFooterMask`) |
| `src/renderer/src/components/pdf/utils/footerStrategies/suffixStrategy.ts` | **New** (wraps existing `findRepeatingPageSuffix`) |
| `src/renderer/src/components/pdf/utils/getPageParagraphs.ts` | Sentence-aware break gate, safety cap |

## Testing

Per repo TDD convention (red-green-refactor) — tests are written first for each unit.

### Unit tests

- **`useVirualization` (height plumbing)**: virtualizer reports correct total size for mixed-height fixtures; scrolling up doesn't fire adjustments when slice is populated.
- **`repetitionStrategy`**: extracted-behavior parity tests against current `buildFooterMask` snapshots.
- **`bottomBandPositionStrategy`**: synthetic pages where chapter titles vary per chapter at consistent y → all chapter-title items flagged.
- **`expandToLineMates`**: single-item mask → all baseline-mates flagged.
- **Orchestrator**: strategy union, idempotent post-processors.
- **`pageDataToParagraphs` (sentence-aware break)**:
  - 6-line paragraph ending mid-sentence → no break at line 6; break at next sentence-ending EOL
  - 6-line paragraph ending at sentence → break at line 6 (matches current behavior)
  - 12-line paragraph with no sentence terminator → safety break at line 12
  - Vertical-gap break in middle of sentence → break fires (layout wins)

### Manual QA

- Open the user's screenshot PDF; scroll up rapidly across many pages; verify no resist sensation.
- Open the same PDF; start TTS; verify `"Chapter 1: Introduction"` is not read.
- Open the same PDF; start TTS on the "Velocity is the key component..." paragraph; verify it is read as one chunk, not split.

## Out of scope

- Replacing TanStack Virtual with another library (considered, rejected — too big a rewrite for the value).
- Persisting `pageHeights` to disk for faster re-open (incremental win, easy follow-up).
- TOC / outline lookup as a footer strategy (incremental win, add later if needed).
- Font-size based footer strategy (incremental win, add later if needed).
- Restructuring TTS to chunk on sentences instead of paragraphs (a separate, larger discussion; current fix preserves paragraph-level chunking and only ensures paragraphs don't split mid-sentence).
