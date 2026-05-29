# PDF Reader Bugfixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three user-reported bugs in the Rishi Electron PDF reader: scroll resistance when scrolling up, footer chrome being read aloud by TTS, and sentences being split across TTS chunks.

**Architecture:** Three independent fixes living in the same subsystem (`apps/rishi-electron/src/renderer/src/components/pdf/`). Part 1 makes paragraph chunking sentence-aware. Part 2 pre-measures page geometry so TanStack Virtual stops firing layout-correction adjustments. Part 3 refactors footer detection into a pluggable strategy framework so multiple heuristics can each contribute to the mask.

**Tech Stack:** TypeScript, React, Vitest (happy-dom), TanStack Virtual, react-pdf / pdfjs-dist, Zustand for the PDF store.

**Spec:** `docs/superpowers/specs/2026-05-30-pdf-reader-bugfixes-design.md`

**Test command:** `pnpm --filter rishi-electron test -- <test-file-name>` (from monorepo root) or `pnpm test -- <test-file-name>` (from `apps/rishi-electron/`)

---

## File Map

| File | Action |
|---|---|
| `src/renderer/src/components/pdf/utils/getPageParagraphs.ts` | Modify — sentence-aware break gate |
| `src/renderer/src/components/pdf/utils/getPageParagraphs.test.ts` | Modify — add cases for new behavior |
| `src/renderer/src/stores/pdfStore.ts` | Modify — add `pageDimensionsByBookId` slice |
| `src/renderer/src/stores/pdfStore.test.ts` (create if absent — colocated) | Tests for new slice |
| `src/renderer/src/components/pdf/hooks/useVirualization.tsx` | Modify — `estimateSize` reads store |
| `src/renderer/src/components/pdf/components/pdf.tsx` | Modify — hoist page walk, populate dimensions |
| `src/renderer/src/components/pdf/utils/footerStrategies/types.ts` | Create — `FooterStrategy` / `FooterPostProcessor` types |
| `src/renderer/src/components/pdf/utils/footerStrategies/repetitionStrategy.ts` | Create — extracted from current `buildFooterMask` |
| `src/renderer/src/components/pdf/utils/footerStrategies/repetitionStrategy.test.ts` | Create — parity tests vs. current behavior |
| `src/renderer/src/components/pdf/utils/footerStrategies/bottomBandPositionStrategy.ts` | Create |
| `src/renderer/src/components/pdf/utils/footerStrategies/bottomBandPositionStrategy.test.ts` | Create |
| `src/renderer/src/components/pdf/utils/footerStrategies/suffixStrategy.ts` | Create — wraps existing `findRepeatingPageSuffix` |
| `src/renderer/src/components/pdf/utils/footerStrategies/expandToLineMates.ts` | Create — post-processor |
| `src/renderer/src/components/pdf/utils/footerStrategies/expandToLineMates.test.ts` | Create |
| `src/renderer/src/components/pdf/utils/buildFooterMask.ts` | Refactor — becomes orchestrator |
| `src/renderer/src/components/pdf/utils/buildFooterMask.test.ts` | Update — orchestrator union test |

All paths below are relative to `apps/rishi-electron/` unless prefixed with `docs/`.

---

# Part 1 — Sentence-Aware Chunking (Bug 3)

Smallest, fully self-contained. One file changed, plus tests. Do this first.

### Task 1.1: Failing test — long paragraph defers break past line 6 to the next sentence terminator

**Files:**
- Modify: `src/renderer/src/components/pdf/utils/getPageParagraphs.test.ts`

- [ ] **Step 1: Add the failing test**

Append to `getPageParagraphs.test.ts`:

```typescript
describe('pageDataToParagraphs — sentence-aware 5-line break', () => {
  // Helper: build a "page" with N successive EOL'd lines at the same y-cluster
  // (no vertical gap, so isVerticallySpaced is false). Lines beyond MIN_PARA_LEN
  // collectively form ONE paragraph today; the 5-line cap is what splits it.
  const makeLongParagraphPage = (lines: string[]): any => {
    const items: any[] = []
    // Start near top, decrement y by exactly the line-height so vertical gap
    // detection does NOT fire (lines are tight, like wrapped body text).
    let y = 560
    const lineHeight = 14 // small enough that y-delta < getParagraphThreshold
    for (const text of lines) {
      items.push(makeItem(text, y, { hasEOL: true, height: 12 }))
      y -= lineHeight
    }
    return { items, styles: {} }
  }

  it('does NOT break a 6-line paragraph mid-sentence', () => {
    // 6 lines, no sentence terminator until the very end. Today this splits at
    // line 6. After the fix, it stays as a single paragraph because lines 1-5
    // do not end a sentence.
    const lines = [
      'Velocity is the key component in nearly all software development',
      'today, and the industry has evolved from shipping boxed CDs',
      'to delivering software via web-based services that update hourly',
      'which means the difference between you and your competitors is',
      'often the speed with which you can develop and deploy new features',
      'or respond to innovations developed by other organizations today.'
    ]
    const paragraphs = pageDataToParagraphs(7, makeLongParagraphPage(lines))
    expect(paragraphs).toHaveLength(1)
    // The whole text should be present in the single emitted paragraph.
    expect(paragraphs[0].text).toContain('Velocity is the key component')
    expect(paragraphs[0].text).toContain('developed by other organizations today.')
  })

  it('breaks at sentence end when line-count threshold has been crossed', () => {
    // 7 lines: first 4 are mid-sentence, line 5 ends a sentence, lines 6-7 are
    // a new sentence. Today breaks at line 6 mid-sentence. After fix, breaks
    // after line 5 (the first sentence-ending EOL beyond the 5-line threshold).
    const lines = [
      'This first sentence wraps across several lines without ending',
      'and continues to wrap so that the line count keeps incrementing',
      'until we are quite a few lines deep into the paragraph here',
      'and still the sentence has not yet reached a terminator yet',
      'but it finally ends right here at the close of this fifth line.',
      'Now a second sentence begins. It is short and ends on line seven.',
      'Trailing matter beyond the break does not affect this test outcome.'
    ]
    const paragraphs = pageDataToParagraphs(7, makeLongParagraphPage(lines))
    expect(paragraphs.length).toBeGreaterThanOrEqual(2)
    // First paragraph contains the first sentence ending with a period.
    expect(paragraphs[0].text).toMatch(/at the close of this fifth line\.\s*$/)
    // Second paragraph contains the start of the second sentence.
    expect(paragraphs[1].text).toContain('Now a second sentence begins')
  })

  it('forces a break at the safety cap when no sentence terminator appears', () => {
    // 13 lines, none ending a sentence. After the fix, the safety cap (12)
    // forces a break so paragraphs never grow unbounded.
    const lines = Array.from(
      { length: 13 },
      (_, i) => `line ${i} of a paragraph that just keeps going and never ends`
    )
    const paragraphs = pageDataToParagraphs(7, makeLongParagraphPage(lines))
    expect(paragraphs.length).toBeGreaterThanOrEqual(2)
  })
})
```

- [ ] **Step 2: Run and confirm failure**

Run: `pnpm test -- getPageParagraphs.test.ts`
Expected: FAIL — first new test fails because today the 6-line paragraph is split mid-sentence.

- [ ] **Step 3: Commit the red test**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/getPageParagraphs.test.ts
git commit -m "test(pdf): failing tests for sentence-aware paragraph break"
```

### Task 1.2: Implement sentence-aware break

**Files:**
- Modify: `src/renderer/src/components/pdf/utils/getPageParagraphs.ts:78-110`

- [ ] **Step 1: Add the regex and safety cap constant**

Near the top of the file (after the existing `MIN_PARAGRAPH_LENGTH` / `PARAGRAPH_INDEX_PER_PAGE` constants), add:

```typescript
const SENTENCE_END_RE = /[.!?][)"'”’]?\s*$/
const PARAGRAPH_LINE_SAFETY_CAP = 12
```

The regex tolerates a trailing close-quote (straight or curly) after the terminator.

- [ ] **Step 2: Change the break condition**

In `assembleRawParagraphs`, locate the existing block:

```typescript
const hasAtlestFiveLines = lineCount >= 5 && item.hasEOL

if ((isVerticallySpaced && isThereText) || hasAtlestFiveLines) {
  if (hasAtlestFiveLines) {
    lineCount = 0
  }
```

Replace with:

```typescript
const wantsLineCountBreak = lineCount >= 5 && item.hasEOL
const endsAtSentence = SENTENCE_END_RE.test(item.str)
const exceedsSafetyCap = lineCount >= PARAGRAPH_LINE_SAFETY_CAP && item.hasEOL
const hasAtlestFiveLines = (wantsLineCountBreak && endsAtSentence) || exceedsSafetyCap

if ((isVerticallySpaced && isThereText) || hasAtlestFiveLines) {
  if (hasAtlestFiveLines) {
    lineCount = 0
  }
```

Two things change: the line-count signal now requires `endsAtSentence` to actually fire the break, and a `PARAGRAPH_LINE_SAFETY_CAP` escape hatch prevents unbounded growth when no terminator appears. Vertical-gap detection is unchanged — real layout breaks always win.

**Note for the engineer:** the new logic must append the current item's text to `paragraghSoFar` *after* deciding to break (i.e., the existing flow that emits the accumulated paragraph, then resets `paragraghSoFar`, then appends `text` on the next loop iteration). The existing code already does this — the only change is the conditions guarding the `if`. Do not reorder anything else.

- [ ] **Step 3: Run the test file**

Run: `pnpm test -- getPageParagraphs.test.ts`
Expected: PASS, all three new tests green. **Existing tests must remain green** — the change is additive (sentence-aware gating only tightens when the break fires, never loosens it for the existing 5-paragraph fixture where every "paragraph" is a single item ending at sentence terminator).

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/getPageParagraphs.ts
git commit -m "fix(pdf): defer 5-line paragraph break until sentence terminator"
```

---

# Part 2 — Pre-Measure Page Heights (Bug 1)

Three files: new store slice → modified hook → modified bootstrap. Tests for the slice and a manual QA step at the end.

### Task 2.1: Add `pageDimensionsByBookId` slice to `pdfStore`

**Files:**
- Modify: `src/renderer/src/stores/pdfStore.ts`

- [ ] **Step 1: Add the state shape**

Find the `PdfState` interface (or wherever existing state fields like `footerMaskByBookId` live). Add:

```typescript
/**
 * Per-book page dimensions in PDF user-space units (1/72 inch).
 * Indexed by 0-based page index. Holds base width/height; the virtualizer
 * derives CSS pixel height from these + the scroll container width at
 * estimate time so render-scale changes need no remeasure.
 */
pageDimensionsByBookId: { [bookId: string]: { baseWidth: number; baseHeight: number }[] }
```

Add to the store body alongside the existing slices:

```typescript
pageDimensionsByBookId: {},

setPageDimensions: (
  bookId: string,
  dims: { baseWidth: number; baseHeight: number }[]
) =>
  set((state) => ({
    pageDimensionsByBookId: { ...state.pageDimensionsByBookId, [bookId]: dims }
  })),

getPageDimension: (bookId: string, pageIndex: number) => {
  const dims = get().pageDimensionsByBookId[bookId]
  return dims ? dims[pageIndex] : undefined
}
```

Add the matching method signatures to the `PdfState` interface:

```typescript
setPageDimensions: (
  bookId: string,
  dims: { baseWidth: number; baseHeight: number }[]
) => void
getPageDimension: (
  bookId: string,
  pageIndex: number
) => { baseWidth: number; baseHeight: number } | undefined
```

- [ ] **Step 2: Add a colocated test file**

Create `src/renderer/src/stores/pdfStore.test.ts` if it doesn't exist; if it exists, append. The test:

```typescript
import { describe, it, expect, beforeEach } from 'vitest'
import { usePdfStore } from './pdfStore'

describe('usePdfStore — pageDimensionsByBookId', () => {
  beforeEach(() => {
    usePdfStore.setState({ pageDimensionsByBookId: {} })
  })

  it('round-trips dimensions for a book', () => {
    const dims = [
      { baseWidth: 612, baseHeight: 792 },
      { baseWidth: 612, baseHeight: 792 },
      { baseWidth: 612, baseHeight: 1000 }
    ]
    usePdfStore.getState().setPageDimensions('book-a', dims)
    expect(usePdfStore.getState().getPageDimension('book-a', 0)).toEqual({
      baseWidth: 612,
      baseHeight: 792
    })
    expect(usePdfStore.getState().getPageDimension('book-a', 2)).toEqual({
      baseWidth: 612,
      baseHeight: 1000
    })
  })

  it('returns undefined for an unknown book', () => {
    expect(usePdfStore.getState().getPageDimension('nope', 0)).toBeUndefined()
  })

  it('returns undefined for an out-of-range page index', () => {
    usePdfStore.getState().setPageDimensions('book-a', [{ baseWidth: 612, baseHeight: 792 }])
    expect(usePdfStore.getState().getPageDimension('book-a', 99)).toBeUndefined()
  })

  it('overwriting dimensions for the same book replaces the array', () => {
    usePdfStore.getState().setPageDimensions('book-a', [{ baseWidth: 1, baseHeight: 1 }])
    usePdfStore.getState().setPageDimensions('book-a', [{ baseWidth: 2, baseHeight: 2 }])
    expect(usePdfStore.getState().getPageDimension('book-a', 0)).toEqual({
      baseWidth: 2,
      baseHeight: 2
    })
  })
})
```

- [ ] **Step 3: Run the test**

Run: `pnpm test -- pdfStore.test.ts`
Expected: PASS — all four cases green.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/stores/pdfStore.ts apps/rishi-electron/src/renderer/src/stores/pdfStore.test.ts
git commit -m "feat(pdf-store): pageDimensionsByBookId slice for virtualizer estimates"
```

### Task 2.2: Wire `useVirualization.estimateSize` to read from the store

**Files:**
- Modify: `src/renderer/src/components/pdf/hooks/useVirualization.tsx`

- [ ] **Step 1: Read the slice in the hook and use it in `estimateSize`**

In `useVirualization`, add (near where `numPages` is read from the store):

```typescript
const getPageDimension = usePdfStore((s) => s.getPageDimension)
```

Replace `estimateSize: () => estimatedPageHeight` (line 82) with:

```typescript
estimateSize: (index: number) => {
  const dim = getPageDimension(book.id, index)
  if (!dim) return estimatedPageHeight
  const containerWidth = scrollContainerRef.current?.clientWidth
  if (!containerWidth || dim.baseWidth <= 0) return estimatedPageHeight
  // Mirror the per-page scale derivation used at render time
  // (PdfView line ~154): scale = renderedWidth / page.view[2].
  // Pages fit to container width, so renderedWidth == containerWidth.
  const scale = containerWidth / dim.baseWidth
  return dim.baseHeight * scale
},
```

The fallback to `estimatedPageHeight` covers (a) book just opened, slice empty; (b) container ref not yet attached; (c) malformed dimensions. None of those should crash the virtualizer.

- [ ] **Step 2: Build to verify no type errors**

Run: `pnpm --filter rishi-electron typecheck` (or whatever the repo's typecheck script is — check `package.json`; fall back to `pnpm tsc -b`).
Expected: clean (no new errors). If the existing baseline already has errors, only make sure you didn't add any.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/hooks/useVirualization.tsx
git commit -m "fix(pdf): estimateSize reads pre-measured dimensions from store"
```

### Task 2.3: Populate the slice during the book-open page walk

**Files:**
- Modify: `src/renderer/src/components/pdf/components/pdf.tsx:720-757`

- [ ] **Step 1: Hoist the page walk above the footer-detection conditional**

Today (line 729) the walk is *inside* `if (usePrefsStore.getState().pdfFooterDetection || numPages >= MIN_PAGES_FOR_DETECTION)`. We need it to run unconditionally so heights are always measured. Restructure the block as follows:

Replace lines 729-757 with:

```typescript
// Always pre-measure page dimensions for the virtualizer — even when
// footer detection is disabled. Heights drive estimateSize so TanStack
// Virtual doesn't have to fire layout-correction adjustments when the
// user scrolls past pages with non-default heights.
const footerDetectionEnabled =
  usePrefsStore.getState().pdfFooterDetection && numPages >= MIN_PAGES_FOR_DETECTION

const pageDims: { baseWidth: number; baseHeight: number }[] = new Array(numPages)
const scans: PageScanInput[] = []

for (let n = 1; n <= numPages; n++) {
  if (isCancelled()) return
  const page = await loadedDoc.getPage(n)
  try {
    const view = page.view
    const baseWidth = view[2] - view[0]
    const baseHeight = view[3] - view[1]
    pageDims[n - 1] = { baseWidth, baseHeight }
    if (footerDetectionEnabled) {
      const content = await page.getTextContent()
      scans.push({ pageNumber: n, content, viewportHeight: baseHeight })
    }
  } finally {
    page.cleanup()
  }
}

if (isCancelled()) return
usePdfStore.getState().setPageDimensions(book.id, pageDims)

if (!footerDetectionEnabled) {
  usePdfStore.getState().setFooterMask(book.id, new Map())
} else {
  const mask = buildFooterMask(scans)
  const suffixMask = findRepeatingPageSuffix(scans)
  for (const [pageNumber, itemSet] of suffixMask) {
    let target = mask.get(pageNumber)
    if (!target) {
      target = new Set<number>()
      mask.set(pageNumber, target)
    }
    for (const ix of itemSet) target.add(ix)
  }
  usePdfStore.getState().setFooterMask(book.id, mask)
}
```

The page-walk loop now does both jobs in one pass: always records dimensions, conditionally records TextContent for the footer pass. The footer-mask assembly logic is unchanged (and will be refactored in Part 3).

- [ ] **Step 2: Verify the build**

Run: `pnpm --filter rishi-electron typecheck`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx
git commit -m "fix(pdf): pre-measure page dimensions during book-open walk"
```

### Task 2.4: Manual QA for scroll feel

- [ ] **Step 1: Start the dev server**

Run from `apps/rishi-electron/`: `pnpm dev`

- [ ] **Step 2: Open a PDF with varied page heights**

A textbook or any PDF with a cover page + body pages works. The Kubernetes book from the user's screenshot is ideal if available locally.

- [ ] **Step 3: Test the regression**

- Scroll **down** several pages, then rapidly scroll **up**. Confirm: no "resist" feel; no visible page-position correction tugging against your scroll direction.
- Repeat at a different render scale (zoom in/out) and verify behavior holds.
- Open the same book a second time and verify the scroll position lands where expected (no off-by-many-pixels regression in the initial-offset logic).

If any of those fail, do not proceed — diagnose. Most likely culprit: `containerWidth` reads as 0 because the ref attaches after first `estimateSize` call. Mitigation: keep the fallback path.

---

# Part 3 — Strategy-Based Footer Detection (Bug 2)

Six new files, two modifications. Built incrementally so the test suite stays green at every commit.

### Task 3.1: Define strategy types

**Files:**
- Create: `src/renderer/src/components/pdf/utils/footerStrategies/types.ts`

- [ ] **Step 1: Write the file**

```typescript
import type { FooterMask, PageScanInput, BuildFooterMaskOptions } from '../buildFooterMask'

/**
 * Pluggable footer-detection strategy. Each strategy independently inspects
 * the per-page TextContent and returns a partial FooterMask. The orchestrator
 * unions the partial masks — an item flagged by ANY strategy is treated as
 * footer chrome.
 */
export type FooterStrategy = (
  pages: PageScanInput[],
  opts: BuildFooterMaskOptions
) => FooterMask

/**
 * Runs AFTER all strategies have unioned. Used to refine the merged mask
 * (e.g., expand each flagged item to its baseline-mates on the same page).
 */
export type FooterPostProcessor = (
  mask: FooterMask,
  pages: PageScanInput[],
  opts: BuildFooterMaskOptions
) => FooterMask

/** Merge any number of FooterMask values into one (set-union per page). */
export function unionMasks(masks: FooterMask[]): FooterMask {
  const out: FooterMask = new Map()
  for (const m of masks) {
    for (const [page, items] of m) {
      let target = out.get(page)
      if (!target) {
        target = new Set<number>()
        out.set(page, target)
      }
      for (const ix of items) target.add(ix)
    }
  }
  return out
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/footerStrategies/types.ts
git commit -m "feat(pdf-footer): strategy framework types and union helper"
```

### Task 3.2: Extract `repetitionStrategy` from current `buildFooterMask`

**Files:**
- Create: `src/renderer/src/components/pdf/utils/footerStrategies/repetitionStrategy.ts`
- Create: `src/renderer/src/components/pdf/utils/footerStrategies/repetitionStrategy.test.ts`

- [ ] **Step 1: Write the failing test (parity vs. current `buildFooterMask`)**

`repetitionStrategy.test.ts`:

```typescript
import { describe, it, expect } from 'vitest'
import { repetitionStrategy } from './repetitionStrategy'
import {
  buildFooterMask,
  DEFAULT_FOOTER_MASK_OPTIONS,
  type PageScanInput
} from '../buildFooterMask'

// Reuse the fixture helpers from buildFooterMask.test.ts — copy the
// makeItem/makePage helpers here to keep the test self-contained.

const VIEWPORT_HEIGHT = 600

const makeItem = (it: {
  str: string
  y: number
  height?: number
  width?: number
  transform?: number[]
  hasEOL?: boolean
}): any => ({
  str: it.str,
  dir: 'ltr',
  width: it.width ?? Math.max(10, it.str.length * 5),
  height: it.height ?? 12,
  transform: it.transform ?? [12, 0, 0, 12, 0, it.y],
  fontName: 'g_d0_f1',
  hasEOL: it.hasEOL ?? true
})

const makePage = (
  pageNumber: number,
  items: { str: string; y: number }[]
): PageScanInput => ({
  pageNumber,
  content: { items: items.map(makeItem), styles: {} as any } as any,
  viewportHeight: VIEWPORT_HEIGHT
})

describe('repetitionStrategy', () => {
  it('flags items that appear at the same y-bin and text on >= 30% of pages', () => {
    // 10 pages, each with a body item at y=400 and a page-number footer at y=30.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'BODY TEXT body text body text body text body text body text', y: 400 },
          { str: String(p), y: 30 }
        ])
      )
    }
    const mask = repetitionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    // Every page's item index 1 (the page number) should be flagged.
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.has(1)).toBe(true)
      expect(mask.get(p)?.has(0)).toBeFalsy()
    }
  })

  it('matches what the current buildFooterMask produces (parity)', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 12; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body content body content body content body content', y: 400 },
          { str: `Page ${p}`, y: 30 }
        ])
      )
    }
    const fromStrategy = repetitionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    const fromCurrent = buildFooterMask(pages)

    // Same pages should be in each map, and the item sets should match.
    expect([...fromStrategy.keys()].sort()).toEqual([...fromCurrent.keys()].sort())
    for (const p of fromStrategy.keys()) {
      expect([...(fromStrategy.get(p) ?? [])].sort()).toEqual(
        [...(fromCurrent.get(p) ?? [])].sort()
      )
    }
  })
})
```

Run: `pnpm test -- repetitionStrategy.test.ts`
Expected: FAIL — file doesn't exist yet.

- [ ] **Step 2: Implement the strategy by extracting from `buildFooterMask.ts:69-165`**

`repetitionStrategy.ts`:

```typescript
import type { TextItem, TextMarkedContent } from 'pdfjs-dist/types/src/display/api'
import {
  normalizeFooterToken,
  type FooterMask,
  type PageScanInput,
  type BuildFooterMaskOptions
} from '../buildFooterMask'
import type { FooterStrategy } from './types'

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

/**
 * Flags items that share both a y-bin and a normalized text token across
 * a threshold proportion of pages. Catches page numbers, running titles,
 * and copyright lines — anything that repeats at the same baseline with
 * (after normalization) the same text.
 *
 * Extracted verbatim from the original `buildFooterMask` body so existing
 * behavior is preserved. The orchestrator unions this with other strategies.
 */
export const repetitionStrategy: FooterStrategy = (pages, opts) => {
  const mask: FooterMask = new Map()
  if (pages.length < opts.minPages) return mask

  // Sentinel: bail if pdf.js didn't give us recognizable y-coords.
  let totalItems = 0
  let withFiniteY = 0
  for (const p of pages) {
    for (const it of p.content.items) {
      if (!isTextItem(it)) continue
      totalItems++
      if (
        Array.isArray(it.transform) &&
        it.transform.length >= 6 &&
        Number.isFinite(it.transform[5])
      ) {
        withFiniteY++
      }
    }
  }
  if (totalItems === 0) return mask
  if (withFiniteY / totalItems < 0.05) return mask

  interface Candidate {
    pageNumber: number
    itemIndex: number
    y: number
    key: string
  }
  const candidatesByPage = new Map<number, Candidate[]>()
  const pagesByKey = new Map<string, Set<number>>()

  for (const p of pages) {
    const band = p.viewportHeight * opts.bottomBandPct
    const binUnit = p.viewportHeight * opts.yBinPct
    const items = p.content.items
    const pageCandidates: Candidate[] = []
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (!isTextItem(it)) continue
      if (!Array.isArray(it.transform) || it.transform.length < 6) continue
      const y = it.transform[5]
      if (!Number.isFinite(y)) continue
      if (y >= band) continue
      if (it.str.length > opts.maxCharsPerLine) continue

      const yBin = binUnit > 0 ? Math.round(y / binUnit) : 0
      const key = `${yBin} ${normalizeFooterToken(it.str)}`
      pageCandidates.push({ pageNumber: p.pageNumber, itemIndex: i, y, key })

      let set = pagesByKey.get(key)
      if (!set) {
        set = new Set()
        pagesByKey.set(key, set)
      }
      set.add(p.pageNumber)
    }
    if (pageCandidates.length > 0) candidatesByPage.set(p.pageNumber, pageCandidates)
  }

  const threshold = opts.repetitionThreshold * pages.length

  for (const p of pages) {
    const pageCandidates = candidatesByPage.get(p.pageNumber)
    if (!pageCandidates) continue
    const passing: Candidate[] = []
    for (const c of pageCandidates) {
      const pageSet = pagesByKey.get(c.key)
      if (pageSet && pageSet.size >= threshold) passing.push(c)
    }
    if (passing.length === 0) continue

    let chosen = passing
    if (passing.length > opts.maxFooterLines) {
      chosen = [...passing].sort((a, b) => a.y - b.y).slice(0, opts.maxFooterLines)
    }

    const indexSet = new Set<number>()
    for (const c of chosen) indexSet.add(c.itemIndex)
    mask.set(p.pageNumber, indexSet)
  }

  return mask
}
```

- [ ] **Step 3: Run the test**

Run: `pnpm test -- repetitionStrategy.test.ts`
Expected: PASS — both tests green.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/footerStrategies/repetitionStrategy.ts apps/rishi-electron/src/renderer/src/components/pdf/utils/footerStrategies/repetitionStrategy.test.ts
git commit -m "feat(pdf-footer): extract repetitionStrategy with parity tests"
```

### Task 3.3: Wrap `findRepeatingPageSuffix` as a strategy

**Files:**
- Create: `src/renderer/src/components/pdf/utils/footerStrategies/suffixStrategy.ts`

- [ ] **Step 1: Write the wrapper**

```typescript
import { findRepeatingPageSuffix } from '../buildFooterMask'
import type { FooterStrategy } from './types'

/**
 * Thin adapter around the existing suffix-matcher footer detector. Lifted
 * out so the orchestrator can treat it uniformly with the other strategies
 * (was previously merged in pdf.tsx via a bespoke loop).
 */
export const suffixStrategy: FooterStrategy = (pages) => findRepeatingPageSuffix(pages)
```

If `findRepeatingPageSuffix` is not currently exported from `buildFooterMask.ts`, add it to the export list in that file (single-line edit at the export statement). Run a grep to confirm: `grep -n "findRepeatingPageSuffix" apps/rishi-electron/src/renderer/src/components/pdf/utils/buildFooterMask.ts` — if it's defined but not exported, prefix with `export`.

- [ ] **Step 2: Typecheck**

Run: `pnpm --filter rishi-electron typecheck`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/footerStrategies/suffixStrategy.ts apps/rishi-electron/src/renderer/src/components/pdf/utils/buildFooterMask.ts
git commit -m "feat(pdf-footer): suffixStrategy wraps findRepeatingPageSuffix"
```

### Task 3.4: Implement `bottomBandPositionStrategy`

**Files:**
- Create: `src/renderer/src/components/pdf/utils/footerStrategies/bottomBandPositionStrategy.ts`
- Create: `src/renderer/src/components/pdf/utils/footerStrategies/bottomBandPositionStrategy.test.ts`

- [ ] **Step 1: Write the failing test**

`bottomBandPositionStrategy.test.ts`:

```typescript
import { describe, it, expect } from 'vitest'
import { bottomBandPositionStrategy } from './bottomBandPositionStrategy'
import { DEFAULT_FOOTER_MASK_OPTIONS, type PageScanInput } from '../buildFooterMask'

const VIEWPORT_HEIGHT = 600

const makeItem = (it: { str: string; y: number; hasEOL?: boolean }): any => ({
  str: it.str,
  dir: 'ltr',
  width: Math.max(10, it.str.length * 5),
  height: 12,
  transform: [12, 0, 0, 12, 0, it.y],
  fontName: 'g_d0_f1',
  hasEOL: it.hasEOL ?? true
})

const makePage = (
  pageNumber: number,
  items: { str: string; y: number }[]
): PageScanInput => ({
  pageNumber,
  content: { items: items.map(makeItem), styles: {} as any } as any,
  viewportHeight: VIEWPORT_HEIGHT
})

describe('bottomBandPositionStrategy', () => {
  it('flags every item at a y-bin that has ANY text on >= 30% of pages', () => {
    // 10 pages. y=30 always has SOME item (varying text per chapter), y=400 is body.
    const pages: PageScanInput[] = []
    const chapterTitles = [
      'Chapter 1', 'Chapter 1', 'Chapter 1',
      'Chapter 2', 'Chapter 2', 'Chapter 2',
      'Chapter 3', 'Chapter 3', 'Chapter 3', 'Chapter 3'
    ]
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'BODY body body body body body body body body body body', y: 400 },
          { str: String(p), y: 30 },           // page number
          { str: chapterTitles[p - 1], y: 30 } // chapter title at same y-bin
        ])
      )
    }
    const mask = bottomBandPositionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    // For every page, items 1 and 2 (page number + chapter title) should be flagged.
    // Item 0 (body) should NOT be.
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.has(1)).toBe(true)
      expect(mask.get(p)?.has(2)).toBe(true)
      expect(mask.get(p)?.has(0)).toBeFalsy()
    }
  })

  it('does not flag anything when the y-bin appears on < 30% of pages', () => {
    // 10 pages. Only pages 1-2 (20%) have anything in the bottom band.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      const items = [{ str: 'body body body body body body body body body', y: 400 }]
      if (p <= 2) items.push({ str: 'one-off note', y: 30 })
      pages.push(makePage(p, items))
    }
    const mask = bottomBandPositionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    // Nothing should be flagged.
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.size ?? 0).toBe(0)
    }
  })

  it('ignores items outside the bottom band', () => {
    // 10 pages with a heading at y=500 (above bottom 25% band of 600px viewport,
    // i.e., band starts at y=150 and below). Even though heading repeats, it
    // should not be flagged.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(makePage(p, [{ str: 'Heading', y: 500 }]))
    }
    const mask = bottomBandPositionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.size ?? 0).toBe(0)
    }
  })
})
```

Run: `pnpm test -- bottomBandPositionStrategy.test.ts`
Expected: FAIL — file doesn't exist.

- [ ] **Step 2: Implement the strategy**

`bottomBandPositionStrategy.ts`:

```typescript
import type { TextItem, TextMarkedContent } from 'pdfjs-dist/types/src/display/api'
import type { FooterMask, PageScanInput } from '../buildFooterMask'
import type { FooterStrategy } from './types'

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

/**
 * Position-only footer detector. For each y-bin within the bottom band,
 * counts how many pages have ANY text-bearing item at that y-bin
 * (text content does not have to match). If the count crosses the
 * repetition threshold, every item at that y-bin on those pages is
 * flagged.
 *
 * Catches footer lines where the text varies per chapter (chapter titles)
 * but the baseline is stable across the book — the case the existing
 * text-keyed repetitionStrategy misses.
 */
export const bottomBandPositionStrategy: FooterStrategy = (pages, opts) => {
  const mask: FooterMask = new Map()
  if (pages.length < opts.minPages) return mask

  interface BandItem {
    pageNumber: number
    itemIndex: number
    yBin: number
  }
  const itemsByPage = new Map<number, BandItem[]>()
  const pagesByBin = new Map<number, Set<number>>()

  for (const p of pages) {
    const band = p.viewportHeight * opts.bottomBandPct
    const binUnit = p.viewportHeight * opts.yBinPct
    if (binUnit <= 0) continue
    const pageBandItems: BandItem[] = []
    for (let i = 0; i < p.content.items.length; i++) {
      const it = p.content.items[i]
      if (!isTextItem(it)) continue
      if (!Array.isArray(it.transform) || it.transform.length < 6) continue
      const y = it.transform[5]
      if (!Number.isFinite(y)) continue
      if (y >= band) continue
      const yBin = Math.round(y / binUnit)
      pageBandItems.push({ pageNumber: p.pageNumber, itemIndex: i, yBin })

      let set = pagesByBin.get(yBin)
      if (!set) {
        set = new Set()
        pagesByBin.set(yBin, set)
      }
      set.add(p.pageNumber)
    }
    if (pageBandItems.length > 0) itemsByPage.set(p.pageNumber, pageBandItems)
  }

  const threshold = opts.repetitionThreshold * pages.length

  for (const p of pages) {
    const bandItems = itemsByPage.get(p.pageNumber)
    if (!bandItems) continue
    const indexSet = new Set<number>()
    for (const bi of bandItems) {
      const pageSet = pagesByBin.get(bi.yBin)
      if (pageSet && pageSet.size >= threshold) {
        indexSet.add(bi.itemIndex)
      }
    }
    if (indexSet.size > 0) mask.set(p.pageNumber, indexSet)
  }

  return mask
}
```

- [ ] **Step 3: Run the test**

Run: `pnpm test -- bottomBandPositionStrategy.test.ts`
Expected: PASS — all three tests green.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/footerStrategies/bottomBandPositionStrategy.ts apps/rishi-electron/src/renderer/src/components/pdf/utils/footerStrategies/bottomBandPositionStrategy.test.ts
git commit -m "feat(pdf-footer): bottomBandPositionStrategy for variable-text footers"
```

### Task 3.5: Implement `expandToLineMates` post-processor

**Files:**
- Create: `src/renderer/src/components/pdf/utils/footerStrategies/expandToLineMates.ts`
- Create: `src/renderer/src/components/pdf/utils/footerStrategies/expandToLineMates.test.ts`

- [ ] **Step 1: Write the failing test**

`expandToLineMates.test.ts`:

```typescript
import { describe, it, expect } from 'vitest'
import { expandToLineMates } from './expandToLineMates'
import {
  DEFAULT_FOOTER_MASK_OPTIONS,
  type FooterMask,
  type PageScanInput
} from '../buildFooterMask'

const VIEWPORT_HEIGHT = 600

const makeItem = (it: { str: string; y: number }): any => ({
  str: it.str,
  dir: 'ltr',
  width: Math.max(10, it.str.length * 5),
  height: 12,
  transform: [12, 0, 0, 12, 0, it.y],
  fontName: 'g_d0_f1',
  hasEOL: true
})

const makePage = (
  pageNumber: number,
  items: { str: string; y: number }[]
): PageScanInput => ({
  pageNumber,
  content: { items: items.map(makeItem), styles: {} as any } as any,
  viewportHeight: VIEWPORT_HEIGHT
})

describe('expandToLineMates', () => {
  it('expands a single flagged item to all baseline-mates on the same page', () => {
    // Page 1: items 0,1,2 share y=30 (footer baseline); item 3 is body at y=400.
    // Only item 0 is in the input mask. Expected: items 0,1,2 all flagged
    // after expansion; item 3 is not.
    const page = makePage(1, [
      { str: '2', y: 30 },
      { str: '|', y: 30 },
      { str: 'Chapter 1: Introduction', y: 30 },
      { str: 'body content', y: 400 }
    ])
    const input: FooterMask = new Map([[1, new Set([0])]])
    const out = expandToLineMates(input, [page], DEFAULT_FOOTER_MASK_OPTIONS)
    expect(out.get(1)?.has(0)).toBe(true)
    expect(out.get(1)?.has(1)).toBe(true)
    expect(out.get(1)?.has(2)).toBe(true)
    expect(out.get(1)?.has(3)).toBeFalsy()
  })

  it('does not pull in items outside the y-bin tolerance', () => {
    // Item 0 at y=30 is flagged. Item 1 at y=80 is too far (>yBinPct band).
    const page = makePage(1, [
      { str: '2', y: 30 },
      { str: 'subheading well above the footer line', y: 80 },
      { str: 'body', y: 400 }
    ])
    const input: FooterMask = new Map([[1, new Set([0])]])
    const out = expandToLineMates(input, [page], DEFAULT_FOOTER_MASK_OPTIONS)
    expect(out.get(1)?.has(0)).toBe(true)
    expect(out.get(1)?.has(1)).toBeFalsy()
  })

  it('returns an empty mask unchanged', () => {
    const out = expandToLineMates(new Map(), [makePage(1, [])], DEFAULT_FOOTER_MASK_OPTIONS)
    expect(out.size).toBe(0)
  })

  it('is idempotent (running twice yields the same result)', () => {
    const page = makePage(1, [
      { str: '2', y: 30 },
      { str: 'Chapter 1: Intro', y: 30 }
    ])
    const input: FooterMask = new Map([[1, new Set([0])]])
    const once = expandToLineMates(input, [page], DEFAULT_FOOTER_MASK_OPTIONS)
    const twice = expandToLineMates(once, [page], DEFAULT_FOOTER_MASK_OPTIONS)
    expect([...(twice.get(1) ?? [])].sort()).toEqual([...(once.get(1) ?? [])].sort())
  })
})
```

Run: `pnpm test -- expandToLineMates.test.ts`
Expected: FAIL — file doesn't exist.

- [ ] **Step 2: Implement the post-processor**

`expandToLineMates.ts`:

```typescript
import type { TextItem, TextMarkedContent } from 'pdfjs-dist/types/src/display/api'
import type { FooterMask, PageScanInput } from '../buildFooterMask'
import type { FooterPostProcessor } from './types'

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

/**
 * For each item already flagged on a page, also flag its baseline-mates
 * (items at the same y-bin on the same page). Pulls in mixed-content
 * footer chrome like "2 | Chapter 1: Introduction" where only "2" got
 * caught by an earlier strategy.
 *
 * Pure post-processor — operates on the already-merged mask, never mutates
 * its inputs, and produces a fresh FooterMask.
 */
export const expandToLineMates: FooterPostProcessor = (mask, pages, opts) => {
  if (mask.size === 0) return new Map()

  const pageByNumber = new Map<number, PageScanInput>()
  for (const p of pages) pageByNumber.set(p.pageNumber, p)

  const out: FooterMask = new Map()
  for (const [pageNumber, flaggedItems] of mask) {
    const page = pageByNumber.get(pageNumber)
    if (!page) {
      out.set(pageNumber, new Set(flaggedItems))
      continue
    }
    const binUnit = page.viewportHeight * opts.yBinPct
    if (binUnit <= 0) {
      out.set(pageNumber, new Set(flaggedItems))
      continue
    }

    // Resolve the y-bins that already have flagged items on this page.
    const flaggedBins = new Set<number>()
    for (const ix of flaggedItems) {
      const it = page.content.items[ix]
      if (!isTextItem(it)) continue
      if (!Array.isArray(it.transform) || it.transform.length < 6) continue
      const y = it.transform[5]
      if (!Number.isFinite(y)) continue
      flaggedBins.add(Math.round(y / binUnit))
    }

    // Walk every item on the page and flag any whose y-bin is in the set.
    const expanded = new Set<number>(flaggedItems)
    for (let i = 0; i < page.content.items.length; i++) {
      const it = page.content.items[i]
      if (!isTextItem(it)) continue
      if (!Array.isArray(it.transform) || it.transform.length < 6) continue
      const y = it.transform[5]
      if (!Number.isFinite(y)) continue
      const bin = Math.round(y / binUnit)
      if (flaggedBins.has(bin)) expanded.add(i)
    }
    out.set(pageNumber, expanded)
  }
  return out
}
```

- [ ] **Step 3: Run the test**

Run: `pnpm test -- expandToLineMates.test.ts`
Expected: PASS — all four tests green.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/footerStrategies/expandToLineMates.ts apps/rishi-electron/src/renderer/src/components/pdf/utils/footerStrategies/expandToLineMates.test.ts
git commit -m "feat(pdf-footer): expandToLineMates post-processor"
```

### Task 3.6: Refactor `buildFooterMask` into the orchestrator

**Files:**
- Modify: `src/renderer/src/components/pdf/utils/buildFooterMask.ts`
- Modify: `src/renderer/src/components/pdf/utils/buildFooterMask.test.ts`

- [ ] **Step 1: Write the new orchestrator test (RED)**

Append to `buildFooterMask.test.ts`:

```typescript
describe('buildFooterMask — orchestrator union', () => {
  it('flags items contributed by repetitionStrategy AND by bottomBandPositionStrategy', () => {
    // 10 pages. Each has a page number (caught by repetition) and a
    // chapter title at the same y-bin (caught only by position).
    const pages: PageScanInput[] = []
    const titles = [
      'Chapter 1', 'Chapter 1', 'Chapter 1', 'Chapter 1',
      'Chapter 2', 'Chapter 2', 'Chapter 2', 'Chapter 2',
      'Chapter 3', 'Chapter 3'
    ]
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'BODY body body body body body body body body body body', y: 400 },
          { str: String(p), y: 30 },     // page number — repetition catches this
          { str: titles[p - 1], y: 30 }  // chapter title — position catches this
        ])
      )
    }
    const mask = buildFooterMask(pages)
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.has(1)).toBe(true)
      expect(mask.get(p)?.has(2)).toBe(true)
      expect(mask.get(p)?.has(0)).toBeFalsy()
    }
  })
})
```

Run: `pnpm test -- buildFooterMask.test.ts`
Expected: FAIL — the chapter title (item 2) is not yet flagged because today's `buildFooterMask` only runs the repetition heuristic.

- [ ] **Step 2: Refactor the orchestrator**

Replace the body of `buildFooterMask` in `buildFooterMask.ts` with:

```typescript
import { repetitionStrategy } from './footerStrategies/repetitionStrategy'
import { bottomBandPositionStrategy } from './footerStrategies/bottomBandPositionStrategy'
import { expandToLineMates } from './footerStrategies/expandToLineMates'
import { unionMasks } from './footerStrategies/types'
import type { FooterStrategy, FooterPostProcessor } from './footerStrategies/types'

const STRATEGIES: FooterStrategy[] = [repetitionStrategy, bottomBandPositionStrategy]
const POST_PROCESSORS: FooterPostProcessor[] = [expandToLineMates]

export function buildFooterMask(
  pages: PageScanInput[],
  opts: Partial<BuildFooterMaskOptions> = {}
): FooterMask {
  const o: BuildFooterMaskOptions = { ...DEFAULT_FOOTER_MASK_OPTIONS, ...opts }
  if (pages.length < o.minPages) return new Map()

  const partial = STRATEGIES.map((s) => s(pages, o))
  let merged = unionMasks(partial)
  for (const pp of POST_PROCESSORS) merged = pp(merged, pages, o)
  return merged
}
```

Keep all the existing exports (`normalizeFooterToken`, `findRepeatingPageSuffix`, `PageScanInput`, `FooterMask`, `BuildFooterMaskOptions`, `DEFAULT_FOOTER_MASK_OPTIONS`, `MIN_PAGES_FOR_DETECTION`) intact — they are imported elsewhere and by the new strategy files. Delete only the now-unused internal helpers that were inlined into the old `buildFooterMask` body (the `Candidate` type, the local `isTextItem`, the loops that built `candidatesByPage` / `pagesByKey`). `normalizeFooterToken`, the `PURE_NUMERIC_RE` / `EMBEDDED_NUMBER_RE` constants, and `findRepeatingPageSuffix` stay.

**`suffixStrategy` is intentionally NOT in `STRATEGIES`** at this point — its current call site in `pdf.tsx` still invokes `findRepeatingPageSuffix` directly. Task 3.7 moves that into the orchestrator. Keeping it separate now means this refactor doesn't change `pdf.tsx` behavior.

- [ ] **Step 3: Run the full test file**

Run: `pnpm test -- buildFooterMask.test.ts`
Expected: PASS — the orchestrator union test passes, AND all existing buildFooterMask tests remain green. If any prior test now fails because the new strategy also flagged something the old test didn't expect, examine carefully — that may be a *correct* expansion of mask coverage (in which case update the test) or an over-flagging regression (in which case tighten the new strategy). Most prior tests should be unaffected.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/buildFooterMask.ts apps/rishi-electron/src/renderer/src/components/pdf/utils/buildFooterMask.test.ts
git commit -m "refactor(pdf-footer): buildFooterMask becomes strategy orchestrator"
```

### Task 3.7: Move `suffixStrategy` into the orchestrator, remove the bespoke merge from `pdf.tsx`

**Files:**
- Modify: `src/renderer/src/components/pdf/utils/buildFooterMask.ts`
- Modify: `src/renderer/src/components/pdf/components/pdf.tsx`

- [ ] **Step 1: Add `suffixStrategy` to the orchestrator's strategy list**

In `buildFooterMask.ts`, update the imports and `STRATEGIES` array:

```typescript
import { suffixStrategy } from './footerStrategies/suffixStrategy'

const STRATEGIES: FooterStrategy[] = [
  repetitionStrategy,
  bottomBandPositionStrategy,
  suffixStrategy
]
```

- [ ] **Step 2: Remove the bespoke merge from `pdf.tsx`**

In `pdf.tsx`, locate (in the block edited in Task 2.3):

```typescript
const mask = buildFooterMask(scans)
const suffixMask = findRepeatingPageSuffix(scans)
for (const [pageNumber, itemSet] of suffixMask) {
  let target = mask.get(pageNumber)
  if (!target) {
    target = new Set<number>()
    mask.set(pageNumber, target)
  }
  for (const ix of itemSet) target.add(ix)
}
usePdfStore.getState().setFooterMask(book.id, mask)
```

Replace with:

```typescript
usePdfStore.getState().setFooterMask(book.id, buildFooterMask(scans))
```

Remove the now-unused `findRepeatingPageSuffix` import from `pdf.tsx`.

- [ ] **Step 3: Run all PDF tests**

Run: `pnpm test -- pdf`
Expected: PASS for all PDF-related test files. If any test that previously asserted on the *exact* set of flagged items now sees additional items (from the suffix strategy now contributing inside `buildFooterMask`), update the assertion — those items were already being added downstream, just at a different layer.

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/pdf/utils/buildFooterMask.ts apps/rishi-electron/src/renderer/src/components/pdf/components/pdf.tsx
git commit -m "refactor(pdf-footer): suffixStrategy joins orchestrator, pdf.tsx loses bespoke merge"
```

### Task 3.8: Manual QA for the footer bug

- [ ] **Step 1: Start the dev server**

Run from `apps/rishi-electron/`: `pnpm dev`

- [ ] **Step 2: Open the bug-repro PDF**

Open a PDF with chapter-title footers (the user's Kubernetes book if available). Start TTS on a page where "Chapter N: Title" appears in the footer.

- [ ] **Step 3: Verify**

- The chapter title and page number footer are NOT read aloud.
- Body text is still read aloud, with correct paragraph chunking.
- Highlighting still tracks correctly (footer items being masked should not break the highlight overlay).
- Open a second, different PDF to confirm no false-positive over-masking (e.g., legitimate text at the bottom of a page being silenced).

---

## Self-Review Notes

**Spec coverage check:**
- Bug 1 (scroll resistance / pre-measure heights) → Tasks 2.1–2.4 ✓
- Bug 2 (footer strategy framework + `bottomBandPositionStrategy` + `expandToLineMates` + `repetitionStrategy` + `suffixStrategy`) → Tasks 3.1–3.8 ✓
- Bug 3 (sentence-aware paragraph break + safety cap) → Tasks 1.1–1.2 ✓
- Manual QA per spec → Tasks 2.4, 3.8 ✓
- Out-of-scope items (TanStack replacement, persisting heights, TOC strategy, font-size strategy, sentence-level TTS chunking) → correctly absent from plan ✓

**Type/identifier consistency check:**
- `pageDimensionsByBookId` / `setPageDimensions` / `getPageDimension` used consistently in 2.1, 2.2, 2.3 ✓
- `FooterStrategy` / `FooterPostProcessor` / `unionMasks` used consistently across 3.1, 3.2, 3.4, 3.5, 3.6 ✓
- `repetitionStrategy` / `bottomBandPositionStrategy` / `suffixStrategy` / `expandToLineMates` names match across creation tasks and orchestrator registration ✓
- `baseWidth` / `baseHeight` consistent across store, hook, and bootstrap ✓
