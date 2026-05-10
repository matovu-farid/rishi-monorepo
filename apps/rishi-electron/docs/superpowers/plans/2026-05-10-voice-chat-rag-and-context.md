# Voice Chat RAG Fix + Context Expansion + Perf Polish

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unbreak the existing semantic-search `bookContext` tool, expand the agent's default context to include the book's chapter structure (title, author, chapter list), and add three perf polish items (skip-update on unchanged context, WebRTC pre-connect after first voice use, instructions trim).

**Architecture:** The vector index name is currently inconsistent between save and search — fix the search side to match (Phase 1). Add a new `getBookOutline(bookId)` SQL helper exposed via IPC, cache the result in `epubStore` on book open, pass it through `chatStore` → `voiceChatService.activate(bookId, ctx)` → `buildRealtimeAgent` so the agent's system prompt includes title + author + chapter titles (Phase 2). On warm-path activate, hash the context and skip `updateAgent` if unchanged. Pre-connect WebRTC on book open only after the user has used voice at least once this app session. Final pass: trim 30-40% off the prose in the instructions template now that the agent gets richer structured context (Phase 3).

**Tech Stack:** Drizzle ORM (SQLite), better-sqlite3, Electron IPC, Zustand, `@openai/agents-realtime@0.3.9`, Vitest.

---

## File Structure

**Modify:**
- `src/main/ipc/search.ts` — fix index naming bug (Phase 1)
- `src/main/database/queries.ts` — add `getBookOutline(bookId)` (Phase 2)
- `src/main/ipc/books-extra.ts` — register `books:getOutline` IPC handler (Phase 2)
- `src/preload/index.ts` — expose `getBookOutline` to renderer (Phase 2)
- `src/renderer/src/lib/api.ts` — renderer wrapper for `getBookOutline` (Phase 2)
- `src/renderer/src/stores/epubStore.ts` — cache outline, pre-connect on book open (Phase 2 + Phase 3.5)
- `src/renderer/src/modules/buildRealtimeAgent.ts` — accept `outline` param, inject into instructions, trim prose (Phase 2 + Phase 3.6)
- `src/renderer/src/modules/voiceChatService.ts` — `activate({ pageText, outline })`, context fingerprint skip, `preconnect()` method (Phase 3.4 + 3.5)
- `src/renderer/src/stores/chatStore.ts` — pass outline through to service (Phase 2)
- Existing tests updated accordingly.

**Create:**
- `src/main/database/__tests__/queries.outline.test.ts` — DB test for `getBookOutline`
- (Reuse existing test files for the other modules.)

---

## Design Decisions (locked)

1. **Outline shape**: `{ title: string, author: string | null, chapters: string[] }`. Chapters are DISTINCT `chunk_data.chapter` values ordered by their minimum `page_number`. Null/empty chapters are excluded.
2. **Current-chapter detection is OUT of scope.** `ParagraphWithIndex` has only `text` and `index` (string) — mapping renderer "current paragraph" to a `chunk_data.page_number` requires plumbing that doesn't exist today. We inject the chapter LIST and let the LLM use it for global context; the existing page-text-in-instructions handles local context. A follow-up plan can add current-chapter detection if it proves valuable.
3. **`activate` signature change**: from `activate(bookId, pageText)` to `activate(bookId, ctx: { pageText, outline? })`. Outline is optional so callers that don't have it (e.g. tests) still work.
4. **Context fingerprint**: a simple string concat of `pageText + '\n' + JSON.stringify(outline ?? {})`. On warm path, if the fingerprint equals the previous activation's fingerprint, skip `updateAgent` entirely — just unmute. Saves 50-100 ms per re-activation on the same page.
5. **Pre-connect trigger**: a module-level `hasUsedVoiceInSession` flag inside `voiceChatService`, set to `true` after the first successful cold-path `activate`. `epubStore`'s bookId subscription, after `prefetchRealtimeKey()`, also calls `voiceChatService.preconnect(bookId, ctx)` when the flag is `true`. `preconnect` runs the cold path but goes straight to `paused` state (muted) instead of `active`.
6. **Instructions trim target**: ~50% length reduction in the prose-heavy "Conversation Flow", "Sample Phrases", and "Tool Usage Guidelines" sections. Rules section stays. Phase structure stays. The big win is removing the verbose example phrases.

---

### Task 0: Sanity check

**Files:** none.

- [ ] **Step 1: Verify branch is clean**

Run: `git status`
Expected: clean working tree on `main` (or a fresh feature branch). Stop here if there are uncommitted changes.

- [ ] **Step 2: Create the feature branch**

Run: `git checkout -b voice-chat-rag-context`
Expected: switched to new branch.

- [ ] **Step 3: Confirm test command works**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: 14 tests pass (the warm-session work merged).

---

### Task 1: Fix the vector-index naming bug

**Files:**
- Modify: `src/main/ipc/search.ts:35`
- Test: `src/main/ipc/__tests__/search.indexName.test.ts` (create)

The save side writes vectors with index name `${bookId}-vectordb` (`src/renderer/src/modules/process_epub.ts:76`). The search side reads from `book_${bookId}`. Always-empty results. Fix the search side to match the existing on-disk data (so users' already-indexed books work without re-indexing).

- [ ] **Step 1: Write a regression test**

Check if `src/main/ipc/__tests__/` exists:
```bash
ls src/main/ipc/__tests__/
```

Create `src/main/ipc/__tests__/search.indexName.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

const mockEmbedText = vi.fn().mockResolvedValue(new Float32Array([0.1, 0.2, 0.3]))
const mockSearchVectors = vi.fn().mockResolvedValue([])

vi.mock('../../vectordb/index.js', () => ({
  embedText: mockEmbedText,
  searchVectors: mockSearchVectors
}))

vi.mock('../../database/queries.js', () => ({
  searchBookText: vi.fn(),
  getTextFromVectorId: vi.fn()
}))

// Capture the contextForQuery handler when it's registered
let handler: ((event: unknown, q: string, b: number, k: number) => Promise<string[]>) | null = null

vi.mock('electron', () => ({
  ipcMain: {
    handle: vi.fn((channel: string, fn: never) => {
      if (channel === 'search:contextForQuery') {
        handler = fn as never
      }
    })
  }
}))

import { registerSearchHandlers } from '../search.js'

describe('search:contextForQuery index name', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    handler = null
    registerSearchHandlers()
  })

  it('searches the index named `{bookId}-vectordb` (matches process_epub.ts:76)', async () => {
    expect(handler).not.toBeNull()
    await handler!({}, 'what is this book about?', 42, 3)
    expect(mockSearchVectors).toHaveBeenCalledTimes(1)
    expect(mockSearchVectors.mock.calls[0][0]).toBe('42-vectordb')
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- --run src/main/ipc/__tests__/search.indexName.test.ts`
Expected: FAIL — asserts `mockSearchVectors` called with `'42-vectordb'` but actually called with `'book_42'`.

- [ ] **Step 3: Fix `search.ts`**

In `src/main/ipc/search.ts`, find line 34-35:

```ts
        // 2. Search vectors for the book's index (uses book_ prefix to match processJob)
        const indexName = `book_${bookId}`
```

Replace with:

```ts
        // 2. Search the vector index. Name must match the save-side name in
        // src/renderer/src/modules/process_epub.ts: `${bookId}-vectordb`.
        const indexName = `${bookId}-vectordb`
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- --run src/main/ipc/__tests__/search.indexName.test.ts`
Expected: PASS.

- [ ] **Step 5: Run full test suite to confirm no regression**

Run: `npm test -- --run`
Expected: all tests pass (337+1 from before + 1 new).

- [ ] **Step 6: Commit**

```bash
git add src/main/ipc/search.ts src/main/ipc/__tests__/search.indexName.test.ts
git commit -m "fix(search): align contextForQuery index name with save side"
```

---

### Task 2: Add `getBookOutline` SQL helper + IPC + renderer wrapper

**Files:**
- Modify: `src/main/database/queries.ts`
- Create: `src/main/database/__tests__/queries.outline.test.ts`
- Modify: `src/main/ipc/books.ts` or `books-extra.ts` (verify which in Step 1)
- Modify: `src/preload/index.ts`
- Modify: `src/renderer/src/lib/api.ts`

The outline is `{ title, author, chapters }`. `title` and `author` come from the `books` table. `chapters` is `SELECT DISTINCT chapter FROM chunk_data WHERE book_id = ? AND chapter IS NOT NULL AND chapter != '' GROUP BY chapter ORDER BY MIN(page_number)`.

- [ ] **Step 1: Verify which IPC file owns book metadata reads**

Run:
```bash
grep -n "ipcMain.handle.*books:" src/main/ipc/*.ts | head -20
```

Note the file (likely `books.ts` or `books-extra.ts`) and the handler-registration pattern.

- [ ] **Step 2: Write the failing SQL-helper test**

Create `src/main/database/__tests__/queries.outline.test.ts`:

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import Database from 'better-sqlite3'

function setupDb() {
  const sqlite = new Database(':memory:')
  sqlite.exec(`
    CREATE TABLE books (
      id INTEGER PRIMARY KEY,
      title TEXT NOT NULL,
      author TEXT
    );
    CREATE TABLE chunk_data (
      id INTEGER PRIMARY KEY,
      book_id INTEGER NOT NULL,
      page_number INTEGER NOT NULL,
      data TEXT NOT NULL,
      chapter TEXT
    );
  `)
  return sqlite
}

describe('getBookOutline', () => {
  let db: Database.Database

  beforeEach(() => {
    db = setupDb()
  })

  it('returns title, author, and ordered chapters', async () => {
    db.exec(`
      INSERT INTO books (id, title, author) VALUES (1, 'The Pragmatic Programmer', 'Hunt and Thomas');
      INSERT INTO chunk_data (book_id, page_number, data, chapter) VALUES
        (1, 1, 'foo', 'Introduction'),
        (1, 2, 'bar', 'Introduction'),
        (1, 3, 'baz', 'Chapter 1'),
        (1, 4, 'qux', 'Chapter 2'),
        (1, 5, 'quux', 'Chapter 2');
    `)
    const { _getBookOutlineWithDb } = await import('../queries.js')
    const outline = _getBookOutlineWithDb(db, 1)
    expect(outline.title).toBe('The Pragmatic Programmer')
    expect(outline.author).toBe('Hunt and Thomas')
    expect(outline.chapters).toEqual(['Introduction', 'Chapter 1', 'Chapter 2'])
  })

  it('excludes null/empty chapters', async () => {
    db.exec(`
      INSERT INTO books (id, title) VALUES (1, 'Book');
      INSERT INTO chunk_data (book_id, page_number, data, chapter) VALUES
        (1, 1, 'x', NULL),
        (1, 2, 'y', ''),
        (1, 3, 'z', 'Real Chapter');
    `)
    const { _getBookOutlineWithDb } = await import('../queries.js')
    const outline = _getBookOutlineWithDb(db, 1)
    expect(outline.chapters).toEqual(['Real Chapter'])
  })

  it('returns null author when missing', async () => {
    db.exec(`INSERT INTO books (id, title) VALUES (1, 'Anon Book');`)
    const { _getBookOutlineWithDb } = await import('../queries.js')
    const outline = _getBookOutlineWithDb(db, 1)
    expect(outline.author).toBeNull()
  })
})
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `npm test -- --run src/main/database/__tests__/queries.outline.test.ts`
Expected: FAIL with `_getBookOutlineWithDb is not a function` or similar.

- [ ] **Step 4: Implement `getBookOutline` in queries.ts**

Open `src/main/database/queries.ts`. Find an existing query function (e.g., `getBookById`) to see the established pattern for reading. Add at the end of the file:

```ts
export interface BookOutline {
  title: string
  author: string | null
  chapters: string[]
}

/**
 * Pure SQL helper exposed for unit testing without the global drizzle wrapper.
 * Use `getBookOutline(bookId)` from production code.
 */
export function _getBookOutlineWithDb(sqlite: import('better-sqlite3').Database, bookId: number): BookOutline {
  const bookRow = sqlite
    .prepare<[number], { title: string; author: string | null }>(
      'SELECT title, author FROM books WHERE id = ?'
    )
    .get(bookId)
  if (!bookRow) {
    return { title: '', author: null, chapters: [] }
  }
  const chapterRows = sqlite
    .prepare<[number], { chapter: string }>(
      `SELECT chapter FROM chunk_data
       WHERE book_id = ? AND chapter IS NOT NULL AND chapter != ''
       GROUP BY chapter
       ORDER BY MIN(page_number)`
    )
    .all(bookId)
  return {
    title: bookRow.title,
    author: bookRow.author ?? null,
    chapters: chapterRows.map((r) => r.chapter)
  }
}

export async function getBookOutline(bookId: number): Promise<BookOutline> {
  // `getDb()` is the project's existing accessor — find it earlier in this file
  // and reuse the pattern from other queries.
  const sqlite = getDb()
  return _getBookOutlineWithDb(sqlite, bookId)
}
```

If the file doesn't have a `getDb()` accessor, look for whatever the existing queries use (e.g., `db`, `database`) and follow that pattern instead. Adapt the line `const sqlite = getDb()` accordingly.

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test -- --run src/main/database/__tests__/queries.outline.test.ts`
Expected: PASS, 3 tests.

- [ ] **Step 6: Register the IPC handler**

Open the file identified in Step 1 (likely `src/main/ipc/books.ts` or `books-extra.ts`). Add a new handler matching the existing pattern:

```ts
import { getBookOutline } from '../database/queries.js'

// ...inside the registration function:
ipcMain.handle('books:getOutline', async (_event, bookId: number) => {
  try {
    return await getBookOutline(bookId)
  } catch (error) {
    throw new Error(
      `Failed to get book outline: ${error instanceof Error ? error.message : String(error)}`
    )
  }
})
```

If the file already has a function like `registerBooksHandlers`, add the handler inside that function. Otherwise follow whatever pattern is established.

- [ ] **Step 7: Expose to the renderer via preload**

In `src/preload/index.ts`, add to the `api` object (find the existing `getContextForQuery` line as reference):

```ts
getBookOutline: (bookId: number) =>
  ipcRenderer.invoke('books:getOutline', bookId),
```

- [ ] **Step 8: Add the typed renderer wrapper in `lib/api.ts`**

In `src/renderer/src/lib/api.ts`, find an existing wrapper function (e.g., `getBook`) as a template. Add at an appropriate spot near other book-reading helpers:

```ts
export interface BookOutline {
  title: string
  author: string | null
  chapters: string[]
}

export async function getBookOutline(bookId: number): Promise<BookOutline> {
  return api().getBookOutline(bookId)
}
```

You may also need to add `getBookOutline` to the TypeScript type for `window.api` — search for where `getContextForQuery` is typed (likely in a `*.d.ts` or interface in preload/index.ts) and add the same signature.

- [ ] **Step 9: Typecheck**

Run: `npm run typecheck`
Expected: no new errors.

- [ ] **Step 10: Commit**

```bash
git add src/main/database/queries.ts src/main/database/__tests__/queries.outline.test.ts src/main/ipc/books.ts src/main/ipc/books-extra.ts src/preload/index.ts src/renderer/src/lib/api.ts
git commit -m "feat(rag): add getBookOutline (title + author + chapter list) IPC"
```

(Adjust `git add` paths based on which IPC file you actually edited in Step 6.)

---

### Task 3: Cache outline in epubStore on book open

**Files:**
- Modify: `src/renderer/src/stores/epubStore.ts`

The outline should be available synchronously when `chatStore.startChat` runs. Pre-fetch it on book open via the existing bookId subscription.

- [ ] **Step 1: Add the outline state to epubStore**

In `src/renderer/src/stores/epubStore.ts`, find the existing state interface (around the top, with fields like `bookId`, `rendition`, etc.). Add:

```ts
bookOutline: BookOutline | null
setBookOutline: (outline: BookOutline | null) => void
```

Import the type at the top:

```ts
import { getBookOutline, type BookOutline } from '@/lib/api'
```

In the store initializer, set:

```ts
bookOutline: null,
setBookOutline: (bookOutline) => set({ bookOutline }),
```

(Add this near the existing `setBookId`/`setRendition` lines.)

- [ ] **Step 2: Wire the outline fetch into the existing bookId subscription**

Find the subscription block (currently around lines 224-240 of `epubStore.ts`):

```ts
  const unsubBookId = useEpubStore.subscribe(
    (state) => state.bookId,
    (bookId) => {
      if (bookId) prefetchRealtimeKey()
      else voiceChatService.dispose()
    }
  )
```

Replace with:

```ts
  const unsubBookId = useEpubStore.subscribe(
    (state) => state.bookId,
    (bookId) => {
      if (bookId) {
        prefetchRealtimeKey()
        // Fetch outline in background — best-effort, won't block voice chat start
        getBookOutline(Number(bookId))
          .then((outline) => useEpubStore.getState().setBookOutline(outline))
          .catch(() => {
            /* outline is best-effort; voice chat still works without it */
          })
      } else {
        useEpubStore.getState().setBookOutline(null)
        voiceChatService.dispose()
      }
    }
  )
```

- [ ] **Step 3: Run all renderer tests**

Run: `npm test -- --run src/renderer`
Expected: no regressions (337+ tests pass). The new field doesn't break anything because existing tests don't assert on it.

- [ ] **Step 4: Typecheck**

Run: `npm run typecheck`
Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/stores/epubStore.ts
git commit -m "feat(rag): cache book outline in epubStore on book open"
```

---

### Task 4: Inject outline into agent instructions

**Files:**
- Modify: `src/renderer/src/modules/buildRealtimeAgent.ts`
- Modify: `src/renderer/src/modules/buildRealtimeAgent.test.ts`

- [ ] **Step 1: Add the failing tests**

In `src/renderer/src/modules/buildRealtimeAgent.test.ts`, append to the existing `describe` block:

```ts
  it('embeds book title and author into instructions when outline is provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      outline: {
        title: 'The Pragmatic Programmer',
        author: 'Hunt and Thomas',
        chapters: ['Introduction', 'Chapter 1']
      },
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('The Pragmatic Programmer')
    expect(agent.instructions).toContain('Hunt and Thomas')
  })

  it('embeds the chapter list into instructions when outline is provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      outline: {
        title: 'Book',
        author: null,
        chapters: ['Foreword', 'Chapter 1: Beginnings', 'Chapter 2: Middles']
      },
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('Foreword')
    expect(agent.instructions).toContain('Chapter 1: Beginnings')
    expect(agent.instructions).toContain('Chapter 2: Middles')
  })

  it('omits the outline section when outline is not provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).not.toContain('## Book Outline')
  })

  it('handles outline with null author gracefully', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      outline: { title: 'Anon Book', author: null, chapters: [] },
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('Anon Book')
    expect(agent.instructions).not.toContain('null')
    expect(agent.instructions).not.toContain('undefined')
  })
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- --run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: 4 new tests FAIL with "expected to contain" assertion errors.

- [ ] **Step 3: Update `buildRealtimeAgent.ts` to accept and inject outline**

Open `src/renderer/src/modules/buildRealtimeAgent.ts`.

Add the import + extend the options interface (at the top, near `BuildAgentOptions`):

```ts
import type { BookOutline } from '@/lib/api'

export interface BuildAgentOptions {
  bookId: number
  pageText: string
  outline?: BookOutline
  onEndConversation: (reason: string) => void
}
```

Add a helper above the `INSTRUCTIONS_TEMPLATE` declaration:

```ts
function renderOutlineSection(outline: BookOutline | undefined): string {
  if (!outline) return ''
  const authorLine = outline.author ? `**Author:** ${outline.author}\n` : ''
  const chapterLines =
    outline.chapters.length > 0
      ? `**Chapters:**\n${outline.chapters.map((c) => `- ${c}`).join('\n')}\n`
      : ''
  return `## Book Outline
**Title:** ${outline.title}
${authorLine}${chapterLines}
Use this outline to orient the user across the book. If they ask about a specific chapter that isn't on their current page, you may use the bookContext tool to retrieve relevant passages from that chapter.

`
}
```

Change the `INSTRUCTIONS_TEMPLATE` signature and body. Find:

```ts
const INSTRUCTIONS_TEMPLATE = (pageText: string) => `## Role and Goal
```

Replace with:

```ts
const INSTRUCTIONS_TEMPLATE = (pageText: string, outline?: BookOutline) => `## Role and Goal
```

Then insert the outline-section call near the top of the template body. Find:

```ts
## Current Page Content
The user is currently looking at this page:
```

Insert before it:

```ts
${renderOutlineSection(outline)}## Current Page Content
The user is currently looking at this page:
```

(Note: no newline between `renderOutlineSection(outline)` and `## Current Page Content` — the helper already includes a trailing blank line when outline is present, and contributes nothing when absent.)

Finally, update the factory's `instructions:` line. Find:

```ts
    instructions: INSTRUCTIONS_TEMPLATE(pageText),
```

Change to:

```ts
    instructions: INSTRUCTIONS_TEMPLATE(pageText, outline),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npm test -- --run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: 9 tests pass (5 existing + 4 new).

- [ ] **Step 5: Typecheck**

Run: `npm run typecheck`
Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/modules/buildRealtimeAgent.ts src/renderer/src/modules/buildRealtimeAgent.test.ts
git commit -m "feat(voice-chat): inject book outline (title + author + chapters) into agent instructions"
```

---

### Task 5: Plumb outline through chatStore → voiceChatService

**Files:**
- Modify: `src/renderer/src/modules/voiceChatService.ts`
- Modify: `src/renderer/src/modules/voiceChatService.test.ts`
- Modify: `src/renderer/src/stores/chatStore.ts`
- Modify: `src/renderer/src/stores/chatStore.test.ts`

The signature change: `voiceChatService.activate(bookId, ctx)` where `ctx = { pageText, outline? }`. Store passes both from epubStore.

- [ ] **Step 1: Update the voiceChatService test call sites**

In `src/renderer/src/modules/voiceChatService.test.ts`, find every call to `voiceChatService.activate(<bookId>, '<text>')` and convert to `voiceChatService.activate(<bookId>, { pageText: '<text>' })`. There are roughly 6 such call sites (verify with `grep "voiceChatService.activate" voiceChatService.test.ts`). For example:

```ts
await voiceChatService.activate(1, 'fresh page text')
```

becomes:

```ts
await voiceChatService.activate(1, { pageText: 'fresh page text' })
```

Update every instance.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: FAIL — type errors / runtime errors because the service still expects a string.

- [ ] **Step 3: Update `voiceChatService.ts` signature**

Open `src/renderer/src/modules/voiceChatService.ts`. Add an import:

```ts
import type { BookOutline } from '@/lib/api'
```

Add a context type near the top (after the `VoiceChatState` type):

```ts
export interface VoiceChatContext {
  pageText: string
  outline?: BookOutline
}
```

Change the `activate` method signature:

```ts
async activate(bookId: number, ctx: VoiceChatContext): Promise<void> {
```

Inside the warm path, find:

```ts
        const newAgent = buildRealtimeAgent({
          bookId,
          pageText,
          onEndConversation: () => listeners.onEndedByAgent?.()
        })
```

Replace with:

```ts
        const newAgent = buildRealtimeAgent({
          bookId,
          pageText: ctx.pageText,
          outline: ctx.outline,
          onEndConversation: () => listeners.onEndedByAgent?.()
        })
```

Do the same for the cold path's `buildRealtimeAgent` call:

```ts
      const agent = buildRealtimeAgent({
        bookId,
        pageText: ctx.pageText,
        outline: ctx.outline,
        onEndConversation: () => listeners.onEndedByAgent?.()
      })
```

- [ ] **Step 4: Update chatStore to pass the outline**

Open `src/renderer/src/stores/chatStore.ts`. Find the `startChat` method, currently:

```ts
        startChat: (bookId: number) => {
          if (get()._isStarting) return
          const gen = get()._chatGeneration + 1
          set({ _chatGeneration: gen, _isStarting: true, chatStatus: 'connecting' })

          const pageText = usePlayerStore
            .getState()
            .currentParagraphs.map((p) => p.text)
            .join('\n')

          voiceChatService
            .activate(bookId, pageText)
            ...
```

Replace with:

```ts
        startChat: (bookId: number) => {
          if (get()._isStarting) return
          const gen = get()._chatGeneration + 1
          set({ _chatGeneration: gen, _isStarting: true, chatStatus: 'connecting' })

          const pageText = usePlayerStore
            .getState()
            .currentParagraphs.map((p) => p.text)
            .join('\n')
          const outline = useEpubStore.getState().bookOutline ?? undefined

          voiceChatService
            .activate(bookId, { pageText, outline })
            ...
```

Add the import at the top:

```ts
import { useEpubStore } from './epubStore'
```

- [ ] **Step 5: Update chatStore test**

In `src/renderer/src/stores/chatStore.test.ts`, find the test:

```ts
  it('startChat delegates to voiceChatService.activate', async () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().startChat(42)
    await Promise.resolve()
    expect(mockActivate).toHaveBeenCalledWith(42, expect.any(String))
  })
```

Change the assertion to:

```ts
    expect(mockActivate).toHaveBeenCalledWith(42, {
      pageText: expect.any(String),
      outline: undefined
    })
```

Add a `vi.mock` for `./epubStore` near the other vi.mock calls:

```ts
vi.mock('./epubStore', () => ({
  useEpubStore: { getState: () => ({ bookOutline: null }) }
}))
```

- [ ] **Step 6: Run all renderer tests**

Run: `npm test -- --run src/renderer`
Expected: all pass.

- [ ] **Step 7: Typecheck**

Run: `npm run typecheck`
Expected: no new errors.

- [ ] **Step 8: Commit**

```bash
git add src/renderer/src/modules/voiceChatService.ts src/renderer/src/modules/voiceChatService.test.ts src/renderer/src/stores/chatStore.ts src/renderer/src/stores/chatStore.test.ts
git commit -m "feat(voice-chat): plumb book outline from store to agent through voiceChatService"
```

---

### Task 6: Skip `updateAgent` on warm path when context is unchanged

**Files:**
- Modify: `src/renderer/src/modules/voiceChatService.ts`
- Modify: `src/renderer/src/modules/voiceChatService.test.ts`

- [ ] **Step 1: Add the failing tests**

In `voiceChatService.test.ts`, inside the existing `describe('voiceChatService', ...)` block, append:

```ts
  it('warm path skips updateAgent when context fingerprint is unchanged', async () => {
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose,
      updateAgent: mockUpdateAgent
    } as never, 1)

    // First warm activate establishes the fingerprint
    await voiceChatService.activate(1, { pageText: 'same text' })
    expect(mockUpdateAgent).toHaveBeenCalledTimes(1)

    // Deactivate then reactivate with identical context
    voiceChatService.deactivate()
    await voiceChatService.activate(1, { pageText: 'same text' })

    // updateAgent should NOT be called a second time — context is unchanged
    expect(mockUpdateAgent).toHaveBeenCalledTimes(1)
    // But mute(false) still fires
    expect(mockMute).toHaveBeenLastCalledWith(false)
  })

  it('warm path calls updateAgent when page text changes', async () => {
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose,
      updateAgent: mockUpdateAgent
    } as never, 1)

    await voiceChatService.activate(1, { pageText: 'page 1 text' })
    voiceChatService.deactivate()
    await voiceChatService.activate(1, { pageText: 'page 2 text' })

    expect(mockUpdateAgent).toHaveBeenCalledTimes(2)
  })
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: the first new test FAILS — `mockUpdateAgent` called 2 times, expected 1.

- [ ] **Step 3: Add the fingerprint logic**

In `src/renderer/src/modules/voiceChatService.ts`, add a module-level variable near the other state declarations:

```ts
let lastContextFingerprint: string | null = null
```

Add a helper just above the `voiceChatService` declaration:

```ts
function fingerprintContext(ctx: VoiceChatContext): string {
  return `${ctx.pageText}\n${JSON.stringify(ctx.outline ?? {})}`
}
```

In the warm-path branch of `activate`, find:

```ts
    if (session && currentBookId === bookId) {
      // Warm path: refresh agent with new page text, then unmute
      setState('connecting')
      try {
        const newAgent = buildRealtimeAgent({
          bookId,
          pageText: ctx.pageText,
          outline: ctx.outline,
          onEndConversation: () => listeners.onEndedByAgent?.()
        })
        await session.updateAgent(newAgent as never)
        session.mute(false)
```

Replace with:

```ts
    if (session && currentBookId === bookId) {
      // Warm path: refresh agent with new page text (if changed), then unmute
      setState('connecting')
      try {
        const fp = fingerprintContext(ctx)
        if (fp !== lastContextFingerprint) {
          const newAgent = buildRealtimeAgent({
            bookId,
            pageText: ctx.pageText,
            outline: ctx.outline,
            onEndConversation: () => listeners.onEndedByAgent?.()
          })
          await session.updateAgent(newAgent as never)
          lastContextFingerprint = fp
        }
        session.mute(false)
```

In the cold path, after a successful connect, set the fingerprint. Find:

```ts
      session = newSession
      currentBookId = bookId
      if (audioElement) audioElement.muted = false
      newSession.mute(false)
      setState('active')
      listeners.onChatStatusChange?.('idle')
```

Replace with:

```ts
      session = newSession
      currentBookId = bookId
      lastContextFingerprint = fingerprintContext(ctx)
      if (audioElement) audioElement.muted = false
      newSession.mute(false)
      setState('active')
      listeners.onChatStatusChange?.('idle')
```

In `dispose()`, near the existing flag resets, add:

```ts
    hasFiredReadyChime = false
    isAgentSpeaking = false
    lastContextFingerprint = null
```

In `_resetForTests`, also reset the fingerprint:

```ts
  _resetForTests() {
    ...existing resets...
    lastContextFingerprint = null
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: all tests pass (16+ existing + 2 new).

- [ ] **Step 5: Typecheck**

Run: `npm run typecheck`
Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/modules/voiceChatService.ts src/renderer/src/modules/voiceChatService.test.ts
git commit -m "perf(voice-chat): skip updateAgent on warm activate when context unchanged"
```

---

### Task 7: Pre-connect WebRTC on book open after first voice use

**Files:**
- Modify: `src/renderer/src/modules/voiceChatService.ts`
- Modify: `src/renderer/src/modules/voiceChatService.test.ts`
- Modify: `src/renderer/src/stores/epubStore.ts`

The pattern: track `hasUsedVoiceInSession` inside the service. Set to `true` after the first successful cold-path activate. Expose a `preconnect(bookId, ctx)` method that runs the cold path and immediately mutes (leaving state in `'paused'`). epubStore calls it after the outline fetch resolves.

- [ ] **Step 1: Add the failing test**

In `voiceChatService.test.ts`, inside the cold-path describe block, append:

```ts
  it('preconnect runs the cold path and leaves the session muted in paused state', async () => {
    // Simulate that voice has been used this session
    await voiceChatService.activate(7, { pageText: 'first activation' })
    voiceChatService.dispose()

    // Now preconnect — hasUsedVoiceInSession should be true
    await voiceChatService.preconnect(8, { pageText: 'preconnect text' })
    expect(mockConnect).toHaveBeenCalled()
    expect(mockMute).toHaveBeenLastCalledWith(true)
    expect(voiceChatService.getState()).toBe('paused')
  })

  it('preconnect is a no-op when hasUsedVoiceInSession is false', async () => {
    voiceChatService._resetForTests()
    // hasUsedVoiceInSession defaults to false after reset
    await voiceChatService.preconnect(7, { pageText: 'x' })
    expect(mockConnect).not.toHaveBeenCalled()
    expect(voiceChatService.getState()).toBe('idle')
  })

  it('first successful cold activate sets hasUsedVoiceInSession', async () => {
    voiceChatService._resetForTests()
    expect(voiceChatService._hasUsedVoiceInSession()).toBe(false)
    await voiceChatService.activate(7, { pageText: 'x' })
    expect(voiceChatService._hasUsedVoiceInSession()).toBe(true)
  })
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: FAIL — `preconnect` and `_hasUsedVoiceInSession` not defined.

- [ ] **Step 3: Implement `preconnect` and the flag**

In `voiceChatService.ts`, add a module-level flag near the other state:

```ts
let hasUsedVoiceInSession = false
```

In the cold path, AFTER `listeners.onChatStatusChange?.('idle')`, add:

```ts
      hasUsedVoiceInSession = true
```

Add a new method to the `voiceChatService` object. Insert after `prewarmKey`:

```ts
  /**
   * Pre-warm the WebRTC connection in the background after the user has used voice chat
   * at least once this session. Saves ~600-1500ms on first activation in subsequent books.
   * No-op if the user hasn't used voice yet — we don't want to burn the WebRTC handshake
   * for users who never use voice.
   */
  async preconnect(bookId: number, ctx: VoiceChatContext): Promise<void> {
    if (!hasUsedVoiceInSession) return
    if (session && currentBookId === bookId) return // Already connected to this book
    try {
      await this.activate(bookId, ctx)
      // Immediately mute — the session is hot but the user hasn't clicked yet
      if (session) {
        session.interrupt()
        session.mute(true)
        if (audioElement) audioElement.muted = true
        setState('paused')
      }
    } catch (err) {
      captureError(err, { operation: 'voiceChatService', step: 'preconnect' })
      // Swallow — preconnect is best-effort
    }
  },
```

Add the test hook to the test-hook section:

```ts
  _hasUsedVoiceInSession() {
    return hasUsedVoiceInSession
  },
```

Reset the flag in `_resetForTests`:

```ts
  _resetForTests() {
    ...existing resets...
    hasUsedVoiceInSession = false
  }
```

Do NOT reset `hasUsedVoiceInSession` in `dispose()` — it's intentionally a session-lifetime flag.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- --run src/renderer/src/modules/voiceChatService.test.ts`
Expected: all tests pass.

- [ ] **Step 5: Wire preconnect into epubStore**

In `src/renderer/src/stores/epubStore.ts`, find the subscription that fetches the outline (from Task 3). Update it to trigger preconnect after outline arrives:

```ts
  const unsubBookId = useEpubStore.subscribe(
    (state) => state.bookId,
    (bookId) => {
      if (bookId) {
        prefetchRealtimeKey()
        getBookOutline(Number(bookId))
          .then((outline) => {
            useEpubStore.getState().setBookOutline(outline)
            // Pre-connect in the background. Service is a no-op if voice
            // chat hasn't been used yet this session.
            const pageText = usePlayerStore
              .getState()
              .currentParagraphs.map((p) => p.text)
              .join('\n')
            void voiceChatService.preconnect(Number(bookId), { pageText, outline })
          })
          .catch(() => {
            /* outline is best-effort; voice chat still works without it */
          })
      } else {
        useEpubStore.getState().setBookOutline(null)
        voiceChatService.dispose()
      }
    }
  )
```

Add the `usePlayerStore` import at the top if not already present:

```ts
import { usePlayerStore } from './playerStore'
```

- [ ] **Step 6: Run all renderer tests**

Run: `npm test -- --run src/renderer`
Expected: all pass.

- [ ] **Step 7: Typecheck**

Run: `npm run typecheck`
Expected: no new errors.

- [ ] **Step 8: Commit**

```bash
git add src/renderer/src/modules/voiceChatService.ts src/renderer/src/modules/voiceChatService.test.ts src/renderer/src/stores/epubStore.ts
git commit -m "perf(voice-chat): preconnect WebRTC on book open after first voice use"
```

---

### Task 8: Trim the agent instructions

**Files:**
- Modify: `src/renderer/src/modules/buildRealtimeAgent.ts`

The current `INSTRUCTIONS_TEMPLATE` is ~120 lines of prose. With the new outline section added in Task 4, total instructions are larger. Trim ~40% off the prose, keeping the structural rules and tool guidelines but removing redundant example phrases.

- [ ] **Step 1: Replace the verbose sections with a trimmed version**

In `src/renderer/src/modules/buildRealtimeAgent.ts`, replace the entire `INSTRUCTIONS_TEMPLATE` body with:

```ts
const INSTRUCTIONS_TEMPLATE = (pageText: string, outline?: BookOutline) => `## Role
You are a teaching assistant helping the user understand the book they're reading. Make complex ideas accessible and answer questions in a way that aids comprehension.

${renderOutlineSection(outline)}## Current Page Content
"""
${pageText || '(No page text available)'}
"""
If the question is answerable from this page, answer directly. Use the bookContext tool only for content outside this page.

## Rules
- Vary phrasing — never repeat the same sentence verbatim in a single response.
- Stay conversational; avoid scripted-sounding language.
- Before calling a tool, say one short line previewing what you're doing (5-12 words).
- Stay focused on the book, but allow natural chat flow.

## Tools

### bookContext
For content NOT visible on the current page. Provide a brief preamble before calling. Do not call if the answer is already in the current page text.

### endConversation
When the user clearly signals they're done (e.g., "thanks, that's all", "goodbye"), respond with a warm closing and call this tool. If the signal is ambiguous, confirm first. Provide a clear \`reason\` describing why the conversation is ending.

## Style notes
- First message: if the user asks a question, answer it directly. If they greet, respond briefly and ask how you can help.
- When explaining concepts, break down complexity and use analogies. Briefly check understanding before moving on.
- Keep responses concise unless depth is requested.`
```

- [ ] **Step 2: Run buildRealtimeAgent tests**

Run: `npm test -- --run src/renderer/src/modules/buildRealtimeAgent.test.ts`
Expected: all 9 tests pass. The existing tests check for page text + outline presence — those structural assertions still hold after the trim.

- [ ] **Step 3: Run full renderer test suite**

Run: `npm test -- --run src/renderer`
Expected: all pass.

- [ ] **Step 4: Typecheck**

Run: `npm run typecheck`
Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/modules/buildRealtimeAgent.ts
git commit -m "refactor(voice-chat): trim agent instructions; rely on outline for structure"
```

---

### Task 9: Manual verification in the running app

**Goal:** Confirm RAG is unbroken and the agent uses outline context.

- [ ] **Step 1: Start the dev app**

Run: `npm run dev`

- [ ] **Step 2: Open a book with multiple chapters**

Choose a book the user has indexed already (or import a fresh EPUB and wait for indexing to complete).

- [ ] **Step 3: Open DevTools and confirm outline is fetched**

In DevTools console, after the book opens:

```js
window.useEpubStore?.getState?.().bookOutline
```

Or inspect the store via the Zustand devtools panel. Expected: `{ title: ..., author: ..., chapters: [...] }` populated within ~500ms of opening.

- [ ] **Step 4: Test the bookContext tool actually returns content**

Start voice chat. Ask the agent: "What does the second chapter say about [topic in the book]?". The agent should call `bookContext` and return non-empty context. If it still returns "Unable to retrieve...", the index name fix didn't take effect — investigate.

- [ ] **Step 5: Test the agent knows the chapter structure**

Ask: "What chapters are in this book?". The agent should list them without using `bookContext` (the outline is baked into the system prompt).

- [ ] **Step 6: Test the warm-path skip**

Toggle voice off, then back on without turning the page. In DevTools, you should NOT see a `session.update` message in the network panel. If you do, the fingerprint comparison is failing — investigate.

- [ ] **Step 7: Test the preconnect**

Open book A, start voice chat once. Toggle off. Back-button to library. Open book B. Wait ~1 second for the outline to load. Then tap voice chat. First activation in book B should feel near-instant (<300 ms perceived) because preconnect ran in the background.

- [ ] **Step 8: Commit any tweaks**

If anything was broken, fix and add tests:

```bash
git add -p
git commit -m "fix(voice-chat): <specific fix>"
```

---

### Task 10: Final validation + branch finish

- [ ] **Step 1: Run full lint + typecheck + tests**

```bash
npm run lint && npm run typecheck && npm test -- --run
```

Expected: 0 new lint errors. 0 new typecheck errors (pre-existing ones in `src/main/ipc/books.ts`, `chunks.ts`, `embeddings.ts` may remain). All tests pass.

- [ ] **Step 2: Confirm diff is scoped to planned files**

```bash
git diff main --stat
```

Expected files:
- `src/main/ipc/search.ts`
- `src/main/ipc/__tests__/search.indexName.test.ts` (new)
- `src/main/database/queries.ts`
- `src/main/database/__tests__/queries.outline.test.ts` (new)
- `src/main/ipc/books.ts` or `books-extra.ts` (one of them)
- `src/preload/index.ts`
- `src/renderer/src/lib/api.ts`
- `src/renderer/src/stores/epubStore.ts`
- `src/renderer/src/stores/chatStore.ts`
- `src/renderer/src/stores/chatStore.test.ts`
- `src/renderer/src/modules/buildRealtimeAgent.ts`
- `src/renderer/src/modules/buildRealtimeAgent.test.ts`
- `src/renderer/src/modules/voiceChatService.ts`
- `src/renderer/src/modules/voiceChatService.test.ts`
- `docs/superpowers/plans/2026-05-10-voice-chat-rag-and-context.md` (this plan)

No unexpected files. If you see other modifications, investigate.

- [ ] **Step 3: Stop here — do not push or merge without explicit instruction**

---

## Risks & Polish (deferred)

These are noted for future work, not part of this plan:

1. **Current-chapter detection**: requires plumbing renderer "current paragraph" → `chunk_data.page_number`. ParagraphWithIndex doesn't carry chapter today. A follow-up plan could add `chapter` to `ParagraphWithIndex` and inject "current chapter" into instructions.
2. **Embedding-dimension mismatch on server fallback**: on-device embeddings are 384-dim, server fallback is 1536-dim. If on-device fails and fallback fires, vectors don't fit the index. Out of scope here; tracked in the original mapping report.
3. **Indexing visibility**: no UI surface tells the user "indexing in progress" or "indexing complete". Would be useful for users who notice the chat works on already-indexed books but not freshly imported ones.
4. **Outline caching**: outline is re-fetched on every book open. The query is cheap (~5 ms), so not worth caching — but if it grows (e.g., includes per-chapter summaries), consider memoization.
5. **Preconnect cost**: pre-connecting opens a WebRTC + OpenAI session, which has small per-connection overhead even if no audio is sent. If users open many books without using voice, this wastes some OpenAI session-creation calls. The `hasUsedVoiceInSession` gate mitigates this, but a per-app-session counter (cap at N preconnects) would tighten it further.
