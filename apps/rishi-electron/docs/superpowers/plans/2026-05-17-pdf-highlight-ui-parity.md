# PDF Highlight UI Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the PDF reader to feature parity with the EPUB reader for highlight UX (selection popover, click-on-highlight popover, note editor, undo, electron read-aloud context menu, persistence). Reuse existing format-agnostic components; add PDF locator math, selection hook, and overlay layer.

**Architecture:** Extend `HighlightRow` with a `format` discriminator and a `locator` JSON column (PDF only). Add three new PDF-specific modules: `pdf-locator.ts` (pure coord math), `usePdfTextSelection` (selection observer hook), and `HighlightLayer` (per-page overlay). Wire them into `PdfView` mirroring the EPUB pattern. The popovers (`SelectionPopover`, `HighlightActionPopover`, `NoteEditor`) and undo hook (`useUndoableHighlightShortcut`) are already format-agnostic and are reused unchanged.

**Tech Stack:** TypeScript / React 18 / electron / react-pdf 10.2 / pdfjs-dist 5.4 / better-sqlite3 + Drizzle ORM / vitest + happy-dom / React Testing Library / sonner toasts / zustand.

**Spec:** `apps/rishi-electron/docs/superpowers/specs/2026-05-17-pdf-highlight-ui-parity-design.md`

---

## File Structure

**Created:**
- `src/renderer/src/modules/pdf-locator.ts` + colocated `pdf-locator.test.ts`
- `src/renderer/src/hooks/usePdfTextSelection.ts` + `usePdfTextSelection.test.tsx`
- `src/renderer/src/components/pdf/HighlightLayer.tsx` + `HighlightLayer.test.tsx`

**Modified:**
- `src/main/database/migrations.ts` — bump `CURRENT_VERSION` to 2 + add v2 migration block
- `src/main/database/schema.ts` — add `format` and `locator` columns
- `src/main/ipc/highlights.ts` — accept new fields on save; surface them on list
- `src/renderer/src/modules/highlight-storage.ts` — extend `HighlightRow`; add `saveHighlightPdf`
- `src/renderer/src/modules/highlight-storage.test.ts` (create if missing) — round-trip
- `src/renderer/src/modules/highlight-actions.ts` — add a PDF apply path
- `src/renderer/src/modules/highlight-actions.test.ts` — coverage for PDF path
- `src/renderer/src/components/pdf/components/pdf-page.tsx` — capture page DOM element + viewport via `onLoadSuccess`; render `HighlightLayer`
- `src/renderer/src/components/pdf/components/pdf.tsx` — host popovers, modal, selection hook, undo shortcut
- `src/renderer/src/test-setup.ts` — ensure new IPC stubs round-trip safely

**Unchanged (re-used):**
- `src/renderer/src/components/highlights/SelectionPopover.tsx`
- `src/renderer/src/components/highlights/HighlightActionPopover.tsx`
- `src/renderer/src/components/highlights/NoteEditor.tsx`
- `src/renderer/src/hooks/useUndoableHighlightShortcut.ts`
- `src/renderer/src/types/highlight.ts`
- `src/main/contextMenu.ts`

---

## Conventions for every task

- Tests must FAIL before implementation (TDD red phase). Each task includes the expected red message.
- Run tests with `pnpm vitest run <path>` (single file) or `pnpm vitest run` (all).
- Commit messages: `feat(highlights): ...`, `fix(highlights): ...`, `test(highlights): ...`, `refactor(highlights): ...` — match recent history.
- Stage only files relevant to the current commit. Do not `git add -A` (working tree has unrelated WIP).

---

## Task 1 — Extend storage schema (DB migration + types)

**Files:**
- Modify: `src/main/database/schema.ts`
- Modify: `src/main/database/migrations.ts`
- Modify: `src/main/ipc/highlights.ts`
- Modify: `src/renderer/src/modules/highlight-storage.ts`
- Create: `src/renderer/src/modules/highlight-storage.test.ts` (if it doesn't already exist; otherwise extend)

### Step 1.1 — Write failing test: `HighlightRow` carries `format` and `locator`

- [ ] Create or extend `src/renderer/src/modules/highlight-storage.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { getHighlightsForBook, saveHighlightPdf, type HighlightRow } from './highlight-storage'

describe('highlight-storage — PDF support', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('saveHighlightPdf sends format=pdf and a locator JSON string to the IPC layer', async () => {
    const saveMock = window.electron.highlightsSave as unknown as ReturnType<typeof vi.fn>
    saveMock.mockResolvedValueOnce('row-id-1')

    const id = await saveHighlightPdf({
      bookSyncId: 'book-1',
      locator: { page: 3, rects: [{ x: 1, y: 2, w: 10, h: 12 }] },
      text: 'hello',
      color: 'yellow'
    })

    expect(id).toBe('row-id-1')
    expect(saveMock).toHaveBeenCalledTimes(1)
    const payload = saveMock.mock.calls[0][0]
    expect(payload.format).toBe('pdf')
    expect(payload.bookSyncId).toBe('book-1')
    expect(typeof payload.locator).toBe('string')
    expect(JSON.parse(payload.locator)).toEqual({ page: 3, rects: [{ x: 1, y: 2, w: 10, h: 12 }] })
    expect(payload.color).toBe('yellow')
  })

  it('getHighlightsForBook returns rows whose format and locator fields are typed', async () => {
    const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
    listMock.mockResolvedValueOnce([
      {
        id: 'r1', bookId: 'b1',
        format: 'epub', cfiRange: 'epubcfi(/6/4!/4/2)', locator: null,
        text: 't', color: 'yellow', note: '', chapter: null,
        createdAt: '2026-05-17T00:00:00.000Z', updatedAt: null,
        syncId: null, syncVersion: 0, isDirty: 0, isDeleted: 0
      },
      {
        id: 'r2', bookId: 'b1',
        format: 'pdf', cfiRange: null, locator: JSON.stringify({ page: 1, rects: [] }),
        text: 't2', color: 'green', note: '', chapter: null,
        createdAt: '2026-05-17T00:00:00.000Z', updatedAt: null,
        syncId: null, syncVersion: 0, isDirty: 0, isDeleted: 0
      }
    ])

    const rows: HighlightRow[] = await getHighlightsForBook('b1')
    expect(rows).toHaveLength(2)
    expect(rows[0].format).toBe('epub')
    expect(rows[1].format).toBe('pdf')
    expect(rows[1].locator).toBe(JSON.stringify({ page: 1, rects: [] }))
  })
})
```

- [ ] **Run and verify red:**

```
pnpm vitest run src/renderer/src/modules/highlight-storage.test.ts
```

Expected fail: `saveHighlightPdf` is not exported; `HighlightRow` does not have `format`/`locator`.

### Step 1.2 — Extend `HighlightRow` and add `saveHighlightPdf` in renderer storage

- [ ] In `src/renderer/src/modules/highlight-storage.ts`:

```ts
// Replace the existing HighlightRow interface (around lines 6-20):
export interface HighlightRow {
  id: string
  bookId: string
  format: 'epub' | 'pdf'      // NEW
  cfiRange: string | null      // CHANGE: was string, now nullable
  locator: string | null       // NEW — JSON-encoded PdfLocator for PDF rows
  text: string
  color: string
  note: string
  chapter: string | null
  createdAt: string
  updatedAt: number | null
  syncId: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
}

// PDF locator JSON shape used in the renderer:
export interface PdfLocator {
  page: number
  rects: Array<{ x: number; y: number; w: number; h: number }>
}

// New function — append below existing saveHighlight:
export async function saveHighlightPdf(params: {
  bookSyncId: string
  locator: PdfLocator
  text: string
  color?: string
  note?: string
  chapter?: string | null
}): Promise<string> {
  return await window.electron.highlightsSave({
    format: 'pdf',
    bookSyncId: params.bookSyncId,
    cfiRange: null,
    locator: JSON.stringify(params.locator),
    text: params.text,
    color: params.color ?? 'yellow',
    note: params.note ?? '',
    chapter: params.chapter ?? null
  })
}
```

- [ ] Also update the existing `saveHighlight` so its payload includes `format: 'epub'` and `locator: null`:

```ts
// Modify the existing saveHighlight body (around lines 25-34):
export async function saveHighlight(params: {
  bookSyncId: string
  cfiRange: string
  text: string
  color?: string
  note?: string
  chapter?: string | null
}): Promise<string> {
  return await window.electron.highlightsSave({
    format: 'epub',          // NEW
    bookSyncId: params.bookSyncId,
    cfiRange: params.cfiRange,
    locator: null,            // NEW
    text: params.text,
    color: params.color ?? 'yellow',
    note: params.note ?? '',
    chapter: params.chapter ?? null
  })
}
```

### Step 1.3 — Update Electron IPC mock if needed

- [ ] Open `src/renderer/src/test-setup.ts`. If `window.electron.highlightsSave` and `highlightsList` are mocked with bare `vi.fn()`, no change is needed (the tests queue specific return values per-case). If the setup hard-codes a row shape, add `format: 'epub'` and `locator: null` to that default.

### Step 1.4 — Run renderer test to verify green

- [ ] Run:

```
pnpm vitest run src/renderer/src/modules/highlight-storage.test.ts
```

Expected: PASS.

### Step 1.5 — Update main-process Drizzle schema

- [ ] In `src/main/database/schema.ts`, modify the `highlights` table (currently lines 45-59) to:

```ts
export const highlights = sqliteTable('highlights', {
  id: text('id').primaryKey(),
  bookId: text('book_id').notNull(),
  format: text('format').notNull().default('epub'),     // NEW
  cfiRange: text('cfi_range'),                            // CHANGED: drop .notNull()
  locator: text('locator'),                               // NEW (nullable JSON string)
  text: text('text').notNull().default(''),
  color: text('color').notNull().default('yellow'),
  note: text('note').notNull().default(''),
  chapter: text('chapter'),
  createdAt: text('created_at').notNull().default(''),
  updatedAt: integer('updated_at'),
  syncId: text('sync_id'),
  syncVersion: integer('sync_version').notNull().default(0),
  isDirty: integer('is_dirty').notNull().default(1),
  isDeleted: integer('is_deleted').notNull().default(0)
})
```

### Step 1.6 — Add v2 migration

- [ ] In `src/main/database/migrations.ts`:

  1. Bump the version constant at the top of the file:

```ts
const CURRENT_VERSION = 2   // was 1
```

  2. After the existing v1 block inside `runMigrations(db)`, add a v2 block following the same pattern the v1 block uses to execute SQL. The SQL to run is:

```sql
ALTER TABLE highlights ADD COLUMN format TEXT NOT NULL DEFAULT 'epub';
ALTER TABLE highlights ADD COLUMN locator TEXT;
```

  Then bump the user_version pragma to 2:

```ts
db.pragma('user_version = 2')
```

  Use the exact same SQL-execution helper the v1 block uses (recon report indicates this is the existing migration entry pattern in this file). Do not introduce a new execution style.

  **SQLite caveat:** plain ALTER cannot drop `NOT NULL`. On disk `cfi_range` remains NOT NULL; for PDF rows the IPC layer writes `''` (empty string) and the row mapper translates `''` → `null` on read. The renderer's `cfiRange` type is `string | null` to reflect this.

### Step 1.7 — Update main-process IPC handler

- [ ] In `src/main/ipc/highlights.ts`:

  1. Add `format: string | null | undefined` and `locator: string | null | undefined` to the type of the `highlights:save` payload.
  2. In the insert/upsert path, persist `format: payload.format ?? 'epub'` and `locator: payload.locator ?? null`.
  3. For PDF rows (`format === 'pdf'`), write `cfi_range: ''` to satisfy on-disk NOT NULL.
  4. In the row mapper that produces results for `highlights:list`, return:
     - `format: row.format ?? 'epub'`
     - `cfiRange: row.cfi_range === '' ? null : row.cfi_range`
     - `locator: row.locator ?? null`
  5. The existing upsert key for EPUB is `(bookId, cfi_range)`. For PDF rows, the upsert should key on `(bookId, locator)`; if `format === 'pdf'`, skip the EPUB upsert lookup and always insert a fresh row with a new id.

### Step 1.8 — Commit

- [ ] 
```
git add src/main/database/schema.ts src/main/database/migrations.ts src/main/ipc/highlights.ts \
        src/renderer/src/modules/highlight-storage.ts src/renderer/src/modules/highlight-storage.test.ts \
        src/renderer/src/test-setup.ts

git commit -m "feat(highlights): add format + locator columns to support PDF highlights"
```

---

## Task 2 — PDF locator math module (`pdf-locator.ts`)

**Files:**
- Create: `src/renderer/src/modules/pdf-locator.ts`
- Create: `src/renderer/src/modules/pdf-locator.test.ts`

### Step 2.1 — Write failing tests

- [ ] Create `src/renderer/src/modules/pdf-locator.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { selectionToPdfLocator, pdfLocatorToScreenRects } from './pdf-locator'

// Minimal fake of pdfjs PageViewport. The real one comes from pdf.getPage(n).getViewport({scale}).
function makeViewport(opts: { width: number; height: number; scale: number }) {
  return {
    width: opts.width,
    height: opts.height,
    scale: opts.scale,
    // For an unrotated page: viewportX = pdfX * scale; viewportY = (pageHeightPdf - pdfY) * scale
    convertToViewportPoint(pdfX: number, pdfY: number): [number, number] {
      const pageHeightPdf = opts.height / opts.scale
      return [pdfX * opts.scale, (pageHeightPdf - pdfY) * opts.scale]
    },
    convertToPdfPoint(vx: number, vy: number): [number, number] {
      const pageHeightPdf = opts.height / opts.scale
      return [vx / opts.scale, pageHeightPdf - vy / opts.scale]
    }
  } as const
}

function makePageEl(rect: { left: number; top: number; width: number; height: number }): HTMLElement {
  const div = document.createElement('div')
  Object.defineProperty(div, 'getBoundingClientRect', {
    value: () => ({
      left: rect.left, top: rect.top,
      right: rect.left + rect.width, bottom: rect.top + rect.height,
      width: rect.width, height: rect.height, x: rect.left, y: rect.top,
      toJSON() { return this }
    })
  })
  return div
}

describe('pdf-locator', () => {
  describe('selectionToPdfLocator', () => {
    it('returns null when range is collapsed', () => {
      const range = document.createRange()
      const pageEl = makePageEl({ left: 0, top: 0, width: 400, height: 600 })
      const viewport = makeViewport({ width: 400, height: 600, scale: 1 })
      expect(selectionToPdfLocator(range, pageEl, viewport as never, 1)).toBeNull()
    })

    it('returns null if start and end resolve to different page elements', () => {
      const pageA = makePageEl({ left: 0, top: 0, width: 400, height: 600 })
      const pageB = makePageEl({ left: 0, top: 700, width: 400, height: 600 })
      pageA.className = 'react-pdf__Page'
      pageB.className = 'react-pdf__Page'
      const t1 = document.createTextNode('hello')
      const t2 = document.createTextNode('world')
      pageA.appendChild(t1); pageB.appendChild(t2)
      const range = document.createRange()
      range.setStart(t1, 0); range.setEnd(t2, 5)
      const viewport = makeViewport({ width: 400, height: 600, scale: 1 })
      expect(selectionToPdfLocator(range, pageA, viewport as never, 1)).toBeNull()
    })

    it('converts a single client rect into PDF coords with bottom-left origin', () => {
      const pageEl = makePageEl({ left: 50, top: 100, width: 400, height: 600 })
      const viewport = makeViewport({ width: 400, height: 600, scale: 1 })
      const range = document.createRange()
      const text = document.createTextNode('xyz')
      pageEl.appendChild(text)
      range.setStart(text, 0); range.setEnd(text, 3)
      Object.defineProperty(range, 'getClientRects', {
        value: () => [{ left: 60, top: 120, width: 100, height: 15, right: 160, bottom: 135 }]
      })

      const result = selectionToPdfLocator(range, pageEl, viewport as never, 7)
      expect(result).toEqual({
        page: 7,
        rects: [
          // viewport top-left of rect is (10, 20) relative to page.
          // bottom-left in PDF coords: x=10, y=600-35=565. w=100, h=15.
          { x: 10, y: 565, w: 100, h: 15 }
        ]
      })
    })

    it('produces stable locators across zoom (round-trip @ scale=2)', () => {
      const pageEl1 = makePageEl({ left: 0, top: 0, width: 400, height: 600 })
      const vp1 = makeViewport({ width: 400, height: 600, scale: 1 })
      const range = document.createRange()
      const t = document.createTextNode('abcdef')
      pageEl1.appendChild(t)
      range.setStart(t, 0); range.setEnd(t, 3)
      Object.defineProperty(range, 'getClientRects', {
        value: () => [{ left: 0, top: 0, width: 50, height: 12, right: 50, bottom: 12 }]
      })

      const loc = selectionToPdfLocator(range, pageEl1, vp1 as never, 1)!
      const pageEl2 = makePageEl({ left: 0, top: 0, width: 800, height: 1200 })
      const vp2 = makeViewport({ width: 800, height: 1200, scale: 2 })
      const screenRects = pdfLocatorToScreenRects(loc, pageEl2, vp2 as never)
      expect(screenRects).toEqual([{ left: 0, top: 0, width: 100, height: 24 }])
    })
  })

  describe('pdfLocatorToScreenRects', () => {
    it('renders saved rects relative to the page element in CSS pixels', () => {
      const pageEl = makePageEl({ left: 50, top: 100, width: 400, height: 600 })
      const vp = makeViewport({ width: 400, height: 600, scale: 1 })
      const screen = pdfLocatorToScreenRects(
        { page: 1, rects: [{ x: 10, y: 565, w: 100, h: 15 }] },
        pageEl, vp as never
      )
      expect(screen).toEqual([{ left: 10, top: 20, width: 100, height: 15 }])
    })
  })
})
```

- [ ] **Run and verify red:**

```
pnpm vitest run src/renderer/src/modules/pdf-locator.test.ts
```

Expected fail: module doesn't exist.

### Step 2.2 — Implement `pdf-locator.ts`

- [ ] Create `src/renderer/src/modules/pdf-locator.ts`:

```ts
import type { PdfLocator } from './highlight-storage'

// Structural subset of pdfjs's PageViewport — anything real from pdfjs satisfies this.
export interface ViewportLike {
  width: number
  height: number
  scale: number
  convertToViewportPoint(pdfX: number, pdfY: number): [number, number]
  convertToPdfPoint(viewportX: number, viewportY: number): [number, number]
}

function findPageAncestor(node: Node | null): HTMLElement | null {
  let cur: Node | null = node
  while (cur) {
    if (cur instanceof HTMLElement && cur.classList.contains('react-pdf__Page')) return cur
    cur = cur.parentNode
  }
  return null
}

export function selectionToPdfLocator(
  range: Range,
  pageEl: HTMLElement,
  viewport: ViewportLike,
  pageNumber: number
): PdfLocator | null {
  if (range.collapsed) return null
  const startPage = findPageAncestor(range.startContainer) ?? pageEl
  const endPage = findPageAncestor(range.endContainer) ?? pageEl
  if (startPage !== endPage) return null

  const pageRect = pageEl.getBoundingClientRect()
  const clientRects = Array.from(range.getClientRects())
  if (clientRects.length === 0) return null

  const rects: PdfLocator['rects'] = []
  for (const r of clientRects) {
    const vxLeft = r.left - pageRect.left
    const vyTop = r.top - pageRect.top
    const vxRight = vxLeft + r.width
    const vyBottom = vyTop + r.height

    const [pdfXLeft, pdfYBottom] = viewport.convertToPdfPoint(vxLeft, vyBottom)
    const [pdfXRight, pdfYTop] = viewport.convertToPdfPoint(vxRight, vyTop)
    const w = pdfXRight - pdfXLeft
    const h = pdfYTop - pdfYBottom
    if (w <= 0 || h <= 0) continue
    rects.push({ x: pdfXLeft, y: pdfYBottom, w, h })
  }
  if (rects.length === 0) return null
  return { page: pageNumber, rects }
}

export function pdfLocatorToScreenRects(
  locator: PdfLocator,
  pageEl: HTMLElement,
  viewport: ViewportLike
): Array<{ left: number; top: number; width: number; height: number }> {
  void pageEl
  return locator.rects.map((r) => {
    const [vxLeft, vyBottom] = viewport.convertToViewportPoint(r.x, r.y)
    const [vxRight, vyTop] = viewport.convertToViewportPoint(r.x + r.w, r.y + r.h)
    return {
      left: vxLeft,
      top: vyTop,
      width: vxRight - vxLeft,
      height: vyBottom - vyTop
    }
  })
}
```

### Step 2.3 — Verify green

- [ ] Run:

```
pnpm vitest run src/renderer/src/modules/pdf-locator.test.ts
```

Expected: PASS, all 5 cases.

### Step 2.4 — Commit

- [ ] 
```
git add src/renderer/src/modules/pdf-locator.ts src/renderer/src/modules/pdf-locator.test.ts
git commit -m "feat(highlights): add pdf-locator coord math for PDF highlight storage"
```

---

## Task 3 — PDF text-selection hook (`usePdfTextSelection`)

**Files:**
- Create: `src/renderer/src/hooks/usePdfTextSelection.ts`
- Create: `src/renderer/src/hooks/usePdfTextSelection.test.tsx`

### Step 3.1 — Write failing tests

- [ ] Create `src/renderer/src/hooks/usePdfTextSelection.test.tsx`:

```tsx
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePdfTextSelection } from './usePdfTextSelection'
import type { ViewportLike } from '@/modules/pdf-locator'

function setupPage(opts: { pageNumber: number; rect: { left: number; top: number; width: number; height: number } }) {
  const page = document.createElement('div')
  page.className = 'react-pdf__Page'
  page.setAttribute('data-page-number', String(opts.pageNumber))
  Object.defineProperty(page, 'getBoundingClientRect', {
    value: () => ({
      left: opts.rect.left, top: opts.rect.top,
      right: opts.rect.left + opts.rect.width, bottom: opts.rect.top + opts.rect.height,
      width: opts.rect.width, height: opts.rect.height, x: opts.rect.left, y: opts.rect.top,
      toJSON() { return this }
    })
  })
  const text = document.createTextNode('hello world')
  page.appendChild(text)
  return { page, text }
}

function makeViewport(scale = 1): ViewportLike {
  return {
    width: 400 * scale, height: 600 * scale, scale,
    convertToViewportPoint(x, y) { return [x * scale, (600 - y) * scale] },
    convertToPdfPoint(x, y) { return [x / scale, 600 - y / scale] }
  }
}

describe('usePdfTextSelection', () => {
  let container: HTMLDivElement
  let containerRef: { current: HTMLDivElement | null }
  let onSelect: ReturnType<typeof vi.fn>
  let onClear: ReturnType<typeof vi.fn>

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    containerRef = { current: container }
    onSelect = vi.fn()
    onClear = vi.fn()
  })

  afterEach(() => {
    document.body.removeChild(container)
    window.getSelection()?.removeAllRanges()
  })

  it('fires onSelect with locator and anchorPos when mouseup completes a non-collapsed selection on a single page', () => {
    const { page, text } = setupPage({ pageNumber: 4, rect: { left: 0, top: 0, width: 400, height: 600 } })
    container.appendChild(page)

    renderHook(() =>
      usePdfTextSelection({
        containerRef,
        getPageElement: (n) => (n === 4 ? page : null),
        getViewport: () => makeViewport(1),
        onSelect, onClear
      })
    )

    const range = document.createRange()
    range.setStart(text, 0)
    range.setEnd(text, 5)
    Object.defineProperty(range, 'getClientRects', {
      value: () => [{ left: 5, top: 10, width: 60, height: 14, right: 65, bottom: 24 }]
    })
    const sel = window.getSelection()!
    sel.removeAllRanges()
    sel.addRange(range)

    act(() => {
      container.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: 30, clientY: 20 }))
    })

    expect(onSelect).toHaveBeenCalledTimes(1)
    const arg = onSelect.mock.calls[0][0]
    expect(arg.locator.page).toBe(4)
    expect(arg.locator.rects[0].w).toBeGreaterThan(0)
    expect(arg.anchorPos).toMatchObject({ x: expect.any(Number), y: expect.any(Number) })
  })

  it('ignores cross-page selections', () => {
    const a = setupPage({ pageNumber: 1, rect: { left: 0, top: 0, width: 400, height: 600 } })
    const b = setupPage({ pageNumber: 2, rect: { left: 0, top: 700, width: 400, height: 600 } })
    container.appendChild(a.page); container.appendChild(b.page)
    renderHook(() => usePdfTextSelection({
      containerRef,
      getPageElement: (n) => (n === 1 ? a.page : b.page),
      getViewport: () => makeViewport(1),
      onSelect, onClear
    }))
    const range = document.createRange()
    range.setStart(a.text, 0)
    range.setEnd(b.text, 5)
    Object.defineProperty(range, 'getClientRects', { value: () => [
      { left: 0, top: 0, width: 50, height: 14, right: 50, bottom: 14 }
    ]})
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)
    act(() => container.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })))
    expect(onSelect).not.toHaveBeenCalled()
  })

  it('fires onClear when selection becomes collapsed', () => {
    renderHook(() => usePdfTextSelection({
      containerRef,
      getPageElement: () => null, getViewport: () => null,
      onSelect, onClear
    }))
    act(() => {
      window.getSelection()!.removeAllRanges()
      document.dispatchEvent(new Event('selectionchange'))
    })
    expect(onClear).toHaveBeenCalled()
  })
})
```

- [ ] **Run and verify red:**

```
pnpm vitest run src/renderer/src/hooks/usePdfTextSelection.test.tsx
```

Expected fail: module doesn't exist.

### Step 3.2 — Implement `usePdfTextSelection.ts`

- [ ] Create `src/renderer/src/hooks/usePdfTextSelection.ts`:

```ts
import { useEffect, useRef } from 'react'
import { selectionToPdfLocator, type ViewportLike } from '@/modules/pdf-locator'
import type { PdfLocator } from '@/modules/highlight-storage'

export interface PdfSelectionEvent {
  locator: PdfLocator
  anchorPos: { x: number; y: number }
  text: string
}

export interface UsePdfTextSelectionParams {
  containerRef: { current: HTMLElement | null }
  getPageElement: (pageNumber: number) => HTMLElement | null
  getViewport: (pageNumber: number) => ViewportLike | null
  onSelect: (sel: PdfSelectionEvent) => void
  onClear: () => void
}

function findPageInfo(node: Node | null): { el: HTMLElement; pageNumber: number } | null {
  let cur: Node | null = node
  while (cur) {
    if (cur instanceof HTMLElement && cur.classList.contains('react-pdf__Page')) {
      const n = Number(cur.getAttribute('data-page-number') ?? '0')
      if (Number.isFinite(n) && n > 0) return { el: cur, pageNumber: n }
    }
    cur = cur.parentNode
  }
  return null
}

export function usePdfTextSelection(params: UsePdfTextSelectionParams): void {
  const paramsRef = useRef(params)
  paramsRef.current = params

  useEffect(() => {
    const container = params.containerRef.current
    if (!container) return

    const handleMouseUp = (): void => {
      const { onSelect, getPageElement, getViewport } = paramsRef.current
      const sel = window.getSelection()
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return
      const range = sel.getRangeAt(0)
      const startInfo = findPageInfo(range.startContainer)
      const endInfo = findPageInfo(range.endContainer)
      if (!startInfo || !endInfo || startInfo.el !== endInfo.el) return
      const expectedEl = getPageElement(startInfo.pageNumber)
      if (expectedEl !== startInfo.el) return
      const viewport = getViewport(startInfo.pageNumber)
      if (!viewport) return
      const locator = selectionToPdfLocator(range, startInfo.el, viewport, startInfo.pageNumber)
      if (!locator) return
      const rects = range.getClientRects()
      const first = rects.item(0)
      if (!first) return
      onSelect({
        locator,
        anchorPos: { x: first.left + first.width / 2, y: first.top - 8 },
        text: range.toString()
      })
    }

    const handleSelectionChange = (): void => {
      const sel = window.getSelection()
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed) {
        paramsRef.current.onClear()
      }
    }

    container.addEventListener('mouseup', handleMouseUp)
    document.addEventListener('selectionchange', handleSelectionChange)
    return () => {
      container.removeEventListener('mouseup', handleMouseUp)
      document.removeEventListener('selectionchange', handleSelectionChange)
    }
  }, [params.containerRef])
}
```

### Step 3.3 — Verify green

- [ ] Run:

```
pnpm vitest run src/renderer/src/hooks/usePdfTextSelection.test.tsx
```

Expected: PASS, all 3 cases.

### Step 3.4 — Commit

- [ ] 
```
git add src/renderer/src/hooks/usePdfTextSelection.ts src/renderer/src/hooks/usePdfTextSelection.test.tsx
git commit -m "feat(highlights): add usePdfTextSelection hook"
```

---

## Task 4 — Highlight overlay component (`HighlightLayer`)

**Files:**
- Create: `src/renderer/src/components/pdf/HighlightLayer.tsx`
- Create: `src/renderer/src/components/pdf/HighlightLayer.test.tsx`

### Step 4.1 — Write failing tests

- [ ] Create `src/renderer/src/components/pdf/HighlightLayer.test.tsx`:

```tsx
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { HighlightLayer } from './HighlightLayer'
import type { HighlightRow } from '@/modules/highlight-storage'
import type { ViewportLike } from '@/modules/pdf-locator'

function makeViewport(scale = 1): ViewportLike {
  return {
    width: 400 * scale, height: 600 * scale, scale,
    convertToViewportPoint(x, y) { return [x * scale, (600 - y) * scale] },
    convertToPdfPoint(x, y) { return [x / scale, 600 - y / scale] }
  }
}

function makeRow(overrides: Partial<HighlightRow> = {}): HighlightRow {
  return {
    id: 'r1', bookId: 'b1', format: 'pdf', cfiRange: null,
    locator: JSON.stringify({ page: 1, rects: [{ x: 10, y: 580, w: 100, h: 15 }] }),
    text: 'hi', color: 'yellow', note: '', chapter: null,
    createdAt: 'now', updatedAt: null, syncId: null, syncVersion: 0, isDirty: 0, isDeleted: 0,
    ...overrides
  }
}

describe('HighlightLayer', () => {
  it('renders one rect div per highlight rect', () => {
    const rows = [
      makeRow({
        id: 'a',
        locator: JSON.stringify({ page: 1, rects: [
          { x: 0, y: 580, w: 50, h: 15 },
          { x: 0, y: 560, w: 80, h: 15 }
        ]})
      }),
      makeRow({ id: 'b' })
    ]
    render(
      <HighlightLayer
        pageNumber={1}
        pageEl={document.createElement('div')}
        viewport={makeViewport(1)}
        highlights={rows}
        onHighlightClick={vi.fn()}
      />
    )
    expect(screen.getAllByTestId('pdf-highlight-rect')).toHaveLength(3)
  })

  it('skips highlights whose locator is null, non-JSON, or for a different page', () => {
    const rows = [
      makeRow({ id: 'null-loc', locator: null }),
      makeRow({ id: 'bad-json', locator: '{not json' }),
      makeRow({ id: 'other-page', locator: JSON.stringify({ page: 99, rects: [{ x: 0, y: 0, w: 10, h: 10 }] }) }),
      makeRow({ id: 'ok' })
    ]
    render(
      <HighlightLayer
        pageNumber={1}
        pageEl={document.createElement('div')}
        viewport={makeViewport(1)}
        highlights={rows}
        onHighlightClick={vi.fn()}
      />
    )
    expect(screen.getAllByTestId('pdf-highlight-rect')).toHaveLength(1)
  })

  it('applies row color as a translucent background', () => {
    render(
      <HighlightLayer
        pageNumber={1}
        pageEl={document.createElement('div')}
        viewport={makeViewport(1)}
        highlights={[makeRow({ color: 'green' })]}
        onHighlightClick={vi.fn()}
      />
    )
    const rect = screen.getByTestId('pdf-highlight-rect')
    // getHighlightHex('green') === '#34D399'; rgba(52, 211, 153, 0.35) — happy-dom reports rgb form.
    expect(rect.style.backgroundColor).toMatch(/52|34/)
  })

  it('invokes onHighlightClick with the row and the mouse event', () => {
    const onClick = vi.fn()
    render(
      <HighlightLayer
        pageNumber={1}
        pageEl={document.createElement('div')}
        viewport={makeViewport(1)}
        highlights={[makeRow({ id: 'clicked' })]}
        onHighlightClick={onClick}
      />
    )
    fireEvent.click(screen.getByTestId('pdf-highlight-rect'))
    expect(onClick).toHaveBeenCalledTimes(1)
    expect(onClick.mock.calls[0][0].id).toBe('clicked')
    expect(onClick.mock.calls[0][1].type).toBe('click')
  })
})
```

- [ ] **Run and verify red:**

```
pnpm vitest run src/renderer/src/components/pdf/HighlightLayer.test.tsx
```

Expected fail: module doesn't exist.

### Step 4.2 — Implement `HighlightLayer.tsx`

- [ ] Create `src/renderer/src/components/pdf/HighlightLayer.tsx`:

```tsx
import { useMemo, type MouseEvent as ReactMouseEvent } from 'react'
import { pdfLocatorToScreenRects, type ViewportLike } from '@/modules/pdf-locator'
import type { HighlightRow, PdfLocator } from '@/modules/highlight-storage'
import { getHighlightHex, type HighlightColor } from '@/types/highlight'

interface HighlightLayerProps {
  pageNumber: number
  pageEl: HTMLElement
  viewport: ViewportLike
  highlights: HighlightRow[]
  onHighlightClick: (row: HighlightRow, event: ReactMouseEvent<HTMLDivElement>) => void
}

function parseLocator(json: string | null): PdfLocator | null {
  if (!json) return null
  try {
    const parsed = JSON.parse(json) as PdfLocator
    if (typeof parsed.page !== 'number' || !Array.isArray(parsed.rects)) return null
    return parsed
  } catch {
    return null
  }
}

function hexWithAlpha(hex: string, alpha: number): string {
  if (!/^#[0-9a-f]{6}$/i.test(hex)) return 'transparent'
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

export function HighlightLayer({
  pageNumber, pageEl, viewport, highlights, onHighlightClick
}: HighlightLayerProps): JSX.Element {
  const rendered = useMemo(() => {
    const items: Array<{
      key: string
      row: HighlightRow
      rect: { left: number; top: number; width: number; height: number }
    }> = []
    for (const row of highlights) {
      const loc = parseLocator(row.locator)
      if (!loc || loc.page !== pageNumber) continue
      const screenRects = pdfLocatorToScreenRects(loc, pageEl, viewport)
      screenRects.forEach((rect, idx) => {
        items.push({ key: `${row.id}:${idx}`, row, rect })
      })
    }
    return items
  }, [highlights, pageNumber, pageEl, viewport])

  return (
    <div
      data-testid="pdf-highlight-layer"
      style={{ position: 'absolute', inset: 0, pointerEvents: 'none', zIndex: 2 }}
    >
      {rendered.map(({ key, row, rect }) => (
        <div
          key={key}
          data-testid="pdf-highlight-rect"
          data-highlight-id={row.id}
          onClick={(e) => onHighlightClick(row, e)}
          style={{
            position: 'absolute',
            left: rect.left, top: rect.top, width: rect.width, height: rect.height,
            backgroundColor: hexWithAlpha(getHighlightHex(row.color as HighlightColor), 0.35),
            pointerEvents: 'auto',
            cursor: 'pointer'
          }}
        />
      ))}
    </div>
  )
}
```

### Step 4.3 — Verify green

- [ ] Run:

```
pnpm vitest run src/renderer/src/components/pdf/HighlightLayer.test.tsx
```

Expected: PASS, all 4 cases.

### Step 4.4 — Commit

- [ ] 
```
git add src/renderer/src/components/pdf/HighlightLayer.tsx src/renderer/src/components/pdf/HighlightLayer.test.tsx
git commit -m "feat(highlights): add HighlightLayer overlay for PDF pages"
```

---

## Task 5 — Wire selection popover + highlight creation in PdfView

This task is integration-heavy. We split the work: (5A) extend `highlight-actions.ts` with a PDF apply helper, (5B) modify `pdf-page.tsx` to capture viewport + page DOM + render the layer, (5C) wire the SelectionPopover in `pdf.tsx`.

### Step 5.1 — Test: `applyHighlightWithUndoPdf` returns a handle and persists via `saveHighlightPdf`

- [ ] In `src/renderer/src/modules/highlight-actions.test.ts`, add (do not delete existing tests):

```ts
import { applyHighlightWithUndoPdf } from './highlight-actions'

describe('applyHighlightWithUndoPdf', () => {
  beforeEach(() => vi.clearAllMocks())

  it('persists via saveHighlightPdf and exposes an undo handle that calls deleteHighlightById', async () => {
    const saveMock = window.electron.highlightsSave as unknown as ReturnType<typeof vi.fn>
    saveMock.mockResolvedValueOnce('pdf-row-1')
    const deleteMock = window.electron.highlightsDeleteById as unknown as ReturnType<typeof vi.fn>
    deleteMock.mockResolvedValueOnce(undefined)

    const applyVisual = vi.fn().mockResolvedValueOnce(undefined)
    const removeVisual = vi.fn().mockResolvedValueOnce(undefined)
    const handle = await applyHighlightWithUndoPdf({
      target: { applyVisual, removeVisual },
      bookSyncId: 'b1',
      locator: { page: 2, rects: [{ x: 0, y: 0, w: 10, h: 10 }] },
      text: 'hi',
      color: 'yellow'
    })

    expect(applyVisual).toHaveBeenCalledTimes(1)
    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(saveMock.mock.calls[0][0].format).toBe('pdf')

    await handle.undo()
    expect(removeVisual).toHaveBeenCalledTimes(1)
    expect(deleteMock).toHaveBeenCalledWith('pdf-row-1')
  })
})
```

- [ ] **Run and verify red:**

```
pnpm vitest run src/renderer/src/modules/highlight-actions.test.ts
```

Expected fail: `applyHighlightWithUndoPdf` is not exported.

### Step 5.2 — Implement `applyHighlightWithUndoPdf`

- [ ] In `src/renderer/src/modules/highlight-actions.ts`, append:

```ts
import { saveHighlightPdf, deleteHighlightById, type PdfLocator } from './highlight-storage'

export interface ApplyHighlightPdfArgs {
  target: HighlightTarget
  bookSyncId: string
  locator: PdfLocator
  text: string
  color: HighlightColor
}

export async function applyHighlightWithUndoPdf(
  args: ApplyHighlightPdfArgs
): Promise<HighlightHandle> {
  await args.target.applyVisual()
  const id = await saveHighlightPdf({
    bookSyncId: args.bookSyncId,
    locator: args.locator,
    text: args.text,
    color: args.color
  })
  return {
    undo: async () => {
      await args.target.removeVisual()
      await deleteHighlightById(id)
    }
  }
}
```

### Step 5.3 — Verify green + commit

- [ ] 
```
pnpm vitest run src/renderer/src/modules/highlight-actions.test.ts
git add src/renderer/src/modules/highlight-actions.ts src/renderer/src/modules/highlight-actions.test.ts
git commit -m "feat(highlights): add applyHighlightWithUndoPdf for PDF highlight creation"
```

### Step 5.4 — Modify `pdf-page.tsx` to expose page DOM + viewport and host the overlay

- [ ] In `src/renderer/src/components/pdf/components/pdf-page.tsx`:

  1. Add to `PageComponentInnerProps`:

```ts
import type { PDFPageProxy } from 'pdfjs-dist'
import type { HighlightRow } from '@/modules/highlight-storage'
import { useRef, useState, type MouseEvent as ReactMouseEvent } from 'react'
import { HighlightLayer } from '../HighlightLayer'

type PageComponentInnerProps = {
  thispageNumber: number
  pdfHeight?: number
  pdfWidth?: number
  isDualPage?: boolean
  bookId: string
  onRenderComplete?: () => void
  pdf: PDFDocumentProxy
  // NEW:
  onPageReady?: (pageNumber: number, info: { pageEl: HTMLElement; page: PDFPageProxy }) => void
  highlights?: HighlightRow[]
  onHighlightClick?: (row: HighlightRow, e: ReactMouseEvent<HTMLDivElement>) => void
}
```

  2. Add wrapper + state in the component body:

```tsx
const wrapperRef = useRef<HTMLDivElement | null>(null)
const [pdfPage, setPdfPage] = useState<PDFPageProxy | null>(null)
```

  3. Wrap the `<Page>` and render `HighlightLayer`:

```tsx
return (
  <div ref={wrapperRef} style={{ position: 'relative' }}>
    <Page
      pageNumber={thispageNumber}
      width={pdfWidth}
      height={pdfHeight}
      renderTextLayer
      renderAnnotationLayer
      onLoadSuccess={(page) => {
        setPdfPage(page)
        const pageEl = wrapperRef.current?.querySelector<HTMLElement>('.react-pdf__Page') ?? null
        if (pageEl && onPageReady) onPageReady(thispageNumber, { pageEl, page })
      }}
      onRenderSuccess={handleRenderSuccess}
    />
    {pdfPage && wrapperRef.current && highlights && onHighlightClick && (
      <HighlightLayer
        pageNumber={thispageNumber}
        pageEl={wrapperRef.current.querySelector<HTMLElement>('.react-pdf__Page') ?? wrapperRef.current}
        viewport={pdfPage.getViewport({
          scale: (pdfWidth ?? pdfPage.view[2]) / pdfPage.view[2]
        })}
        highlights={highlights}
        onHighlightClick={onHighlightClick}
      />
    )}
  </div>
)
```

### Step 5.5 — Test SelectionPopover integration in PdfView

- [ ] Create `src/renderer/src/components/pdf/components/pdf.test.tsx`. Mock `react-pdf` at module scope:

```tsx
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'

vi.mock('react-pdf', () => ({
  Document: ({ children }: { children: React.ReactNode }) => <div data-testid="pdf-doc">{children}</div>,
  Page: ({ pageNumber, onLoadSuccess }: { pageNumber: number; onLoadSuccess?: (p: unknown) => void }) => {
    React.useEffect(() => {
      onLoadSuccess?.({
        getViewport: ({ scale }: { scale: number }) => ({
          width: 400 * scale, height: 600 * scale, scale,
          convertToViewportPoint: (x: number, y: number) => [x * scale, (600 - y) * scale],
          convertToPdfPoint: (x: number, y: number) => [x / scale, 600 - y / scale]
        }),
        view: [0, 0, 400, 600]
      })
    }, [onLoadSuccess])
    return <div className="react-pdf__Page" data-page-number={pageNumber}>page {pageNumber}</div>
  },
  pdfjs: { GlobalWorkerOptions: { workerSrc: '' } }
}))

import { PdfView } from './pdf'

describe('PdfView — selection popover', () => {
  it('shows SelectionPopover when user finishes a text selection in a PDF page', async () => {
    render(<PdfView book={{ syncId: 'b1', filepath: '/tmp/x.pdf' } as never} filepath="/tmp/x.pdf" />)

    // Wait for the mock page to render.
    const pageEl = (await screen.findByText(/page 1/)).parentElement as HTMLElement
    pageEl.className = 'react-pdf__Page'
    pageEl.setAttribute('data-page-number', '1')

    // Synthesize a selection over the text node.
    const textNode = pageEl.firstChild as Text
    const range = document.createRange()
    range.setStart(textNode, 0); range.setEnd(textNode, 4)
    Object.defineProperty(range, 'getClientRects', {
      value: () => [{ left: 5, top: 10, width: 60, height: 14, right: 65, bottom: 24 }]
    })
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)

    // Find the scroll container (the test should locate it via testId or the wrapper around <Document>).
    const scroll = screen.getByTestId('pdf-scroll-container')
    fireEvent.mouseUp(scroll)

    await waitFor(() => {
      expect(screen.queryByTestId('selection-popover')).not.toBeNull()
    })
  })
})
```

  **Test-id requirement:** the scroll container in `pdf.tsx` needs `data-testid="pdf-scroll-container"` (add when wiring Step 5.6). `SelectionPopover` needs `data-testid="selection-popover"` on its root — verify the current component has it; if missing, add it in this commit (single line, won't break existing popover tests).

- [ ] **Run and verify red:**

```
pnpm vitest run src/renderer/src/components/pdf/components/pdf.test.tsx
```

Expected fail: PdfView does not render the popover yet.

### Step 5.6 — Wire `PdfView` to host the SelectionPopover

- [ ] In `src/renderer/src/components/pdf/components/pdf.tsx`:

  1. Imports:

```ts
import { useEffect, useMemo, useRef, useState } from 'react'
import { toast } from 'sonner'
import { SelectionPopover } from '@/components/highlights/SelectionPopover'
import { usePdfTextSelection } from '@/hooks/usePdfTextSelection'
import { useUndoableHighlightShortcut } from '@/hooks/useUndoableHighlightShortcut'
import { applyHighlightWithUndoPdf } from '@/modules/highlight-actions'
import { getHighlightsForBook, type HighlightRow, type PdfLocator } from '@/modules/highlight-storage'
import type { PDFPageProxy } from 'pdfjs-dist'
import type { HighlightColor } from '@/types/highlight'
```

  2. State inside `PdfView`:

```tsx
const [highlights, setHighlights] = useState<HighlightRow[]>([])
const [selectionPopover, setSelectionPopover] = useState<{
  locator: PdfLocator
  text: string
  anchorPos: { x: number; y: number }
} | null>(null)
const pageInfoRef = useRef<Map<number, { pageEl: HTMLElement; page: PDFPageProxy }>>(new Map())
const { setLastUndoable } = useUndoableHighlightShortcut()
```

  3. Add `data-testid="pdf-scroll-container"` to the existing scrollable container element (find the element that already uses `scrollContainerRef`).

  4. Load highlights on book change:

```tsx
useEffect(() => {
  let active = true
  const bookSyncId = book.syncId
  if (!bookSyncId) return
  void getHighlightsForBook(bookSyncId).then((rows) => {
    if (!active) return
    setHighlights(rows.filter((r) => r.format === 'pdf'))
  })
  return () => { active = false }
}, [book.syncId])
```

  5. Plug `usePdfTextSelection`:

```tsx
usePdfTextSelection({
  containerRef: scrollContainerRef,
  getPageElement: (n) => pageInfoRef.current.get(n)?.pageEl ?? null,
  getViewport: (n) => {
    const info = pageInfoRef.current.get(n)
    if (!info) return null
    const scale = info.pageEl.getBoundingClientRect().width / info.page.view[2]
    return info.page.getViewport({ scale })
  },
  onSelect: (sel) => setSelectionPopover({ locator: sel.locator, text: sel.text, anchorPos: sel.anchorPos }),
  onClear: () => setSelectionPopover(null)
})
```

  6. Pass page info + highlights to each `<PageComponent />` instance:

```tsx
<PageComponent
  thispageNumber={n}
  pdfHeight={pdfHeight}
  pdfWidth={pdfWidth}
  isDualPage={isDualPage}
  bookId={book.syncId}
  pdf={pdf}
  onPageReady={(num, info) => pageInfoRef.current.set(num, info)}
  highlights={highlights}
  onHighlightClick={() => { /* wired in Task 6 */ }}
/>
```

  7. Render the popover:

```tsx
{selectionPopover && (
  <SelectionPopover
    cfiRange={''}
    selectedText={selectionPopover.text}
    position={selectionPopover.anchorPos}
    onHighlight={(color) => void handleCreatePdfHighlight(color)}
    onClose={() => setSelectionPopover(null)}
  />
)}
```

  8. The handler:

```tsx
const handleCreatePdfHighlight = async (color: HighlightColor): Promise<void> => {
  if (!selectionPopover || !book.syncId) return
  const { locator, text } = selectionPopover
  setSelectionPopover(null)
  try {
    const handle = await applyHighlightWithUndoPdf({
      target: {
        applyVisual: async () => {
          setHighlights((prev) => [
            ...prev,
            {
              id: `pending-${Date.now()}`,
              bookId: book.syncId!,
              format: 'pdf',
              cfiRange: null,
              locator: JSON.stringify(locator),
              text, color, note: '', chapter: null,
              createdAt: new Date().toISOString(),
              updatedAt: null, syncId: null, syncVersion: 0, isDirty: 1, isDeleted: 0
            }
          ])
        },
        removeVisual: async () => {
          if (!book.syncId) return
          const rows = await getHighlightsForBook(book.syncId)
          setHighlights(rows.filter((r) => r.format === 'pdf'))
        }
      },
      bookSyncId: book.syncId,
      locator, text, color
    })
    setLastUndoable(handle)
    // Reconcile pending row with the real one from DB.
    const rows = await getHighlightsForBook(book.syncId)
    setHighlights(rows.filter((r) => r.format === 'pdf'))
    toast.success('Highlight added', {
      action: { label: 'Undo', onClick: () => void handle.undo() }
    })
  } catch (err) {
    console.error('Failed to apply PDF highlight', err)
    toast.error('Could not save highlight')
  }
}
```

### Step 5.7 — Verify green + commit

- [ ] 
```
pnpm vitest run src/renderer/src/components/pdf/components/pdf.test.tsx
git add src/renderer/src/components/pdf/components/pdf.tsx \
        src/renderer/src/components/pdf/components/pdf-page.tsx \
        src/renderer/src/components/pdf/components/pdf.test.tsx \
        src/renderer/src/components/highlights/SelectionPopover.tsx

git commit -m "feat(highlights): selection popover + create flow in PdfView"
```

(The last file is included only if you added the `data-testid` in Step 5.5.)

---

## Task 6 — Click-on-highlight popover (`HighlightActionPopover`) in PdfView

**Files:**
- Modify: `src/renderer/src/components/pdf/components/pdf.tsx`
- Modify: `src/renderer/src/components/pdf/components/pdf.test.tsx`
- Modify: `src/renderer/src/modules/highlight-actions.ts`
- Modify: `src/renderer/src/modules/highlight-actions.test.ts`

### Step 6.1 — Write failing tests

- [ ] In `pdf.test.tsx`, append:

```tsx
it('opens HighlightActionPopover when a saved highlight is clicked', async () => {
  const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
  listMock.mockResolvedValue([{
    id: 'r1', bookId: 'b1', format: 'pdf', cfiRange: null,
    locator: JSON.stringify({ page: 1, rects: [{ x: 0, y: 580, w: 50, h: 15 }] }),
    text: 'hi', color: 'yellow', note: '', chapter: null,
    createdAt: 'now', updatedAt: null, syncId: null, syncVersion: 0, isDirty: 0, isDeleted: 0
  }])
  render(<PdfView book={{ syncId: 'b1', filepath: '/tmp/x.pdf' } as never} filepath="/tmp/x.pdf" />)
  const rect = await screen.findByTestId('pdf-highlight-rect')
  fireEvent.click(rect)
  await waitFor(() => {
    expect(screen.queryByTestId('highlight-action-popover')).not.toBeNull()
  })
})

it('deleting from the action popover removes the rect and shows an undo toast', async () => {
  const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
  listMock
    .mockResolvedValueOnce([{
      id: 'r1', bookId: 'b1', format: 'pdf', cfiRange: null,
      locator: JSON.stringify({ page: 1, rects: [{ x: 0, y: 580, w: 50, h: 15 }] }),
      text: 'hi', color: 'yellow', note: '', chapter: null,
      createdAt: 'now', updatedAt: null, syncId: null, syncVersion: 0, isDirty: 0, isDeleted: 0
    }])
    .mockResolvedValueOnce([])
  const deleteMock = window.electron.highlightsDeleteById as unknown as ReturnType<typeof vi.fn>
  deleteMock.mockResolvedValue(undefined)

  render(<PdfView book={{ syncId: 'b1', filepath: '/tmp/x.pdf' } as never} filepath="/tmp/x.pdf" />)
  fireEvent.click(await screen.findByTestId('pdf-highlight-rect'))
  fireEvent.click(await screen.findByRole('button', { name: /delete/i }))
  await waitFor(() => {
    expect(screen.queryByTestId('pdf-highlight-rect')).toBeNull()
  })
  expect(deleteMock).toHaveBeenCalledTimes(1)
})
```

  **Test-id requirement:** verify `HighlightActionPopover` has `data-testid="highlight-action-popover"` on root; add if missing.

- [ ] **Run red.**

### Step 6.2 — Add `deleteHighlightByIdWithUndo` to highlight-actions

- [ ] In `src/renderer/src/modules/highlight-actions.test.ts`, add:

```ts
import { deleteHighlightByIdWithUndo } from './highlight-actions'

describe('deleteHighlightByIdWithUndo', () => {
  beforeEach(() => vi.clearAllMocks())

  it('deletes by id and re-inserts on undo using the row snapshot', async () => {
    const deleteMock = window.electron.highlightsDeleteById as unknown as ReturnType<typeof vi.fn>
    deleteMock.mockResolvedValueOnce(undefined)
    const saveMock = window.electron.highlightsSave as unknown as ReturnType<typeof vi.fn>
    saveMock.mockResolvedValueOnce('reinserted-1')

    const handle = await deleteHighlightByIdWithUndo({
      target: { applyVisual: vi.fn(), removeVisual: vi.fn() },
      rowId: 'r1',
      snapshot: {
        bookId: 'b1', format: 'pdf', cfiRange: null,
        locator: JSON.stringify({ page: 1, rects: [{ x: 0, y: 0, w: 10, h: 10 }] }),
        text: 'hi', color: 'yellow', note: '', chapter: null
      }
    })
    expect(deleteMock).toHaveBeenCalledWith('r1')

    await handle.undo()
    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(saveMock.mock.calls[0][0].format).toBe('pdf')
  })
})
```

- [ ] Run red. Then in `src/renderer/src/modules/highlight-actions.ts`, append:

```ts
import { saveHighlight } from './highlight-storage'

export interface DeleteHighlightByIdWithUndoArgs {
  target: HighlightTarget
  rowId: string
  snapshot: Pick<HighlightRow, 'bookId' | 'format' | 'cfiRange' | 'locator' | 'text' | 'color' | 'note' | 'chapter'>
}

export async function deleteHighlightByIdWithUndo(
  args: DeleteHighlightByIdWithUndoArgs
): Promise<HighlightHandle> {
  await args.target.removeVisual()
  await deleteHighlightById(args.rowId)
  return {
    undo: async () => {
      if (args.snapshot.format === 'pdf' && args.snapshot.locator) {
        await saveHighlightPdf({
          bookSyncId: args.snapshot.bookId,
          locator: JSON.parse(args.snapshot.locator) as PdfLocator,
          text: args.snapshot.text,
          color: args.snapshot.color,
          note: args.snapshot.note,
          chapter: args.snapshot.chapter
        })
      } else if (args.snapshot.format === 'epub' && args.snapshot.cfiRange) {
        await saveHighlight({
          bookSyncId: args.snapshot.bookId,
          cfiRange: args.snapshot.cfiRange,
          text: args.snapshot.text,
          color: args.snapshot.color,
          note: args.snapshot.note,
          chapter: args.snapshot.chapter
        })
      }
      await args.target.applyVisual()
    }
  }
}
```

  `HighlightRow` import: the file already imports types from `./highlight-storage`. Add `HighlightRow` to the imports if not already present.

  Verify green for highlight-actions tests before moving on.

### Step 6.3 — Wire the click + delete flow in PdfView

- [ ] In `src/renderer/src/components/pdf/components/pdf.tsx`:

  1. Imports:

```ts
import { HighlightActionPopover } from '@/components/highlights/HighlightActionPopover'
import { deleteHighlightByIdWithUndo } from '@/modules/highlight-actions'
import { updateHighlightColor } from '@/modules/highlight-storage'
```

  2. State:

```tsx
const [inlinePopover, setInlinePopover] = useState<{
  rowId: string
  position: { x: number; y: number }
  currentColor: HighlightColor
  hasNote: boolean
} | null>(null)
```

  3. Handlers:

```tsx
const handleHighlightClick = (row: HighlightRow, e: React.MouseEvent<HTMLDivElement>): void => {
  setInlinePopover({
    rowId: row.id,
    position: { x: e.clientX, y: e.clientY - 8 },
    currentColor: row.color as HighlightColor,
    hasNote: row.note.trim().length > 0
  })
}

const handleInlineColorChange = async (color: HighlightColor): Promise<void> => {
  if (!inlinePopover) return
  await updateHighlightColor(inlinePopover.rowId, color)
  setHighlights((prev) => prev.map((r) => r.id === inlinePopover.rowId ? { ...r, color } : r))
  setInlinePopover(null)
}

const handleInlineDelete = async (): Promise<void> => {
  if (!inlinePopover || !book.syncId) return
  const row = highlights.find((r) => r.id === inlinePopover.rowId)
  if (!row) return
  setInlinePopover(null)
  const handle = await deleteHighlightByIdWithUndo({
    target: {
      applyVisual: async () => {
        if (!book.syncId) return
        const rows = await getHighlightsForBook(book.syncId)
        setHighlights(rows.filter((r) => r.format === 'pdf'))
      },
      removeVisual: async () => { /* local removal handled below */ }
    },
    rowId: row.id,
    snapshot: {
      bookId: row.bookId,
      format: row.format,
      cfiRange: row.cfiRange,
      locator: row.locator,
      text: row.text,
      color: row.color,
      note: row.note,
      chapter: row.chapter
    }
  })
  setHighlights((prev) => prev.filter((r) => r.id !== row.id))
  setLastUndoable(handle)
  toast.success('Highlight removed', {
    action: { label: 'Undo', onClick: () => void handle.undo() }
  })
}
```

  4. Pass `onHighlightClick={handleHighlightClick}` to each `<PageComponent />`.

  5. Render:

```tsx
{inlinePopover && (
  <HighlightActionPopover
    position={inlinePopover.position}
    currentColor={inlinePopover.currentColor}
    hasNote={inlinePopover.hasNote}
    onSelectColor={(c) => void handleInlineColorChange(c)}
    onEditNote={() => { /* wired in Task 7 */ }}
    onDelete={() => void handleInlineDelete()}
    onClose={() => setInlinePopover(null)}
  />
)}
```

### Step 6.4 — Verify green + commit

- [ ] 
```
pnpm vitest run src/renderer/src/components/pdf/components/pdf.test.tsx \
                src/renderer/src/modules/highlight-actions.test.ts
git add src/renderer/src/components/pdf/components/pdf.tsx \
        src/renderer/src/components/pdf/components/pdf.test.tsx \
        src/renderer/src/modules/highlight-actions.ts \
        src/renderer/src/modules/highlight-actions.test.ts \
        src/renderer/src/components/highlights/HighlightActionPopover.tsx

git commit -m "feat(highlights): click-on-highlight popover + delete-with-undo for PDF"
```

(The last file is included only if you added the `data-testid` in Step 6.1.)

---

## Task 7 — Wire NoteEditor in PdfView

**Files:**
- Modify: `src/renderer/src/components/pdf/components/pdf.tsx`
- Modify: `src/renderer/src/components/pdf/components/pdf.test.tsx`

### Step 7.1 — Write failing test

- [ ] In `pdf.test.tsx`, append:

```tsx
it('opens NoteEditor when "Edit note" is selected from the highlight action popover', async () => {
  const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
  listMock.mockResolvedValue([{
    id: 'r1', bookId: 'b1', format: 'pdf', cfiRange: null,
    locator: JSON.stringify({ page: 1, rects: [{ x: 0, y: 580, w: 50, h: 15 }] }),
    text: 'hi', color: 'yellow', note: '', chapter: null,
    createdAt: 'now', updatedAt: null, syncId: null, syncVersion: 0, isDirty: 0, isDeleted: 0
  }])
  render(<PdfView book={{ syncId: 'b1', filepath: '/tmp/x.pdf' } as never} filepath="/tmp/x.pdf" />)
  fireEvent.click(await screen.findByTestId('pdf-highlight-rect'))
  fireEvent.click(await screen.findByRole('button', { name: /note/i }))
  await waitFor(() => {
    expect(screen.queryByRole('dialog')).not.toBeNull()
  })
})
```

- [ ] **Run red.**

### Step 7.2 — Implement

- [ ] In `pdf.tsx`:

```tsx
import { NoteEditor } from '@/components/highlights/NoteEditor'

const [editingNoteRow, setEditingNoteRow] = useState<HighlightRow | null>(null)

// In the HighlightActionPopover JSX, replace the placeholder onEditNote:
onEditNote={() => {
  const row = highlights.find((r) => r.id === inlinePopover!.rowId)
  if (row) setEditingNoteRow(row)
  setInlinePopover(null)
}}

// Render at the bottom of PdfView:
<NoteEditor
  highlight={editingNoteRow}
  open={editingNoteRow !== null}
  onOpenChange={(open) => !open && setEditingNoteRow(null)}
  onSaved={async () => {
    if (!book.syncId) return
    const rows = await getHighlightsForBook(book.syncId)
    setHighlights(rows.filter((r) => r.format === 'pdf'))
  }}
/>
```

### Step 7.3 — Verify green + commit

- [ ] 
```
pnpm vitest run src/renderer/src/components/pdf/components/pdf.test.tsx
git add src/renderer/src/components/pdf/components/pdf.tsx \
        src/renderer/src/components/pdf/components/pdf.test.tsx
git commit -m "feat(highlights): wire NoteEditor in PdfView"
```

---

## Task 8 — Electron "Read Aloud From Here" for PDF

The IPC channel `reader:readAloudFromSelection` already exists. PdfView needs a listener that, when fired, reads the current `window.getSelection()` and starts TTS from the corresponding paragraph.

**Files:**
- Modify: `src/renderer/src/components/pdf/components/pdf.tsx`
- Modify: `src/renderer/src/components/pdf/components/pdf.test.tsx`

### Step 8.1 — Inspect the EpubView equivalent before writing the test

Open `src/renderer/src/components/epub/EpubView.tsx` and find the IPC handler for `reader:readAloudFromSelection` (recon report references it around line 302). Note exactly how it:
- Reads the selection
- Dispatches the result (custom event vs. direct player call)

The PDF handler should mirror whichever pattern EpubView uses, so the upstream listener (in playerStore or wherever) is exercised the same way for both readers.

### Step 8.2 — Write failing test (shape-aware)

- [ ] In `pdf.test.tsx`, append. Adapt the assertion to whichever pattern EpubView uses; the spec below assumes the CustomEvent pattern:

```tsx
it('dispatches rishi:readAloudFromSelection with the selected text when the IPC fires', async () => {
  render(<PdfView book={{ syncId: 'b1', filepath: '/tmp/x.pdf' } as never} filepath="/tmp/x.pdf" />)

  // Locate the IPC listener registered by PdfView.
  const onMock = window.electron.on as unknown as ReturnType<typeof vi.fn>
  const handler = onMock.mock.calls.find(([ch]) => ch === 'reader:readAloudFromSelection')?.[1]
  expect(handler).toBeTypeOf('function')

  // Stage a real selection in the DOM.
  const node = document.createTextNode('start here')
  document.body.appendChild(node)
  const range = document.createRange()
  range.setStart(node, 0); range.setEnd(node, 'start'.length)
  window.getSelection()!.removeAllRanges()
  window.getSelection()!.addRange(range)

  const events: CustomEvent[] = []
  const listener = (e: Event) => events.push(e as CustomEvent)
  window.addEventListener('rishi:readAloudFromSelection', listener)

  handler!()
  expect(events).toHaveLength(1)
  expect(events[0].detail).toEqual({ text: 'start' })

  window.removeEventListener('rishi:readAloudFromSelection', listener)
})
```

- [ ] **Run red.**

### Step 8.3 — Implement

- [ ] In `pdf.tsx`:

```tsx
useEffect(() => {
  const off = window.electron.on('reader:readAloudFromSelection', () => {
    const sel = window.getSelection()
    const text = sel?.toString()?.trim()
    if (!text) return
    window.dispatchEvent(new CustomEvent('rishi:readAloudFromSelection', { detail: { text } }))
  })
  return () => { off?.() }
}, [])
```

  If EpubView calls a player-store method directly instead of dispatching the CustomEvent, do the same here and update the test accordingly.

### Step 8.4 — Verify green + commit

- [ ] 
```
pnpm vitest run src/renderer/src/components/pdf/components/pdf.test.tsx
git add src/renderer/src/components/pdf/components/pdf.tsx \
        src/renderer/src/components/pdf/components/pdf.test.tsx
git commit -m "feat(highlights): wire 'Read Aloud From Here' IPC in PdfView"
```

---

## Task 9 — Manual UAT in dev server

Automated tests cannot certify UX correctness — only that code paths execute. This task is hands-on validation.

### Step 9.1 — Start dev server

- [ ] 
```
pnpm dev
```

### Step 9.2 — Smoke checklist

Open a PDF book. Walk through each item; if any fails, file a follow-up.

- [ ] Select text on a single page → SelectionPopover appears at the selection top-center.
- [ ] Click each color swatch in turn → highlight appears in that color; toast "Highlight added · Undo" shows.
- [ ] Press `Cmd/Ctrl+Z` within 5 s → highlight disappears.
- [ ] Recreate a highlight → close the toast → click toast's Undo → highlight disappears.
- [ ] Click an existing highlight → HighlightActionPopover appears near the click point.
- [ ] Change color → highlight repaints in the new color, popover closes.
- [ ] Edit Note → NoteEditor modal opens. Type a note, save → modal closes. Re-open: note populated.
- [ ] Delete from action popover → highlight disappears; "Highlight removed · Undo" toast. Undo → highlight returns at the same rect.
- [ ] Zoom in/out → highlight overlays scale with the page, no drift.
- [ ] Reload the book → highlights re-appear in their saved positions.
- [ ] Right-click on selected PDF text → "Read Aloud From Here" appears in the context menu and starts TTS from the selection.
- [ ] Press Escape with a popover open → popover closes.
- [ ] Click outside a popover → popover closes (with the 100 ms grace from the shared component).
- [ ] EPUB regression check: open an EPUB book, create + delete a highlight, change color, edit note → all unchanged.

### Step 9.3 — Final hygiene

- [ ] 
```
pnpm typecheck
pnpm vitest run
pnpm lint
```

All must exit clean before declaring the feature complete.

---

## Plan Self-Review Findings

- **Schema mutability caveat:** SQLite cannot drop `NOT NULL` via plain ALTER. The plan keeps `cfi_range` NOT NULL on disk and stores `''` for PDF rows; renderer maps `''` → `null`. Documented in Step 1.6 and 1.7. A rebuild-table migration would be cleaner but is deferred.
- **Two helpers, not one:** `deleteHighlightWithUndo` (EPUB, by cfiRange) stays unchanged. New `deleteHighlightByIdWithUndo` lives next to it for PDF and any future format. EPUB code paths are untouched.
- **Test-id additions:** `SelectionPopover`, `HighlightActionPopover`, and the PdfView scroll container need stable `data-testid` attributes. Steps 5.5, 6.1, and 5.6 instruct the engineer to verify and add if missing. Single-line changes, no behavior impact.
- **Optimistic local state with pending sentinel id:** the create flow inserts a `pending-<ts>` row immediately, then reconciles via re-fetch. There is a transient duplicate window which the re-fetch resolves cleanly.
- **`usePlayerMachine` is in-flight (recon item 12):** Task 8's test is shape-aware — Step 8.1 asks the engineer to read EpubView's pattern at execution time and mirror it. Assertion adjusts accordingly.
- **Spec coverage check:** every spec section maps to a task — schema (T1), locator math (T2), selection hook (T3), overlay (T4), selection popover wiring (T5), action popover wiring (T6), note editor (T7), context menu (T8), UAT (T9). Agent team mapping (test-planner → tester → test-reviewer → code-planner → coder → code-reviewer) is not embedded in individual tasks; it's the orchestration pattern the execution skill applies per task.
