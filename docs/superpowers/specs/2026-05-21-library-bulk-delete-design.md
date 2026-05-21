# Library bulk delete & multi-select

**Status:** Design approved, ready for plan.
**Scope:** `apps/rishi-electron` (renderer only — no IPC, schema, or backend changes).

## Problem

The Electron library view (`src/renderer/src/components/FileComponent.tsx`) lets users delete one book at a time via a right-click context menu. There is no way to delete many books at once, and no way to clear the entire library short of right-clicking each cover.

## Goals

- Add a multi-select mode for bulk deletion of books.
- Provide a path to clear the entire library that does not require a dedicated "danger button".
- Reuse the existing single-book delete pipeline (soft-delete + chunk + HNSW cleanup + renderer cache eviction) without changing IPC or schema.

## Non-goals

- Undo of bulk deletes (deletes are already destructive of the local HNSW index file and chunk rows; restoring would require a new flow).
- Bulk operations other than delete (move, tag, export).
- A separate top-level "Clear All" button. The path to clearing the library is `Select → Select All → Delete`.
- A batch IPC handler. Looping the existing `books:delete` IPC is sufficient at current scale.

## UX

### Entering Select mode

Any of:

- Click the new **Select** button in the top toolbar (between `Add Book` and `LoginButton`).
- **Cmd/Ctrl+click** any book cover — auto-enters Select mode with that book selected.
- **Right-click** any book → context menu gains a new **Select** item alongside the existing **Delete**.

### Inside Select mode

- Each cover renders a checkbox in the top-left corner. Selected covers gain a subtle ring/overlay.
- Clicking a cover toggles its selection. The single-click "open book" behavior is suppressed while Select mode is active.
- **Shift+click** a cover extends selection from the last-clicked book to the target, inclusive, across the currently-displayed grid order.
- A **bottom action bar** slides up containing: `N selected | Select All | Delete | Cancel`.
  - `Select All` picks every book in the currently-filtered set (respects the search query).
  - `Delete` opens the confirm modal.
  - `Cancel` exits Select mode and clears selection.

### Keyboard

- `Esc` exits Select mode and clears selection.
- `Cmd/Ctrl+A` while in Select mode selects all currently-filtered books.
- `Delete` or `Backspace` triggers the confirm modal (no-op if 0 selected).

### Confirm modal

Built on the existing Radix Dialog primitive (`src/renderer/src/components/ui/dialog.tsx`).

- Title: `Delete N book(s)?`
- Body: `This cannot be undone.`
- Buttons: `Cancel` (default-focused, also Esc / overlay click) and `Delete` (destructive styling).
- The `Delete` button is disabled while the bulk-delete mutation is pending.

### After delete

- Confirm modal closes.
- Toast surfaces the outcome:
  - All succeeded: `Deleted N books` (singular for N=1).
  - All failed: `Failed to delete books`.
  - Partial: `Deleted X of N — Y failed`.
- Select mode exits. Books whose delete failed reappear after the books query refetches.

### Search interaction

- Select mode survives search-query edits.
- `Select All` always means "every book currently visible".
- A selected book that gets hidden by a new search query stays selected (its id remains in the set; the count still includes it). Clearing the search restores its visible-and-checked state.

## Implementation

### State

State is local to `FileComponent.tsx`. Selection is ephemeral and does not need to survive remounts, so a Zustand store is not justified.

```ts
const [selectMode, setSelectMode] = useState(false)
const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set())
const [lastClickedId, setLastClickedId] = useState<number | null>(null) // for Shift+click range
const [confirmOpen, setConfirmOpen] = useState(false)
```

Exiting Select mode clears `selectedIds` and `lastClickedId` and sets `selectMode=false`.

### New files

- `src/renderer/src/components/library/useBookSelection.ts` — hook owning selection state and handlers (`toggle`, `selectAll(filtered)`, `clear`, `extendTo(targetId, displayOrder)`, `enterSelectMode(initialId?)`). Returns the state plus handlers. Keeps `FileComponent.tsx` from growing further.
- `src/renderer/src/components/library/SelectionActionBar.tsx` — purely presentational bottom bar. Props: `count`, `onSelectAll`, `onDelete`, `onCancel`.
- `src/renderer/src/components/library/DeleteConfirmDialog.tsx` — Radix Dialog wrapper. Props: `open`, `count`, `onCancel`, `onConfirm`, `isDeleting`.

### Modified files

- `src/renderer/src/components/FileComponent.tsx`:
  - Wire `useBookSelection`.
  - Add toolbar **Select** button.
  - Adapt the book-cover `onClick` to route through the selection hook when `selectMode` is true; preserve the open-book behavior when it is false.
  - Handle Cmd/Ctrl+click and Shift+click on covers.
  - Render `SelectionActionBar` (conditional on `selectMode`) and `DeleteConfirmDialog`.
  - Add the **Select** item to the existing context menu.
  - Attach a window-level `keydown` listener for `Esc`, `Cmd/Ctrl+A`, `Delete`/`Backspace` while in Select mode.
- `BookCoverImage` inside `FileComponent.tsx` gains `isSelected` and `isSelectMode` props that drive the checkbox overlay and ring styling. The existing cover-cache logic (`coverUrlCache`, `coverImageCache`, `decoding="sync"`) is untouched.

### Bulk-delete mutation

Replaces ad-hoc looping with a dedicated TanStack Query mutation. Reuses every step of the existing per-book delete path:

```ts
const bulkDeleteMutation = useMutation({
  mutationKey: ['bulkDeleteBooks'],
  mutationFn: async ({ books }: { books: Book[] }) => {
    const failures: { book: Book; error: unknown }[] = []
    for (const book of books) {
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
    return { total: books.length, failures }
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

A delete that throws does **not** abort the loop. Per-failure `console.error` for debuggability; one aggregated toast for the user.

### Why no batch IPC

Each delete already does meaningful per-book work (`deleteChunksByBookId`, `deleteIndex` of the HNSW file, soft-delete row update, then renderer-side cache eviction). A batch IPC would still loop these internally. The renderer-side cleanup (`removeBook`, `revokeCachedCoverUrl`, `evictPdf`, `evictEpub`) is per-id anyway. Looping the existing IPC keeps one code path; a batch handler can be added later if multi-thousand deletes become a real workflow.

### Search-filter integrity

`selectedIds` references book ids, not array indices. Search filter changes do not invalidate selection. The `Select All` handler reads `filteredBooks` at call-time.

### Concurrency

While the mutation is pending:

- The action bar's Delete button is disabled.
- The confirm dialog's Delete button is disabled and shows a pending state.
- The dialog stays open until the loop finishes; on completion it closes together with Select mode.

## Testing

TDD per repo convention. Red tests first, implementation second.

### Unit / hook tests

- `useBookSelection.test.ts`:
  - `toggle(id)` adds an unselected id and removes a selected one.
  - `clear()` empties the set.
  - `selectAll(filteredBooks)` selects exactly those ids; existing selection is replaced.
  - `extendTo(targetId, displayOrder)` selects the inclusive range between `lastClickedId` and `targetId` across `displayOrder`.
  - `enterSelectMode(id)` flips `selectMode=true` and seeds selection with the given id.
  - Exiting Select mode clears `selectedIds` and `lastClickedId`.

### Component tests

- `SelectionActionBar.test.tsx`: renders the count, fires handlers, Delete disabled at count 0.
- `DeleteConfirmDialog.test.tsx`: shows the right count, Cancel focused on open, fires `onConfirm` on Delete, fires `onCancel` on Esc / overlay click / Cancel, Delete disabled when `isDeleting`.

### Integration tests in `FileComponent.test.tsx`

- Clicking the toolbar **Select** button enters Select mode (checkboxes render, action bar appears).
- Cmd/Ctrl+click on a cover auto-enters Select mode with that book selected.
- Right-click → **Select** enters Select mode with that book selected.
- In Select mode, clicking a cover toggles selection and does **not** open the book.
- `Esc` exits Select mode and clears selection.
- `Cmd/Ctrl+A` in Select mode selects exactly the currently-filtered books (verified with an active search query).
- `Delete` / `Backspace` opens the confirm dialog (no-op at 0 selected).
- Confirming bulk delete calls `deleteBook` once per selected id, exits Select mode, and surfaces the success toast with the right count.
- Partial-failure path: one of N deletes rejects → loop continues, surviving books invalidate, warning toast shows `Deleted X of N — Y failed`.

### Out of scope for tests

- Backend / IPC tests are unchanged. The existing `books:delete` handler tests remain authoritative for the per-book pipeline.

## Risks & open questions

- **HNSW file removal latency.** `deleteIndex` is filesystem I/O. Deleting hundreds of books sequentially could take a few seconds. The UI shows the pending state on the confirm dialog's Delete button; toast then summarizes. If this becomes a UX issue, the follow-up is a batch IPC that parallelises file removal in the main process.
- **Sync engine load.** Each soft-delete sets `is_dirty=1`. Bulk deletes will produce a burst of sync work. This is the same per-book load as repeated single deletes; not a new failure mode.
- **No undo.** Deletes hard-remove chunks and the HNSW index. Restoring a "deleted" book would re-download cloud state if available, but local artifacts would need re-indexing. Out of scope here.
