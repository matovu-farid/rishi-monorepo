# Import Wizard: Auto-Dismiss, Single-Book Auto-Open, Hash-Based Dedup

**Date:** 2026-05-21
**Scope:** `apps/rishi-electron`
**Status:** Approved (pending user review of this written spec)

## Problem

Three related UX/correctness gaps in the book import wizard (`BookDiscoveryModal`):

1. After the user clicks "Import Selected", the wizard stays open. There's no signal that the import succeeded other than a toast, and the user has to manually click Cancel to dismiss.
2. When the user imports exactly one book, the natural next action is to open it — but they currently have to close the wizard, find the book in the library grid, and click it.
3. The same book can be imported repeatedly. The discovery wizard re-surfaces books already in the library (cluttering the result list), and the import pipeline has no duplicate detection. A `file_hash` column exists on the `books` table but is only populated post-import by the best-effort R2 upload path, so it isn't useful for dedup.

## Goals

- Dismiss the wizard automatically once an import finishes (success, partial, or all-failed).
- Auto-open the single book when an import results in exactly one new book in the library.
- Prevent the same book file from being imported twice (cheap path check during discovery; authoritative SHA-256 check at import time).
- Update existing tests; keep existing bulk-confirm and "no Import All" guarantees intact.

## Non-Goals

- Backfilling `file_hash` for books that pre-date this change. Books without a hash simply don't participate in the import-time hash comparison; their `filepath` still excludes them from discovery results.
- Changing the cloud (R2) upload path's hash computation semantics beyond the obvious optimization that the hash already exists when upload starts.
- Detecting "same book, different file format" (e.g. EPUB vs PDF of the same title). We dedup at the byte level only.
- Showing duplicate-skip results inline in the wizard (the wizard will already be dismissed). Per-book failures land in the global toast like any other failure.

## Design

### Layer 1 — UI behavior (`BookDiscoveryModal.tsx`)

**`performImport` becomes awaiting.** Today it kicks off `toast.promise(runImport(paths), …)` synchronously and returns. `runImport` here refers to the local helper inside `BookDiscoveryModal` (the one that calls `importBatch` and then `queryClient.invalidateQueries(['books'])`), not the exported `runImport` from `importer.ts`. New behavior:

```ts
const performImport = async (paths: string[]) => {
  if (paths.length === 0) return
  const count = paths.length
  // ... existing optimistic state cleanup (remove from `books`, clear selection) ...

  const importPromise = runImport(paths)
  toast.promise(importPromise, {
    loading: `Importing ${count} book${count === 1 ? '' : 's'}...`,
    success: (results) => summarizeBatchResults(results).message,
    error: `Failed to import ${count} book${count === 1 ? '' : 's'}`
  })

  const results = await importPromise
  const successes = results.filter((r): r is ImportSuccess => r.ok)
  if (successes.length === 1) {
    await window.electron.openBook(successes[0].bookId)
  }
  await handleClose()
}
```

The toast is fired first (so the user sees "Importing…" immediately), then we await the same promise to drive the auto-open and dismiss decisions.

`handleConfirmImport` and `handleImportClick` become async or `void`-fire the async call.

`handleBrowseFiles` (the "Browse Files" header button) already closes the wizard immediately on file pick — leave it alone. (Same toast-driven UX; just doesn't participate in the auto-open since it doesn't await results.)

**Discovery filter.** On wizard open, fetch the current library's filepaths once:

```ts
const existingPaths = useQuery({
  queryKey: ['books', 'filepaths'],
  queryFn: () => window.electron.getBookFilepaths()
})
```

When `book-found` events arrive in the discovery subscription, drop any book whose `filepath` is in `existingPaths.data`. Filter applies pre-state-update so the rendered list never shows already-imported books.

If `existingPaths` hasn't resolved by the time the scanner starts emitting events (race), buffer the events until it does, or accept a brief flicker — see "Open Questions" below; default is to gate `book-found` handling on `existingPaths.isSuccess`.

### Layer 2 — Importer (`services/book-import/importer.ts`)

Insert a new stage between copy (stage 1) and parse (stage 2) — call it **stage 1.5: hash + dedup-check**.

```
Stage 1   copy file to app data
Stage 1.5 hash file, look up by hash → if hit, rollback copy + return duplicate
Stage 2a  validate extension
Stage 2b  parse metadata
Stage 3   save (now with fileHash already populated)
Stage 4   fire-and-forget R2 upload (skip the redundant rehash)
```

**`runImport` changes:**

```ts
// After Stage 1 succeeds:
const fileHash = await withTimeout(
  deps.fileSync.hashBookFile(bookPath),
  deps.config.hashTimeoutMs,
  'Hashing file'
)
const existing = await deps.db.findBookByHash(fileHash)
if (existing) {
  await deps.fs.removeFile(bookPath).catch(() => {})
  emit({ kind: 'failed', filePath, stage: 'duplicate', error: 'Already in library' })
  return { ok: false, filePath, stage: 'duplicate', error: 'Already in library' }
}
```

**`saveBook` payload** now includes `fileHash`.

**`runUpload`** no longer calls `hashBookFile` — the hash is passed in. It just does `uploadBookFile(bookPath, hash, format)` and `booksUpdateFileHash(bookId, hash, r2Key)`.

**New stage timeout.** `BookImportConfig.hashTimeoutMs` (default 30_000) — hashing is I/O bound on file size; SHA-256 of a 100 MB EPUB on a slow disk should be well under that.

### Layer 3 — Types (`services/book-import/types.ts`)

```ts
export interface ImportFailure {
  ok: false
  filePath: string
  stage: 'unsupported' | 'copy' | 'hash' | 'duplicate' | 'parse' | 'save' | 'unknown'
  error: string
}

export type ImportProgressEvent =
  | { kind: 'copying'; filePath: string }
  | { kind: 'hashing'; filePath: string }          // new
  | { kind: 'parsing'; filePath: string; format: BookFormat }
  // ... rest unchanged

export interface BookStoreIpc {
  saveBook(book: BookInsertable): Promise<Book>
  findBookByHash(hash: string): Promise<Book | null>  // new
  // ... rest unchanged
}

export interface BookImportConfig {
  copyTimeoutMs: number
  hashTimeoutMs: number   // new
  parseTimeoutMs: number
  saveTimeoutMs: number
  embedBatchSize: number
}
```

### Layer 4 — Main process

**`main/database/queries.ts`** — two new queries:

```ts
export function findBookByHash(hash: string): Book | undefined {
  const db = getDb()
  const row = db.prepare(
    'SELECT * FROM books WHERE file_hash = ? AND is_deleted = 0 LIMIT 1'
  ).get(hash)
  return row ? rowToBook(row as Record<string, unknown>) : undefined
}

export function getBookFilepaths(): string[] {
  const db = getDb()
  const rows = db.prepare(
    'SELECT filepath FROM books WHERE is_deleted = 0'
  ).all() as Array<{ filepath: string }>
  return rows.map((r) => r.filepath).filter((p) => p.length > 0)
}
```

**`main/ipc/books.ts`** — two new handlers:

```ts
handle('books:findByHash', (_event, hash: string) => {
  try {
    return findBookByHash(hash) ?? null
  } catch (error) {
    throw new Error(`Failed to find book by hash: ${errorMessage(error)}`)
  }
})

handle('books:getFilepaths', () => {
  try {
    return getBookFilepaths()
  } catch (error) {
    throw new Error(`Failed to get book filepaths: ${errorMessage(error)}`)
  }
})
```

**`preload/index.ts` + `preload/types.ts` + `preload/ipc-contract.ts`** — bridge `findBookByHash` and `getBookFilepaths` through the standard `invoke` wrappers, matching existing convention for `books:get` and `books:getAll`.

**`renderer/src/lib/api.ts`** — add thin wrappers:

```ts
export async function findBookByHash(hash: string): Promise<Book | null> {
  return api().findBookByHash(hash)
}

export async function getBookFilepaths(): Promise<string[]> {
  return api().getBookFilepaths()
}
```

**`renderer/src/services/index.ts`** — wire `findBookByHash` into the `BookStoreIpc` adapter passed to `getBookImportService`.

### Data flow summary

```
Wizard open
  ├─ useQuery(['books','filepaths']) → existingPaths: Set<string>
  └─ scanner emits book-found
      └─ if filepath ∈ existingPaths: drop
          else: add to UI list

User clicks Import Selected
  └─ performImport(paths)
      ├─ optimistic UI cleanup (remove from list, clear selection)
      ├─ toast.promise(runImport(paths), …)
      └─ await results
          ├─ for each path: copy → hash → findBookByHash
          │     ├─ hit: rollback copy, return { ok:false, stage:'duplicate' }
          │     └─ miss: parse → save (with fileHash) → fire upload
          ├─ if successes.length === 1: window.electron.openBook(id)
          └─ handleClose()
```

### Error handling

| Scenario | Behavior |
|---|---|
| Hash IPC throws / times out | Treated as stage `'hash'` failure; copy is rolled back; user sees toast. |
| `findBookByHash` returns existing | Treated as stage `'duplicate'` failure; copy is rolled back; user sees toast. Not an error — expected outcome. |
| `getBookFilepaths` IPC fails on wizard open | Discovery list shows everything (no client-side filter). Import-time hash check still catches duplicates. Logged to console; no user-facing error. |
| `openBook` fails after import | Logged; wizard still closes. Library invalidation already happened so the book shows in the grid. |
| Wizard closed mid-import (user clicks backdrop) | `handleClose` already runs; `performImport` keeps awaiting in the background; auto-open and second `handleClose` from `performImport` are no-ops (modal already closed). The toast still reports completion. |

### Testing strategy

Tests live next to source: component tests in `BookDiscoveryModal.test.tsx`, pipeline tests in `importer.test.ts`, service tests in `service.test.ts`, query tests in `queries.test.ts` (if it exists for the books table; otherwise inline in the importer test via the existing fake `BookStoreIpc`).

**`BookDiscoveryModal.test.tsx` — new tests:**

1. `importBatch` resolves with `[{ ok: true, bookId: 42 }]` → `window.electron.openBook` called with `42`, then `onClose` called.
2. `importBatch` resolves with two successes → `openBook` NOT called, `onClose` called.
3. `importBatch` resolves with zero successes (all failed) → `openBook` NOT called, `onClose` called.
4. `getBookFilepaths` returns `['/docs/a.pdf']`; scanner emits books at `/docs/a.pdf` and `/docs/b.pdf` → only `b.pdf` is rendered.
5. `getBookFilepaths` rejects → all discovered books still render (graceful degradation).

**`BookDiscoveryModal.test.tsx` — updates:**

- Mocks: add `window.electron.openBook = vi.fn()`, mock `getBookFilepaths` (default `[]`), make `importBatch` mock resolve to `[]` by default still works.
- Existing "small selection imports" tests need to await microtasks after click (the assertion that `importBatch` was called still holds, but the close happens async now).

**`importer.test.ts` — new tests:**

1. `findBookByHash` returns a book → `runImport` returns `{ ok: false, stage: 'duplicate' }`, `removeFile` called with copied path.
2. `findBookByHash` returns null → `saveBook` called with the computed `fileHash` in the payload.
3. `hashBookFile` rejects → `runImport` returns `{ ok: false, stage: 'hash' }`, `removeFile` called.
4. `hashBookFile` exceeds `hashTimeoutMs` → same as above.

**`importer.test.ts` — updates:**

- Existing upload test: `runUpload` no longer calls `hashBookFile`; it receives the precomputed hash. Update the fake's call expectations.

**`service.test.ts` — minor:**

- `importBatch` of `[a, b]` where `b` is a duplicate → returns `[ok:true, {ok:false, stage:'duplicate'}]` in order, doesn't short-circuit.

**Tests we explicitly keep:**

- "Does NOT render a one-click Import All button" — unchanged.
- "Large selection requires confirmation" — unchanged (confirmation gates the call to `performImport`; everything after is the same).
- "Cancelling large-import confirmation does not call importBatch" — unchanged.

### File checklist

**Modified:**
- `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx`
- `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.test.tsx`
- `apps/rishi-electron/src/renderer/src/services/book-import/importer.ts`
- `apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts`
- `apps/rishi-electron/src/renderer/src/services/book-import/types.ts`
- `apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts`
- `apps/rishi-electron/src/renderer/src/services/index.ts` (wire new IPC into adapter + add `hashTimeoutMs` to config)
- `apps/rishi-electron/src/renderer/src/lib/api.ts`
- `apps/rishi-electron/src/main/database/queries.ts`
- `apps/rishi-electron/src/main/ipc/books.ts`
- `apps/rishi-electron/src/preload/index.ts`
- `apps/rishi-electron/src/preload/types.ts`
- `apps/rishi-electron/src/preload/ipc-contract.ts`

**No new files.**

### Open questions (resolved inline)

- **Race: scanner emits before `getBookFilepaths` resolves.** Resolution: gate the `book-found` handler on `existingPaths.isSuccess`. Buffer events until ready by accumulating into a ref and flushing once the query resolves. Worst case: a small wait at the start of a scan. The scanner already produces results over hundreds of ms, so this is invisible in practice.
- **What about books with `filepath === ''`?** The filter is "drop discovered if path ∈ existing", so empty-string filepaths in the library don't poison the filter. `getBookFilepaths` also filters empties out defensively.
- **Soft-deleted books.** Both queries filter on `is_deleted = 0`. Restoring a deleted book is a separate flow; if you re-import a previously deleted file, it gets a fresh row.
