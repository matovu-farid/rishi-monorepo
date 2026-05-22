# Resume Reading From Last-Played Paragraph — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When TTS pauses or the user closes the book, remember which paragraph was last being read. On next open, land on that paragraph's page, highlight it with the active-TTS style, keep playback paused, and let `PLAY` resume from there. Works across EPUB, PDF, AZW3, and MOBI.

**Architecture:** New nullable `last_paragraph` column on `books` stores the format-specific paragraph index (CFI for EPUB, `pdf-{page}-{idx}` for PDF, `azw3-{chap}-{idx}` for AZW3/MOBI). Renderer subscribes to `usePlayerStore.activeParagraph`, mirrors it locally and debounces a write to the DB. On reopen, `getBook` returns `lastParagraph`; per-format viewers prefer it over `book.location` for initial display, the route seeds a new `usePlayerStore.lastPlayedParagraphIndex` field for highlight rendering, and `playerMachine.INITIALIZE` carries a `resumeParagraphIndex` that gets applied when paragraphs arrive in `stopped`.

**Tech Stack:** Electron (Node 20 main + Chromium renderer), better-sqlite3, TypeScript, XState v5, Zustand, Vitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-05-21-resume-paragraph-design.md`

---

## File map

### New files
- `src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.ts` — pure helper, `pdf-{page}-{idx}` → page number or null
- `src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.test.ts`
- `src/renderer/src/components/azw3/paragraphToLocation.ts` — pure helper, `azw3-{chap}-{idx}` → `{chapter, page}` or null
- `src/renderer/src/components/azw3/paragraphToLocation.test.ts`
- `e2e/resume-paragraph.spec.ts` — end-to-end smoke test

### Modified files
- `src/main/database/schema.ts` — add `lastParagraph` Drizzle column
- `src/main/database/migrations.ts` — bump version, `ALTER TABLE`
- `src/main/database/queries.ts` — add `updateBookLastParagraph` + `_updateBookLastParagraphWithDb` + map `last_paragraph` in `rowToBook`
- `src/main/database/queries.test.ts` — schema includes new column, tests for the new query
- `src/main/ipc/books.ts` — register `books:updateLastParagraph` handler
- `src/preload/ipc-contract.ts` — contract entry for new channel
- `src/preload/types.ts` — `ChannelToMethod` entry + `Book` interface adds `lastParagraph`
- `src/preload/index.ts` — `updateBookLastParagraph` wrapper
- `src/renderer/src/lib/api.ts` — `Book` interface + `updateBookLastParagraph` function
- `src/renderer/src/test-setup.ts` — mock the new IPC method
- `src/renderer/src/machines/playerMachine.ts` — `resumeParagraphIndex` slot + guard + action + branch
- `src/renderer/src/machines/playerMachine.test.ts` — resume-paragraph tests
- `src/renderer/src/stores/playerStore.ts` — add `lastPlayedParagraphIndex` field + setter
- `src/renderer/src/hooks/usePlayerMachine.ts` — pass resume index to INITIALIZE; new write subscription; CLEANUP flush
- `src/renderer/src/hooks/__tests__/usePlayerMachine.writePath.test.ts` — focused write-path test (new file)
- `src/renderer/src/routes/books.$id.lazy.tsx` — seed `lastPlayedParagraphIndex` on mount
- `src/renderer/src/components/epub/EpubView.tsx` — prefer `book.lastParagraph` for initial location
- `src/renderer/src/components/pdf/components/pdf.tsx` — same, on the indexing-startPage path; plus highlight fallback subscription
- `src/renderer/src/hooks/usePdfReader.ts` — same, on the actor `initialPage` input
- `src/renderer/src/components/azw3/Azw3View.tsx` — same + highlight fallback subscription
- `src/renderer/src/components/react-reader/epub_viewer/index.tsx` — highlight fallback subscription

---

## Conventions

- **Run tests** from the package root: `cd apps/rishi-electron && pnpm vitest run <file>`. Use `pnpm vitest run` for the full suite.
- **TypeScript:** `pnpm typecheck`.
- **Lint:** `pnpm lint` (cached; safe to run frequently).
- **E2E:** `pnpm e2e <spec>` (Playwright). Slower; only at the end.
- **Commits:** keep small. Conventional-style messages following the repo (`feat:`, `fix:`, `test:`, `refactor:`, `chore:`).
- **Don't add comments** that only restate the code. The spec carries the rationale; if a step has a non-obvious *why*, the plan calls it out in prose.

---

## Task 1: Schema + migration for `last_paragraph` column

**Files:**
- Modify: `src/main/database/schema.ts`
- Modify: `src/main/database/migrations.ts`

- [ ] **Step 1: Add column to Drizzle schema**

In `src/main/database/schema.ts`, inside the `books = sqliteTable('books', { ... })` block, add a new field after `isDeleted`:

```ts
  isDeleted: integer('is_deleted').notNull().default(0),
  lastParagraph: text('last_paragraph')
```

(Nullable, no default. Drizzle infers `string | null`.)

- [ ] **Step 2: Bump migration version and add the ALTER**

In `src/main/database/migrations.ts`:

```ts
const CURRENT_VERSION = 3
```

Then add a new `if` block after the `version < 2` block (use the same `db.exec` style the existing migrations use):

```ts
  if (version < 3) {
    db.exec(`ALTER TABLE books ADD COLUMN last_paragraph TEXT`)
    db.pragma('user_version = 3')
  }
```

- [ ] **Step 3: Sanity-check by running the existing query tests**

```bash
cd apps/rishi-electron && pnpm vitest run src/main/database/queries.test.ts
```

Expected: PASS. The existing tests use their own in-memory schema and ignore the new column — they should not break.

- [ ] **Step 4: Commit**

```bash
git add src/main/database/schema.ts src/main/database/migrations.ts
git commit -m "feat(db): add last_paragraph column to books"
```

---

## Task 2: Query function + Book row mapping

**Files:**
- Modify: `src/main/database/queries.ts`
- Modify: `src/main/database/queries.test.ts`

- [ ] **Step 1: Update the test schema and add failing tests**

In `src/main/database/queries.test.ts`, extend the inline `SCHEMA` constant to include the new column and the columns used by the new query:

```ts
const SCHEMA = `
  CREATE TABLE books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT, cover BLOB, title TEXT, author TEXT, publisher TEXT,
    filepath TEXT, location TEXT, cover_kind TEXT, version INTEGER,
    sync_id TEXT, file_hash TEXT, file_r2_key TEXT, cover_r2_key TEXT,
    format TEXT, current_cfi TEXT, current_page INTEGER, user_id TEXT,
    sync_version INTEGER, is_dirty INTEGER, is_deleted INTEGER DEFAULT 0,
    last_paragraph TEXT
  )
`
```

Then add a new import at the top:

```ts
import {
  _findBookByHashWithDb,
  _getBookFilepathsWithDb,
  _updateBookLastParagraphWithDb,
  _getBookByIdWithDb
} from './queries'
```

Append these `describe` blocks at the end of the file:

```ts
describe('_updateBookLastParagraphWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('writes the value to the last_paragraph column', () => {
    const id = insert(db, {})
    _updateBookLastParagraphWithDb(db, id, 'epubcfi(/6/4!/2)')
    const row = db.prepare('SELECT last_paragraph FROM books WHERE id = ?').get(id) as {
      last_paragraph: string | null
    }
    expect(row.last_paragraph).toBe('epubcfi(/6/4!/2)')
  })

  it('accepts null to clear the column', () => {
    const id = insert(db, {})
    _updateBookLastParagraphWithDb(db, id, 'pdf-3-7')
    _updateBookLastParagraphWithDb(db, id, null)
    const row = db.prepare('SELECT last_paragraph FROM books WHERE id = ?').get(id) as {
      last_paragraph: string | null
    }
    expect(row.last_paragraph).toBeNull()
  })

  it('is a no-op for a missing book id', () => {
    expect(() => _updateBookLastParagraphWithDb(db, 999, 'x')).not.toThrow()
  })
})

describe('_getBookByIdWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('returns lastParagraph as null when never set', () => {
    const id = insert(db, {})
    const book = _getBookByIdWithDb(db, id)
    expect(book?.lastParagraph).toBeNull()
  })

  it('returns lastParagraph after it has been written', () => {
    const id = insert(db, {})
    _updateBookLastParagraphWithDb(db, id, 'azw3-2-15')
    const book = _getBookByIdWithDb(db, id)
    expect(book?.lastParagraph).toBe('azw3-2-15')
  })
})
```

- [ ] **Step 2: Run the new tests — verify they fail**

```bash
cd apps/rishi-electron && pnpm vitest run src/main/database/queries.test.ts
```

Expected: FAIL on `_updateBookLastParagraphWithDb`/`_getBookByIdWithDb` not exported.

- [ ] **Step 3: Implement the query + extend rowToBook**

In `src/main/database/queries.ts`:

Add `lastParagraph: string | null` to the `Book` interface (at the top of the file, after `isDeleted`):

```ts
export interface Book {
  // ...existing fields...
  isDeleted: number
  lastParagraph: string | null
}
```

Add the row mapping inside `rowToBook`, just before the closing `}`:

```ts
    isDeleted: row.is_deleted as number,
    lastParagraph: (row.last_paragraph as string | null) ?? null
  }
```

Add a `_getBookByIdWithDb` helper next to the existing `getBook` function:

```ts
export function _getBookByIdWithDb(db: Database, id: number): Book | undefined {
  const row = db.prepare('SELECT * FROM books WHERE id = ?').get(id)
  return row ? rowToBook(row as Record<string, unknown>) : undefined
}
```

Refactor `getBook` to delegate:

```ts
export function getBook(id: number): Book | undefined {
  return _getBookByIdWithDb(getDb(), id)
}
```

Add the new write query just below `updateBookLocation`:

```ts
/**
 * Test-injectable variant. Updates the `last_paragraph` column for one book.
 * Pass `null` to clear it. No-op when the id doesn't match a row.
 */
export function _updateBookLastParagraphWithDb(
  db: Database,
  id: number,
  lastParagraph: string | null
): void {
  db.prepare('UPDATE books SET last_paragraph = ?, is_dirty = 1 WHERE id = ?').run(
    lastParagraph,
    id
  )
}

export function updateBookLastParagraph(id: number, lastParagraph: string | null): void {
  _updateBookLastParagraphWithDb(getDb(), id, lastParagraph)
}
```

- [ ] **Step 4: Run the tests — verify they pass**

```bash
cd apps/rishi-electron && pnpm vitest run src/main/database/queries.test.ts
```

Expected: PASS.

- [ ] **Step 5: Typecheck**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: PASS. (If it fails on `lastParagraph` missing in some `Book` mapping elsewhere, fix those — they're code we need to touch in Task 4.)

- [ ] **Step 6: Commit**

```bash
git add src/main/database/queries.ts src/main/database/queries.test.ts
git commit -m "feat(db): updateBookLastParagraph + return lastParagraph on getBook"
```

---

## Task 3: IPC channel for `books:updateLastParagraph`

**Files:**
- Modify: `src/preload/ipc-contract.ts`
- Modify: `src/preload/types.ts`
- Modify: `src/preload/index.ts`
- Modify: `src/main/ipc/books.ts`

- [ ] **Step 1: Add the channel to the contract**

In `src/preload/ipc-contract.ts`, inside `IpcContract` next to the existing `books:updateLocation` line:

```ts
  'books:updateLastParagraph': {
    args: [bookId: number, lastParagraph: string | null]
    returns: void
  }
```

- [ ] **Step 2: Map the channel to a renderer method name**

In `src/preload/types.ts`, in `ChannelToMethod`, alongside `'books:updateLocation': 'updateBookLocation'`:

```ts
  'books:updateLastParagraph': 'updateBookLastParagraph'
```

Also extend the `Book` interface near the bottom of the same file to include `lastParagraph`:

```ts
export interface Book {
  // ...existing fields...
  isDeleted: number
  lastParagraph: string | null
}
```

- [ ] **Step 3: Expose the wrapper on the contextBridge surface**

In `src/preload/index.ts`, in the `electronAPI` literal alongside `updateBookLocation`:

```ts
  updateBookLastParagraph: (bookId, lastParagraph) =>
    invoke('books:updateLastParagraph', bookId, lastParagraph),
```

- [ ] **Step 4: Register the main-process handler**

In `src/main/ipc/books.ts`:

Add `updateBookLastParagraph` to the imports from `'../database/queries.js'`:

```ts
import {
  // ...existing imports...
  updateBookLocation,
  updateBookLastParagraph,
  hasSavedEpubData,
  // ...
} from '../database/queries.js'
```

Add a new handler inside `registerBookHandlers()`, right after the `books:updateLocation` handler:

```ts
  handle('books:updateLastParagraph', (_event, bookId, lastParagraph) => {
    try {
      return void updateBookLastParagraph(bookId, lastParagraph)
    } catch (error) {
      throw new Error(
        `Failed to update last paragraph for book ${bookId}: ${errorMessage(error)}`
      )
    }
  })
```

- [ ] **Step 5: Typecheck**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: PASS. The compile-time `_AssertChannelToMethodCoversContract` in `preload/types.ts` proves every contract channel has a method mapping.

- [ ] **Step 6: Commit**

```bash
git add src/preload/ipc-contract.ts src/preload/types.ts src/preload/index.ts src/main/ipc/books.ts
git commit -m "feat(ipc): books:updateLastParagraph channel"
```

---

## Task 4: Renderer-side API + Book interface + test mock

**Files:**
- Modify: `src/renderer/src/lib/api.ts`
- Modify: `src/renderer/src/test-setup.ts`

- [ ] **Step 1: Extend the renderer-side Book interface**

In `src/renderer/src/lib/api.ts`, find the `Book` interface and add a field:

```ts
export interface Book {
  // ...existing fields...
  isDeleted: number
  lastParagraph?: string | null
}
```

Make it optional (`?`) so downstream consumers can incrementally adopt it without sprinkling `lastParagraph: null` through fixtures.

- [ ] **Step 2: Add the API wrapper**

In `src/renderer/src/lib/api.ts`, right after `updateBookLocation`:

```ts
export async function updateBookLastParagraph(params: {
  bookId: number
  lastParagraph: string | null
}): Promise<void> {
  return api().updateBookLastParagraph(params.bookId, params.lastParagraph)
}
```

- [ ] **Step 3: Add the test-setup mock**

In `src/renderer/src/test-setup.ts`, in the `mockElectronAPI` literal next to `updateBookLocation`:

```ts
  updateBookLocation: vi.fn().mockResolvedValue(undefined),
  updateBookLastParagraph: vi.fn().mockResolvedValue(undefined),
```

- [ ] **Step 4: Typecheck**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/lib/api.ts src/renderer/src/test-setup.ts
git commit -m "feat(api): renderer updateBookLastParagraph + Book.lastParagraph"
```

---

## Task 5: Pure helper — `pdfParagraphToPageNumber`

**Files:**
- Create: `src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.ts`
- Create: `src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { pdfParagraphToPageNumber } from './pdfParagraphToPageNumber'

describe('pdfParagraphToPageNumber', () => {
  it('parses pdf-{page}-{idx} into the page number', () => {
    expect(pdfParagraphToPageNumber('pdf-1-0')).toBe(1)
    expect(pdfParagraphToPageNumber('pdf-42-7')).toBe(42)
  })

  it('returns null for empty input', () => {
    expect(pdfParagraphToPageNumber('')).toBeNull()
  })

  it('returns null for non-PDF paragraph ids', () => {
    expect(pdfParagraphToPageNumber('epubcfi(/6/4!/2)')).toBeNull()
    expect(pdfParagraphToPageNumber('azw3-1-2')).toBeNull()
    expect(pdfParagraphToPageNumber('42')).toBeNull()
  })

  it('returns null when page or idx is non-numeric', () => {
    expect(pdfParagraphToPageNumber('pdf-foo-7')).toBeNull()
    expect(pdfParagraphToPageNumber('pdf-7-foo')).toBeNull()
    expect(pdfParagraphToPageNumber('pdf--7')).toBeNull()
  })

  it('returns null when the page number is zero', () => {
    expect(pdfParagraphToPageNumber('pdf-0-0')).toBeNull()
  })

  it('returns null on missing segments', () => {
    expect(pdfParagraphToPageNumber('pdf-7')).toBeNull()
    expect(pdfParagraphToPageNumber('pdf-')).toBeNull()
  })
})
```

- [ ] **Step 2: Run — verify red**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.test.ts
```

Expected: FAIL ("cannot find module").

- [ ] **Step 3: Implement**

Create `src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.ts`:

```ts
/**
 * Parse a PDF paragraph id of the form `pdf-{page}-{idx}` and return the
 * 1-based page number. Returns null for any input that doesn't match the
 * shape exactly, including legacy ids, ids from other formats, and ids
 * with non-numeric or non-positive page components.
 */
export function pdfParagraphToPageNumber(idx: string): number | null {
  const m = /^pdf-(\d+)-(\d+)$/.exec(idx)
  if (!m) return null
  const page = Number(m[1])
  if (!Number.isFinite(page) || page <= 0) return null
  return page
}
```

- [ ] **Step 4: Run — verify green**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.ts \
        src/renderer/src/components/pdf/utils/pdfParagraphToPageNumber.test.ts
git commit -m "feat(pdf): pdfParagraphToPageNumber pure helper"
```

---

## Task 6: Pure helper — `azw3ParagraphToLocation`

**Files:**
- Create: `src/renderer/src/components/azw3/paragraphToLocation.ts`
- Create: `src/renderer/src/components/azw3/paragraphToLocation.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/renderer/src/components/azw3/paragraphToLocation.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { azw3ParagraphToLocation } from './paragraphToLocation'

describe('azw3ParagraphToLocation', () => {
  it('extracts the chapter from a well-formed paragraph id', () => {
    expect(azw3ParagraphToLocation('azw3-0-0')).toEqual({ chapter: 0, page: 0 })
    expect(azw3ParagraphToLocation('azw3-3-12')).toEqual({ chapter: 3, page: 0 })
  })

  it('returns null on empty input', () => {
    expect(azw3ParagraphToLocation('')).toBeNull()
  })

  it('returns null for non-AZW3 paragraph ids', () => {
    expect(azw3ParagraphToLocation('pdf-3-2')).toBeNull()
    expect(azw3ParagraphToLocation('epubcfi(/6/4)')).toBeNull()
    expect(azw3ParagraphToLocation('1')).toBeNull()
  })

  it('returns null on missing or non-numeric segments', () => {
    expect(azw3ParagraphToLocation('azw3-foo-1')).toBeNull()
    expect(azw3ParagraphToLocation('azw3-1-foo')).toBeNull()
    expect(azw3ParagraphToLocation('azw3-1')).toBeNull()
  })
})
```

- [ ] **Step 2: Run — verify red**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/components/azw3/paragraphToLocation.test.ts
```

Expected: FAIL.

- [ ] **Step 3: Implement**

Create `src/renderer/src/components/azw3/paragraphToLocation.ts`:

```ts
import { parseParagraphIndex } from './highlight'
import type { ReadingPosition } from './pagination'

/**
 * Derive a ReadingPosition (chapter + page-within-chapter) from an AZW3/MOBI
 * paragraph id. Always lands on page 0 of the chapter — the column-paginated
 * reader will rerun viewport math after the chapter loads. Returns null when
 * the input isn't an `azw3-{chap}-{idx}` string.
 */
export function azw3ParagraphToLocation(idx: string): ReadingPosition | null {
  const parsed = parseParagraphIndex(idx)
  if (!parsed) return null
  return { chapter: parsed.chapter, page: 0 }
}
```

- [ ] **Step 4: Run — verify green**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/components/azw3/paragraphToLocation.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/components/azw3/paragraphToLocation.ts \
        src/renderer/src/components/azw3/paragraphToLocation.test.ts
git commit -m "feat(azw3): paragraphToLocation pure helper"
```

---

## Task 7: playerMachine — `resumeParagraphIndex` slot

**Files:**
- Modify: `src/renderer/src/machines/playerMachine.ts`
- Modify: `src/renderer/src/machines/playerMachine.test.ts`

This task adds the event payload, context slot, and the action that stores it on INITIALIZE. The `PARAGRAPHS_UPDATED` branch comes in Task 8.

- [ ] **Step 1: Write failing tests**

In `src/renderer/src/machines/playerMachine.test.ts`, append a new `describe` at the end of the existing test file:

```ts
describe('resumeParagraphIndex (INITIALIZE option)', () => {
  it('starts with a null resumeParagraphIndex by default', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    expect(actor.getSnapshot().context.resumeParagraphIndex).toBeNull()
  })

  it('stores resumeParagraphIndex from INITIALIZE payload', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1', resumeParagraphIndex: 'p-2' })
    expect(actor.getSnapshot().context.resumeParagraphIndex).toBe('p-2')
  })

  it('treats an absent resumeParagraphIndex as null (not undefined)', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    expect(actor.getSnapshot().context.resumeParagraphIndex).toBeNull()
  })
})
```

- [ ] **Step 2: Run — verify red**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/machines/playerMachine.test.ts
```

Expected: FAIL — `resumeParagraphIndex` not on context.

- [ ] **Step 3: Add the event field and context slot**

In `src/renderer/src/machines/playerMachine.ts`:

Extend the `PlayerMachineContext` type:

```ts
export type PlayerMachineContext = {
  bookId: string
  paragraphIndex: number
  // ...existing fields...
  partialFirstParagraphIndex: number | null
  resumeParagraphIndex: string | null
}
```

Extend the `INITIALIZE` event in `PlayerMachineEvent`:

```ts
  | { type: 'INITIALIZE'; bookId: string; resumeParagraphIndex?: string | null }
```

Extend `initialContext`:

```ts
const initialContext: PlayerMachineContext = {
  // ...existing fields...
  partialFirstParagraphIndex: null,
  resumeParagraphIndex: null
}
```

In the `actions` map, add a new action right after `storeBookId`:

```ts
    storeResumeIndex: assign({
      resumeParagraphIndex: ({ event }) =>
        event.type === 'INITIALIZE' ? (event.resumeParagraphIndex ?? null) : null
    }),
```

Then in the `idle` state, extend the INITIALIZE transition's actions:

```ts
    idle: {
      on: {
        INITIALIZE: {
          target: 'stopped',
          actions: ['storeBookId', 'resetIndex', 'storeResumeIndex']
        },
        // ...rest unchanged...
      }
    },
```

- [ ] **Step 4: Run — verify green**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/machines/playerMachine.test.ts
```

Expected: PASS (new tests + all existing tests still pass).

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/machines/playerMachine.ts src/renderer/src/machines/playerMachine.test.ts
git commit -m "feat(player): INITIALIZE accepts resumeParagraphIndex"
```

---

## Task 8: playerMachine — apply resume on PARAGRAPHS_UPDATED in `stopped`

**Files:**
- Modify: `src/renderer/src/machines/playerMachine.ts`
- Modify: `src/renderer/src/machines/playerMachine.test.ts`

- [ ] **Step 1: Write failing tests**

Append a new `describe` to the test file:

```ts
describe('resume paragraph application', () => {
  it('sets paragraphIndex to the matched paragraph when paragraphs arrive', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1', resumeParagraphIndex: 'p-2' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    const ctx = actor.getSnapshot().context
    expect(ctx.paragraphIndex).toBe(2)
    expect(ctx.resumeParagraphIndex).toBeNull()
    expect(actor.getSnapshot().value).toBe('stopped')
  })

  it('leaves paragraphIndex at 0 when the resume id is not in the new paragraphs', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1', resumeParagraphIndex: 'p-99' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    const ctx = actor.getSnapshot().context
    expect(ctx.paragraphIndex).toBe(0)
    expect(ctx.resumeParagraphIndex).toBe('p-99')
  })

  it('PLAY after resume applied starts loading from the resumed paragraph', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1', resumeParagraphIndex: 'p-3' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'PLAY' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('loading')
    expect(snap.context.paragraphIndex).toBe(3)
  })

  it('second PARAGRAPHS_UPDATED after resume applied falls into default branch', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1', resumeParagraphIndex: 'p-2' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    expect(actor.getSnapshot().context.paragraphIndex).toBe(2)
    // Page navigates; new page's first paragraph also happens to be id p-2.
    // Since resume already cleared, paragraphIndex must NOT re-set itself.
    actor.send({
      type: 'PARAGRAPHS_UPDATED',
      paragraphs: [{ index: 'p-2', text: 'new page p-2' }, ...makeParagraphs(3)]
    })
    expect(actor.getSnapshot().context.paragraphIndex).toBe(2) // unchanged
    expect(actor.getSnapshot().context.resumeParagraphIndex).toBeNull()
  })
})
```

- [ ] **Step 2: Run — verify red**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/machines/playerMachine.test.ts
```

Expected: FAIL on the resume-applied tests (paragraphIndex stays at 0; resumeParagraphIndex doesn't clear).

- [ ] **Step 3: Add the guard and action**

In `src/renderer/src/machines/playerMachine.ts`:

In the `guards` map:

```ts
  guards: {
    // ...existing guards...
    wantsAutoResumeAfterChat: ({ context }) => context.wantsAutoResumeAfterChat,
    hasUnresolvedResume: ({ context, event }) => {
      if (context.resumeParagraphIndex === null) return false
      if (event.type !== 'PARAGRAPHS_UPDATED') return false
      return event.paragraphs.some((p) => p.index === context.resumeParagraphIndex)
    }
  },
```

In the `actions` map:

```ts
    applyResumeIndex: assign({
      paragraphIndex: ({ context, event }) => {
        if (event.type !== 'PARAGRAPHS_UPDATED') return context.paragraphIndex
        const idx = event.paragraphs.findIndex((p) => p.index === context.resumeParagraphIndex)
        return idx >= 0 ? idx : context.paragraphIndex
      },
      resumeParagraphIndex: null
    }),
```

In the `stopped` state, replace the existing `PARAGRAPHS_UPDATED` block with:

```ts
        PARAGRAPHS_UPDATED: [
          {
            guard: 'wasTimedOut',
            target: 'loading',
            actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
          },
          {
            guard: 'hasUnresolvedResume',
            actions: ['storeParagraphs', 'applyResumeIndex']
          },
          {
            actions: ['storeParagraphs']
          }
        ],
```

- [ ] **Step 4: Run — verify green**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/machines/playerMachine.test.ts
```

Expected: PASS (all tests, new and existing).

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/machines/playerMachine.ts src/renderer/src/machines/playerMachine.test.ts
git commit -m "feat(player): apply resumeParagraphIndex when paragraphs arrive in stopped"
```

---

## Task 9: `usePlayerStore` — add `lastPlayedParagraphIndex` field

**Files:**
- Modify: `src/renderer/src/stores/playerStore.ts`
- Modify: `src/renderer/src/stores/playerStore.test.ts`

- [ ] **Step 1: Write the failing test**

In `src/renderer/src/stores/playerStore.test.ts`, append:

```ts
describe('lastPlayedParagraphIndex', () => {
  it('starts as null', () => {
    usePlayerStore.setState({ lastPlayedParagraphIndex: null })
    expect(usePlayerStore.getState().lastPlayedParagraphIndex).toBeNull()
  })

  it('setLastPlayedParagraphIndex updates the field', () => {
    usePlayerStore.getState().setLastPlayedParagraphIndex('p-7')
    expect(usePlayerStore.getState().lastPlayedParagraphIndex).toBe('p-7')

    usePlayerStore.getState().setLastPlayedParagraphIndex(null)
    expect(usePlayerStore.getState().lastPlayedParagraphIndex).toBeNull()
  })
})
```

(If the existing test file has a `beforeEach` that resets the store, follow that pattern.)

- [ ] **Step 2: Run — verify red**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/stores/playerStore.test.ts
```

Expected: FAIL.

- [ ] **Step 3: Implement**

In `src/renderer/src/stores/playerStore.ts`, extend the `PlayerStore` interface:

```ts
interface PlayerStore {
  // ...existing fields...
  send: PlayerSend | null

  // Hydration hint: the paragraph id we want to highlight when no
  // activeParagraph is set. Mirrored live from activeParagraph during
  // playback, and seeded from book.lastParagraph on book open.
  lastPlayedParagraphIndex: string | null

  // ...existing actions...
  setSend: (send: PlayerSend) => void
  setLastPlayedParagraphIndex: (idx: string | null) => void
}
```

In the initial state object:

```ts
    send: null,
    lastPlayedParagraphIndex: null,
```

In the actions, alongside `setSend`:

```ts
    setSend: (send) => set({ send }),
    setLastPlayedParagraphIndex: (lastPlayedParagraphIndex) =>
      set({ lastPlayedParagraphIndex })
```

- [ ] **Step 4: Run — verify green**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/stores/playerStore.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/stores/playerStore.ts src/renderer/src/stores/playerStore.test.ts
git commit -m "feat(player): add lastPlayedParagraphIndex to playerStore"
```

---

## Task 10: usePlayerMachine — write path subscription + cleanup flush

**Files:**
- Modify: `src/renderer/src/hooks/usePlayerMachine.ts`
- Create: `src/renderer/src/hooks/__tests__/usePlayerMachine.writePath.test.ts`

This adds a new subscription that mirrors `activeParagraph` to `lastPlayedParagraphIndex` synchronously and writes the same id to the DB after 500 ms of quiet. The subscription is the only writer; we *don't* persist nulls.

- [ ] **Step 1: Write the failing test**

Create `src/renderer/src/hooks/__tests__/usePlayerMachine.writePath.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { usePlayerStore } from '@/stores/playerStore'

// Mock the IPC layer BEFORE importing the hook so the spy is in place
// when the module initializes its subscription wrapper.
const updateBookLastParagraph = vi.fn().mockResolvedValue(undefined)
vi.mock('@/lib/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/lib/api')>()
  return {
    ...actual,
    updateBookLastParagraph: (...args: Parameters<typeof actual.updateBookLastParagraph>) =>
      updateBookLastParagraph(...args)
  }
})

import { startResumeWriteSubscription } from '@/hooks/usePlayerMachine'

describe('startResumeWriteSubscription', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    updateBookLastParagraph.mockClear()
    usePlayerStore.setState({
      activeParagraph: null,
      lastPlayedParagraphIndex: null
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('mirrors activeParagraph.index to lastPlayedParagraphIndex synchronously', () => {
    const { dispose } = startResumeWriteSubscription({ bookId: 42 })
    usePlayerStore.setState({ activeParagraph: { index: 'p-3', text: 't' } })
    expect(usePlayerStore.getState().lastPlayedParagraphIndex).toBe('p-3')
    dispose()
  })

  it('debounces IPC writes to a single trailing call at 500ms', () => {
    const { dispose } = startResumeWriteSubscription({ bookId: 42 })
    usePlayerStore.setState({ activeParagraph: { index: 'p-1', text: 't' } })
    usePlayerStore.setState({ activeParagraph: { index: 'p-2', text: 't' } })
    usePlayerStore.setState({ activeParagraph: { index: 'p-3', text: 't' } })

    expect(updateBookLastParagraph).not.toHaveBeenCalled()
    vi.advanceTimersByTime(499)
    expect(updateBookLastParagraph).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)
    expect(updateBookLastParagraph).toHaveBeenCalledWith({
      bookId: 42,
      lastParagraph: 'p-3'
    })
    dispose()
  })

  it('does not write when activeParagraph transitions to null', () => {
    const { dispose } = startResumeWriteSubscription({ bookId: 42 })
    usePlayerStore.setState({ activeParagraph: { index: 'p-1', text: 't' } })
    usePlayerStore.setState({ activeParagraph: null })
    vi.advanceTimersByTime(1000)
    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)
    expect(updateBookLastParagraph).toHaveBeenCalledWith({
      bookId: 42,
      lastParagraph: 'p-1'
    })
    dispose()
  })

  it('flush() writes a pending debounced value synchronously', () => {
    const { dispose, flush } = startResumeWriteSubscription({ bookId: 42 })
    usePlayerStore.setState({ activeParagraph: { index: 'p-9', text: 't' } })
    expect(updateBookLastParagraph).not.toHaveBeenCalled()
    flush()
    expect(updateBookLastParagraph).toHaveBeenCalledTimes(1)
    expect(updateBookLastParagraph).toHaveBeenCalledWith({
      bookId: 42,
      lastParagraph: 'p-9'
    })
    dispose()
  })

  it('flush() is a no-op when no debounced write is pending', () => {
    const { dispose, flush } = startResumeWriteSubscription({ bookId: 42 })
    flush()
    expect(updateBookLastParagraph).not.toHaveBeenCalled()
    dispose()
  })
})
```

- [ ] **Step 2: Run — verify red**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/hooks/__tests__/usePlayerMachine.writePath.test.ts
```

Expected: FAIL — `startResumeWriteSubscription` not exported.

- [ ] **Step 3: Implement**

In `src/renderer/src/hooks/usePlayerMachine.ts`, add the import (alongside existing imports):

```ts
import { updateBookLastParagraph } from '@/lib/api'
```

Then export the subscription helper (place it above the `usePlayerMachine` function so the hook can reuse it):

```ts
export function startResumeWriteSubscription({ bookId }: { bookId: number }): {
  dispose: () => void
  flush: () => void
} {
  let pendingId: string | null = null
  let timer: ReturnType<typeof setTimeout> | null = null

  const writeNow = (id: string): void => {
    void updateBookLastParagraph({ bookId, lastParagraph: id }).catch((err: unknown) => {
      console.warn('[player] resume-paragraph save failed:', err)
    })
  }

  const flush = (): void => {
    if (timer === null || pendingId === null) return
    clearTimeout(timer)
    const id = pendingId
    timer = null
    pendingId = null
    writeNow(id)
  }

  const unsub = usePlayerStore.subscribe(
    (s) => s.activeParagraph,
    (active) => {
      if (active === null) return
      usePlayerStore.setState({ lastPlayedParagraphIndex: active.index })
      pendingId = active.index
      if (timer !== null) clearTimeout(timer)
      timer = setTimeout(() => {
        const id = pendingId
        timer = null
        pendingId = null
        if (id !== null) writeNow(id)
      }, 500)
    }
  )

  const dispose = (): void => {
    if (timer !== null) clearTimeout(timer)
    timer = null
    pendingId = null
    unsub()
  }

  return { dispose, flush }
}
```

Wire it into the existing `usePlayerMachine` hook. Inside the `useEffect(() => { ... }, [bookId])` block, just after the existing subscription setup, add:

```ts
    // Persist the live paragraph id so reopen can highlight + resume.
    // bookId is a string in this hook (xstate context expects string ids);
    // the DB column is keyed by numeric book id.
    const resumeWrite = startResumeWriteSubscription({ bookId: Number(bookId) })
```

Inside the cleanup `return () => { ... }`, BEFORE the `actor.send({ type: 'CLEANUP' })` line:

```ts
      resumeWrite.flush()
      resumeWrite.dispose()
```

- [ ] **Step 4: Run — verify green**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/hooks/__tests__/usePlayerMachine.writePath.test.ts
```

Expected: PASS.

- [ ] **Step 5: Run the full vitest suite to catch regressions**

```bash
cd apps/rishi-electron && pnpm vitest run
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/hooks/usePlayerMachine.ts \
        src/renderer/src/hooks/__tests__/usePlayerMachine.writePath.test.ts
git commit -m "feat(player): debounced write of last-played paragraph to DB"
```

---

## Task 11: usePlayerMachine — pass `resumeParagraphIndex` into INITIALIZE

**Files:**
- Modify: `src/renderer/src/hooks/usePlayerMachine.ts`

- [ ] **Step 1: Add the read from the store and pass it through**

In `usePlayerMachine`, find the existing initialization line:

```ts
    actor.send({ type: 'INITIALIZE', bookId })
```

Replace with:

```ts
    // Seeded by routes/books.$id.lazy.tsx before this hook initializes.
    const resumeParagraphIndex = usePlayerStore.getState().lastPlayedParagraphIndex
    actor.send({ type: 'INITIALIZE', bookId, resumeParagraphIndex })
```

Reading from the store at INITIALIZE time means the route (Task 12) seeds the value before the actor starts.

- [ ] **Step 2: Run vitest to confirm nothing broke**

```bash
cd apps/rishi-electron && pnpm vitest run
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/hooks/usePlayerMachine.ts
git commit -m "feat(player): forward lastPlayedParagraphIndex into INITIALIZE"
```

---

## Task 12: Route — seed `lastPlayedParagraphIndex` from `book.lastParagraph`

**Files:**
- Modify: `src/renderer/src/routes/books.$id.lazy.tsx`

- [ ] **Step 1: Add the seeding effect**

In `src/renderer/src/routes/books.$id.lazy.tsx`, add an import:

```ts
import { usePlayerStore } from '@/stores/playerStore'
```

After the `setBook` effect, add:

```ts
  useEffect(() => {
    if (!book) return
    usePlayerStore.setState({
      lastPlayedParagraphIndex: book.lastParagraph ?? null
    })
  }, [book])
```

Then in the unmount cleanup (the existing `useEffect` returning the cleanup function), add a reset:

```ts
  useEffect(() => {
    return () => {
      setBookNavigationState(BookNavigationState.Idle)
      setBook(null)
      useEpubStore.getState().reset()
      usePageTracker.getState().reset()
      usePlayerStore.setState({ lastPlayedParagraphIndex: null })
    }
  }, [setBook, setBookNavigationState])
```

- [ ] **Step 2: Sanity-check by running existing route/component tests**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/routes
```

Expected: PASS (or "no tests in this directory" — either is fine).

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/routes/books.$id.lazy.tsx
git commit -m "feat(route): seed lastPlayedParagraphIndex from book.lastParagraph"
```

---

## Task 13: EpubView — prefer `book.lastParagraph` for initial location

**Files:**
- Modify: `src/renderer/src/components/epub/EpubView.tsx`

- [ ] **Step 1: Update the initial-location state**

In `src/renderer/src/components/epub/EpubView.tsx`, find:

```ts
  const [currentLocation, setCurrentLocation] = useState<string>(book.location || '0')
```

Replace with:

```ts
  const [currentLocation, setCurrentLocation] = useState<string>(
    book.lastParagraph || book.location || '0'
  )
```

Rationale: an EPUB paragraph index is a CFI, which is a valid `rendition.display()` target. Falsy `lastParagraph` (null / empty string) falls through to the existing default.

- [ ] **Step 2: Leave the refetch-sync effect alone**

A few lines down there's a `useEffect` that re-syncs `currentLocation` whenever `book.location` changes (the refetch path for mid-session updates). **Do not** add `book.lastParagraph` to its dependency list — `lastParagraph` is only meaningful at initial mount; teleporting the user back to the resume point during the session would be jarring.

- [ ] **Step 3: Lint + typecheck**

```bash
cd apps/rishi-electron && pnpm typecheck && pnpm lint
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(epub): prefer book.lastParagraph for initial display location"
```

---

## Task 14: PDF — prefer `book.lastParagraph` for initial page

**Files:**
- Modify: `src/renderer/src/hooks/usePdfReader.ts`
- Modify: `src/renderer/src/components/pdf/components/pdf.tsx`

- [ ] **Step 1: Update the PDF reader hook**

In `src/renderer/src/hooks/usePdfReader.ts`, add the import:

```ts
import { pdfParagraphToPageNumber } from '@/components/pdf/utils/pdfParagraphToPageNumber'
```

Find:

```ts
    const { page: parsedPage, offset: parsedOffset } = parsePdfLocation(book.location)
    const initialPage = parsedPage > 0 ? parsedPage : 1
    const initialOffset = parsedOffset
```

Replace with:

```ts
    const { page: parsedPage, offset: parsedOffset } = parsePdfLocation(book.location)
    const resumePage = book.lastParagraph ? pdfParagraphToPageNumber(book.lastParagraph) : null
    const initialPage = resumePage ?? (parsedPage > 0 ? parsedPage : 1)
    const initialOffset = resumePage !== null ? 0 : parsedOffset
```

(Resume always lands at the top of the page; we don't store sub-page offset alongside the paragraph id.)

- [ ] **Step 2: Update the indexing startPage in pdf.tsx**

In `src/renderer/src/components/pdf/components/pdf.tsx`, add the import:

```ts
import { pdfParagraphToPageNumber } from '@/components/pdf/utils/pdfParagraphToPageNumber'
```

Find the existing line that derives `startPage`:

```ts
        const startPage = parsePdfLocation(book.location).page || 1
```

Replace with:

```ts
        const resumePage = book.lastParagraph
          ? pdfParagraphToPageNumber(book.lastParagraph)
          : null
        const startPage = resumePage ?? parsePdfLocation(book.location).page || 1
```

- [ ] **Step 3: Lint + typecheck**

```bash
cd apps/rishi-electron && pnpm typecheck && pnpm lint
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/src/hooks/usePdfReader.ts src/renderer/src/components/pdf/components/pdf.tsx
git commit -m "feat(pdf): prefer book.lastParagraph for initial page + index start"
```

---

## Task 15: Azw3View — prefer `book.lastParagraph` for initial location

**Files:**
- Modify: `src/renderer/src/components/azw3/Azw3View.tsx`

- [ ] **Step 1: Update initial-location derivation**

In `src/renderer/src/components/azw3/Azw3View.tsx`, add the import:

```ts
import { azw3ParagraphToLocation } from './paragraphToLocation'
```

Find:

```ts
  const initialLocation = useMemo(() => parseLocation(book.location), [book.location])
```

Replace with:

```ts
  const initialLocation = useMemo(() => {
    if (book.lastParagraph) {
      const resume = azw3ParagraphToLocation(book.lastParagraph)
      if (resume) return resume
    }
    return parseLocation(book.location)
  }, [book.lastParagraph, book.location])
```

- [ ] **Step 2: Lint + typecheck**

```bash
cd apps/rishi-electron && pnpm typecheck && pnpm lint
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/components/azw3/Azw3View.tsx
git commit -m "feat(azw3): prefer book.lastParagraph for initial chapter"
```

---

## Task 16: PDF highlight fallback

**Files:**
- Modify: `src/renderer/src/components/pdf/components/pdf.tsx`

PDF highlights are driven by `pdfStore.highlightedParagraphIndex`. There's an existing subscription that writes `activeParagraph.index` into that store (around line 178 in `pdf.tsx`). We broaden it to also forward `lastPlayedParagraphIndex` when there's no active paragraph.

- [ ] **Step 1: Find the existing subscription**

In `src/renderer/src/components/pdf/components/pdf.tsx`, search for `setHighlightedParagraphIndex`. There's a subscription wired to `usePlayerStore.activeParagraph` that calls `usePdfStore.getState().setHighlightedParagraphIndex(paragraph.index)`.

- [ ] **Step 2: Extend the subscription**

Replace the existing subscription. The new shape subscribes to both `activeParagraph` and `lastPlayedParagraphIndex` and computes the effective highlight:

```ts
    const unsubHighlight = usePlayerStore.subscribe(
      (s) => ({
        active: s.activeParagraph,
        resume: s.lastPlayedParagraphIndex
      }),
      ({ active, resume }) => {
        const effectiveIndex = active?.index ?? resume ?? ''
        usePdfStore.getState().setHighlightedParagraphIndex(effectiveIndex)
      },
      { equalityFn: (a, b) => a.active === b.active && a.resume === b.resume }
    )
```

(Adapt the wrapper function name and surrounding lines to match what's actually in the file. If the existing subscription uses a different selector style, preserve that style and add the `resume` field.)

In the same effect's cleanup, add `unsubHighlight()` to the disposers.

- [ ] **Step 3: Smoke-test PDF unit tests**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/components/pdf
```

Expected: PASS. The existing `pdf-page.test.tsx` already proves that `highlightedParagraphIndex` round-trips through the page renderer; our change just supplies a different *source* for that index.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/src/components/pdf/components/pdf.tsx
git commit -m "feat(pdf): fall back to lastPlayedParagraphIndex for highlight"
```

---

## Task 17: AZW3 highlight fallback

**Files:**
- Modify: `src/renderer/src/components/azw3/Azw3View.tsx`

- [ ] **Step 1: Locate the existing highlight subscription**

In `src/renderer/src/components/azw3/Azw3View.tsx`, search for `usePlayerStore.subscribe` near the comment `This effect is intentionally scoped to activeParagraph store changes only`. It selects `s.activeParagraph` and applies/removes the `TTS_ACTIVE_CLASS` on the matching paragraph element via `findParagraphElement`.

- [ ] **Step 2: Broaden the selector**

Change the selector to expose both fields and pick the effective one inside the listener:

```ts
    const unsub = usePlayerStore.subscribe(
      (s) => ({ active: s.activeParagraph, resume: s.lastPlayedParagraphIndex }),
      ({ active, resume }) => {
        const indexStr = active?.index ?? resume ?? null
        // ...existing body, using `indexStr` instead of the previous
        // `activeParagraph?.index` value...
      },
      { equalityFn: (a, b) => a.active === b.active && a.resume === b.resume }
    )
```

Inside the listener body, every place that used `activeParagraph?.index` now reads from the local `indexStr`. Every place that used `activeParagraph` as a falsy-check (e.g. `if (activeParagraph)`) should test `indexStr !== null`.

- [ ] **Step 3: Run AZW3 tests**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/components/azw3
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/src/components/azw3/Azw3View.tsx
git commit -m "feat(azw3): fall back to lastPlayedParagraphIndex for highlight"
```

---

## Task 18: EPUB highlight fallback

**Files:**
- Modify: `src/renderer/src/components/react-reader/epub_viewer/index.tsx`

- [ ] **Step 1: Locate the subscription**

In `src/renderer/src/components/react-reader/epub_viewer/index.tsx`, find the block where `activeParagraph = usePlayerStore.getState().activeParagraph` is consumed (around line 354). It applies `rendition.annotations.highlight(cfi, ...)` (or the wrapper from `epub/reconcileTtsHighlight.ts`).

- [ ] **Step 2: Extend selector + listener**

Apply the same pattern as Tasks 16/17: change the subscription selector to include `lastPlayedParagraphIndex`, and in the listener body read

```ts
        const indexStr = active?.index ?? resume ?? null
```

before passing it to the existing highlight-reconcile call.

- [ ] **Step 3: Run EPUB tests**

```bash
cd apps/rishi-electron && pnpm vitest run src/renderer/src/components/epub src/renderer/src/components/react-reader
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/src/components/react-reader/epub_viewer/index.tsx
git commit -m "feat(epub): fall back to lastPlayedParagraphIndex for highlight"
```

---

## Task 19: Full-suite verification

- [ ] **Step 1: Vitest**

```bash
cd apps/rishi-electron && pnpm vitest run
```

Expected: PASS.

- [ ] **Step 2: Typecheck**

```bash
cd apps/rishi-electron && pnpm typecheck
```

Expected: PASS.

- [ ] **Step 3: Lint**

```bash
cd apps/rishi-electron && pnpm lint
```

Expected: PASS.

If any of these fail, fix inline before proceeding.

---

## Task 20: E2E spec — close, reopen, highlight, resume

**Files:**
- Create: `e2e/resume-paragraph.spec.ts`

This validates the full round-trip against the real Electron app. Use one of the small books already present in `e2e/fixtures/`.

- [ ] **Step 1: Pick a fixture book**

```bash
ls e2e/fixtures
```

Note the path to a small EPUB. If no EPUB fixture exists, pick the smallest book of any format the existing specs already use.

- [ ] **Step 2: Write the spec**

Create `e2e/resume-paragraph.spec.ts`:

```ts
import { test, expect } from '@playwright/test'
import { launchAppWithBook, closeApp } from './helpers'

// Replace the fixture path with whichever small book your fixtures dir provides.
const FIXTURE_BOOK = 'fixtures/example.epub'

test('resumes from the last-played paragraph on reopen', async () => {
  // 1. First launch — open book, play, advance, pause.
  let app = await launchAppWithBook(FIXTURE_BOOK)

  const playBtn = app.window.getByTestId('tts-play-pause')
  await playBtn.click() // start TTS

  // Wait for activeParagraph highlight to render at least once.
  await app.window
    .locator('.rishi-tts-active, [data-tts-active="true"]')
    .first()
    .waitFor({ state: 'visible', timeout: 10_000 })

  // Let it advance a couple of paragraphs.
  await app.window.waitForTimeout(2_500)

  // Pause.
  await playBtn.click()

  // Capture the highlighted paragraph's id for the post-reopen assertion.
  const highlightedBefore = await app.window
    .locator('.rishi-tts-active, [data-tts-active="true"]')
    .first()
    .getAttribute('data-paragraph-index')

  expect(highlightedBefore).toBeTruthy()

  await closeApp(app)

  // 2. Second launch — book auto-opens via Recent or library click.
  app = await launchAppWithBook(FIXTURE_BOOK)

  // The highlight should appear without pressing play.
  const highlightedAfter = app.window
    .locator('.rishi-tts-active, [data-tts-active="true"]')
    .first()
  await highlightedAfter.waitFor({ state: 'visible', timeout: 10_000 })
  expect(await highlightedAfter.getAttribute('data-paragraph-index')).toBe(highlightedBefore)

  // The reader should be paused (play button shows play-icon, not pause-icon).
  await expect(playBtn).toHaveAttribute('data-state', 'paused')

  // Pressing play resumes from the same paragraph.
  await playBtn.click()
  await expect(playBtn).toHaveAttribute('data-state', 'playing')
  expect(await highlightedAfter.getAttribute('data-paragraph-index')).toBe(highlightedBefore)

  await closeApp(app)
})
```

**Spec writer note:** the locator selectors (`data-tts-active`, `data-paragraph-index`, `data-testid="tts-play-pause"`, `data-state` on the play button) and the `launchAppWithBook` / `closeApp` helpers are the ones the existing e2e suite uses. If your repo's helpers have different names, adapt the calls without changing the asserted behavior. If the paragraph element doesn't have a `data-paragraph-index` attribute today, fall back to comparing the text content of the highlighted node before/after the reopen.

- [ ] **Step 3: Run the spec**

```bash
cd apps/rishi-electron && pnpm e2e e2e/resume-paragraph.spec.ts
```

Expected: PASS.

If selectors don't match, adjust them based on what the rendered DOM actually exposes (use `pnpm e2e --headed --debug` to inspect).

- [ ] **Step 4: Commit**

```bash
git add e2e/resume-paragraph.spec.ts
git commit -m "test(e2e): resume reading from last-played paragraph"
```

---

## Self-review

- **Spec coverage** — every numbered section of the design doc maps to at least one task:
  - § 1 persistence layer → Tasks 1–4
  - § 2 hydration + per-format resolvers → Tasks 5, 6, 13–15
  - § 3 player machine + write path → Tasks 7–11
  - § 4 test plan → embedded red phases in every task + Task 19 (full suite) + Task 20 (E2E)
- **Placeholder scan** — no "TBD", "add appropriate validation", or "similar to Task N" left behind.
- **Type/name consistency** — `lastParagraph` (DB field, IPC contract, renderer `Book` interface) and `lastPlayedParagraphIndex` (store field) are spelled consistently across tasks. Method names — `updateBookLastParagraph`, `pdfParagraphToPageNumber`, `azw3ParagraphToLocation`, `startResumeWriteSubscription`, `hasUnresolvedResume`, `applyResumeIndex`, `storeResumeIndex` — also match across tasks.

---

## Out of scope (do NOT implement here)

- "Clear my progress" UI to null out `last_paragraph`.
- Home-screen "Continue listening" pill.
- Sync of `last_paragraph` across devices.

Track these as separate follow-ups if you want.
