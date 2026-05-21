# Library bulk delete & multi-select — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-select + bulk delete to the Electron library, with the path to clearing the library being `Select → Select All → Delete`. No separate "Clear All" button.

**Architecture:** Local state in `FileComponent.tsx` via a new `useBookSelection` hook. Two new presentational components (`SelectionActionBar`, `DeleteConfirmDialog`). Bulk delete loops the existing `books:delete` IPC inside a new TanStack Query mutation that reuses the per-book cleanup (PDF/EPUB cache eviction, cover URL revocation, `pdfStore.removeBook`).

**Tech Stack:** React 19, TanStack Query, Radix Dialog (already in `components/ui/dialog.tsx`), Vitest + Testing Library, Zustand (existing `usePdfStore`), Tailwind, lucide-react icons.

**Spec:** `docs/superpowers/specs/2026-05-21-library-bulk-delete-design.md`

**Out of scope (per spec):** undo, separate "Clear All" button, batch IPC handler, schema changes.

---

## File structure

**Create:**

- `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.ts` — hook owning Select-mode state + handlers (`toggle`, `selectAll`, `clear`, `extendTo`, `enterSelectMode`, `exitSelectMode`).
- `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.test.ts` — unit tests for the hook.
- `apps/rishi-electron/src/renderer/src/components/library/SelectionActionBar.tsx` — bottom action bar (count + Select All + Delete + Cancel).
- `apps/rishi-electron/src/renderer/src/components/library/SelectionActionBar.test.tsx` — unit tests.
- `apps/rishi-electron/src/renderer/src/components/library/DeleteConfirmDialog.tsx` — Radix-Dialog–based confirm modal.
- `apps/rishi-electron/src/renderer/src/components/library/DeleteConfirmDialog.test.tsx` — unit tests.
- `apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx` — integration tests (does not currently exist).

**Modify:**

- `apps/rishi-electron/src/renderer/src/components/FileComponent.tsx` — wire the hook, the toolbar Select button, cover checkboxes, Cmd/Ctrl+click + Shift+click handlers, context-menu Select item, bulk-delete mutation, action bar, confirm dialog, keyboard shortcuts.

**Implementation detail (intentional deviation from spec wording):** The cover checkbox + selected-ring chrome are rendered on the wrapper `<div>` in `FileComponent`'s grid render, **not** by modifying the `BookCoverImage` component. This keeps `BookCoverImage` focused on its cover-cache concerns (`coverUrlCache`, `coverImageCache`, `decoding="sync"`).

---

## Conventions and shared helpers used by every task

**Run all tests for one file:**
```bash
pnpm --filter rishi-electron exec vitest run <path>
```

**Run a single test by name:**
```bash
pnpm --filter rishi-electron exec vitest run <path> -t "<test name>"
```

**Typecheck the renderer:**
```bash
pnpm --filter rishi-electron run typecheck:web
```

**`renderHook`** from `@testing-library/react` is used for hook unit tests.

**No QueryClientProvider** is needed for hook tests or the small presentational components. Integration tests in `FileComponent.test.tsx` wrap the component in a `QueryClientProvider` with a per-test client (helper defined inside the test file in Task 9).

---

## Task 1: Scaffold `useBookSelection` — initial state, toggle, clear, exitSelectMode

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.ts`
- Create: `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.test.ts`

- [ ] **Step 1: Write the failing test**

Create `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { useBookSelection } from './useBookSelection'

describe('useBookSelection — base state', () => {
  it('starts not in Select mode with an empty selection', () => {
    const { result } = renderHook(() => useBookSelection())
    expect(result.current.selectMode).toBe(false)
    expect(result.current.selectedIds.size).toBe(0)
  })

  it('toggle adds an unselected id and enters Select mode', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(7))
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.has(7)).toBe(true)
  })

  it('toggle removes a selected id', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(7))
    act(() => result.current.toggle(7))
    expect(result.current.selectedIds.has(7)).toBe(false)
  })

  it('clear empties selection but keeps Select mode on', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(1))
    act(() => result.current.toggle(2))
    act(() => result.current.clear())
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.size).toBe(0)
  })

  it('exitSelectMode resets selectMode and selectedIds', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(1))
    act(() => result.current.exitSelectMode())
    expect(result.current.selectMode).toBe(false)
    expect(result.current.selectedIds.size).toBe(0)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/useBookSelection.test.ts
```
Expected: FAIL — `Failed to resolve import './useBookSelection'`.

- [ ] **Step 3: Write minimal implementation**

Create `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.ts`:

```ts
import { useCallback, useState } from 'react'

export interface BookSelection {
  selectMode: boolean
  selectedIds: Set<number>
  toggle: (id: number) => void
  clear: () => void
  exitSelectMode: () => void
}

export function useBookSelection(): BookSelection {
  const [selectMode, setSelectMode] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set())

  const toggle = useCallback((id: number) => {
    setSelectMode(true)
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) {
        next.delete(id)
      } else {
        next.add(id)
      }
      return next
    })
  }, [])

  const clear = useCallback(() => {
    setSelectedIds(new Set())
  }, [])

  const exitSelectMode = useCallback(() => {
    setSelectMode(false)
    setSelectedIds(new Set())
  }, [])

  return { selectMode, selectedIds, toggle, clear, exitSelectMode }
}
```

- [ ] **Step 4: Run tests, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/useBookSelection.test.ts
```
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/library/useBookSelection.ts \
        apps/rishi-electron/src/renderer/src/components/library/useBookSelection.test.ts
git commit -m "feat(electron): add useBookSelection hook base (toggle, clear, exit)"
```

---

## Task 2: `useBookSelection` — selectAll(filtered)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.ts`
- Modify: `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.test.ts`

- [ ] **Step 1: Add failing tests**

Append to `useBookSelection.test.ts`:

```ts
describe('useBookSelection — selectAll', () => {
  it('selects exactly the ids of the given list', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.selectAll([{ id: 1 }, { id: 2 }, { id: 3 }]))
    expect(result.current.selectMode).toBe(true)
    expect([...result.current.selectedIds].sort()).toEqual([1, 2, 3])
  })

  it('replaces an existing selection rather than merging', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(99))
    act(() => result.current.selectAll([{ id: 1 }, { id: 2 }]))
    expect([...result.current.selectedIds].sort()).toEqual([1, 2])
  })

  it('handles empty input (no-op selection, mode preserved)', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(5))
    act(() => result.current.selectAll([]))
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.size).toBe(0)
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/useBookSelection.test.ts
```
Expected: 3 new tests FAIL with `result.current.selectAll is not a function`.

- [ ] **Step 3: Implement**

Update the `BookSelection` interface and add `selectAll` inside the hook:

```ts
export interface BookSelection {
  selectMode: boolean
  selectedIds: Set<number>
  toggle: (id: number) => void
  selectAll: (books: ReadonlyArray<{ id: number }>) => void
  clear: () => void
  exitSelectMode: () => void
}
```

Inside `useBookSelection`, add:

```ts
  const selectAll = useCallback((books: ReadonlyArray<{ id: number }>) => {
    setSelectMode(true)
    setSelectedIds(new Set(books.map((b) => b.id)))
  }, [])
```

Include `selectAll` in the returned object.

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/useBookSelection.test.ts
```
Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/library/useBookSelection.ts \
        apps/rishi-electron/src/renderer/src/components/library/useBookSelection.test.ts
git commit -m "feat(electron): useBookSelection.selectAll(filtered)"
```

---

## Task 3: `useBookSelection` — enterSelectMode + extendTo (Shift+click range)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.ts`
- Modify: `apps/rishi-electron/src/renderer/src/components/library/useBookSelection.test.ts`

- [ ] **Step 1: Add failing tests**

Append:

```ts
describe('useBookSelection — enterSelectMode', () => {
  it('enters Select mode with no id (toolbar Select button)', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.enterSelectMode())
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.size).toBe(0)
  })

  it('enters Select mode pre-seeded with one id (context menu / Cmd+click)', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.enterSelectMode(42))
    expect(result.current.selectMode).toBe(true)
    expect(result.current.selectedIds.has(42)).toBe(true)
  })
})

describe('useBookSelection — extendTo (Shift+click range)', () => {
  const order = [10, 20, 30, 40, 50]

  it('selects an inclusive forward range from the last-toggled id', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(20)) // anchor
    act(() => result.current.extendTo(40, order))
    expect([...result.current.selectedIds].sort((a, b) => a - b)).toEqual([20, 30, 40])
  })

  it('selects an inclusive reverse range from the last-toggled id', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(40)) // anchor
    act(() => result.current.extendTo(20, order))
    expect([...result.current.selectedIds].sort((a, b) => a - b)).toEqual([20, 30, 40])
  })

  it('falls back to selecting only the target when no anchor exists', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.extendTo(30, order))
    expect([...result.current.selectedIds]).toEqual([30])
  })

  it('preserves existing selection when extending', () => {
    const { result } = renderHook(() => useBookSelection())
    act(() => result.current.toggle(50))
    act(() => result.current.toggle(10)) // newest anchor is 10
    act(() => result.current.extendTo(30, order))
    expect([...result.current.selectedIds].sort((a, b) => a - b)).toEqual([10, 20, 30, 50])
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/useBookSelection.test.ts
```
Expected: 6 new tests FAIL.

- [ ] **Step 3: Implement**

Replace the hook body so that `lastClickedId` is tracked, and add `enterSelectMode` + `extendTo`. Update the return type:

```ts
import { useCallback, useState } from 'react'

export interface BookSelection {
  selectMode: boolean
  selectedIds: Set<number>
  toggle: (id: number) => void
  selectAll: (books: ReadonlyArray<{ id: number }>) => void
  extendTo: (targetId: number, displayOrder: ReadonlyArray<number>) => void
  enterSelectMode: (initialId?: number) => void
  clear: () => void
  exitSelectMode: () => void
}

export function useBookSelection(): BookSelection {
  const [selectMode, setSelectMode] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set())
  const [lastClickedId, setLastClickedId] = useState<number | null>(null)

  const toggle = useCallback((id: number) => {
    setSelectMode(true)
    setLastClickedId(id)
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) {
        next.delete(id)
      } else {
        next.add(id)
      }
      return next
    })
  }, [])

  const selectAll = useCallback((books: ReadonlyArray<{ id: number }>) => {
    setSelectMode(true)
    setSelectedIds(new Set(books.map((b) => b.id)))
  }, [])

  const extendTo = useCallback(
    (targetId: number, displayOrder: ReadonlyArray<number>) => {
      setSelectMode(true)
      setSelectedIds((prev) => {
        const next = new Set(prev)
        const targetIdx = displayOrder.indexOf(targetId)
        const anchorIdx = lastClickedId == null ? -1 : displayOrder.indexOf(lastClickedId)
        if (targetIdx === -1 || anchorIdx === -1) {
          next.add(targetId)
          return next
        }
        const [from, to] =
          anchorIdx <= targetIdx ? [anchorIdx, targetIdx] : [targetIdx, anchorIdx]
        for (let i = from; i <= to; i++) next.add(displayOrder[i])
        return next
      })
      setLastClickedId(targetId)
    },
    [lastClickedId]
  )

  const enterSelectMode = useCallback((initialId?: number) => {
    setSelectMode(true)
    if (initialId !== undefined) {
      setLastClickedId(initialId)
      setSelectedIds(new Set([initialId]))
    }
  }, [])

  const clear = useCallback(() => {
    setSelectedIds(new Set())
  }, [])

  const exitSelectMode = useCallback(() => {
    setSelectMode(false)
    setSelectedIds(new Set())
    setLastClickedId(null)
  }, [])

  return { selectMode, selectedIds, toggle, selectAll, extendTo, enterSelectMode, clear, exitSelectMode }
}
```

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/useBookSelection.test.ts
```
Expected: 13 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/library/useBookSelection.ts \
        apps/rishi-electron/src/renderer/src/components/library/useBookSelection.test.ts
git commit -m "feat(electron): useBookSelection enterSelectMode + extendTo range"
```

---

## Task 4: `SelectionActionBar` component

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/components/library/SelectionActionBar.tsx`
- Create: `apps/rishi-electron/src/renderer/src/components/library/SelectionActionBar.test.tsx`

- [ ] **Step 1: Write failing tests**

Create `SelectionActionBar.test.tsx`:

```tsx
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { SelectionActionBar } from './SelectionActionBar'

describe('SelectionActionBar', () => {
  it('renders the count (singular and plural)', () => {
    const { rerender } = render(
      <SelectionActionBar count={1} onSelectAll={() => {}} onDelete={() => {}} onCancel={() => {}} />
    )
    expect(screen.getByText('1 selected')).toBeInTheDocument()
    rerender(
      <SelectionActionBar count={3} onSelectAll={() => {}} onDelete={() => {}} onCancel={() => {}} />
    )
    expect(screen.getByText('3 selected')).toBeInTheDocument()
  })

  it('fires onSelectAll, onDelete, onCancel when clicked', () => {
    const onSelectAll = vi.fn()
    const onDelete = vi.fn()
    const onCancel = vi.fn()
    render(
      <SelectionActionBar
        count={2}
        onSelectAll={onSelectAll}
        onDelete={onDelete}
        onCancel={onCancel}
      />
    )
    fireEvent.click(screen.getByRole('button', { name: /select all/i }))
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }))
    expect(onSelectAll).toHaveBeenCalledTimes(1)
    expect(onDelete).toHaveBeenCalledTimes(1)
    expect(onCancel).toHaveBeenCalledTimes(1)
  })

  it('disables Delete when count is 0', () => {
    render(
      <SelectionActionBar count={0} onSelectAll={() => {}} onDelete={() => {}} onCancel={() => {}} />
    )
    expect(screen.getByRole('button', { name: /^delete$/i })).toBeDisabled()
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/SelectionActionBar.test.tsx
```
Expected: FAIL — `Failed to resolve import './SelectionActionBar'`.

- [ ] **Step 3: Implement**

Create `SelectionActionBar.tsx`:

```tsx
import { Trash2 } from 'lucide-react'
import { Button } from '../ui/Button'

export interface SelectionActionBarProps {
  count: number
  onSelectAll: () => void
  onDelete: () => void
  onCancel: () => void
}

export function SelectionActionBar({
  count,
  onSelectAll,
  onDelete,
  onCancel
}: SelectionActionBarProps): React.JSX.Element {
  return (
    <div
      role="toolbar"
      aria-label="Selection actions"
      className="fixed bottom-4 left-1/2 -translate-x-1/2 z-40 flex items-center gap-2 bg-white border border-gray-200 shadow-lg rounded-full px-4 py-2"
    >
      <span className="text-sm font-medium text-gray-700 mr-1">{count} selected</span>
      <Button variant="ghost" onClick={onSelectAll}>
        Select All
      </Button>
      <Button
        variant="ghost"
        onClick={onDelete}
        disabled={count === 0}
        startIcon={<Trash2 size={16} />}
        className="text-red-600 hover:text-red-700"
      >
        Delete
      </Button>
      <Button variant="ghost" onClick={onCancel}>
        Cancel
      </Button>
    </div>
  )
}
```

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/SelectionActionBar.test.tsx
```
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/library/SelectionActionBar.tsx \
        apps/rishi-electron/src/renderer/src/components/library/SelectionActionBar.test.tsx
git commit -m "feat(electron): SelectionActionBar component"
```

---

## Task 5: `DeleteConfirmDialog` component

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/components/library/DeleteConfirmDialog.tsx`
- Create: `apps/rishi-electron/src/renderer/src/components/library/DeleteConfirmDialog.test.tsx`

- [ ] **Step 1: Write failing tests**

Create `DeleteConfirmDialog.test.tsx`:

```tsx
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { DeleteConfirmDialog } from './DeleteConfirmDialog'

describe('DeleteConfirmDialog', () => {
  it('does not render when closed', () => {
    render(
      <DeleteConfirmDialog
        open={false}
        count={3}
        onCancel={() => {}}
        onConfirm={() => {}}
        isDeleting={false}
      />
    )
    expect(screen.queryByText(/delete/i)).not.toBeInTheDocument()
  })

  it('renders the count in the title (singular and plural)', () => {
    const { rerender } = render(
      <DeleteConfirmDialog
        open={true}
        count={1}
        onCancel={() => {}}
        onConfirm={() => {}}
        isDeleting={false}
      />
    )
    expect(screen.getByText('Delete 1 book?')).toBeInTheDocument()
    rerender(
      <DeleteConfirmDialog
        open={true}
        count={5}
        onCancel={() => {}}
        onConfirm={() => {}}
        isDeleting={false}
      />
    )
    expect(screen.getByText('Delete 5 books?')).toBeInTheDocument()
  })

  it('fires onConfirm when Delete is clicked', () => {
    const onConfirm = vi.fn()
    render(
      <DeleteConfirmDialog
        open={true}
        count={2}
        onCancel={() => {}}
        onConfirm={onConfirm}
        isDeleting={false}
      />
    )
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it('fires onCancel when Cancel is clicked', () => {
    const onCancel = vi.fn()
    render(
      <DeleteConfirmDialog
        open={true}
        count={2}
        onCancel={onCancel}
        onConfirm={() => {}}
        isDeleting={false}
      />
    )
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(onCancel).toHaveBeenCalledTimes(1)
  })

  it('disables the Delete button while deleting', () => {
    render(
      <DeleteConfirmDialog
        open={true}
        count={2}
        onCancel={() => {}}
        onConfirm={() => {}}
        isDeleting={true}
      />
    )
    expect(screen.getByRole('button', { name: /deleting/i })).toBeDisabled()
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/DeleteConfirmDialog.test.tsx
```
Expected: FAIL — `Failed to resolve import './DeleteConfirmDialog'`.

- [ ] **Step 3: Implement**

Create `DeleteConfirmDialog.tsx`:

```tsx
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '../ui/dialog'
import { Button } from '../ui/Button'

export interface DeleteConfirmDialogProps {
  open: boolean
  count: number
  onCancel: () => void
  onConfirm: () => void
  isDeleting: boolean
}

export function DeleteConfirmDialog({
  open,
  count,
  onCancel,
  onConfirm,
  isDeleting
}: DeleteConfirmDialogProps): React.JSX.Element {
  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next && !isDeleting) onCancel()
      }}
    >
      <DialogContent showCloseButton={false}>
        <DialogHeader>
          <DialogTitle>
            Delete {count} {count === 1 ? 'book' : 'books'}?
          </DialogTitle>
          <DialogDescription>This cannot be undone.</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="ghost" onClick={onCancel} disabled={isDeleting} autoFocus>
            Cancel
          </Button>
          <Button
            onClick={onConfirm}
            disabled={isDeleting}
            className="bg-red-600 text-white hover:bg-red-700"
          >
            {isDeleting ? 'Deleting…' : 'Delete'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
```

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/library/DeleteConfirmDialog.test.tsx
```
Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/library/DeleteConfirmDialog.tsx \
        apps/rishi-electron/src/renderer/src/components/library/DeleteConfirmDialog.test.tsx
git commit -m "feat(electron): DeleteConfirmDialog component"
```

---

## Task 6: Integration test scaffold for `FileComponent` (renderWithClient helper)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx`

This task lays the groundwork (test helper, mocks, sanity test) so tasks 7-11 each add one focused integration test.

- [ ] **Step 1: Write a sanity test**

Create `FileComponent.test.tsx`:

```tsx
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { Book } from '@/lib/api'

// Avoid the dropzone effect / handleDroppedFiles import surface
vi.mock('@/modules/handleDroppedFiles', () => ({
  resolveDroppedFilePaths: vi.fn(() => []),
  DroppedFilesError: class extends Error {},
  getFilesFromDropEvent: vi.fn(async () => [])
}))

// Avoid prefetching TTS during tests
vi.mock('@/modules/ttsPrefetch', () => ({
  prefetchTTSForBooks: vi.fn(async () => {})
}))

// Stub services used in useEffect side-effects
vi.mock('@/services', () => ({
  getBookImportService: () => ({ importBatch: vi.fn(async () => []) }),
  getVoiceChatService: () => ({ prewarmKey: vi.fn() })
}))

// Stub reader caches (their internals require a Worker setup)
vi.mock('@/services/reader-cache/pdf-cache', () => ({
  evictPdf: vi.fn()
}))
vi.mock('@/services/reader-cache/epub-cache', () => ({
  evictEpub: vi.fn()
}))

vi.mock('sonner', () => ({
  toast: Object.assign(vi.fn(), {
    success: vi.fn(),
    error: vi.fn(),
    warning: vi.fn()
  })
}))

import FileComponent from './FileComponent'

function makeBook(over: Partial<Book> = {}): Book {
  return {
    id: 1,
    title: 'Book One',
    author: 'Author A',
    kind: 'pdf',
    cover: [],
    filepath: '/tmp/one.pdf',
    ...(over as object)
  } as Book
}

function renderWithClient(ui: React.ReactNode) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0, staleTime: 0 } }
  })
  return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>)
}

beforeEach(() => {
  // Default fixture: two books
  ;(window.electron.getBooks as unknown as ReturnType<typeof vi.fn>).mockResolvedValue([
    makeBook({ id: 1, title: 'Alpha', author: 'A' }),
    makeBook({ id: 2, title: 'Beta', author: 'B' })
  ])
  ;(window.electron.deleteBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
  localStorage.clear()
})

describe('FileComponent — base render', () => {
  it('shows the library after loading and renders book titles', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => expect(screen.getByText('Alpha')).toBeInTheDocument())
    expect(screen.getByText('Beta')).toBeInTheDocument()
  })
})

export { renderWithClient, makeBook }
```

- [ ] **Step 2: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 1 PASS. If it fails because of unmocked imports, add the missing mock above the `import FileComponent` line.

- [ ] **Step 3: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx
git commit -m "test(electron): scaffold FileComponent test (helpers, mocks, base render)"
```

---

## Task 7: Wire toolbar Select button + cover checkboxes + click-toggle in Select mode

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx`

- [ ] **Step 1: Add failing integration tests**

Append to `FileComponent.test.tsx`:

```tsx
import { fireEvent } from '@testing-library/react'

describe('FileComponent — entering Select mode', () => {
  it('toolbar Select button enters Select mode and shows the action bar', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))

    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    expect(screen.getByRole('toolbar', { name: /selection actions/i })).toBeInTheDocument()
    expect(screen.getByText('0 selected')).toBeInTheDocument()
  })

  it('clicking a cover in Select mode toggles selection (does not open the book)', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    fireEvent.click(screen.getByLabelText('Select Alpha'))

    expect(screen.getByText('1 selected')).toBeInTheDocument()
    expect(window.electron.openBook).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 2 FAIL — no toolbar `Select` button, no `Select Alpha` aria-label.

- [ ] **Step 3: Implement in `FileComponent.tsx`**

Add the import near the top:

```ts
import { useBookSelection } from './library/useBookSelection'
import { SelectionActionBar } from './library/SelectionActionBar'
import { Check, Square, CheckSquare } from 'lucide-react'
```

Inside `FileComponent`, after the other `useState` declarations, add:

```ts
const selection = useBookSelection()
```

In the top toolbar, between the search bar's flex spacer and the `LoginButton`, **add** a Select button:

```tsx
<Button
  variant="ghost"
  className="cursor-pointer"
  onClick={() => {
    if (selection.selectMode) selection.exitSelectMode()
    else selection.enterSelectMode()
  }}
  startIcon={selection.selectMode ? <CheckSquare size={20} /> : <Square size={20} />}
>
  {selection.selectMode ? 'Cancel' : 'Select'}
</Button>
```

In the grid render, replace the book-cover wrapper `<div>` and inner `<button>` block (currently lines ~338–356 of `FileComponent.tsx`) with:

```tsx
filteredBooks.map((book) => {
  const isSelected = selection.selectedIds.has(book.id)
  return (
    <div
      key={book.id}
      className={`flex flex-col gap-1 relative transition-transform duration-200 ease-out hover:scale-[1.03] ${
        isSelected ? 'ring-2 ring-blue-500 rounded-lg' : ''
      }`}
      onContextMenu={(e) => {
        e.preventDefault()
        setContextMenu({ x: e.clientX, y: e.clientY, book })
      }}
    >
      <button
        type="button"
        aria-label={selection.selectMode ? `Select ${book.title}` : undefined}
        onClick={(e) => {
          if (selection.selectMode) {
            e.preventDefault()
            selection.toggle(book.id)
            return
          }
          openBookInNewWindow(book.id)
        }}
        className="block bg-transparent w-full p-0 border-0 cursor-pointer relative"
      >
        <BookCoverImage book={book} />
        {selection.selectMode ? (
          <span
            className={`absolute top-2 left-2 w-5 h-5 rounded-full flex items-center justify-center ${
              isSelected ? 'bg-blue-600 text-white' : 'bg-white/90 border border-gray-300'
            }`}
            aria-hidden="true"
          >
            {isSelected ? <Check size={14} strokeWidth={3} /> : null}
          </span>
        ) : null}
      </button>
      <p className="text-xs font-medium text-gray-900 truncate mt-1">{book.title}</p>
      <p className="text-xs text-gray-500 truncate">{book.author}</p>
    </div>
  )
})
```

Just before the closing `</div>` of the root drop zone (after the `BookDiscoveryModal` line), render the action bar:

```tsx
{selection.selectMode ? (
  <SelectionActionBar
    count={selection.selectedIds.size}
    onSelectAll={() => selection.selectAll(filteredBooks)}
    onDelete={() => {}}
    onCancel={() => selection.exitSelectMode()}
  />
) : null}
```

(`onDelete` is wired in Task 9. Empty for now is intentional — keeps each task tightly scoped.)

- [ ] **Step 4: Run integration tests, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 3 PASS (sanity + 2 new).

- [ ] **Step 5: Run typecheck**

```bash
pnpm --filter rishi-electron run typecheck:web
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/FileComponent.tsx \
        apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx
git commit -m "feat(electron): Select mode toolbar + cover checkboxes + click-toggle"
```

---

## Task 8: Cmd/Ctrl+click and Shift+click on covers

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx`

- [ ] **Step 1: Add failing tests**

Append:

```tsx
describe('FileComponent — modifier-click selection', () => {
  it('Cmd+click on a cover (not in Select mode) auto-enters Select mode with that book selected', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))

    const alpha = screen.getByText('Alpha').closest('div')!.querySelector('button')!
    fireEvent.click(alpha, { metaKey: true })

    expect(screen.getByText('1 selected')).toBeInTheDocument()
    expect(window.electron.openBook).not.toHaveBeenCalled()
  })

  it('Shift+click extends selection across display order', async () => {
    ;(window.electron.getBooks as ReturnType<typeof vi.fn>).mockResolvedValue([
      makeBook({ id: 10, title: 'Alpha' }),
      makeBook({ id: 20, title: 'Beta' }),
      makeBook({ id: 30, title: 'Gamma' })
    ])
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Gamma'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    fireEvent.click(screen.getByLabelText('Select Alpha'))
    fireEvent.click(screen.getByLabelText('Select Gamma'), { shiftKey: true })

    expect(screen.getByText('3 selected')).toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 2 new FAIL — Cmd+click currently opens the book; Shift+click doesn't extend.

- [ ] **Step 3: Implement**

In the cover button's `onClick`, replace the body with this expanded logic:

```tsx
onClick={(e) => {
  if (e.shiftKey && selection.selectMode) {
    e.preventDefault()
    selection.extendTo(
      book.id,
      filteredBooks.map((b) => b.id)
    )
    return
  }
  if (e.metaKey || e.ctrlKey) {
    e.preventDefault()
    if (!selection.selectMode) {
      selection.enterSelectMode(book.id)
    } else {
      selection.toggle(book.id)
    }
    return
  }
  if (selection.selectMode) {
    e.preventDefault()
    selection.toggle(book.id)
    return
  }
  openBookInNewWindow(book.id)
}}
```

Also: when Cmd/Ctrl+click triggers `enterSelectMode`, the button now needs an `aria-label` even *before* Select mode is on — otherwise the test query `getByLabelText('Select Alpha')` for Shift+click won't resolve until after the first render swap. The first test uses a different query so this is already fine; no extra change required.

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 5 PASS total.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/FileComponent.tsx \
        apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx
git commit -m "feat(electron): Cmd/Ctrl+click enters select; Shift+click extends range"
```

---

## Task 9: Context-menu "Select" item

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx`

- [ ] **Step 1: Add failing test**

Append:

```tsx
describe('FileComponent — context menu', () => {
  it('right-click → Select enters Select mode with that book selected', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))

    const alphaCard = screen.getByText('Alpha').closest('div')!
    fireEvent.contextMenu(alphaCard)

    fireEvent.click(screen.getByRole('button', { name: /^select$/i, hidden: false }))
    // ^ matches the new context-menu item — there will be two buttons named
    // "Select" momentarily; the toolbar one is rendered before the context
    // menu, so the second match (the menu item) wins in document order via
    // getAllByRole. Use the menu item directly:

    const items = screen.getAllByRole('button', { name: 'Select' })
    fireEvent.click(items[items.length - 1])

    expect(screen.getByText('1 selected')).toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 1 new FAIL.

- [ ] **Step 3: Implement**

In the existing context-menu JSX (`{contextMenu ? ( ... ) : null}`), **add** a Select item above the Delete item:

```tsx
<button
  className="flex items-center gap-2 px-3 py-2 text-sm text-gray-700 hover:bg-gray-50 w-full text-left rounded"
  onClick={() => {
    selection.enterSelectMode(contextMenu.book.id)
    setContextMenu(null)
  }}
>
  <CheckSquare size={16} /> Select
</button>
```

(`CheckSquare` is already imported in Task 7.)

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 6 PASS total.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/FileComponent.tsx \
        apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx
git commit -m "feat(electron): right-click context menu gains Select item"
```

---

## Task 10: Bulk-delete mutation + DeleteConfirmDialog wiring

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx`

- [ ] **Step 1: Add failing tests**

Append:

```tsx
describe('FileComponent — bulk delete', () => {
  it('confirming bulk delete calls deleteBook per selected id and shows success toast', async () => {
    const { toast } = await import('sonner')
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    fireEvent.click(screen.getByLabelText('Select Alpha'))
    fireEvent.click(screen.getByLabelText('Select Beta'))

    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))
    // Confirm modal appears
    expect(screen.getByText('Delete 2 books?')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))

    await waitFor(() => {
      expect(window.electron.deleteBook).toHaveBeenCalledTimes(2)
    })
    expect(window.electron.deleteBook).toHaveBeenCalledWith(1)
    expect(window.electron.deleteBook).toHaveBeenCalledWith(2)
    expect((toast as unknown as { success: ReturnType<typeof vi.fn> }).success).toHaveBeenCalledWith(
      'Deleted 2 books'
    )
  })

  it('partial failure shows a warning toast with the right counts', async () => {
    const { toast } = await import('sonner')
    ;(window.electron.deleteBook as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('boom'))

    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    fireEvent.click(screen.getByLabelText('Select Alpha'))
    fireEvent.click(screen.getByLabelText('Select Beta'))
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))

    await waitFor(() => {
      expect(
        (toast as unknown as { warning: ReturnType<typeof vi.fn> }).warning
      ).toHaveBeenCalledWith('Deleted 1 of 2 — 1 failed')
    })
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 2 new FAIL (confirm dialog not wired; mutation doesn't exist).

- [ ] **Step 3: Implement**

Add imports near the top:

```ts
import { DeleteConfirmDialog } from './library/DeleteConfirmDialog'
```

Add the confirm state in `FileComponent`:

```ts
const [confirmOpen, setConfirmOpen] = useState(false)
```

Add the bulk-delete mutation alongside `deleteBookMutation`:

```ts
const bulkDeleteMutation = useMutation({
  mutationKey: ['bulkDeleteBooks'],
  mutationFn: async ({ books: toDelete }: { books: Book[] }) => {
    const failures: { book: Book; error: unknown }[] = []
    for (const book of toDelete) {
      try {
        await deleteBook({ bookId: book.id })
        removeBook(book.id)
        revokeCachedCoverUrl(book.id)
        evictPdf(book.id)
        evictEpub(book.id)
      } catch (error) {
        console.error('Bulk delete failure for book', book.id, error)
        failures.push({ book, error })
      }
    }
    return { total: toDelete.length, failures }
  },
  onSettled: () => {
    void queryClient.invalidateQueries({ queryKey: ['books'] })
  },
  onSuccess: ({ total, failures }) => {
    if (failures.length === 0) {
      toast.success(`Deleted ${total} book${total === 1 ? '' : 's'}`)
    } else if (failures.length === total) {
      toast.error('Failed to delete books')
    } else {
      toast.warning(`Deleted ${total - failures.length} of ${total} — ${failures.length} failed`)
    }
  }
})
```

In the `SelectionActionBar` JSX, wire `onDelete`:

```tsx
onDelete={() => setConfirmOpen(true)}
```

Just below the `BookDiscoveryModal` line, render the confirm dialog:

```tsx
<DeleteConfirmDialog
  open={confirmOpen}
  count={selection.selectedIds.size}
  isDeleting={bulkDeleteMutation.isPending}
  onCancel={() => setConfirmOpen(false)}
  onConfirm={() => {
    const selected = (books ?? []).filter((b) => selection.selectedIds.has(b.id))
    bulkDeleteMutation.mutate(
      { books: selected },
      {
        onSettled: () => {
          setConfirmOpen(false)
          selection.exitSelectMode()
        }
      }
    )
  }}
/>
```

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 8 PASS total.

- [ ] **Step 5: Run typecheck**

```bash
pnpm --filter rishi-electron run typecheck:web
```
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/FileComponent.tsx \
        apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx
git commit -m "feat(electron): bulk delete mutation + confirm dialog"
```

---

## Task 11: Action-bar Select All respects search filter

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx` (the `onSelectAll` prop was already wired in Task 7, so this is a verification task)

- [ ] **Step 1: Add failing test**

Append:

```tsx
describe('FileComponent — Select All scope', () => {
  it('Select All selects only currently-filtered books (search active)', async () => {
    ;(window.electron.getBooks as ReturnType<typeof vi.fn>).mockResolvedValue([
      makeBook({ id: 1, title: 'Apple', author: 'A' }),
      makeBook({ id: 2, title: 'Banana', author: 'A' }),
      makeBook({ id: 3, title: 'Apricot', author: 'B' })
    ])
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Banana'))

    fireEvent.change(screen.getByPlaceholderText(/search library/i), {
      target: { value: 'Ap' }
    })
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    fireEvent.click(screen.getByRole('button', { name: /select all/i }))

    expect(screen.getByText('2 selected')).toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: PASS (Task 7 already wired `onSelectAll={() => selection.selectAll(filteredBooks)}`). If this test fails, fix the wiring before continuing.

- [ ] **Step 3: Commit (test-only addition)**

```bash
git add apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx
git commit -m "test(electron): Select All respects active search filter"
```

---

## Task 12: Keyboard shortcuts (Esc / Cmd-A / Delete / Backspace)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx`

- [ ] **Step 1: Add failing tests**

Append:

```tsx
describe('FileComponent — keyboard shortcuts', () => {
  it('Esc exits Select mode and clears selection', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    fireEvent.click(screen.getByLabelText('Select Alpha'))

    fireEvent.keyDown(window, { key: 'Escape' })

    expect(screen.queryByRole('toolbar', { name: /selection actions/i })).not.toBeInTheDocument()
    // Toolbar Select button label flips back to "Select"
    expect(screen.getByRole('button', { name: /^select$/i })).toBeInTheDocument()
  })

  it('Cmd+A in Select mode selects all filtered books', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    fireEvent.keyDown(window, { key: 'a', metaKey: true })

    expect(screen.getByText('2 selected')).toBeInTheDocument()
  })

  it('Delete in Select mode opens the confirm dialog when at least one is selected', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    fireEvent.click(screen.getByLabelText('Select Alpha'))

    fireEvent.keyDown(window, { key: 'Delete' })

    expect(screen.getByText('Delete 1 book?')).toBeInTheDocument()
  })

  it('Delete is a no-op when nothing is selected', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    fireEvent.keyDown(window, { key: 'Delete' })

    expect(screen.queryByText(/^Delete \d+ book/)).not.toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run, expect FAIL**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 4 new FAIL.

- [ ] **Step 3: Implement**

Inside `FileComponent`, add a single `useEffect` that registers the shortcuts while in Select mode. **Important:** skip the handler when an `<input>`, `<textarea>`, or `contenteditable` element is focused so the search bar still accepts text (`a`, `Delete`, etc.):

```tsx
useEffect(() => {
  if (!selection.selectMode) return
  const handler = (e: KeyboardEvent) => {
    const target = e.target as HTMLElement | null
    const tag = target?.tagName
    if (tag === 'INPUT' || tag === 'TEXTAREA' || target?.isContentEditable) return

    if (e.key === 'Escape') {
      e.preventDefault()
      selection.exitSelectMode()
      return
    }
    if ((e.metaKey || e.ctrlKey) && (e.key === 'a' || e.key === 'A')) {
      e.preventDefault()
      selection.selectAll(filteredBooks)
      return
    }
    if (e.key === 'Delete' || e.key === 'Backspace') {
      if (selection.selectedIds.size === 0) return
      e.preventDefault()
      setConfirmOpen(true)
      return
    }
  }
  window.addEventListener('keydown', handler)
  return () => window.removeEventListener('keydown', handler)
}, [selection, filteredBooks])
```

- [ ] **Step 4: Run, expect PASS**

```bash
pnpm --filter rishi-electron exec vitest run src/renderer/src/components/FileComponent.test.tsx
```
Expected: 12 PASS total.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/FileComponent.tsx \
        apps/rishi-electron/src/renderer/src/components/FileComponent.test.tsx
git commit -m "feat(electron): keyboard shortcuts (Esc / Cmd-A / Delete / Backspace)"
```

---

## Task 13: Final verification

**Files:** none.

- [ ] **Step 1: Run all renderer tests**

```bash
pnpm --filter rishi-electron exec vitest run
```
Expected: all PASS, no skipped tests in the new files.

- [ ] **Step 2: Typecheck**

```bash
pnpm --filter rishi-electron run typecheck:web
```
Expected: clean.

- [ ] **Step 3: Lint**

```bash
pnpm --filter rishi-electron run lint
```
Expected: clean. If unused imports linger from earlier task edits, remove them and commit a small follow-up.

- [ ] **Step 4: Manual smoke test**

Run the dev app:
```bash
pnpm --filter rishi-electron dev
```

Verify by hand:
1. Toolbar **Select** button enters Select mode; checkboxes appear; click to toggle; Cancel exits.
2. Cmd/Ctrl+click on a cover (from default mode) enters Select with that book selected.
3. Shift+click extends a range across the grid.
4. Right-click → **Select** enters Select with that book selected. Right-click → **Delete** still works for single deletes.
5. Type in the search bar with Select mode on: selection survives; **Select All** picks only visible books.
6. Confirm modal: Cancel closes; Delete triggers bulk delete with appropriate toast.
7. `Esc`, `Cmd/Ctrl+A`, `Delete`/`Backspace` work as specified.

- [ ] **Step 5: Commit any lint/format fixes**

```bash
git add -A
git commit -m "chore(electron): lint + format cleanup for library bulk delete"
```
(Skip if nothing changed.)

---

## Self-review notes (already addressed inline)

- **Spec coverage:** Every UX item in §UX of the spec maps to a task (toolbar Select → Task 7; Cmd/Ctrl+click + Shift+click → Task 8; context-menu Select → Task 9; bottom action bar + confirm modal → Tasks 4, 5, 10; keyboard → Task 12; search-scoped Select All → Task 11; per-book cache eviction in mutation → Task 10).
- **Type consistency:** Hook returns `BookSelection` with stable names (`selectMode`, `selectedIds`, `toggle`, `selectAll`, `extendTo`, `enterSelectMode`, `clear`, `exitSelectMode`). Same names used in every later task.
- **No placeholders:** Every step includes the full code or the full command + expected outcome.
- **Deviation from spec:** Cover-selection chrome lives on the wrapper `<div>`/cover `<button>` in `FileComponent.tsx` rather than as new props on `BookCoverImage`. Reason: keeps `BookCoverImage`'s cover-cache contract untouched. Functionally identical.
