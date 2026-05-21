# Import Wizard: Auto-Dismiss, Single-Book Auto-Open, Hash Dedup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `BookDiscoveryModal` dismiss itself after import completes, auto-open the book if exactly one was imported, and prevent duplicate imports via SHA-256 file-hash deduplication (with a cheap filepath filter in the discovery list).

**Architecture:** Build inside-out: DB queries → IPC handlers → preload bridge → renderer API wrappers → importer pipeline (hash + dedup stage) → wizard UI (auto-dismiss, auto-open, filter). Each layer ships with tests before implementation (TDD red→green→commit).

**Tech Stack:** Electron + React + TypeScript + Vitest + better-sqlite3 + Drizzle (read-only here) + TanStack Query + Sonner toasts + Tailwind. All work lives in `apps/rishi-electron`.

**Spec:** `docs/superpowers/specs/2026-05-21-import-wizard-dismiss-dedup-design.md`

---

## File Structure

| Path | Role | Action |
|---|---|---|
| `apps/rishi-electron/src/main/database/queries.ts` | DB query layer | Modify — add `_findBookByHashWithDb`, `findBookByHash`, `_getBookFilepathsWithDb`, `getBookFilepaths` |
| `apps/rishi-electron/src/main/database/queries.test.ts` | Query tests | **Create** — TDD tests for the two new queries against in-memory better-sqlite3 |
| `apps/rishi-electron/src/main/ipc/books.ts` | IPC handlers | Modify — register `books:findByHash` + `books:getFilepaths` handlers |
| `apps/rishi-electron/src/preload/ipc-contract.ts` | IPC channel contract | Modify — add the two new channels |
| `apps/rishi-electron/src/preload/types.ts` | Renderer-facing API derivation | Modify — add channel→method mappings |
| `apps/rishi-electron/src/preload/index.ts` | Preload bridge | Modify — wire `invoke('books:findByHash', …)` + `invoke('books:getFilepaths')` |
| `apps/rishi-electron/src/renderer/src/lib/api.ts` | Renderer API wrappers | Modify — add `findBookByHash` + `getBookFilepaths` exports |
| `apps/rishi-electron/src/renderer/src/services/book-import/types.ts` | Importer port types | Modify — add `'hash'`/`'duplicate'` to `ImportFailure.stage`; add `'hashing'` to `ImportProgressEvent`; add `findBookByHash` to `BookStoreIpc`; add `hashTimeoutMs` to `BookImportConfig` |
| `apps/rishi-electron/src/renderer/src/services/book-import/importer.ts` | Import pipeline | Modify — insert hash + dedup stage between copy and parse; pass hash to `saveBook`; strip rehash from `runUpload` |
| `apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts` | Pipeline tests | Modify — add dedup + hash failure tests; update upload test to expect no rehash |
| `apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts` | Service-level tests | Modify — verify `importBatch` propagates `'duplicate'` failures inline |
| `apps/rishi-electron/src/renderer/src/services/index.ts` | DI composition root | Modify — wire `findBookByHash` adapter; add `hashTimeoutMs: 30_000` default |
| `apps/rishi-electron/src/renderer/src/test-setup.ts` | Global window.electron mock | Modify — add `openBook`, `findBookByHash`, `getBookFilepaths` mocks |
| `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx` | Wizard component | Modify — async `performImport`; auto-open single book; auto-close; filter discovered list by existing filepaths |
| `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.test.tsx` | Wizard tests | Modify — add auto-close, auto-open, filter tests; keep existing bulk/confirm tests intact |

No new source files outside `queries.test.ts`. Every modification is small and focused.

---

## Conventions for this plan

- **TDD:** every task starts with a failing test, then minimal implementation, then green.
- **One commit per task** — granular history, easy revert.
- **Always run from the repo root** (`/Users/faridmatovu/projects/rishi-monorepo`).
- **Package manager:** `pnpm` (workspace root has `pnpm-workspace.yaml`).
- **Test runner:** Vitest. Filter by file path or test name with `-t`.

Common commands:
```bash
# Run a single test file (renderer)
cd apps/rishi-electron && pnpm test -- src/renderer/src/services/book-import/importer.test.ts --run

# Run all renderer tests
cd apps/rishi-electron && pnpm test -- --run

# Type-check
cd apps/rishi-electron && pnpm typecheck
```

---

## Task 1: Add DB queries (`findBookByHash`, `getBookFilepaths`)

**Files:**
- Create: `apps/rishi-electron/src/main/database/queries.test.ts`
- Modify: `apps/rishi-electron/src/main/database/queries.ts`

The existing `_listRecentBooksWithDb` pattern injects a `Database` for unit testing — follow it.

- [ ] **Step 1: Write the failing test**

Create `apps/rishi-electron/src/main/database/queries.test.ts`:

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import type { Database } from 'better-sqlite3'
import { _findBookByHashWithDb, _getBookFilepathsWithDb } from './queries'

const SCHEMA = `
  CREATE TABLE books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT, cover BLOB, title TEXT, author TEXT, publisher TEXT,
    filepath TEXT, location TEXT, cover_kind TEXT, version INTEGER,
    sync_id TEXT, file_hash TEXT, file_r2_key TEXT, cover_r2_key TEXT,
    format TEXT, current_cfi TEXT, current_page INTEGER, user_id TEXT,
    sync_version INTEGER, is_dirty INTEGER, is_deleted INTEGER DEFAULT 0
  )
`

function makeDb(): Database {
  const db = new BetterSqlite3(':memory:')
  // better-sqlite3 multi-statement DDL goes through Database#exec.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ;(db as any).exec(SCHEMA)
  return db
}

function insert(db: Database, row: Partial<{
  filepath: string; file_hash: string | null; is_deleted: number; title: string
}>): number {
  const info = db.prepare(
    `INSERT INTO books (filepath, file_hash, is_deleted, title, kind, cover, author,
       publisher, location, cover_kind, version, format, sync_version, is_dirty)
     VALUES (@filepath, @file_hash, @is_deleted, @title, 'epub', x'', '', '', '1', 'png',
       0, 'epub', 0, 0)`
  ).run({
    filepath: row.filepath ?? '/books/x.epub',
    file_hash: row.file_hash ?? null,
    is_deleted: row.is_deleted ?? 0,
    title: row.title ?? 'X'
  })
  return Number(info.lastInsertRowid)
}

describe('_findBookByHashWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('returns the book when a non-deleted row has the matching file_hash', () => {
    const id = insert(db, { file_hash: 'abc123', title: 'Found' })
    const result = _findBookByHashWithDb(db, 'abc123')
    expect(result?.id).toBe(id)
    expect(result?.title).toBe('Found')
  })

  it('returns undefined when no row matches', () => {
    insert(db, { file_hash: 'other' })
    expect(_findBookByHashWithDb(db, 'missing')).toBeUndefined()
  })

  it('skips soft-deleted rows even if their hash matches', () => {
    insert(db, { file_hash: 'abc123', is_deleted: 1 })
    expect(_findBookByHashWithDb(db, 'abc123')).toBeUndefined()
  })

  it('does not match rows with NULL file_hash for any non-empty hash query', () => {
    // Defensive: pre-backfill rows must never be returned by hash lookup.
    insert(db, { file_hash: null })
    expect(_findBookByHashWithDb(db, '')).toBeUndefined()
    expect(_findBookByHashWithDb(db, 'anything')).toBeUndefined()
  })
})

describe('_getBookFilepathsWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('returns filepaths of all non-deleted books', () => {
    insert(db, { filepath: '/books/a.epub' })
    insert(db, { filepath: '/books/b.pdf' })
    insert(db, { filepath: '/books/c.epub', is_deleted: 1 })
    expect(_getBookFilepathsWithDb(db).sort()).toEqual(['/books/a.epub', '/books/b.pdf'])
  })

  it('filters out empty-string filepaths', () => {
    insert(db, { filepath: '/books/a.epub' })
    insert(db, { filepath: '' })
    expect(_getBookFilepathsWithDb(db)).toEqual(['/books/a.epub'])
  })

  it('returns an empty array when no books exist', () => {
    expect(_getBookFilepathsWithDb(db)).toEqual([])
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd apps/rishi-electron && pnpm test -- src/main/database/queries.test.ts --run
```

Expected: FAIL with `_findBookByHashWithDb is not exported` or similar.

- [ ] **Step 3: Implement the queries**

Open `apps/rishi-electron/src/main/database/queries.ts`. After the existing `getBook(id)` function (around line 165), add:

```ts
/**
 * Pure-SQL variant of `findBookByHash` for unit testing. Returns the first
 * non-deleted book whose `file_hash` matches, or `undefined` if no row matches.
 * The `IS NOT NULL` guard ensures pre-backfill rows (file_hash IS NULL) are
 * never returned, so dedup is opt-in per-row.
 */
export function _findBookByHashWithDb(db: Database, hash: string): Book | undefined {
  const row = db
    .prepare('SELECT * FROM books WHERE file_hash = ? AND file_hash IS NOT NULL AND COALESCE(is_deleted, 0) = 0 LIMIT 1')
    .get(hash)
  return row ? rowToBook(row as Record<string, unknown>) : undefined
}

/**
 * Look up a book by SHA-256 file hash. Returns `undefined` when no row matches
 * or when the existing rows for that hash are all soft-deleted.
 */
export function findBookByHash(hash: string): Book | undefined {
  return _findBookByHashWithDb(getDb(), hash)
}

/**
 * Pure-SQL variant for testing. Returns non-empty filepaths of every
 * non-deleted book — used by the import wizard to filter discovered books
 * the user already has.
 */
export function _getBookFilepathsWithDb(db: Database): string[] {
  const rows = db
    .prepare('SELECT filepath FROM books WHERE COALESCE(is_deleted, 0) = 0')
    .all() as Array<{ filepath: string | null }>
  return rows
    .map((r) => r.filepath ?? '')
    .filter((p) => p.length > 0)
}

/**
 * Return filepaths of every non-deleted book. Lightweight (no cover blobs)
 * — safe to pull across the IPC boundary on wizard open.
 */
export function getBookFilepaths(): string[] {
  return _getBookFilepathsWithDb(getDb())
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd apps/rishi-electron && pnpm test -- src/main/database/queries.test.ts --run
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/rishi-electron/src/main/database/queries.ts \
        apps/rishi-electron/src/main/database/queries.test.ts
git commit -m "feat(db): add findBookByHash and getBookFilepaths queries"
```

---

## Task 2: Wire the IPC channels

**Files:**
- Modify: `apps/rishi-electron/src/preload/ipc-contract.ts`
- Modify: `apps/rishi-electron/src/preload/types.ts`
- Modify: `apps/rishi-electron/src/preload/index.ts`
- Modify: `apps/rishi-electron/src/main/ipc/books.ts`

The contract is the source of truth: `IpcContract` (channel→args/returns) and `ChannelToMethod` (channel→renderer method name) both need entries. A compile-time check enforces coverage, so adding to one without the other will fail typecheck.

- [ ] **Step 1: Add channels to the IPC contract**

In `apps/rishi-electron/src/preload/ipc-contract.ts`, locate the `'books:updateFileHash'` entry (~line 79–82) and add directly below it inside the same `// -- Book operations --` section:

```ts
  'books:findByHash': { args: [hash: string]; returns: Book | null }
  'books:getFilepaths': { args: []; returns: string[] }
```

- [ ] **Step 2: Add channel→method mappings**

In `apps/rishi-electron/src/preload/types.ts`, locate the books block (line 24–35) and add (anywhere in the books block):

```ts
  'books:findByHash': 'findBookByHash'
  'books:getFilepaths': 'getBookFilepaths'
```

- [ ] **Step 3: Add preload bridge methods**

In `apps/rishi-electron/src/preload/index.ts`, locate the Book operations block (line 8–15) and add directly below `getBookOutline`:

```ts
  findBookByHash: (hash) => invoke('books:findByHash', hash),
  getBookFilepaths: () => invoke('books:getFilepaths'),
```

- [ ] **Step 4: Run typecheck — should pass**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: PASS. (The contract check `_AssertChannelToMethodCoversContract` confirms every channel has a method mapping; the `ElectronAPI` type derives the new methods automatically.)

- [ ] **Step 5: Register the main-process handlers**

In `apps/rishi-electron/src/main/ipc/books.ts`:

1. Add to the imports block at the top:

```ts
import {
  getAllBooks,
  getBook,
  saveBook,
  deleteBook,
  deleteChunksByBookId,
  updateBookCover,
  updateBookLocation,
  hasSavedEpubData,
  getBookOutline,
  findBookByHash,
  getBookFilepaths
} from '../database/queries.js'
```

2. Inside `registerBookHandlers()`, after the `'books:getOutline'` handler (~line 87), add:

```ts
  handle('books:findByHash', (_event, hash) => {
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

- [ ] **Step 6: Run typecheck again**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: PASS. The handler signatures must match the contract.

- [ ] **Step 7: Commit**

```bash
git add apps/rishi-electron/src/preload/ipc-contract.ts \
        apps/rishi-electron/src/preload/types.ts \
        apps/rishi-electron/src/preload/index.ts \
        apps/rishi-electron/src/main/ipc/books.ts
git commit -m "feat(ipc): expose books:findByHash and books:getFilepaths channels"
```

---

## Task 3: Renderer API wrappers + global test mocks

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/lib/api.ts`
- Modify: `apps/rishi-electron/src/renderer/src/test-setup.ts`

- [ ] **Step 1: Add the renderer api wrappers**

In `apps/rishi-electron/src/renderer/src/lib/api.ts`, locate `export async function getBooks()` (line 164) and add directly below it:

```ts
export async function findBookByHash(hash: string): Promise<Book | null> {
  return api().findBookByHash(hash)
}

export async function getBookFilepaths(): Promise<string[]> {
  return api().getBookFilepaths()
}
```

(`api()` is the existing helper that returns `window.electron`. The existing wrappers in this file follow the same pattern.)

- [ ] **Step 2: Add mocks to test-setup**

In `apps/rishi-electron/src/renderer/src/test-setup.ts`, inside the `mockElectronAPI` object literal, find the `booksUpdateFileHash: vi.fn().mockResolvedValue(undefined),` line (line 71) and add directly after it:

```ts
  findBookByHash: vi.fn().mockResolvedValue(null),
  getBookFilepaths: vi.fn().mockResolvedValue([]),
  openBook: vi.fn().mockResolvedValue(undefined),
```

(`openBook` is already exposed on `window.electron` in production but isn't mocked here yet — needed for the wizard tests in Task 7.)

- [ ] **Step 3: Verify typecheck and existing tests still pass**

```bash
cd apps/rishi-electron && pnpm typecheck && pnpm test -- --run
```

Expected: typecheck PASS, all existing tests still PASS. (No behavior changed yet — just added wrappers and mocks.)

- [ ] **Step 4: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/lib/api.ts \
        apps/rishi-electron/src/renderer/src/test-setup.ts
git commit -m "feat(renderer): add findBookByHash/getBookFilepaths API + test mocks"
```

---

## Task 4: Update importer port types

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/book-import/types.ts`

Types-only change. The importer + service + tests will fail typecheck after this — they'll be fixed in Tasks 5–6.

- [ ] **Step 1: Update `ImportFailure.stage`**

Find lines 40–46 (`export interface ImportFailure`) and update the `stage` union:

```ts
export interface ImportFailure {
  ok: false
  filePath: string
  /** Which stage failed. */
  stage: 'unsupported' | 'copy' | 'hash' | 'duplicate' | 'parse' | 'save' | 'unknown'
  error: string
}
```

- [ ] **Step 2: Add the `hashing` progress event**

In the `ImportProgressEvent` union (lines 51–60), add a new variant immediately after `'copying'`:

```ts
export type ImportProgressEvent =
  | { kind: 'copying'; filePath: string }
  | { kind: 'hashing'; filePath: string }
  | { kind: 'parsing'; filePath: string; format: BookFormat }
  | { kind: 'saving'; filePath: string; format: BookFormat }
  | { kind: 'upload-started'; filePath: string; bookId: number }
  | { kind: 'upload-failed'; filePath: string; bookId: number; error: string }
  | { kind: 'indexing'; bookId: number; reason: 'chunks-missing' | 'vectors-missing' }
  | { kind: 'indexed'; bookId: number; ok: boolean }
  | { kind: 'done'; filePath: string; bookId: number; format: BookFormat }
  | { kind: 'failed'; filePath: string; stage: ImportFailure['stage']; error: string }
```

- [ ] **Step 3: Add `findBookByHash` to `BookStoreIpc`**

In the `BookStoreIpc` interface (lines 95–101), add the new method:

```ts
export interface BookStoreIpc {
  saveBook(book: BookInsertable): Promise<Book>
  findBookByHash(hash: string): Promise<Book | null>
  savePageDataMany(pageData: ChunkDataInsertable[]): Promise<void>
  getAllPageDataByBookId(bookId: number): Promise<PageData[]>
  hasSavedEpubData(bookId: number): Promise<boolean>
  saveVectors(name: string, dim: number, vectors: Vector[]): Promise<void>
}
```

- [ ] **Step 4: Add `hashTimeoutMs` to `BookImportConfig`**

In the `BookImportConfig` interface (lines 130–137), add the new timeout:

```ts
export interface BookImportConfig {
  /** Per-stage timeouts. Defaults: copy=120_000, hash=30_000, parse=60_000, save=30_000 ms. */
  copyTimeoutMs: number
  hashTimeoutMs: number
  parseTimeoutMs: number
  saveTimeoutMs: number
  /** Embedding batch size. Default 2. */
  embedBatchSize: number
}
```

- [ ] **Step 5: Verify typecheck — should FAIL in the importer/service/tests**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: FAIL with errors like:
- `services/book-import/importer.test.ts: Property 'findBookByHash' is missing in type ...`
- `services/index.ts: Property 'findBookByHash' is missing` and `Property 'hashTimeoutMs' is missing`

Don't fix yet — those are the next tasks.

- [ ] **Step 6: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/book-import/types.ts
git commit -m "feat(import): add hash/duplicate stages, findBookByHash port, hashTimeoutMs config

Types-only change. Importer pipeline and service wiring updates land in
follow-up commits."
```

(Yes — committing a temporarily broken typecheck is intentional. The next two tasks restore it. Keeping the type change isolated makes the contract explicit.)

---

## Task 5: Wire the new port into the importer test fakes + service composition root

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/index.ts`

This restores typecheck without changing runtime behavior yet. We give the test fake a default `findBookByHash` (returns null → no duplicates), and add the real adapter + config default at the composition root.

- [ ] **Step 1: Extend `makeDbForImport` fake**

In `apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts`, find `makeDbForImport` (lines 39–73) and update its options + body. Add a `findBookByHashImpl` option, expose call tracking, and default to returning `null`:

```ts
export function makeDbForImport(opts?: {
  savedBook?: Book
  failOn?: 'saveBook'
  findBookByHashImpl?: (hash: string) => Promise<Book | null>
}): {
  db: BookStoreIpc
  savedBooks: Book[]
  findHashCalls: string[]
} {
  const savedBooks: Book[] = []
  const findHashCalls: string[] = []
  const fallback: Book = {
    id: 42,
    kind: 'epub',
    cover: [],
    title: 'Title',
    author: 'Author',
    publisher: 'Pub',
    filepath: '/userData/book.epub',
    location: '1',
    coverKind: 'image/png',
    version: 0,
    format: 'epub',
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0
  }
  const db: BookStoreIpc = {
    saveBook: vi.fn(async (b) => {
      if (opts?.failOn === 'saveBook') throw new Error('saveBook failed')
      const out = { ...fallback, ...b, id: opts?.savedBook?.id ?? fallback.id } as Book
      savedBooks.push(out)
      return out
    }),
    findBookByHash: vi.fn(async (hash) => {
      findHashCalls.push(hash)
      return opts?.findBookByHashImpl ? opts.findBookByHashImpl(hash) : null
    }),
    savePageDataMany: vi.fn(),
    getAllPageDataByBookId: vi.fn(async () => []),
    hasSavedEpubData: vi.fn(async () => false),
    saveVectors: vi.fn()
  }
  return { db, savedBooks, findHashCalls }
}
```

- [ ] **Step 2: Add `hashTimeoutMs` to the shared `baseConfig`**

In the same file, find `baseConfig` (lines 92–97) and add the field:

```ts
export const baseConfig: BookImportConfig = {
  copyTimeoutMs: 5_000,
  hashTimeoutMs: 5_000,
  parseTimeoutMs: 5_000,
  saveTimeoutMs: 5_000,
  embedBatchSize: 2
}
```

- [ ] **Step 3: Wire the real adapter at the composition root**

In `apps/rishi-electron/src/renderer/src/services/index.ts`:

1. Find the `db:` block in the `createBookImportService` call (~lines 196–202) and add `findBookByHash` directly below `saveBook`:

```ts
      db: {
        saveBook: (b) => window.electron.saveBook(b),
        findBookByHash: (hash) => window.electron.findBookByHash(hash),
        savePageDataMany: (rows) => window.electron.savePageDataMany(rows),
        getAllPageDataByBookId: (bookId) => window.electron.getAllPageDataByBookId(bookId),
        hasSavedEpubData: (bookId) => window.electron.hasSavedEpubData(bookId),
        saveVectors: (name, dim, vectors) => window.electron.saveVectors(name, dim, vectors)
      },
```

2. Find the `config:` block (~lines 217–222) and add `hashTimeoutMs`:

```ts
      config: {
        copyTimeoutMs: 2 * 60 * 1000,
        hashTimeoutMs: 30 * 1000,
        parseTimeoutMs: 60 * 1000,
        saveTimeoutMs: 30 * 1000,
        embedBatchSize: 2
      }
```

- [ ] **Step 4: Check if `service.test.ts` builds its own fake**

Search the file for `BookStoreIpc`:

```bash
grep -n "BookStoreIpc\|saveBook:" apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts
```

If you find a hand-rolled `BookStoreIpc` literal (not using `makeDbForImport`), add `findBookByHash: vi.fn(async () => null)` to it. If everything uses `makeDbForImport`, no change needed.

- [ ] **Step 5: Verify typecheck — should now PASS**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: PASS.

- [ ] **Step 6: Verify tests still pass (behavior unchanged)**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/services/book-import --run
```

Expected: existing importer + service tests PASS (the new `findBookByHash` is called but returns null, so the pipeline behaves identically).

- [ ] **Step 7: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts \
        apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts \
        apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "chore(import): plumb findBookByHash + hashTimeoutMs through fakes and wiring"
```

---

## Task 6: Add hash + dedup stage to the importer

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/book-import/importer.ts`

This is the meat. TDD: write the four new tests, run them red, implement, run them green.

- [ ] **Step 1: Write the failing tests**

Append the following `describe` block to `apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts`:

```ts
describe('runImport — hash + dedup stage', () => {
  it('returns stage: duplicate and rolls back the copy when the hash matches an existing book', async () => {
    const existing: Book = {
      id: 7, kind: 'epub', cover: [], title: 'Already here', author: '', publisher: '',
      filepath: '/userData/already.epub', location: '1', coverKind: 'image/png', version: 0,
      format: 'epub', syncVersion: 0, isDirty: 0, isDeleted: 0
    }
    const { db, findHashCalls } = makeDbForImport({
      findBookByHashImpl: async () => existing
    })
    const { fs, removeCalls } = makeFs()
    const fileSync = makeFileSync({ hashImpl: async () => 'dupe-hash' })
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats: makeFormats(), fs, db, fileSync, config: baseConfig },
      '/external/dupe.epub',
      (e) => events.push(e)
    )

    expect(result).toEqual({
      ok: false,
      filePath: '/external/dupe.epub',
      stage: 'duplicate',
      error: expect.stringMatching(/already in library/i)
    })
    expect(findHashCalls).toEqual(['dupe-hash'])
    // The copied file under /userData was rolled back.
    expect(removeCalls).toEqual(['/userData/dupe.epub'])
    // saveBook never ran.
    expect(db.saveBook).not.toHaveBeenCalled()
    // We emitted a hashing event and a failed event.
    expect(events.map((e) => e.kind)).toEqual(['copying', 'hashing', 'failed'])
  })

  it('passes the computed file hash to saveBook when no duplicate exists', async () => {
    const { db, savedBooks } = makeDbForImport()
    const { fs } = makeFs()
    const fileSync = makeFileSync({ hashImpl: async () => 'new-hash-xyz' })

    const result = await runImport(
      { formats: makeFormats(), fs, db, fileSync, config: baseConfig },
      '/external/new.epub',
      () => {}
    )

    expect(result.ok).toBe(true)
    expect(savedBooks).toHaveLength(1)
    expect(savedBooks[0].fileHash).toBe('new-hash-xyz')
  })

  it('returns stage: hash and rolls back the copy when hashing throws', async () => {
    const { db } = makeDbForImport()
    const { fs, removeCalls } = makeFs()
    const fileSync = makeFileSync({
      hashImpl: async () => {
        throw new Error('disk read failed')
      }
    })

    const result = await runImport(
      { formats: makeFormats(), fs, db, fileSync, config: baseConfig },
      '/external/broken.epub',
      () => {}
    )

    expect(result).toEqual({
      ok: false,
      filePath: '/external/broken.epub',
      stage: 'hash',
      error: expect.stringMatching(/disk read failed|hash/i)
    })
    expect(removeCalls).toEqual(['/userData/broken.epub'])
    expect(db.findBookByHash).not.toHaveBeenCalled()
    expect(db.saveBook).not.toHaveBeenCalled()
  })

  it('returns stage: hash when hashBookFile exceeds hashTimeoutMs', async () => {
    const { db } = makeDbForImport()
    const { fs, removeCalls } = makeFs()
    const fileSync = makeFileSync({
      hashImpl: () => new Promise<string>(() => {}) // never resolves
    })
    const tightConfig: BookImportConfig = { ...baseConfig, hashTimeoutMs: 10 }

    const result = await runImport(
      { formats: makeFormats(), fs, db, fileSync, config: tightConfig },
      '/external/slow.epub',
      () => {}
    )

    expect(result.ok).toBe(false)
    expect((result as ImportFailure).stage).toBe('hash')
    expect((result as ImportFailure).error).toMatch(/timed out|hash/i)
    expect(removeCalls).toEqual(['/userData/slow.epub'])
  })
})
```

Add `ImportFailure` to the imports at the top of the file if it isn't already there:

```ts
import type {
  BookImportConfig,
  BookStoreIpc,
  FileSyncIpc,
  FsIpc,
  ImportFailure,
  ImportProgressEvent
} from './types'
```

- [ ] **Step 2: Find and update the existing upload test**

The current upload-related tests in this file assume `hashBookFile` is called *after* save. Search for tests that assert on `fileSync.hashBookFile` call counts:

```bash
grep -n "hashBookFile\|hashImpl\|upload" apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts
```

For each upload test that does `expect(fileSync.hashBookFile).toHaveBeenCalledTimes(1)`: the hash now runs once during the dedup stage (pre-save) and is no longer recomputed in `runUpload`. So the assertion remains "called once" — but for a different reason. Add a comment if the test asserts on ordering. If the test expected hash to be called *after* save (e.g. by waiting on a setTimeout 0), update it to expect the hash to be available pre-save.

If the test asserts `expect(fileSync.hashBookFile).toHaveBeenCalledTimes(1)` and that's it: no change needed (still true, just called earlier).

If the test additionally checks `expect(fileSync.uploadBookFile).toHaveBeenCalledWith(bookPath, 'somehash', format)`: still true — the hash is now passed in from `runImport` instead of computed in `runUpload`.

- [ ] **Step 3: Run the new tests — verify they FAIL**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/services/book-import/importer.test.ts --run -t "hash + dedup stage"
```

Expected: FAIL — runImport doesn't yet hash, dedup, or pass `fileHash` to `saveBook`.

- [ ] **Step 4: Implement the hash + dedup stage in `importer.ts`**

In `apps/rishi-electron/src/renderer/src/services/book-import/importer.ts`:

1. After the Stage 1 copy block (after line 102, which is `return { ok: false, filePath, stage: 'copy', error }`), insert a new **Stage 1.5: hash + dedup-check** block:

```ts
  // Stage 1.5: hash + dedup-check. Compute SHA-256 of the copied file, look
  // up the library by hash. A hit means we've already imported this file;
  // roll back the copy so we don't orphan bytes in app data. Books missing
  // a file_hash (pre-backfill rows) are excluded from the comparison by the
  // query itself — they fall through to parse/save as normal.
  emit({ kind: 'hashing', filePath })
  let fileHash: string
  try {
    fileHash = await withTimeout(
      deps.fileSync.hashBookFile(bookPath),
      deps.config.hashTimeoutMs,
      'Hashing file'
    )
  } catch (err) {
    const error = messageOf(err, 'Hash failed')
    emit({ kind: 'failed', filePath, stage: 'hash', error })
    try {
      await deps.fs.removeFile(bookPath)
    } catch {
      /* swallow */
    }
    return { ok: false, filePath, stage: 'hash', error }
  }

  const existing = await deps.db.findBookByHash(fileHash)
  if (existing) {
    const error = 'Already in library'
    emit({ kind: 'failed', filePath, stage: 'duplicate', error })
    try {
      await deps.fs.removeFile(bookPath)
    } catch {
      /* swallow */
    }
    return { ok: false, filePath, stage: 'duplicate', error }
  }
```

2. Update the `saveBook` call in Stage 3 (around lines 144–158) to include the freshly computed hash:

```ts
  try {
    book = await withTimeout(
      deps.db.saveBook({
        coverKind: bookData.coverKind ?? '',
        title: bookData.title ?? '',
        author: bookData.author ?? '',
        publisher: bookData.publisher ?? '',
        filepath: bookPath,
        location: format === 'mobi' || format === 'azw3' ? '0' : '1',
        version: 0,
        kind: bookData.kind,
        cover: bookData.cover,
        fileHash
      }),
      deps.config.saveTimeoutMs,
      'Saving to library'
    )
  } catch (err) {
```

3. Simplify `runUpload` — it no longer needs to compute the hash. Replace `runUpload` (lines 49–77) with:

```ts
/**
 * Best-effort R2 upload. Failure does not affect the import result; it only
 * emits an `upload-failed` event. The hash is precomputed in the dedup stage,
 * so we don't rehash here.
 */
function runUpload(
  deps: ImporterDeps,
  bookId: number,
  bookPath: string,
  format: 'epub' | 'pdf' | 'mobi' | 'azw3',
  fileHash: string,
  filePath: string,
  emit: (event: ImportProgressEvent) => void
): void {
  const formatForUpload: 'epub' | 'pdf' | 'mobi' = format === 'azw3' ? 'mobi' : format
  setTimeout(() => {
    emit({ kind: 'upload-started', filePath, bookId })
    void uploadInner()
  }, 0)

  async function uploadInner(): Promise<void> {
    try {
      const { r2Key } = await deps.fileSync.uploadBookFile(bookPath, fileHash, formatForUpload)
      await deps.fileSync.booksUpdateFileHash(bookId, fileHash, r2Key)
    } catch (err) {
      emit({
        kind: 'upload-failed',
        filePath,
        bookId,
        error: messageOf(err, 'Upload failed')
      })
    }
  }
}
```

4. Update the `runUpload` call at the bottom of `runImport` (line 169) to pass the hash:

```ts
  // Stage 4: fire-and-forget upload (hash already computed in stage 1.5).
  runUpload(deps, book.id, bookPath, format, fileHash, filePath, emit)
```

- [ ] **Step 5: Run the new tests — verify they PASS**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/services/book-import/importer.test.ts --run -t "hash + dedup stage"
```

Expected: all four new tests PASS.

- [ ] **Step 6: Run the full importer test file — verify nothing regressed**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/services/book-import/importer.test.ts --run
```

Expected: PASS for all describes including the existing copy/parse/save/upload tests.

If an existing upload test fails because it asserted `hashBookFile` was called *after* `done`: that test's invariant changed — the hash is now computed pre-save. Update the assertion to reflect the new ordering (hash before save, upload still after) or delete the call-ordering assertion entirely if it was just observing implementation detail.

- [ ] **Step 7: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/services/book-import/importer.ts \
        apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts
git commit -m "feat(import): hash files at import time and reject duplicates

Insert a hash + dedup stage between copy and parse. SHA-256 is computed
once and threaded through save -> R2 upload, so we no longer rehash
post-save. Duplicate hits roll back the copy and return stage: duplicate."
```

---

## Task 7a: Wizard auto-close + auto-open single book

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.test.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx`

- [ ] **Step 1: Update the existing test mocks**

In `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.test.tsx`, replace the `importBatch` mock signature and add an `openBook` spy. Find the mock declarations (lines 7–11) and replace with:

```ts
const importBatch = vi.fn<(paths: string[]) => Promise<ImportResult[]>>()
const startDiscovery = vi.fn()
const cancelDiscovery = vi.fn<() => Promise<void>>()
const onDiscoveryEvent =
  vi.fn<(cb: (event: DiscoveryEvent) => void) => () => void>()
const openBook = vi.fn<(id: number) => Promise<void>>()
```

Then in `beforeEach` (lines 61–72), add at the end:

```ts
  openBook.mockReset().mockResolvedValue(undefined)
  ;(window.electron as unknown as { openBook: typeof openBook }).openBook = openBook
```

(`window.electron` is already populated by `test-setup.ts`. We reassign `openBook` per test so we can spy on call args without poisoning other suites.)

Also add `waitFor` to the testing-library imports at the top of the file:

```ts
import { render, screen, fireEvent, act, within, waitFor } from '@testing-library/react'
```

- [ ] **Step 2: Write the failing tests for auto-close + auto-open**

Append a new describe block at the end of `BookDiscoveryModal.test.tsx`:

```ts
describe('BookDiscoveryModal post-import behavior', () => {
  it('closes the wizard after the import resolves (regardless of success)', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: true, bookId: 1, filePath: '/docs/a.pdf', format: 'pdf' }
    ])
    render(<BookDiscoveryModal open={true} onClose={onClose} />)
    emitBooks([makeBook({ filepath: '/docs/a.pdf', folder: '/docs' })])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
  })

  it('auto-opens the book when exactly one import succeeds', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: true, bookId: 99, filePath: '/docs/a.pdf', format: 'pdf' }
    ])
    render(<BookDiscoveryModal open={true} onClose={onClose} />)
    emitBooks([makeBook({ filepath: '/docs/a.pdf', folder: '/docs' })])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(openBook).toHaveBeenCalledWith(99))
    expect(onClose).toHaveBeenCalled()
  })

  it('does NOT auto-open when more than one book is imported', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: true, bookId: 1, filePath: '/docs/a.pdf', format: 'pdf' },
      { ok: true, bookId: 2, filePath: '/docs/b.pdf', format: 'pdf' }
    ])
    render(<BookDiscoveryModal open={true} onClose={onClose} />)
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    fireEvent.click(screen.getByRole('checkbox', { name: /select all books in \/docs/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(openBook).not.toHaveBeenCalled()
  })

  it('does NOT auto-open when zero books succeed (all failed)', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: false, filePath: '/docs/a.pdf', stage: 'parse', error: 'corrupt' }
    ])
    render(<BookDiscoveryModal open={true} onClose={onClose} />)
    emitBooks([makeBook({ filepath: '/docs/a.pdf', folder: '/docs' })])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(openBook).not.toHaveBeenCalled()
  })

  it('auto-opens the single successful book even when other selected imports failed', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: true, bookId: 5, filePath: '/docs/a.pdf', format: 'pdf' },
      { ok: false, filePath: '/docs/b.pdf', stage: 'parse', error: 'bad' }
    ])
    render(<BookDiscoveryModal open={true} onClose={onClose} />)
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    fireEvent.click(screen.getByRole('checkbox', { name: /select all books in \/docs/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(openBook).toHaveBeenCalledWith(5))
    expect(onClose).toHaveBeenCalled()
  })
})
```

- [ ] **Step 3: Run the new tests — verify they FAIL**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/components/BookDiscoveryModal.test.tsx --run -t "post-import behavior"
```

Expected: FAIL — current `performImport` doesn't await, doesn't call `openBook`, and doesn't call `onClose`.

- [ ] **Step 4: Update `performImport`**

In `apps/rishi-electron/src/renderer/src/services/index.ts`, find the re-export line:

```ts
export type { DiscoveredBook, ImportResult, PageDataInsertable, ScanProgress } from './book-import'
```

Add `ImportSuccess` to it:

```ts
export type { DiscoveredBook, ImportResult, ImportSuccess, PageDataInsertable, ScanProgress } from './book-import'
```

Then in `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx`:

1. Add the import for `ImportSuccess` near the top with the other `@/services` imports:

```ts
import {
  getBookImportService,
  type DiscoveredBook,
  type ImportResult,
  type ImportSuccess,
  type ScanProgress
} from '@/services'
```

2. Replace the existing `performImport` (lines 185–203) with the async, awaiting version:

```ts
  const performImport = async (paths: string[]) => {
    if (paths.length === 0) return
    const pathSet = new Set(paths)
    const count = paths.length

    setBooks((prev) => prev.filter((b) => !pathSet.has(b.filepath)))
    setSelectedPaths((prev) => {
      const next = new Set(prev)
      paths.forEach((p) => next.delete(p))
      return next
    })
    setFilter('')

    const importPromise = runImport(paths)
    toast.promise(importPromise, {
      loading: `Importing ${count} book${count === 1 ? '' : 's'}...`,
      success: (results) => summarizeBatchResults(results).message,
      error: `Failed to import ${count} book${count === 1 ? '' : 's'}`
    })

    let results: ImportResult[] = []
    try {
      results = await importPromise
    } catch (err) {
      // toast.promise already surfaced the error; nothing else to do here.
      console.error('[BookDiscoveryModal] import batch rejected:', err)
    }

    const successes = results.filter((r): r is ImportSuccess => r.ok)
    if (successes.length === 1) {
      try {
        await window.electron.openBook(successes[0].bookId)
      } catch (err) {
        console.error('[BookDiscoveryModal] failed to open imported book:', err)
      }
    }

    await handleClose()
  }
```

3. Update the two callers to `void` the now-async function. Find `handleImportClick` (~line 205) and replace with:

```ts
  const handleImportClick = () => {
    if (selectedPaths.size === 0) return
    if (selectedPaths.size > BULK_CONFIRM_THRESHOLD) {
      setConfirmOpen(true)
      return
    }
    void performImport(Array.from(selectedPaths))
  }
```

Find `handleConfirmImport` (~line 214) and replace with:

```ts
  const handleConfirmImport = () => {
    const paths = Array.from(selectedPaths)
    setConfirmOpen(false)
    void performImport(paths)
  }
```

- [ ] **Step 5: Run the new tests — verify they PASS**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/components/BookDiscoveryModal.test.tsx --run -t "post-import behavior"
```

Expected: all 5 new tests PASS.

- [ ] **Step 6: Run the full wizard test file**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/components/BookDiscoveryModal.test.tsx --run
```

Expected: PASS. The "small selection imports without confirmation" test (line 149) still passes — it asserts `importBatch` was called, which it still is (the await happens after). The "large selection requires confirmation" test (line 163) still works — confirmation gates the call to `performImport`, which then runs the same async flow.

- [ ] **Step 7: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx \
        apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.test.tsx
git commit -m "feat(wizard): auto-close after import and auto-open single-book imports

performImport now awaits the batch promise so we can branch on the result.
Exactly one success -> openBook that id. Any other count -> just close.
Toast is fired first so the user still sees loading state during the wait."
```

---

## Task 7b: Wizard discovery filter (hide already-imported books)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.test.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx`

- [ ] **Step 1: Write failing tests for the filter behavior**

In `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.test.tsx`, append:

```ts
describe('BookDiscoveryModal discovery filter', () => {
  beforeEach(() => {
    ;(window.electron.getBookFilepaths as ReturnType<typeof vi.fn>) = vi
      .fn()
      .mockResolvedValue([])
  })

  it('hides discovered books whose filepath is already in the library', async () => {
    ;(window.electron.getBookFilepaths as ReturnType<typeof vi.fn>) = vi
      .fn()
      .mockResolvedValue(['/docs/already.pdf'])

    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)

    // Wait for the filepath query to resolve before emitting books — the
    // wizard buffers book-found events until the existing-paths query is ready.
    await waitFor(() =>
      expect(window.electron.getBookFilepaths).toHaveBeenCalled()
    )

    emitBooks([
      makeBook({ filepath: '/docs/already.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/new.pdf', folder: '/docs' })
    ])

    expect(screen.queryByRole('checkbox', { name: /select already\.pdf/i })).not.toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: /select new\.pdf/i })).toBeInTheDocument()
  })

  it('shows all discovered books when getBookFilepaths rejects (graceful degradation)', async () => {
    ;(window.electron.getBookFilepaths as ReturnType<typeof vi.fn>) = vi
      .fn()
      .mockRejectedValue(new Error('db offline'))

    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)

    await waitFor(() =>
      expect(window.electron.getBookFilepaths).toHaveBeenCalled()
    )

    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    expect(screen.getByRole('checkbox', { name: /select a\.pdf/i })).toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: /select b\.pdf/i })).toBeInTheDocument()
  })
})
```

The current `vi.mock('@tanstack/react-query', …)` at the top of the file (lines 26–28) returns a stub `useQueryClient`. We also need it to return a working `useQuery`. Update that mock:

```ts
vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual<typeof import('@tanstack/react-query')>('@tanstack/react-query')
  return {
    ...actual,
    useQueryClient: () => ({ invalidateQueries: vi.fn().mockResolvedValue(undefined) })
  }
})
```

(This keeps the real `useQuery` so the wizard's filepath query actually runs against the mocked `window.electron.getBookFilepaths`. The previous mock replaced the module wholesale; we now spread the actual module and only override `useQueryClient`.)

You'll also need a `QueryClientProvider` wrapper because `useQuery` requires one. Add a small helper at the top of the file (after the imports, before the `describe`s):

```ts
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

function renderWithClient(ui: React.ReactElement) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } }
  })
  return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>)
}
```

Replace **every existing `render(...)` call** in this file with `renderWithClient(...)`. (The auto-close / auto-open tests in Task 7a also need this update — easier to do it once here.)

Also add `import type React from 'react'` if it isn't already imported.

- [ ] **Step 2: Run the new filter tests — verify they FAIL**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/components/BookDiscoveryModal.test.tsx --run -t "discovery filter"
```

Expected: FAIL — the wizard doesn't call `getBookFilepaths` or filter the list.

- [ ] **Step 3: Implement the filter in the wizard**

In `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx`:

1. Update the TanStack import (line 4):

```ts
import { useQueryClient, useQuery } from '@tanstack/react-query'
```

2. Inside `BookDiscoveryModal`, just after `const queryClient = useQueryClient()` (line 78), add the existing-paths query and a buffered-events ref:

```ts
  const existingPathsQuery = useQuery({
    queryKey: ['books', 'filepaths'],
    queryFn: () => window.electron.getBookFilepaths(),
    enabled: open,
    staleTime: 30_000
  })
  const existingPaths = useMemo(
    () => new Set(existingPathsQuery.data ?? []),
    [existingPathsQuery.data]
  )
  // Buffer book-found events that arrive before the existing-paths query
  // resolves, so the filter is never bypassed by a fast scanner.
  const pendingBooksRef = useRef<DiscoveredBook[]>([])
```

3. Modify the discovery subscription effect (lines 114–147). Replace the `book-found` branch and reset the buffer on open:

```ts
  useEffect(() => {
    if (!open) return
    const svc = getBookImportService()

    setBooks([])
    setProgress(null)
    setScanComplete(false)
    setScanning(true)
    setSelectedPaths(new Set())
    pendingBooksRef.current = []

    const filterReady = (): boolean =>
      existingPathsQuery.isSuccess || existingPathsQuery.isError

    const acceptBook = (book: DiscoveredBook): void => {
      if (existingPaths.has(book.filepath)) return
      setBooks((prev) => [...prev, book])
    }

    const unsub = svc.onDiscoveryEvent((event) => {
      if (event.kind === 'book-found') {
        if (filterReady()) acceptBook(event.book)
        else pendingBooksRef.current.push(event.book)
      } else if (event.kind === 'progress') {
        setProgress(event.progress)
      } else if (event.kind === 'complete') {
        setScanning(false)
        setScanComplete(true)
        setProgress(null)
      } else {
        console.error('[discovery] scanner error:', event.error)
        setScanning(false)
      }
    })

    svc.startDiscovery(mode)

    return () => {
      unsub()
      void svc.cancelDiscovery()
    }
  }, [open, mode, existingPathsQuery.isSuccess, existingPathsQuery.isError, existingPaths])
```

4. Add a flush effect that drains `pendingBooksRef` once the query resolves:

```ts
  // Drain any buffered book-found events once the existing-paths query lands.
  useEffect(() => {
    if (!open) return
    if (!existingPathsQuery.isSuccess && !existingPathsQuery.isError) return
    const pending = pendingBooksRef.current
    if (pending.length === 0) return
    pendingBooksRef.current = []
    setBooks((prev) => {
      const next = [...prev]
      for (const b of pending) {
        if (!existingPaths.has(b.filepath)) next.push(b)
      }
      return next
    })
  }, [open, existingPathsQuery.isSuccess, existingPathsQuery.isError, existingPaths])
```

5. Verify `useRef` is in the React import at the top (line 1):

```ts
import { useEffect, useMemo, useRef, useState } from 'react'
```

(It's already imported per the existing code — confirm.)

- [ ] **Step 4: Run the new filter tests — verify they PASS**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/components/BookDiscoveryModal.test.tsx --run -t "discovery filter"
```

Expected: both new filter tests PASS.

- [ ] **Step 5: Run the full wizard test file again**

```bash
cd apps/rishi-electron && pnpm test -- src/renderer/src/components/BookDiscoveryModal.test.tsx --run
```

Expected: ALL tests PASS, including the existing selection/folder/bulk-confirm tests.

If existing tests fail because `emitBooks` now races with the query: each affected existing test needs `await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())` before calling `emitBooks`. The default `mockResolvedValue([])` from the new `beforeEach` makes the filter a no-op for them — they just need to wait for the query to settle first.

- [ ] **Step 6: Run the full renderer test suite**

```bash
cd apps/rishi-electron && pnpm test -- --run
```

Expected: all PASS.

- [ ] **Step 7: Run typecheck**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx \
        apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.test.tsx
git commit -m "feat(wizard): hide already-imported books from discovery results

Fetch the library's filepaths on wizard open via the new books:getFilepaths
IPC, then filter book-found events as they stream in. Buffers events
arriving before the query resolves; falls back to showing everything if
the query fails."
```

---

## Task 8: Verify filepaths cache invalidation works via prefix

**Why this task exists:** the wizard's existing `runImport` helper invalidates `['books']` after each batch. TanStack Query v5 invalidates by prefix by default, so `['books', 'filepaths']` should also be invalidated. We verify this is true and add an explicit test only if needed.

- [ ] **Step 1: Quickly check the TanStack Query version**

```bash
grep -A1 '"@tanstack/react-query"' apps/rishi-electron/package.json
```

Expected: v5.x or higher.

- [ ] **Step 2: Manually verify in the running app (Task 9 covers this end-to-end)**

If after Task 9 step 4, the filter does NOT pick up newly imported books on the *second* wizard-open: add an explicit invalidation in `BookDiscoveryModal.tsx`'s `runImport` helper:

```ts
  async function runImport(filePaths: string[]): Promise<ImportResult[]> {
    const results = await getBookImportService().importBatch(filePaths)
    await queryClient.invalidateQueries({ queryKey: ['books'] })
    return results
  }
```

(Already in this shape — TanStack v5 prefix matching is the default behavior. No code change expected.)

- [ ] **Step 3: No commit unless code changed.** Skip if step 2 confirmed the behavior.

---

## Task 9: Manual smoke test in the running app

Automated tests cover the logic; this confirms the wired-up app behaves end-to-end.

- [ ] **Step 1: Start the dev server**

```bash
cd apps/rishi-electron && pnpm dev
```

The Electron app should launch with the renderer hot-reloaded.

- [ ] **Step 2: Test auto-open + auto-close**

1. In the library, click "Add Book".
2. Wait for the scan to find a book.
3. Select exactly one book and click "Import Selected (1)".
4. **Expected:** the wizard closes, a toast says "Imported 1 book", and the imported book opens in a new window.

- [ ] **Step 3: Test multi-book auto-close (no auto-open)**

1. Open Add Book again.
2. Select 2 books and click "Import Selected (2)".
3. **Expected:** wizard closes, toast says "Imported 2 books", no book auto-opens.

- [ ] **Step 4: Test the dedup filter**

1. Open Add Book again.
2. Wait for the scan to complete.
3. **Expected:** the books imported in Steps 2–3 do NOT appear in the discovery list.

- [ ] **Step 5: Test the import-time hash check**

1. Browse Files (header button) and pick a book file that's already in the library. (You may need to manually copy a file to a new path so it gets past the filepath filter.)
2. Click Import.
3. **Expected:** toast says "Failed to import 1 book" or "Imported 0, failed 1"; the book is NOT added a second time. Verify by re-opening the library — no duplicate entry.

- [ ] **Step 6: Test "all failed" scenario (optional)**

If you have a corrupt or unsupported file handy: import it. Expect the wizard to close, toast to show the failure, and no book to open.

- [ ] **Step 7: If everything looks right, no commit needed.**

If you noticed a behavior bug, file it as a separate task — don't bundle fixes with the smoke test.

---

## Self-Review Checklist

Before declaring done, verify:

- [ ] Spec "Layer 4 — Main process" → Tasks 1–2.
- [ ] Spec "Layer 3 — Types" → Task 4.
- [ ] Spec "Layer 2 — Importer" → Tasks 5–6.
- [ ] Spec "Layer 1 — UI behavior" → Tasks 7a + 7b.
- [ ] Spec "Auto-open single new book" → Task 7a tests 2 + 5.
- [ ] Spec "filepath filter in discovery" → Task 7b test 1.
- [ ] Spec "Hash check at import time, no backfill" → Task 6 + Task 1 `IS NOT NULL` guard.
- [ ] Spec new `ImportFailure.stage = 'duplicate'` → Task 4 + Task 6 test 1.
- [ ] Spec "graceful degradation when getBookFilepaths fails" → Task 7b test 2.

If any item is unchecked, add the missing task before declaring done.
