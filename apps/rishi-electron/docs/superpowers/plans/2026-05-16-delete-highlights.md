# Delete Highlights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the user a discoverable way to delete highlights (View menu + `Cmd/Ctrl+Shift+H` opens the existing panel; clicking a highlighted span opens an inline popover with color swatches + edit note + delete), with toast + `Cmd/Ctrl+Z` undo for delete.

**Architecture:** A new `deleteHighlightWithUndo` helper sits beside `applyHighlightWithUndo` and returns the same `HighlightHandle` shape, so the existing `useUndoableHighlightShortcut` slot picks up delete undo for free. A new `HighlightActionPopover` component is opened by the per-annotation click callback that epubjs's `annotations.highlight()` already supports. The existing application menu pipeline (`MenuCommand` → `menu:command` IPC → `useMenuCommands`) gets a new `showHighlights` command that flips the panel open.

**Tech Stack:** Electron native menu, React 18, Vitest + happy-dom + `@testing-library/react`, Zustand, sonner, epubjs.

**Spec:** `docs/superpowers/specs/2026-05-16-delete-highlights-design.md`

**Working directory for all commands:** `apps/rishi-electron/`.

---

## File Map

**Created:**
- `src/renderer/src/components/highlights/HighlightActionPopover.tsx` — inline popover (color swatches + edit-note button + delete button).
- `src/renderer/src/components/highlights/HighlightActionPopover.test.tsx` — popover unit tests.

**Modified:**
- `src/main/menu/accelerators.ts` + `.test.ts` — add `showHighlights: 'CmdOrCtrl+Shift+H'`.
- `src/main/menu/commands.ts` — add `{ command: 'showHighlights' }` to the `MenuCommand` union.
- `src/main/menu/menuBuilder.ts` + `.test.ts` — add the View → Show Highlights item (EPUB-only).
- `src/renderer/src/modules/highlight-actions.ts` + `.test.ts` — add `deleteHighlightWithUndo` helper.
- `src/renderer/src/modules/epubjs-extensions.d.ts` — widen `annotations.highlight()` callback signature so it can receive a `MouseEvent`.
- `src/renderer/src/components/highlights/HighlightsPanel.tsx` — replace `handleDelete` with the new helper, accept `setLastUndoable` + `rendition` props (the latter already present).
- `src/renderer/src/components/epub/EpubView.tsx` — add `showHighlights` menu handler; pass `setLastUndoable` into `HighlightsPanel`; wire the per-annotation click callback to the popover; add color-change and edit-note paths; reuse `NoteEditor`.

---

## Task 1: Add `showHighlights` accelerator + menu command + menu item (TDD across three test files)

**Files:**
- Modify: `src/main/menu/accelerators.ts` and `src/main/menu/accelerators.test.ts`
- Modify: `src/main/menu/commands.ts`
- Modify: `src/main/menu/menuBuilder.ts` and `src/main/menu/menuBuilder.test.ts`

- [ ] **Step 1: Add the failing accelerator test**

In `src/main/menu/accelerators.test.ts`, append inside the existing `describe('ACCELERATORS', ...)` block:

```ts
  it('has Show Highlights bound to CmdOrCtrl+Shift+H', () => {
    expect(ACCELERATORS.showHighlights).toBe('CmdOrCtrl+Shift+H')
  })
```

Run: `pnpm test -- src/main/menu/accelerators.test.ts`
Expected: FAIL — `Property 'showHighlights' does not exist`.

- [ ] **Step 2: Add the accelerator constant**

In `src/main/menu/accelerators.ts`, add inside the `ACCELERATORS` object literal (alongside the other entries):

```ts
  showHighlights: 'CmdOrCtrl+Shift+H'
```

Run: `pnpm test -- src/main/menu/accelerators.test.ts`
Expected: PASS.

- [ ] **Step 3: Extend the `MenuCommand` union**

In `src/main/menu/commands.ts`, add a new variant to the `MenuCommand` union (keep the existing entries; add this line near the other reader-related variants):

```ts
  | { command: 'showHighlights' }
```

Run: `pnpm typecheck:node`
Expected: clean.

- [ ] **Step 4: Add the failing menuBuilder test**

In `src/main/menu/menuBuilder.test.ts`, append inside the existing `describe(...)` block (near the other View-submenu tests):

```ts
  it('View > Show Highlights is present for EPUB books with CmdOrCtrl+Shift+H and dispatches showHighlights', () => {
    const dispatch = vi.fn<(c: MenuCommand) => void>()
    const epubCtx = { ...pdfCtx, format: 'epub' as const }
    const tpl = buildMenu(epubCtx, dispatch)
    const item = findItem(tpl, ['View', 'Show Highlights'])
    expect(item).toBeDefined()
    expect(item!.accelerator).toBe('CmdOrCtrl+Shift+H')
    item!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'showHighlights' })
  })

  it('View > Show Highlights is omitted for non-EPUB books', () => {
    const dispatch = vi.fn<(c: MenuCommand) => void>()
    const tpl = buildMenu(pdfCtx, dispatch)  // pdfCtx.format === 'pdf'
    expect(findItem(tpl, ['View', 'Show Highlights'])).toBeUndefined()
  })
```

Run: `pnpm test -- src/main/menu/menuBuilder.test.ts`
Expected: FAIL — `findItem(...)` returns undefined for EPUB context.

- [ ] **Step 5: Add the menu item**

In `src/main/menu/menuBuilder.ts`, locate the existing block (lines ~67-97) that adds View-submenu items conditional on `ctx.kind === 'book'`. After the `{ label: 'Show TOC', ... }` block (and after the PDF-only thumbnails / dual-page block closes), add a new conditional for EPUB:

```ts
    if (ctx.format === 'epub') {
      viewSubmenu.push({
        label: 'Show Highlights',
        accelerator: ACCELERATORS.showHighlights,
        click: fire({ command: 'showHighlights' })
      })
    }
```

Place this block immediately after the closing `}` of the existing `if (ctx.format === 'pdf') { ... }` block and before the outer block's closing `}`. The result is: every book gets "Show TOC"; PDFs additionally get "Show Thumbnails" / "Dual Page"; EPUBs additionally get "Show Highlights".

Run: `pnpm test -- src/main/menu/menuBuilder.test.ts`
Expected: both new tests PASS; all existing menu tests PASS.

- [ ] **Step 6: Run all menu suites + typecheck**

```bash
pnpm test -- src/main/menu
pnpm typecheck:node
```
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add src/main/menu/accelerators.ts src/main/menu/accelerators.test.ts \
        src/main/menu/commands.ts \
        src/main/menu/menuBuilder.ts src/main/menu/menuBuilder.test.ts
git commit -m "feat(menu): View > Show Highlights for EPUB (CmdOrCtrl+Shift+H)"
```

---

## Task 2: Wire `showHighlights` menu handler in EpubView

**Files:**
- Modify: `src/renderer/src/components/epub/EpubView.tsx` (the `menuHandlers` `useMemo` near line 212)

- [ ] **Step 1: Add the handler**

In `EpubView.tsx`, locate the `menuHandlers` `useMemo` (currently around lines 212-238). Inside the object literal (alongside `addBookmark` and `readAloudFromSelection`), add:

```ts
      showHighlights: () => {
        setHighlightsPanelOpen(true)
      },
```

`setHighlightsPanelOpen` is already in scope (line 194). No additional imports.

- [ ] **Step 2: Run renderer suite + typecheck**

```bash
pnpm test
pnpm typecheck:web
```
Expected: 826/826 still passes; typecheck clean.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(epub): handle showHighlights menu command -> open panel"
```

---

## Task 3: `deleteHighlightWithUndo` helper — failing apply test, then green

**Files:**
- Modify: `src/renderer/src/modules/highlight-actions.test.ts` (append a new `describe`)
- Modify: `src/renderer/src/modules/highlight-actions.ts`

- [ ] **Step 1: Append the failing test**

In `src/renderer/src/modules/highlight-actions.test.ts`, append at the bottom of the file (after the existing `describe('applyHighlightWithUndo — undo path', ...)` block):

```ts
describe('deleteHighlightWithUndo — delete path', () => {
  it('calls removeVisual, deleteHighlight and triggerWrite exactly once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })

    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledWith('book-1', 'cfi:1')
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })
})
```

Update the import line at the top of the file from:

```ts
import { applyHighlightWithUndo } from './highlight-actions'
```

to:

```ts
import { applyHighlightWithUndo, deleteHighlightWithUndo } from './highlight-actions'
```

Run: `pnpm test -- src/renderer/src/modules/highlight-actions.test.ts`
Expected: FAIL — `deleteHighlightWithUndo` is not exported.

- [ ] **Step 2: Implement the helper**

In `src/renderer/src/modules/highlight-actions.ts`, append BELOW the existing `applyHighlightWithUndo` function (and keep all existing types/exports):

```ts
export interface DeleteHighlightArgs {
  target: HighlightTarget
  bookSyncId: string
  cfiRange: string
  text: string
  color: HighlightColor
  note?: string
  chapter?: string | null
}

/**
 * Delete a highlight optimistically and return a handle whose `undo()`
 * re-applies the visual mark and re-inserts the row via saveHighlight.
 * Errors during persistence are logged but never block the handle.
 *
 * Note: the underlying `highlights:save` IPC ignores soft-deleted rows in
 * its upsert check, so undo inserts a FRESH row; the soft-deleted ghost
 * remains. Sync semantics stay correct (both rows carry `isDirty=1`).
 */
export async function deleteHighlightWithUndo(args: DeleteHighlightArgs): Promise<HighlightHandle> {
  const { target, bookSyncId, cfiRange, text, color, note, chapter } = args

  await target.removeVisual()

  try {
    await deleteHighlight(bookSyncId, cfiRange)
    getSyncService().triggerWrite()
  } catch (err) {
    console.warn('[highlight] delete failed:', err)
  }

  return {
    async undo() {
      await target.applyVisual()
      try {
        await saveHighlight({ bookSyncId, cfiRange, text, color, note, chapter })
        getSyncService().triggerWrite()
      } catch (err) {
        console.warn('[highlight] re-save failed:', err)
      }
    }
  }
}
```

Run: `pnpm test -- src/renderer/src/modules/highlight-actions.test.ts`
Expected: PASS (5 existing + 1 new = 5 + 1 inside the new describe block).

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/modules/highlight-actions.ts src/renderer/src/modules/highlight-actions.test.ts
git commit -m "feat(highlight): deleteHighlightWithUndo helper - delete path"
```

---

## Task 4: `deleteHighlightWithUndo` — undo + edge-case tests

**Files:**
- Modify: `src/renderer/src/modules/highlight-actions.test.ts`

- [ ] **Step 1: Append the undo + edge tests**

In `src/renderer/src/modules/highlight-actions.test.ts`, append the three additional tests INSIDE the `describe('deleteHighlightWithUndo — delete path', ...)` block (the same one created in Task 3):

```ts
  it('handle.undo() calls applyVisual, saveHighlight and triggerWrite once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow',
      note: 'a note'
    })

    target.removeVisual.mockClear()
    ;(deleteHighlight as unknown as ReturnType<typeof vi.fn>).mockClear()
    triggerWrite.mockClear()

    await handle.undo()

    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledWith({
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow',
      note: 'a note',
      chapter: undefined
    })
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('returns a working handle even if deleteHighlight rejects', async () => {
    ;(deleteHighlight as unknown as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('boom'))
    const target = makeTarget()
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-3',
      cfiRange: 'cfi:3',
      text: 'x',
      color: 'yellow'
    })

    expect(warn).toHaveBeenCalled()
    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    await handle.undo()
    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    warn.mockRestore()
  })

  it('calling undo twice is safe — second call still re-applies visual but does not throw', async () => {
    const target = makeTarget()
    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-4',
      cfiRange: 'cfi:4',
      text: 'x',
      color: 'yellow'
    })

    await handle.undo()
    await expect(handle.undo()).resolves.toBeUndefined()
    expect(target.applyVisual).toHaveBeenCalledTimes(2)
  })
```

- [ ] **Step 2: Run**

```bash
pnpm test -- src/renderer/src/modules/highlight-actions.test.ts
pnpm typecheck:web
```
Expected: all tests pass; typecheck clean. (The helper already supports these contracts thanks to Task 3.)

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/modules/highlight-actions.test.ts
git commit -m "test(highlight-actions): delete undo, save-failure, idempotent paths"
```

---

## Task 5: `HighlightsPanel` — use new helper, fix stale-visual bug, accept new props

**Files:**
- Modify: `src/renderer/src/components/highlights/HighlightsPanel.tsx`
- Modify: `src/renderer/src/components/epub/EpubView.tsx` (the JSX site where `<HighlightsPanel ... />` is mounted, around line 889)

Background: today the panel's `handleDelete` (lines 41-49 of `HighlightsPanel.tsx`) calls `deleteHighlightById` + `triggerWrite` + `refreshHighlights`, but does NOT call `removeHighlight(rendition, cfiRange)` — the colored visual stays on screen. This task fixes that AND makes the delete undoable via the same slot the apply path uses.

- [ ] **Step 1: Update `HighlightsPanel` props and `handleDelete`**

Replace the contents of `src/renderer/src/components/highlights/HighlightsPanel.tsx` lines 1-8 (the imports) with:

```tsx
import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { Pencil, Trash2 } from 'lucide-react'
import { getHighlightsForBook } from '@/modules/highlight-storage'
import { deleteHighlightWithUndo } from '@/modules/highlight-actions'
import { getHighlightHex, type HighlightColor } from '@/types/highlight'
import { NoteEditor } from './NoteEditor'
import type { HighlightRow } from '@/modules/highlight-storage'
import { highlightRange, removeHighlight } from '@/modules/epubwrapper'
import type { Rendition } from 'epubjs/types'
import type { HighlightHandle } from '@/modules/highlight-actions'
```

Note: `deleteHighlightById` is no longer imported here — the helper uses `deleteHighlight(bookSyncId, cfiRange)` instead, which is what we want for the optimistic-undo flow.

Replace the existing `HighlightsPanelProps` interface (lines 10-15) with:

```tsx
interface HighlightsPanelProps {
  bookSyncId: string
  rendition: Rendition | null
  open: boolean
  onOpenChange: (open: boolean) => void
  setLastUndoable: (handle: HighlightHandle) => void
}
```

Update the destructuring in the function signature (lines 17-22) to include `setLastUndoable`:

```tsx
export function HighlightsPanel({
  bookSyncId,
  rendition,
  open,
  onOpenChange,
  setLastUndoable
}: HighlightsPanelProps) {
```

Replace the existing `handleDelete` (lines 41-49) with:

```tsx
  const handleDelete = useCallback(
    (hl: HighlightRow) => {
      if (!rendition) return
      const cfiRange = hl.cfiRange
      const color = hl.color as HighlightColor
      const hex = getHighlightHex(color)

      void deleteHighlightWithUndo({
        target: {
          applyVisual: async () => {
            await highlightRange(rendition, cfiRange, {}, () => {}, 'epubjs-hl', {
              fill: hex,
              'fill-opacity': '0.3',
              'mix-blend-mode': 'multiply'
            })
          },
          removeVisual: async () => {
            await removeHighlight(rendition, cfiRange)
          }
        },
        bookSyncId,
        cfiRange,
        text: hl.text,
        color,
        note: hl.note,
        chapter: hl.chapter
      })
        .then((handle) => {
          setLastUndoable(handle)
          toast('Highlight deleted', {
            action: {
              label: 'Undo',
              onClick: () => {
                void handle.undo().then(() => refreshHighlights())
              }
            },
            duration: 5_000
          })
          return refreshHighlights()
        })
        .catch((err: unknown) => console.warn('[highlights] delete failed:', err))
    },
    [bookSyncId, rendition, setLastUndoable, refreshHighlights]
  )
```

Update the call site of `handleDelete` (currently `onClick={(e) => { e.stopPropagation(); void handleDelete(hl.id) }}` inside the trash button at lines 118-121) to pass the full row:

```tsx
                        onClick={(e) => {
                          e.stopPropagation()
                          handleDelete(hl)
                        }}
```

Notes on the changes:
- The toast's Undo button calls `handle.undo()` then `refreshHighlights()` so the panel list immediately reflects the re-inserted row.
- After delete, `refreshHighlights()` runs as part of the `.then` chain so the row vanishes from the panel without an additional manual refresh.
- The visual mark is now removed via `removeHighlight(rendition, cfiRange)` inside `removeVisual` — fixes the stale-visual bug.

- [ ] **Step 2: Update the call site in EpubView**

In `src/renderer/src/components/epub/EpubView.tsx`, locate the `<HighlightsPanel ...>` element (around line 889-894). Add a `setLastUndoable={setLastUndoable}` prop:

Find this:
```tsx
        <HighlightsPanel
          bookSyncId={bookSyncId}
          rendition={rendition}
          open={highlightsPanelOpen}
          onOpenChange={setHighlightsPanelOpen}
        />
```

Replace with:
```tsx
        <HighlightsPanel
          bookSyncId={bookSyncId}
          rendition={rendition}
          open={highlightsPanelOpen}
          onOpenChange={setHighlightsPanelOpen}
          setLastUndoable={setLastUndoable}
        />
```

`setLastUndoable` is already destructured from `useUndoableHighlightShortcut()` at line 196.

- [ ] **Step 3: Run + typecheck**

```bash
pnpm test
pnpm typecheck:web
```
Expected: all tests pass; typecheck clean.

The existing `HighlightsPanel` has no test file, so no test changes are needed here. The new behavior (visual removed, toast shown, slot updated) is verified by the helper unit tests + manual smoke (Task 9).

- [ ] **Step 4: Commit**

```bash
git add src/renderer/src/components/highlights/HighlightsPanel.tsx src/renderer/src/components/epub/EpubView.tsx
git commit -m "fix(panel): use deleteHighlightWithUndo - removes visual + adds undo toast"
```

---

## Task 6: `HighlightActionPopover` component (red → green)

**Files:**
- Create: `src/renderer/src/components/highlights/HighlightActionPopover.test.tsx`
- Create: `src/renderer/src/components/highlights/HighlightActionPopover.tsx`

- [ ] **Step 1: Write the failing test file**

Create `src/renderer/src/components/highlights/HighlightActionPopover.test.tsx`:

```tsx
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { HighlightActionPopover } from './HighlightActionPopover'
import { HIGHLIGHT_COLORS } from '@/types/highlight'

function baseProps() {
  return {
    position: { x: 100, y: 100 },
    currentColor: 'yellow' as const,
    onSelectColor: vi.fn(),
    onEditNote: vi.fn(),
    onDelete: vi.fn(),
    onClose: vi.fn()
  }
}

describe('HighlightActionPopover', () => {
  it('renders a swatch per HIGHLIGHT_COLORS entry, plus Edit note and Delete buttons', () => {
    render(<HighlightActionPopover {...baseProps()} />)
    for (const c of HIGHLIGHT_COLORS) {
      expect(screen.getByRole('button', { name: new RegExp(`change.*${c.name}`, 'i') }))
        .toBeInTheDocument()
    }
    expect(screen.getByRole('button', { name: /edit note/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /delete highlight/i })).toBeInTheDocument()
  })

  it('clicking a color swatch fires onSelectColor and then onClose', () => {
    const props = baseProps()
    const target = HIGHLIGHT_COLORS[0]
    render(<HighlightActionPopover {...props} />)
    fireEvent.click(screen.getByRole('button', { name: new RegExp(`change.*${target.name}`, 'i') }))
    expect(props.onSelectColor).toHaveBeenCalledWith(target.name)
    expect(props.onClose).toHaveBeenCalledTimes(1)
  })

  it('clicking Edit note fires onEditNote and then onClose', () => {
    const props = baseProps()
    render(<HighlightActionPopover {...props} />)
    fireEvent.click(screen.getByRole('button', { name: /edit note/i }))
    expect(props.onEditNote).toHaveBeenCalledTimes(1)
    expect(props.onClose).toHaveBeenCalledTimes(1)
  })

  it('clicking Delete fires onDelete and then onClose', () => {
    const props = baseProps()
    render(<HighlightActionPopover {...props} />)
    fireEvent.click(screen.getByRole('button', { name: /delete highlight/i }))
    expect(props.onDelete).toHaveBeenCalledTimes(1)
    expect(props.onClose).toHaveBeenCalledTimes(1)
  })

  it('pressing Escape fires onClose', () => {
    const props = baseProps()
    render(<HighlightActionPopover {...props} />)
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(props.onClose).toHaveBeenCalled()
  })

  it('clicking outside the popover fires onClose', () => {
    const props = baseProps()
    render(
      <>
        <div data-testid="outside" />
        <HighlightActionPopover {...props} />
      </>
    )
    // Same 100ms delay as SelectionPopover before binding the listener; advance time.
    vi.useFakeTimers()
    vi.advanceTimersByTime(150)
    fireEvent.mouseDown(screen.getByTestId('outside'))
    expect(props.onClose).toHaveBeenCalled()
    vi.useRealTimers()
  })

  it('marks the currentColor swatch as active (aria-pressed=true)', () => {
    render(<HighlightActionPopover {...baseProps()} />)
    const yellowSwatch = screen.getByRole('button', { name: /change.*yellow/i })
    expect(yellowSwatch.getAttribute('aria-pressed')).toBe('true')
  })
})
```

Run: `pnpm test -- src/renderer/src/components/highlights/HighlightActionPopover.test.tsx`
Expected: FAIL — `Cannot find module './HighlightActionPopover'`.

- [ ] **Step 2: Implement the component**

Create `src/renderer/src/components/highlights/HighlightActionPopover.tsx`:

```tsx
import { useEffect, useRef } from 'react'
import { Pencil, Trash2 } from 'lucide-react'
import { HIGHLIGHT_COLORS, type HighlightColor } from '@/types/highlight'

export interface HighlightActionPopoverProps {
  position: { x: number; y: number }
  currentColor: HighlightColor
  onSelectColor: (color: HighlightColor) => void
  onEditNote: () => void
  onDelete: () => void
  onClose: () => void
}

export function HighlightActionPopover({
  position,
  currentColor,
  onSelectColor,
  onEditNote,
  onDelete,
  onClose
}: HighlightActionPopoverProps) {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [onClose])

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        onClose()
      }
    }
    // Same 100 ms delay as SelectionPopover so the click that opened the
    // popover doesn't immediately close it.
    const timer = setTimeout(() => {
      document.addEventListener('mousedown', handleClickOutside)
    }, 100)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('mousedown', handleClickOutside)
    }
  }, [onClose])

  return (
    <div
      ref={containerRef}
      className="fixed z-50 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg shadow-md p-2"
      style={{ left: position.x, top: position.y }}
    >
      <div className="flex items-center gap-2">
        {HIGHLIGHT_COLORS.map((c) => {
          const isCurrent = c.name === currentColor
          return (
            <button
              key={c.name}
              type="button"
              aria-pressed={isCurrent}
              aria-label={`Change to ${c.name}`}
              title={`Change to ${c.name}`}
              className={
                'rounded-full transition-transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-blue-500 ' +
                (isCurrent
                  ? 'border-2 border-blue-500'
                  : 'border border-gray-300/50')
              }
              style={{
                width: 28,
                height: 28,
                backgroundColor: c.hex
              }}
              onClick={() => {
                onSelectColor(c.name)
                onClose()
              }}
            />
          )
        })}

        <button
          type="button"
          aria-label="Edit note"
          title="Edit note"
          className="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
          onClick={() => {
            onEditNote()
            onClose()
          }}
        >
          <Pencil size={16} className="text-gray-700 dark:text-gray-200" />
        </button>

        <button
          type="button"
          aria-label="Delete highlight"
          title="Delete highlight"
          className="p-1 rounded hover:bg-red-100 dark:hover:bg-red-900/30 text-red-500 focus:outline-none focus:ring-2 focus:ring-red-500"
          onClick={() => {
            onDelete()
            onClose()
          }}
        >
          <Trash2 size={16} />
        </button>
      </div>
    </div>
  )
}
```

Run: `pnpm test -- src/renderer/src/components/highlights/HighlightActionPopover.test.tsx`
Expected: all 7 tests PASS.

Run: `pnpm typecheck:web`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/components/highlights/HighlightActionPopover.tsx src/renderer/src/components/highlights/HighlightActionPopover.test.tsx
git commit -m "feat(highlight): HighlightActionPopover - color swatches + edit + delete"
```

---

## Task 7: Widen epubjs annotation callback type to receive `MouseEvent`

**Files:**
- Modify: `src/renderer/src/modules/epubjs-extensions.d.ts` (the `highlight()` signature around lines 63-69)

At runtime, epubjs's `annotations.highlight(...)` invokes the click callback with a `MouseEvent` argument from the iframe. The local type declaration currently narrows this to `() => void`. We need the event to position the popover.

- [ ] **Step 1: Widen the signature**

Replace lines 63-69 of `src/renderer/src/modules/epubjs-extensions.d.ts`:

```ts
    highlight(
      cfiRange: string | EpubCFI,
      data?: Record<string, unknown>,
      cb?: () => void,
      className?: string,
      styles?: Record<string, unknown>
    ): unknown
```

with:

```ts
    highlight(
      cfiRange: string | EpubCFI,
      data?: Record<string, unknown>,
      cb?: (e?: MouseEvent) => void,
      className?: string,
      styles?: Record<string, unknown>
    ): unknown
```

- [ ] **Step 2: Run typecheck + tests**

```bash
pnpm typecheck:web
pnpm test
```
Expected: clean. The existing callsites all pass `() => {}` which is still assignable to `(e?: MouseEvent) => void`.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/modules/epubjs-extensions.d.ts
git commit -m "types(epubjs): widen annotation click callback to accept MouseEvent"
```

---

## Task 8: Wire click callback in EpubView (popover + color/note/delete handlers)

**Files:**
- Modify: `src/renderer/src/components/epub/EpubView.tsx`

This is the biggest task. It wires the popover to highlight clicks, adds color-change and note-edit paths, and integrates `deleteHighlightWithUndo` for the inline delete.

- [ ] **Step 1: Add imports**

In `EpubView.tsx`, near the existing highlight-related imports (around lines 22-24), add:

```ts
import { applyHighlightWithUndo, deleteHighlightWithUndo, type HighlightHandle } from '@/modules/highlight-actions'
```

(Replace the existing `import { applyHighlightWithUndo } from '@/modules/highlight-actions'` line — combine into one.)

Near the existing `HighlightsPanel` import (around line 30), add:

```ts
import { HighlightActionPopover } from '@/components/highlights/HighlightActionPopover'
import { NoteEditor } from '@/components/highlights/NoteEditor'
```

Near the highlight-storage import:

```ts
import { getHighlightsForBook, updateHighlightColor } from '@/modules/highlight-storage'
```

(Replace the existing `import { getHighlightsForBook } from '@/modules/highlight-storage'` line to add `updateHighlightColor`.)

Also add a ref import if not already present (it is — `useRef` is already imported on line 7).

- [ ] **Step 2: Add component state and the in-memory highlights map**

Inside the component body, near the existing `const [highlightsPanelOpen, setHighlightsPanelOpen] = useState(false)` (line 194), add:

```ts
  // Map of cfiRange -> the latest HighlightRow, kept in a ref so the per-
  // annotation click callback (registered once, never re-bound) can read
  // the current color/note after edits.
  const highlightsByRangeRef = useRef<Map<string, import('@/modules/highlight-storage').HighlightRow>>(new Map())

  const [inlinePopover, setInlinePopover] = useState<{
    cfiRange: string
    position: { x: number; y: number }
    currentColor: import('@/types/highlight').HighlightColor
  } | null>(null)

  const [editingNoteRow, setEditingNoteRow] = useState<
    import('@/modules/highlight-storage').HighlightRow | null
  >(null)
```

- [ ] **Step 3: Define the click callback factory**

Just after the new state declarations above (still inside the component body, before `handleHighlightColor`), add the click callback factory. This function returns a callback closure-bound to the cfiRange so we don't need a reverse lookup inside the click:

```ts
  const onHighlightClickRef = useRef<(cfiRange: string) => (e?: MouseEvent) => void>(() => () => {})

  useEffect(() => {
    onHighlightClickRef.current = (cfiRange: string) => (e?: MouseEvent) => {
      const row = highlightsByRangeRef.current.get(cfiRange)
      if (!row) return
      // Translate iframe-local click coords to viewport coords. If the event
      // is missing (defensive — epubjs always passes one in current versions),
      // center the popover at the viewport's mid-bottom.
      let x = window.innerWidth / 2
      let y = window.innerHeight / 2
      if (e?.target instanceof Element) {
        const iframe = e.target.ownerDocument?.defaultView?.frameElement as HTMLElement | null
        const iframeRect = iframe?.getBoundingClientRect()
        x = (iframeRect?.left ?? 0) + e.clientX
        y = (iframeRect?.top ?? 0) + e.clientY
      }
      setInlinePopover({
        cfiRange,
        position: { x, y },
        currentColor: row.color as import('@/types/highlight').HighlightColor
      })
    }
  })

  const makeAnnotationClickCb = useCallback(
    (cfiRange: string) => (e?: MouseEvent) => onHighlightClickRef.current(cfiRange)(e),
    []
  )
```

Why two layers: the listener registered with epubjs is the inner closure captured at draw time, but it forwards through `onHighlightClickRef.current` so future state updates (e.g. color changed → row entry replaced) propagate to clicks on highlights drawn earlier.

- [ ] **Step 4: Update the persisted-highlights load loop to populate the map and wire the click callback**

Locate the existing `useEffect` that loads persisted highlights on rendition-ready (currently around lines 274-282 — look for `getHighlightsForBook(syncId)`). Replace its body with:

```ts
    void getHighlightsForBook(syncId).then((highlights) => {
      highlightsByRangeRef.current.clear()
      for (const hl of highlights) {
        highlightsByRangeRef.current.set(hl.cfiRange, hl)
        void highlightRange(
          rendition,
          hl.cfiRange,
          {},
          makeAnnotationClickCb(hl.cfiRange),
          'epubjs-hl',
          {
            fill: getHighlightHex(hl.color as HighlightColor),
            'fill-opacity': '0.3',
            'mix-blend-mode': 'multiply'
          }
        )
      }
    })
```

(Keep the surrounding effect — only the body of the `.then(...)` is replaced. Make sure `makeAnnotationClickCb` is in the dependency array of the parent effect — add it.)

- [ ] **Step 5: Update `handleHighlightColor` to register the new annotation in the map and pass the click callback**

Find the existing `handleHighlightColor` (post-Wave-4 it's around lines 322-360). The current `applyVisual` callback is:

```ts
        target: {
          applyVisual: async () => {
            await highlightRange(rendition, cfiRange, {}, () => {}, 'epubjs-hl', {
              fill: hex,
              'fill-opacity': '0.3',
              'mix-blend-mode': 'multiply'
            })
          },
```

Change the `() => {}` to `makeAnnotationClickCb(cfiRange)` and also update the map entry on success. The full replacement of `handleHighlightColor`:

```ts
  const handleHighlightColor = useCallback(
    (color: HighlightColor) => {
      if (!selectionInfo || !rendition || !bookSyncIdRef.current) return
      const hex = getHighlightHex(color)
      const cfiRange = selectionInfo.cfiRange
      const text = selectionInfo.text
      const bookSyncId = bookSyncIdRef.current

      void applyHighlightWithUndo({
        target: {
          applyVisual: async () => {
            await highlightRange(
              rendition,
              cfiRange,
              {},
              makeAnnotationClickCb(cfiRange),
              'epubjs-hl',
              { fill: hex, 'fill-opacity': '0.3', 'mix-blend-mode': 'multiply' }
            )
          },
          removeVisual: async () => {
            await removeHighlight(rendition, cfiRange)
          }
        },
        bookSyncId,
        cfiRange,
        text,
        color
      })
        .then((handle) => {
          // Reflect the newly-created highlight in the click-time lookup map.
          // The row's id/createdAt aren't observable here, but `cfiRange`,
          // `text`, and `color` are enough for the popover.
          highlightsByRangeRef.current.set(cfiRange, {
            id: '__pending__',
            bookId: bookSyncId,
            cfiRange,
            text,
            color,
            note: '',
            chapter: null,
            createdAt: String(Date.now()),
            updatedAt: Date.now(),
            syncId: null,
            syncVersion: 0,
            isDirty: 1,
            isDeleted: 0
          })
          setLastUndoable(handle)
          toast('Highlighted', {
            action: { label: 'Undo', onClick: () => void handle.undo() },
            duration: 5_000
          })
        })
        .catch((err: unknown) => {
          console.warn('[highlight] apply failed:', err)
        })

      setSelectionInfo(null)
      useSelectionStore.getState().clear()
    },
    [selectionInfo, rendition, setLastUndoable, bookSyncIdRef, makeAnnotationClickCb]
  )
```

Note on `id: '__pending__'`: the map only needs row identity for the popover's color/note read-back. If the user re-opens the panel, `refreshHighlights` (in the panel) will overwrite this sentinel with the real DB row.

- [ ] **Step 6: Add the popover action handlers**

After `handleHighlightColor`, add three new handlers:

```ts
  const handleInlineColorChange = useCallback(
    async (newColor: HighlightColor) => {
      if (!inlinePopover || !rendition || !bookSyncIdRef.current) return
      const cfiRange = inlinePopover.cfiRange
      const row = highlightsByRangeRef.current.get(cfiRange)
      if (!row) return
      const newHex = getHighlightHex(newColor)

      // Visual swap: remove old, re-draw with new color and the same click cb.
      await removeHighlight(rendition, cfiRange)
      await highlightRange(
        rendition,
        cfiRange,
        {},
        makeAnnotationClickCb(cfiRange),
        'epubjs-hl',
        { fill: newHex, 'fill-opacity': '0.3', 'mix-blend-mode': 'multiply' }
      )

      // DB update (only if we have a real DB id — pending sentinel skips).
      if (row.id !== '__pending__') {
        try {
          await updateHighlightColor(row.id, newColor)
          getSyncService().triggerWrite()
        } catch (err) {
          console.warn('[highlight] color update failed:', err)
        }
      }

      // Reflect in the map.
      highlightsByRangeRef.current.set(cfiRange, { ...row, color: newColor })
    },
    [inlinePopover, rendition, bookSyncIdRef, makeAnnotationClickCb]
  )

  const handleInlineDelete = useCallback(() => {
    if (!inlinePopover || !rendition || !bookSyncIdRef.current) return
    const cfiRange = inlinePopover.cfiRange
    const row = highlightsByRangeRef.current.get(cfiRange)
    if (!row) return
    const hex = getHighlightHex(row.color as HighlightColor)
    const bookSyncId = bookSyncIdRef.current

    void deleteHighlightWithUndo({
      target: {
        applyVisual: async () => {
          await highlightRange(
            rendition,
            cfiRange,
            {},
            makeAnnotationClickCb(cfiRange),
            'epubjs-hl',
            { fill: hex, 'fill-opacity': '0.3', 'mix-blend-mode': 'multiply' }
          )
        },
        removeVisual: async () => {
          await removeHighlight(rendition, cfiRange)
        }
      },
      bookSyncId,
      cfiRange,
      text: row.text,
      color: row.color as HighlightColor,
      note: row.note,
      chapter: row.chapter ?? undefined
    })
      .then((handle) => {
        highlightsByRangeRef.current.delete(cfiRange)
        setLastUndoable(handle)
        toast('Highlight deleted', {
          action: {
            label: 'Undo',
            onClick: () => {
              void handle.undo().then(() => {
                highlightsByRangeRef.current.set(cfiRange, row)
              })
            }
          },
          duration: 5_000
        })
      })
      .catch((err: unknown) => {
        console.warn('[highlight] delete failed:', err)
      })
  }, [inlinePopover, rendition, bookSyncIdRef, setLastUndoable, makeAnnotationClickCb])

  const handleInlineEditNote = useCallback(() => {
    if (!inlinePopover) return
    const row = highlightsByRangeRef.current.get(inlinePopover.cfiRange)
    if (!row) return
    setEditingNoteRow(row)
  }, [inlinePopover])
```

- [ ] **Step 7: Render the popover and NoteEditor in the JSX**

In the JSX render output of EpubView, immediately after the existing `<SelectionPopover ... />` JSX element (search for `<SelectionPopover` to find it), add:

```tsx
        {inlinePopover ? (
          <HighlightActionPopover
            position={inlinePopover.position}
            currentColor={inlinePopover.currentColor}
            onSelectColor={(c) => {
              void handleInlineColorChange(c)
            }}
            onEditNote={handleInlineEditNote}
            onDelete={handleInlineDelete}
            onClose={() => setInlinePopover(null)}
          />
        ) : null}

        <NoteEditor
          highlight={editingNoteRow}
          open={editingNoteRow !== null}
          onOpenChange={(isOpen) => {
            if (!isOpen) setEditingNoteRow(null)
          }}
          onSaved={async () => {
            // Refresh the in-memory map so the popover sees the new note next time.
            if (!bookSyncIdRef.current) return
            const rows = await getHighlightsForBook(bookSyncIdRef.current)
            highlightsByRangeRef.current = new Map(rows.map((r) => [r.cfiRange, r]))
          }}
        />
```

- [ ] **Step 8: Run + typecheck + lint**

```bash
pnpm test
pnpm typecheck:web
pnpm lint
```
Expected: all tests pass (826/826), typecheck clean, no new lint findings on `EpubView.tsx`.

If lint flags `react-hooks/exhaustive-deps` on the `makeAnnotationClickCb` `useCallback` (the empty array `[]`), keep it — the function depends only on the ref, which is stable.

- [ ] **Step 9: Commit**

```bash
git add src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(epub): click-on-highlight popover - color, edit note, delete with undo"
```

---

## Task 9: Manual smoke test + final verification

**Files:** none — verification only.

- [ ] **Step 1: Start the dev app**

Run: `pnpm dev`
Wait for the Electron window.

- [ ] **Step 2: Verify the panel entry points**

1. Open an EPUB book.
2. Open the View menu → "Show Highlights" item is present.
3. Click "Show Highlights" — the panel slides in from the right.
4. Close it. Press `Cmd+Shift+H` (mac) or `Ctrl+Shift+H` (win/linux) — panel opens.
5. Open a PDF book in a new window. The View menu should NOT show "Show Highlights".

- [ ] **Step 3: Verify panel delete with visual removal and undo**

1. With the EPUB book open, apply a yellow highlight to a sentence.
2. Open the highlights panel.
3. Click the Trash icon next to the highlight.
4. Confirm: the colored mark on the page disappears immediately (this was the bug); the row disappears from the panel; a toast appears with "Undo".
5. Click "Undo" in the toast — the highlight reappears on the page AND in the panel.
6. Delete again. This time press `Cmd/Ctrl+Z` instead of clicking the toast — same result, highlight is back.

- [ ] **Step 4: Verify the inline highlight popover**

1. Apply a fresh yellow highlight.
2. Click on the highlighted span in the book content.
3. The HighlightActionPopover appears near the click. It shows all color swatches (yellow is marked active), a Pencil icon, and a Trash icon.
4. **Color change**: click the blue swatch. The highlight visually changes to blue. Open the panel — the row's color stripe is blue.
5. Click the highlight again, click Pencil. The NoteEditor opens. Type a note, save. Close the popover. Click the highlight again — popover should re-open; close it. Open the panel — the note text appears.
6. Click the highlight again, click Trash. Same delete+toast+undo behavior as the panel.

- [ ] **Step 5: Verify Cmd/Ctrl+Z window boundary**

1. Apply a highlight.
2. Wait >6 seconds.
3. Press `Cmd/Ctrl+Z` — nothing happens (slot expired).

- [ ] **Step 6: Full automated suite, typecheck, lint**

```bash
pnpm test
pnpm typecheck
pnpm lint
```
Expected: all suites pass, typecheck clean (web + node), zero new lint findings.

- [ ] **Step 7: If any manual check failed, STOP and report**

Do not commit fixes without writing an automated test that captures the regression where reasonable. For pure native-menu integration issues, document them in the smoke checklist for future runs.

No commit — this task is verification only.

---

## Out of Scope (do NOT touch in this plan)

- AZW3/PDF view changes — they don't render user-applied highlights.
- Bulk operations from the panel.
- Color/note edit undo via toast — natural undo paths are sufficient.
- A dedicated `highlights:undelete` IPC — re-applying via `saveHighlight` is sufficient; the soft-deleted ghost row is benign.
- Tests for `HighlightsPanel.tsx` itself — no existing test file, and the panel's behavior is verified via the helper unit tests + manual smoke.
- E2E Playwright spec for the click-on-highlight flow — deferred (same as the previous wave's deferred E2E coverage).
