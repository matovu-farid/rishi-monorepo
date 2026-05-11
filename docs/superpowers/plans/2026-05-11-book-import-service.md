# Book Import service refactor — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the scattered book-import flow (`FileComponent` orchestration + `BookDiscoveryModal` scan handling + `process_epub.ts` indexing + `embed-fallback.ts` helper + the loose IPC wrappers in `lib/api.ts`) into a single deep `services/book-import/` module with a typed factory boundary and injected ports for `formats` / `db` / `fs` / `rag` / `embed` / `scanner` / `config`.

**Architecture:** One factory `createBookImportService(deps: BookImportServiceDeps)`. Dependencies injected at the boundary. Format dispatch (extension → IPC call) lives inside the service. The just-shipped `RagService` is consumed via the `rag` port. Embedding fallback (on-device → server) stays in `embed-fallback.ts` as a helper consumed via the `embed` port. Scanner IPC event subscription is wrapped behind a `scanner` port. Status + per-file progress + discovery events use the typed `Emitter<T>` pattern from TTS/Sync (subscribe returns unsubscribe).

**Tech Stack:** TypeScript, vitest, Electron IPC (via injected ports).

---

## Plan overview

- **Task 0 — Worktree + scaffold + spec/plan commit:** Worktree at `/tmp/rishi-book-import-refactor` already exists on branch `refactor/book-import-service`. Copy the spec + this plan in (they live only on the orchestrator's main), commit them, then scaffold the empty `services/book-import/` directory with placeholder `index.ts`.
- **Tasks 1–8 — Build the service (TDD):** Types → emitter helper → format dispatch → indexer → importer → scanner adapter → service factory → public exports. Each behavior gets its own RED → GREEN → COMMIT cycle.
- **Tasks 9–12 — Wire & migrate callers:** Add `getBookImportService()` to `services/index.ts`, then migrate `FileComponent`, `BookDiscoveryModal`, `MobiView`, `DjvuView`, and `epubStore`.
- **Task 13 — Delete legacy modules:** `git rm` for `process_epub.ts` and its test. Keep `embed-fallback.ts` and `modules/books.ts` and `modules/file-sync.ts` (consumed via ports).
- **Task 14 — Final verification.** `pnpm typecheck`, `pnpm lint`, `pnpm vitest run`.

All paths below are absolute from `/tmp/rishi-book-import-refactor` (the worktree root). All `pnpm` commands should be run from `/tmp/rishi-book-import-refactor/apps/rishi-electron` unless otherwise stated. All `git` commands should be run from `/tmp/rishi-book-import-refactor`.

---

## Task 0: Worktree + branch + spec/plan commit + scaffold

**Files:**
- Copy: `docs/superpowers/specs/2026-05-11-book-import-service-design.md` from orchestrator main
- Copy: `docs/superpowers/plans/2026-05-11-book-import-service.md` (this file) from orchestrator main
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/index.ts` (placeholder)

- [ ] **Step 1: Confirm the worktree exists and is on the expected branch**

```bash
cd /tmp/rishi-book-import-refactor
git status -sb
```

Expected output starts with `## refactor/book-import-service` and the tree is clean. If the worktree is missing, ask the orchestrator to create it via `git worktree add /tmp/rishi-book-import-refactor -b refactor/book-import-service origin/main`.

- [ ] **Step 2: Copy the spec and plan into the worktree**

The spec and this plan live on the orchestrator's local `main` and are not yet on `origin/main`, so the fresh worktree won't have them. Copy them across:

```bash
mkdir -p /tmp/rishi-book-import-refactor/docs/superpowers/specs
mkdir -p /tmp/rishi-book-import-refactor/docs/superpowers/plans
cp /Users/faridmatovu/projects/rishi-monorepo/docs/superpowers/specs/2026-05-11-book-import-service-design.md \
   /tmp/rishi-book-import-refactor/docs/superpowers/specs/
cp /Users/faridmatovu/projects/rishi-monorepo/docs/superpowers/plans/2026-05-11-book-import-service.md \
   /tmp/rishi-book-import-refactor/docs/superpowers/plans/
```

- [ ] **Step 3: Commit the spec + plan**

```bash
cd /tmp/rishi-book-import-refactor
git add docs/superpowers/specs/2026-05-11-book-import-service-design.md \
        docs/superpowers/plans/2026-05-11-book-import-service.md
git commit -m "docs(book-import): add design spec and implementation plan

Wave 2 service 1 of 2. Spec defines the boundary, the 8-port dependency
shape (formats / db / fs / fileSync / rag / embed / scanner / config),
the 17 boundary test scenarios, and the migration of 5 callers
(FileComponent, BookDiscoveryModal, MobiView, DjvuView, epubStore)."
```

- [ ] **Step 4: Create the empty service directory with a placeholder `index.ts`**

```bash
mkdir -p /tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import
```

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/index.ts`:

```ts
// Placeholder — populated incrementally by subsequent tasks.
export {}
```

- [ ] **Step 5: Verify typecheck still passes**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes. (Pre-existing typecheck noise in `src/main/**` and `stores/navStore.test.ts` is out of scope — see Task 14.)

- [ ] **Step 6: Commit the scaffold**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/index.ts
git commit -m "refactor(book-import): scaffold services/book-import directory

Empty index.ts placeholder. Behavior added incrementally in subsequent
commits (TDD: red -> green -> commit per behavior)."
```

---

## Task 1: Type definitions (`types.ts`)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/types.ts`

- [ ] **Step 1: Create `types.ts` with the full public + port type surface**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/types.ts`:

```ts
import type {
  BookInsertable,
  Book,
  ChunkDataInsertable,
  PageData,
  Vector,
  EmbedParam,
  EmbedResult
} from '@/lib/api'
import type { RagService } from '../rag'

/** Five supported file extensions, normalized to lowercase. */
export type BookFormat = 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'

/** What a format port returns after parsing. Shape from `@/lib/api`. */
export interface BookDataParsed {
  kind: string
  cover: number[]
  title?: string | null
  author?: string | null
  publisher?: string | null
  coverKind?: string | null
}

/** A single chunk of indexed page data passed into `indexBook`. */
export interface PageDataInsertable {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

export interface ImportSuccess {
  ok: true
  bookId: number
  filePath: string
  format: BookFormat
}

export interface ImportFailure {
  ok: false
  filePath: string
  /** Which stage failed. */
  stage: 'unsupported' | 'copy' | 'parse' | 'save' | 'unknown'
  error: string
}

export type ImportResult = ImportSuccess | ImportFailure

/** Per-file pipeline lifecycle event. */
export type ImportProgressEvent =
  | { kind: 'copying'; filePath: string }
  | { kind: 'parsing'; filePath: string; format: BookFormat }
  | { kind: 'saving'; filePath: string; format: BookFormat }
  | { kind: 'upload-started'; filePath: string; bookId: number }
  | { kind: 'upload-failed'; filePath: string; bookId: number; error: string }
  | { kind: 'indexing'; bookId: number; reason: 'chunks-missing' | 'vectors-missing' }
  | { kind: 'done'; filePath: string; bookId: number; format: BookFormat }
  | { kind: 'failed'; filePath: string; stage: ImportFailure['stage']; error: string }

/** Discovered-book record streamed by the scanner port. */
export interface DiscoveredBook {
  filepath: string
  filename: string
  title: string | null
  author: string | null
  format: string
  fileSize: number
  folder: string
  fileHash: string | null
}

export interface ScanProgress {
  folder: string
  scanned: number
  total: number
}

export type DiscoveryEvent =
  | { kind: 'book-found'; book: DiscoveredBook }
  | { kind: 'progress'; progress: ScanProgress }
  | { kind: 'complete'; cancelled: boolean }
  | { kind: 'error'; error: string }

/** Exactly the four format IPCs the service uses. */
export interface FormatsIpc {
  getBookData(path: string): Promise<BookDataParsed>
  getPdfData(path: string): Promise<BookDataParsed>
  getMobiData(path: string): Promise<BookDataParsed>
  getDjvuData(path: string): Promise<BookDataParsed>
}

/** Exactly the five DB IPCs the service uses. */
export interface BookStoreIpc {
  saveBook(book: BookInsertable): Promise<Book>
  savePageDataMany(pageData: ChunkDataInsertable[]): Promise<void>
  getAllPageDataByBookId(bookId: number): Promise<PageData[]>
  hasSavedEpubData(bookId: number): Promise<boolean>
  saveVectors(name: string, dim: number, vectors: Vector[]): Promise<void>
}

/** Exactly the six FS IPCs the service uses. */
export interface FsIpc {
  copyBookToAppData(filePath: string): Promise<string>
  removeFile(path: string): Promise<void>
  getAppDataPath(): Promise<string>
}

/** File-hash + R2 upload helpers. Best-effort consumers. */
export interface FileSyncIpc {
  hashBookFile(filePath: string): Promise<string>
  uploadBookFile(
    filePath: string,
    hash: string,
    format: 'epub' | 'pdf' | 'mobi' | 'djvu'
  ): Promise<{ r2Key: string }>
  booksUpdateFileHash(bookId: number, hash: string, r2Key: string): Promise<void>
}

/** Scanner port — wraps `window.electron.scanForBooks` + the three IPC events. */
export interface ScannerPort {
  start(mode: 'default' | 'full'): Promise<void>
  cancel(): Promise<void>
  on(kind: 'result', listener: (book: DiscoveredBook) => void): () => void
  on(kind: 'progress', listener: (progress: ScanProgress) => void): () => void
  on(kind: 'complete', listener: () => void): () => void
}

export interface BookImportConfig {
  /** Per-stage timeouts. Defaults match today: 120_000 / 60_000 / 30_000 ms. */
  copyTimeoutMs: number
  parseTimeoutMs: number
  saveTimeoutMs: number
  /** Embedding batch size. Default 2. */
  embedBatchSize: number
}

export interface BookImportServiceDeps {
  formats: FormatsIpc
  db: BookStoreIpc
  fs: FsIpc
  fileSync: FileSyncIpc
  rag: RagService
  embed: (params: EmbedParam[]) => Promise<EmbedResult[]>
  scanner: ScannerPort
  config: BookImportConfig
}

export interface BookImportService {
  /**
   * Single-file import: copy -> parse (by extension) -> save -> fire-and-forget
   * hash+upload -> emit done. Resolves with discriminated `ImportResult`; does
   * not reject for classified failures.
   */
  importFromPath(filePath: string): Promise<ImportResult>

  /**
   * Sequential bulk import. Each file processed via `importFromPath`; failures
   * isolated per item; results returned in input order. Never rejects.
   */
  importBatch(filePaths: string[]): Promise<ImportResult[]>

  /**
   * Run RAG indexing for a book. Skips if both chunks and vectors exist.
   * Re-embeds if chunks exist but vectors missing. If `pageData` omitted, reads
   * chunks from the DB via `db.getAllPageDataByBookId`.
   */
  indexBook(bookId: number, pageData?: PageDataInsertable[]): Promise<void>

  /**
   * Start the scanner. Calling while a scan is running cancels the prior scan
   * first (single-flight). Results stream via `onDiscoveryEvent`.
   */
  startDiscovery(mode: 'default' | 'full'): void

  /**
   * Abort the running scan. Idempotent. Emits `{ kind: 'complete', cancelled: true }`.
   */
  cancelDiscovery(): Promise<void>

  onDiscoveryEvent(listener: (event: DiscoveryEvent) => void): () => void
  onImportProgress(listener: (event: ImportProgressEvent) => void): () => void
}
```

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes (types only — no behavior).

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/types.ts
git commit -m "refactor(book-import): add public type surface and port interfaces

Discriminated ImportResult union centralizes per-stage error
classification. Eight ports (formats / db / fs / fileSync / rag / embed
/ scanner / config) push every transitive dependency to the wiring
site. BookFormat covers all five extensions today."
```

---

## Task 2: Emitter helper (`emitter.ts`)

The book-import service uses the same tiny typed-emitter primitive as TTS and Sync. Per the spec's open question #4, we duplicate (not import) so services stay independent.

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/emitter.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/emitter.ts`

- [ ] **Step 1: Write the failing test (RED)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/emitter.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createEmitter } from './emitter'

describe('createEmitter', () => {
  it('delivers emitted values to a subscribed listener', () => {
    const e = createEmitter<{ value: number }>()
    const listener = vi.fn()
    e.on(listener)

    e.emit({ value: 42 })

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith({ value: 42 })
  })

  it('fans an emit out to every subscriber', () => {
    const e = createEmitter<string>()
    const a = vi.fn()
    const b = vi.fn()
    e.on(a)
    e.on(b)

    e.emit('hello')

    expect(a).toHaveBeenCalledWith('hello')
    expect(b).toHaveBeenCalledWith('hello')
  })

  it('returns an unsubscribe function that removes the listener', () => {
    const e = createEmitter<number>()
    const listener = vi.fn()
    const unsubscribe = e.on(listener)

    e.emit(1)
    unsubscribe()
    e.emit(2)

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith(1)
  })
})
```

- [ ] **Step 2: Run — expect RED**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/book-import/emitter.test.ts
```

Expected: 3 tests fail with `Cannot find module './emitter'`.

- [ ] **Step 3: Implement `createEmitter` (GREEN)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/emitter.ts`:

```ts
/**
 * Tiny typed emitter — no event names, single payload type T.
 * `on(listener)` returns an unsubscribe function (idempotent).
 *
 * Duplicated from services/tts/emitter.ts and services/sync/emitter.ts per
 * the spec's Open Question 4 (services should not depend on each other's
 * internals). If a fourth service wants the same primitive, lift to
 * services/_shared/emitter.ts.
 */
export interface Emitter<T> {
  emit(payload: T): void
  on(listener: (payload: T) => void): () => void
}

export function createEmitter<T>(): Emitter<T> {
  const listeners = new Set<(payload: T) => void>()
  return {
    emit(payload) {
      for (const listener of listeners) listener(payload)
    },
    on(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}
```

- [ ] **Step 4: Run — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/emitter.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/emitter.ts \
        apps/rishi-electron/src/renderer/src/services/book-import/emitter.test.ts
git commit -m "test(book-import): typed Emitter helper with unsubscribe returns

Tiny utility (~15 LOC). Duplicates services/tts/emitter.ts and
services/sync/emitter.ts deliberately so services stay independent."
```

---

## Task 3: Format dispatch (`dispatch.ts`)

Internal module. Maps file extension to the right `FormatsIpc` method. Returns the parsed `BookDataParsed` plus the normalized `BookFormat`. Throws `UnsupportedFormatError` for unknown extensions.

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/dispatch.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/dispatch.ts`

- [ ] **Step 1: Write the test helpers + first failing test (`.epub` → `getBookData`)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/dispatch.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import type { FormatsIpc, BookDataParsed } from './types'
import { dispatchFormatExtraction, UnsupportedFormatError } from './dispatch'

const sampleParsed: BookDataParsed = {
  kind: 'epub',
  cover: [],
  title: 'Sample',
  author: 'Author',
  publisher: 'Pub',
  coverKind: 'image/png'
}

export function makeFormats(opts?: {
  epubReturns?: BookDataParsed
  pdfReturns?: BookDataParsed
  mobiReturns?: BookDataParsed
  djvuReturns?: BookDataParsed
}): { formats: FormatsIpc; calls: Array<{ method: keyof FormatsIpc; path: string }> } {
  const calls: Array<{ method: keyof FormatsIpc; path: string }> = []
  const formats: FormatsIpc = {
    getBookData: vi.fn(async (path: string) => {
      calls.push({ method: 'getBookData', path })
      return opts?.epubReturns ?? sampleParsed
    }),
    getPdfData: vi.fn(async (path: string) => {
      calls.push({ method: 'getPdfData', path })
      return opts?.pdfReturns ?? { ...sampleParsed, kind: 'pdf' }
    }),
    getMobiData: vi.fn(async (path: string) => {
      calls.push({ method: 'getMobiData', path })
      return opts?.mobiReturns ?? { ...sampleParsed, kind: 'mobi' }
    }),
    getDjvuData: vi.fn(async (path: string) => {
      calls.push({ method: 'getDjvuData', path })
      return opts?.djvuReturns ?? { ...sampleParsed, kind: 'djvu' }
    })
  }
  return { formats, calls }
}

describe('dispatchFormatExtraction', () => {
  it('routes .epub to formats.getBookData and returns the parsed data + format', async () => {
    const { formats, calls } = makeFormats()

    const result = await dispatchFormatExtraction(formats, '/userData/book.epub')

    expect(result.format).toBe('epub')
    expect(result.data.kind).toBe('epub')
    expect(calls).toEqual([{ method: 'getBookData', path: '/userData/book.epub' }])
  })
})
```

- [ ] **Step 2: Run — expect RED**

```bash
pnpm vitest run src/renderer/src/services/book-import/dispatch.test.ts
```

Expected: 1 test fails — `Cannot find module './dispatch'`.

- [ ] **Step 3: Implement `dispatchFormatExtraction` (GREEN)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/dispatch.ts`:

```ts
import type { BookDataParsed, BookFormat, FormatsIpc } from './types'

export class UnsupportedFormatError extends Error {
  readonly extension: string
  constructor(extension: string) {
    super(`Unsupported format: .${extension}`)
    this.extension = extension
    this.name = 'UnsupportedFormatError'
  }
}

/** Resolve the lowercase extension (no leading dot) from a file path. */
export function extOf(filePath: string): string {
  return filePath.split('.').pop()?.toLowerCase() ?? ''
}

/** Map a normalized extension to the BookFormat tag, or null if unsupported. */
export function formatFor(extension: string): BookFormat | null {
  switch (extension) {
    case 'epub':
      return 'epub'
    case 'pdf':
      return 'pdf'
    case 'mobi':
      return 'mobi'
    case 'azw3':
      return 'azw3'
    case 'djvu':
      return 'djvu'
    default:
      return null
  }
}

export interface DispatchResult {
  format: BookFormat
  data: BookDataParsed
}

/**
 * Internal dispatcher: pick the right `FormatsIpc` method by extension and
 * return the parsed shape plus the normalized format tag. Throws
 * `UnsupportedFormatError` for unknown extensions.
 */
export async function dispatchFormatExtraction(
  formats: FormatsIpc,
  filePath: string
): Promise<DispatchResult> {
  const extension = extOf(filePath)
  const format = formatFor(extension)
  if (format === null) throw new UnsupportedFormatError(extension)

  if (format === 'epub') return { format, data: await formats.getBookData(filePath) }
  if (format === 'pdf') return { format, data: await formats.getPdfData(filePath) }
  if (format === 'mobi' || format === 'azw3')
    return { format, data: await formats.getMobiData(filePath) }
  // format === 'djvu'
  return { format, data: await formats.getDjvuData(filePath) }
}
```

- [ ] **Step 4: Run — expect 1 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/dispatch.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/dispatch.ts \
        apps/rishi-electron/src/renderer/src/services/book-import/dispatch.test.ts
git commit -m "test(book-import): dispatch .epub via formats.getBookData

Internal dispatch module: extOf + formatFor + dispatchFormatExtraction.
Throws UnsupportedFormatError for unknown extensions. .epub branch
covered; remaining four extensions added in follow-up commits."
```

- [ ] **Step 6: Add tests for `.pdf` / `.mobi` / `.azw3` / `.djvu` / unsupported (test-only commit)**

Append to `dispatch.test.ts`:

```ts
describe('dispatchFormatExtraction — extension routing', () => {
  it('routes .pdf to formats.getPdfData', async () => {
    const { formats, calls } = makeFormats()
    const result = await dispatchFormatExtraction(formats, '/tmp/book.pdf')
    expect(result.format).toBe('pdf')
    expect(calls).toEqual([{ method: 'getPdfData', path: '/tmp/book.pdf' }])
  })

  it('routes .mobi to formats.getMobiData', async () => {
    const { formats, calls } = makeFormats()
    const result = await dispatchFormatExtraction(formats, '/tmp/book.mobi')
    expect(result.format).toBe('mobi')
    expect(calls).toEqual([{ method: 'getMobiData', path: '/tmp/book.mobi' }])
  })

  it('routes .azw3 to formats.getMobiData (today behavior)', async () => {
    const { formats, calls } = makeFormats()
    const result = await dispatchFormatExtraction(formats, '/tmp/book.azw3')
    expect(result.format).toBe('azw3')
    expect(calls).toEqual([{ method: 'getMobiData', path: '/tmp/book.azw3' }])
  })

  it('routes .djvu to formats.getDjvuData', async () => {
    const { formats, calls } = makeFormats()
    const result = await dispatchFormatExtraction(formats, '/tmp/book.djvu')
    expect(result.format).toBe('djvu')
    expect(calls).toEqual([{ method: 'getDjvuData', path: '/tmp/book.djvu' }])
  })

  it('throws UnsupportedFormatError for unknown extensions', async () => {
    const { formats, calls } = makeFormats()
    await expect(dispatchFormatExtraction(formats, '/tmp/notes.txt')).rejects.toBeInstanceOf(
      UnsupportedFormatError
    )
    expect(calls).toEqual([])
  })

  it('is case-insensitive on the extension', async () => {
    const { formats, calls } = makeFormats()
    await dispatchFormatExtraction(formats, '/tmp/BOOK.EPUB')
    expect(calls).toEqual([{ method: 'getBookData', path: '/tmp/BOOK.EPUB' }])
  })
})
```

- [ ] **Step 7: Run — expect 7 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/dispatch.test.ts
```

- [ ] **Step 8: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/dispatch.test.ts
git commit -m "test(book-import): dispatch covers pdf/mobi/azw3/djvu/unsupported + case-insensitive ext"
```

---

## Task 4: Indexer (`indexer.ts`)

Internal module. Replaces `process_epub.ts`. `indexBook(deps, bookId, pageDataOpt, progressEmit)` consolidates the chunks-vs-vectors recovery logic.

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/indexer.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/indexer.ts`

- [ ] **Step 1: Write `makeDb` / `makeRag` / `makeEmbed` helpers + first failing test (skip when fully indexed)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/indexer.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import type {
  BookStoreIpc,
  PageDataInsertable,
  ImportProgressEvent
} from './types'
import type { RagService } from '../rag'
import type { EmbedParam, EmbedResult, PageData } from '@/lib/api'
import { indexBook } from './indexer'

export function makeDb(opts?: {
  chunksExist?: boolean
  pageData?: PageData[]
  failOn?: keyof BookStoreIpc
}): {
  db: BookStoreIpc
  savePageDataCalls: ChunkRecord[]
  saveVectorsCalls: SaveVectorsCall[]
} {
  const savePageDataCalls: ChunkRecord[] = []
  const saveVectorsCalls: SaveVectorsCall[] = []
  const db: BookStoreIpc = {
    saveBook: vi.fn(),
    savePageDataMany: vi.fn(async (rows) => {
      if (opts?.failOn === 'savePageDataMany') throw new Error('savePageDataMany failed')
      savePageDataCalls.push(...rows)
    }),
    getAllPageDataByBookId: vi.fn(async () => opts?.pageData ?? []),
    hasSavedEpubData: vi.fn(async () => opts?.chunksExist ?? false),
    saveVectors: vi.fn(async (name, dim, vectors) => {
      if (opts?.failOn === 'saveVectors') throw new Error('saveVectors failed')
      saveVectorsCalls.push({ name, dim, vectors })
    })
  }
  return { db, savePageDataCalls, saveVectorsCalls }
}

type ChunkRecord = { id?: number | null; pageNumber: number; bookId: number; data: string }
type SaveVectorsCall = { name: string; dim: number; vectors: { id: number; vector: number[] }[] }

export function makeRag(opts?: { indexedBookIds?: Set<number> }): RagService {
  const indexed = opts?.indexedBookIds ?? new Set<number>()
  return {
    searchSemantic: vi.fn(async () => []),
    searchText: vi.fn(async () => []),
    isIndexed: vi.fn(async (bookId: number) => indexed.has(bookId))
  }
}

export function makeEmbed(opts?: {
  vectorByText?: Record<string, number[]>
  failNTimes?: number
}): (params: EmbedParam[]) => Promise<EmbedResult[]> {
  let failsLeft = opts?.failNTimes ?? 0
  return vi.fn(async (params) => {
    if (failsLeft > 0) {
      failsLeft -= 1
      throw new Error('embed failed')
    }
    return params.map((p) => ({
      dim: 3,
      embedding: opts?.vectorByText?.[p.text] ?? [0.1, 0.2, 0.3],
      text: p.text,
      metadata: p.metadata
    }))
  })
}

const samplePageData: PageDataInsertable[] = [
  { id: 1, pageNumber: 1, bookId: 42, data: 'Chapter 1' },
  { id: 2, pageNumber: 2, bookId: 42, data: 'Chapter 2' }
]

describe('indexBook — skip when fully indexed', () => {
  it('does nothing if chunks AND vectors already exist', async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({ chunksExist: true })
    const rag = makeRag({ indexedBookIds: new Set([42]) })
    const embed = makeEmbed()
    const events: ImportProgressEvent[] = []

    await indexBook(
      { db, rag, embed, embedBatchSize: 2 },
      42,
      samplePageData,
      (e) => events.push(e)
    )

    expect(savePageDataCalls).toEqual([])
    expect(saveVectorsCalls).toEqual([])
    expect(embed).not.toHaveBeenCalled()
    expect(events).toEqual([])
  })
})
```

- [ ] **Step 2: Run — expect RED**

```bash
pnpm vitest run src/renderer/src/services/book-import/indexer.test.ts
```

Expected: 1 test fails — `Cannot find module './indexer'`.

- [ ] **Step 3: Implement `indexBook` (GREEN)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/indexer.ts`:

```ts
import type { EmbedParam, EmbedResult, ChunkDataInsertable } from '@/lib/api'
import type { RagService } from '../rag'
import type {
  BookStoreIpc,
  ImportProgressEvent,
  PageDataInsertable
} from './types'

export interface IndexerDeps {
  db: BookStoreIpc
  rag: RagService
  embed: (params: EmbedParam[]) => Promise<EmbedResult[]>
  embedBatchSize: number
}

function chunkArray<T>(array: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < array.length; i += size) out.push(array.slice(i, i + size))
  return out
}

/**
 * RAG-indexing recovery pipeline. Replaces process_epub.ts.
 *
 * - Skip entirely if chunks AND vectors exist.
 * - If chunks missing: save chunks, then embed + save vectors.
 * - If chunks exist but vectors missing (regression caught in e44ab1b9):
 *   skip chunk save, only embed + save vectors.
 * - Embed failure is swallowed (best-effort, matches today's processEpubJob).
 */
export async function indexBook(
  deps: IndexerDeps,
  bookId: number,
  pageDataOpt: PageDataInsertable[] | undefined,
  progressEmit: (event: ImportProgressEvent) => void
): Promise<void> {
  const [chunksExist, vectorsExist] = await Promise.all([
    deps.db.hasSavedEpubData(bookId),
    deps.rag.isIndexed(bookId)
  ])
  if (chunksExist && vectorsExist) return

  // Resolve pageData: caller-provided wins; else read from DB if chunks exist.
  let pageData: PageDataInsertable[]
  if (pageDataOpt !== undefined) {
    pageData = pageDataOpt
  } else if (chunksExist) {
    const rows = await deps.db.getAllPageDataByBookId(bookId)
    pageData = rows.map((p) => ({
      id: p.id,
      pageNumber: p.pageNumber,
      bookId: p.bookId,
      data: p.data
    }))
  } else {
    pageData = []
  }
  if (pageData.length === 0) return

  if (!chunksExist) {
    progressEmit({ kind: 'indexing', bookId, reason: 'chunks-missing' })
    const chunks: ChunkDataInsertable[] = pageData.map((p) => ({
      id: p.id,
      pageNumber: p.pageNumber,
      bookId: p.bookId,
      data: p.data
    }))
    await deps.db.savePageDataMany(chunks)
  } else {
    progressEmit({ kind: 'indexing', bookId, reason: 'vectors-missing' })
  }

  // Embed + save vectors. Best-effort: swallow failures so page data stays.
  try {
    const embedParams: EmbedParam[] = pageData.map((p) => ({
      text: p.data,
      metadata: { id: p.id, pageNumber: p.pageNumber, bookId }
    }))
    for (const batch of chunkArray(embedParams, deps.embedBatchSize)) {
      const results = await deps.embed(batch)
      const vectors = results.map((r) => ({ id: r.metadata.id, vector: r.embedding }))
      if (vectors.length > 0) {
        await deps.db.saveVectors(`${bookId}-vectordb`, results[0].embedding.length, vectors)
      }
    }
  } catch (err) {
    console.error('[book-import] embedding/vector save failed, will retry on next open:', err)
  }
}
```

- [ ] **Step 4: Run — expect 1 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/indexer.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/indexer.ts \
        apps/rishi-electron/src/renderer/src/services/book-import/indexer.test.ts
git commit -m "test(book-import): indexBook skips when chunks+vectors exist

Internal indexer module: chunks-vs-vectors recovery + best-effort embed
loop. Replaces modules/process_epub.ts. The skip-when-done branch is
covered; remaining scenarios in follow-up commits."
```

- [ ] **Step 6: Add tests for full pipeline / re-embed-only / swallow-embed-failure / read-from-DB**

Append to `indexer.test.ts`:

```ts
describe('indexBook — full pipeline (chunks + vectors)', () => {
  it('saves chunks, embeds in batches of 2, and saves vectors with name "<bookId>-vectordb"', async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({ chunksExist: false })
    const rag = makeRag()
    const embed = makeEmbed()
    const events: ImportProgressEvent[] = []

    await indexBook(
      { db, rag, embed, embedBatchSize: 2 },
      42,
      samplePageData,
      (e) => events.push(e)
    )

    expect(savePageDataCalls).toHaveLength(2)
    expect(saveVectorsCalls).toHaveLength(1)
    expect(saveVectorsCalls[0].name).toBe('42-vectordb')
    expect(saveVectorsCalls[0].dim).toBe(3)
    expect(events).toEqual([{ kind: 'indexing', bookId: 42, reason: 'chunks-missing' }])
  })
})

describe('indexBook — re-embed regression (chunks exist, vectors missing)', () => {
  it('does NOT re-save chunks; DOES embed and save vectors', async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({ chunksExist: true })
    const rag = makeRag() // not indexed
    const embed = makeEmbed()
    const events: ImportProgressEvent[] = []

    await indexBook(
      { db, rag, embed, embedBatchSize: 2 },
      42,
      samplePageData,
      (e) => events.push(e)
    )

    expect(savePageDataCalls).toEqual([])
    expect(saveVectorsCalls).toHaveLength(1)
    expect(saveVectorsCalls[0].name).toBe('42-vectordb')
    expect(events).toEqual([{ kind: 'indexing', bookId: 42, reason: 'vectors-missing' }])
  })
})

describe('indexBook — embed failure is swallowed', () => {
  it('saves chunks but resolves void when embed throws', async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({ chunksExist: false })
    const rag = makeRag()
    const embed = makeEmbed({ failNTimes: 1 })
    const events: ImportProgressEvent[] = []

    await expect(
      indexBook(
        { db, rag, embed, embedBatchSize: 2 },
        42,
        samplePageData,
        (e) => events.push(e)
      )
    ).resolves.toBeUndefined()

    expect(savePageDataCalls).toHaveLength(2) // chunks were saved
    expect(saveVectorsCalls).toEqual([]) // vectors were NOT saved
  })
})

describe('indexBook — reads pageData from DB when omitted', () => {
  it('uses db.getAllPageDataByBookId when caller passes no pageData and chunks exist', async () => {
    const dbPageData = [
      { id: 10, pageNumber: 1, bookId: 42, data: 'A' },
      { id: 11, pageNumber: 2, bookId: 42, data: 'B' }
    ]
    const { db, saveVectorsCalls } = makeDb({ chunksExist: true, pageData: dbPageData })
    const rag = makeRag() // not indexed -> vectors-missing branch
    const embed = makeEmbed()
    const events: ImportProgressEvent[] = []

    await indexBook({ db, rag, embed, embedBatchSize: 2 }, 42, undefined, (e) => events.push(e))

    expect(db.getAllPageDataByBookId).toHaveBeenCalledWith(42)
    expect(saveVectorsCalls).toHaveLength(1)
    expect(events).toEqual([{ kind: 'indexing', bookId: 42, reason: 'vectors-missing' }])
  })
})
```

- [ ] **Step 7: Run — expect 5 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/indexer.test.ts
```

- [ ] **Step 8: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/indexer.test.ts
git commit -m "test(book-import): indexBook full-pipeline + re-embed regression + swallow-embed-failure + db-fallback

Preserves the regression caught in commit e44ab1b9 (chunks exist but
vectors missing must re-embed without re-saving chunks)."
```

---

## Task 5: Importer (`importer.ts`)

Internal module. `runImport(deps, filePath, progressEmit)` orchestrates copy → dispatch → save → fire-and-forget upload. Returns `ImportResult`. Rollback on parse failure (remove copied file).

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/importer.ts`

- [ ] **Step 1: Write `makeFs` / `makeFileSync` helpers + first failing test (happy path EPUB)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import type {
  BookImportConfig,
  BookStoreIpc,
  FileSyncIpc,
  FsIpc,
  ImportProgressEvent
} from './types'
import type { Book } from '@/lib/api'
import { makeFormats } from './dispatch.test'
import { runImport } from './importer'

export function makeFs(opts?: {
  copyImpl?: (path: string) => Promise<string>
  removeImpl?: (path: string) => Promise<void>
}): {
  fs: FsIpc
  removeCalls: string[]
  copyCalls: string[]
} {
  const removeCalls: string[] = []
  const copyCalls: string[] = []
  const fs: FsIpc = {
    copyBookToAppData: vi.fn(async (path: string) => {
      copyCalls.push(path)
      if (opts?.copyImpl) return opts.copyImpl(path)
      const filename = path.split('/').pop() ?? 'book'
      return `/userData/${filename}`
    }),
    removeFile: vi.fn(async (path: string) => {
      removeCalls.push(path)
      if (opts?.removeImpl) return opts.removeImpl(path)
    }),
    getAppDataPath: vi.fn(async () => '/userData')
  }
  return { fs, removeCalls, copyCalls }
}

export function makeDbForImport(opts?: {
  savedBook?: Book
  failOn?: 'saveBook'
}): { db: BookStoreIpc; savedBooks: Book[] } {
  const savedBooks: Book[] = []
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
    savePageDataMany: vi.fn(),
    getAllPageDataByBookId: vi.fn(async () => []),
    hasSavedEpubData: vi.fn(async () => false),
    saveVectors: vi.fn()
  }
  return { db, savedBooks }
}

export function makeFileSync(opts?: {
  hashImpl?: (path: string) => Promise<string>
  uploadImpl?: () => Promise<{ r2Key: string }>
  throwOn?: 'upload' | 'updateHash'
}): FileSyncIpc {
  return {
    hashBookFile: vi.fn(async (path: string) =>
      opts?.hashImpl ? opts.hashImpl(path) : 'abc123'
    ),
    uploadBookFile: vi.fn(async () => {
      if (opts?.throwOn === 'upload') throw new Error('upload failed')
      return opts?.uploadImpl ? opts.uploadImpl() : { r2Key: 'r2/abc' }
    }),
    booksUpdateFileHash: vi.fn(async () => {
      if (opts?.throwOn === 'updateHash') throw new Error('updateHash failed')
    })
  }
}

export const baseConfig: BookImportConfig = {
  copyTimeoutMs: 5_000,
  parseTimeoutMs: 5_000,
  saveTimeoutMs: 5_000,
  embedBatchSize: 2
}

describe('runImport — happy path EPUB', () => {
  it('returns { ok: true } and emits copying -> parsing -> saving -> done', async () => {
    const { formats } = makeFormats()
    const { fs, copyCalls } = makeFs()
    const { db, savedBooks } = makeDbForImport()
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/sample.epub',
      (e) => events.push(e)
    )

    expect(result).toEqual({
      ok: true,
      bookId: 42,
      filePath: '/Downloads/sample.epub',
      format: 'epub'
    })
    expect(copyCalls).toEqual(['/Downloads/sample.epub'])
    expect(savedBooks).toHaveLength(1)
    expect(savedBooks[0].filepath).toBe('/userData/sample.epub')
    expect(events.map((e) => e.kind)).toEqual(['copying', 'parsing', 'saving', 'done'])
  })
})
```

- [ ] **Step 2: Run — expect RED**

```bash
pnpm vitest run src/renderer/src/services/book-import/importer.test.ts
```

Expected: 1 test fails — `Cannot find module './importer'`.

- [ ] **Step 3: Implement `runImport` (GREEN)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/importer.ts`:

```ts
import type {
  BookImportConfig,
  BookStoreIpc,
  FileSyncIpc,
  FormatsIpc,
  FsIpc,
  ImportProgressEvent,
  ImportResult
} from './types'
import { dispatchFormatExtraction, UnsupportedFormatError } from './dispatch'

export interface ImporterDeps {
  formats: FormatsIpc
  fs: FsIpc
  db: BookStoreIpc
  fileSync: FileSyncIpc
  config: BookImportConfig
}

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${Math.round(ms / 1000)}s`)),
      ms
    )
    promise.then(
      (v) => {
        clearTimeout(timer)
        resolve(v)
      },
      (e) => {
        clearTimeout(timer)
        reject(e)
      }
    )
  })
}

function messageOf(err: unknown, fallback: string): string {
  return err instanceof Error ? err.message : fallback
}

/**
 * Best-effort hash + R2 upload. Failure does not affect the import result;
 * it only emits an `upload-failed` event.
 */
function runUpload(
  deps: ImporterDeps,
  bookId: number,
  bookPath: string,
  format: 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu',
  filePath: string,
  emit: (event: ImportProgressEvent) => void
): void {
  emit({ kind: 'upload-started', filePath, bookId })
  const formatForUpload: 'epub' | 'pdf' | 'mobi' | 'djvu' =
    format === 'azw3' ? 'mobi' : format
  void (async () => {
    try {
      const fileHash = await deps.fileSync.hashBookFile(bookPath)
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
  })()
}

/**
 * Single-file import pipeline. Sequential stages with per-stage timeouts.
 * Returns a discriminated ImportResult. Rolls back the copy on parse failure;
 * leaves the copied file on save failure (caller can retry).
 */
export async function runImport(
  deps: ImporterDeps,
  filePath: string,
  emit: (event: ImportProgressEvent) => void
): Promise<ImportResult> {
  // Stage 1: copy.
  emit({ kind: 'copying', filePath })
  let bookPath: string
  try {
    bookPath = await withTimeout(
      deps.fs.copyBookToAppData(filePath),
      deps.config.copyTimeoutMs,
      'Copying file'
    )
  } catch (err) {
    const error = messageOf(err, 'Copy failed')
    emit({ kind: 'failed', filePath, stage: 'copy', error })
    return { ok: false, filePath, stage: 'copy', error }
  }

  // Stage 2: parse via format dispatch.
  let format: 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'
  let bookData
  try {
    const dispatched = await dispatchFormatExtraction(deps.formats, filePath)
    format = dispatched.format
    emit({ kind: 'parsing', filePath, format })
    const parsed = await withTimeout(
      Promise.resolve(dispatched.data),
      deps.config.parseTimeoutMs,
      'Extracting metadata'
    )
    bookData = parsed
  } catch (err) {
    if (err instanceof UnsupportedFormatError) {
      emit({ kind: 'failed', filePath, stage: 'unsupported', error: err.message })
      return { ok: false, filePath, stage: 'unsupported', error: err.message }
    }
    const error = messageOf(err, 'Parse failed')
    emit({ kind: 'failed', filePath, stage: 'parse', error })
    // Rollback the copied file (best-effort).
    try {
      await deps.fs.removeFile(bookPath)
    } catch {
      /* swallow */
    }
    return { ok: false, filePath, stage: 'parse', error }
  }

  // Stage 3: save.
  emit({ kind: 'saving', filePath, format })
  let book
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
        cover: bookData.cover
      }),
      deps.config.saveTimeoutMs,
      'Saving to library'
    )
  } catch (err) {
    const error = messageOf(err, 'Save failed')
    emit({ kind: 'failed', filePath, stage: 'save', error })
    return { ok: false, filePath, stage: 'save', error }
  }

  // Stage 4: fire-and-forget upload.
  runUpload(deps, book.id, bookPath, format, filePath, emit)

  emit({ kind: 'done', filePath, bookId: book.id, format })
  return { ok: true, bookId: book.id, filePath, format }
}
```

Note: the `dispatch.ts` lookup happens *before* the `parsing` event so that an unknown extension short-circuits with `stage: 'unsupported'` without emitting a stray `parsing`.

- [ ] **Step 4: Run — expect 1 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/importer.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/importer.ts \
        apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts
git commit -m "test(book-import): runImport happy path returns ok and emits stage events

Internal importer module: copy -> dispatch+parse -> save -> fire-and-
forget upload pipeline. Replaces the inline importBook in
FileComponent.tsx (~80 LOC). Per-stage timeouts via withTimeout."
```

- [ ] **Step 6: Add tests for unsupported / copy-failure / parse-rollback / save-failure / upload-failure (test-only, then verify)**

Append to `importer.test.ts`:

```ts
describe('runImport — unsupported extension', () => {
  it('returns stage: unsupported and never touches FS / formats / DB', async () => {
    const { formats, calls } = makeFormats()
    const { fs, copyCalls, removeCalls } = makeFs()
    const { db, savedBooks } = makeDbForImport()
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/note.txt',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.stage).toBe('unsupported')
      expect(result.error).toMatch(/Unsupported format: \.txt/)
    }
    // Copy DID run (we copy before dispatch in pipeline order); format calls did not.
    expect(copyCalls).toEqual(['/Downloads/note.txt'])
    expect(calls).toEqual([])
    expect(savedBooks).toEqual([])
    // No rollback for unsupported (the file is a normal copy; caller may delete).
    expect(removeCalls).toEqual([])
    expect(events.map((e) => e.kind)).toEqual(['copying', 'failed'])
  })
})

describe('runImport — copy failure', () => {
  it('returns stage: copy and never parses', async () => {
    const { formats, calls } = makeFormats()
    const { fs, removeCalls } = makeFs({
      copyImpl: async () => {
        throw new Error('disk full')
      }
    })
    const { db } = makeDbForImport()
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/book.epub',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.stage).toBe('copy')
    expect(calls).toEqual([])
    expect(removeCalls).toEqual([])
    expect(events.map((e) => e.kind)).toEqual(['copying', 'failed'])
  })
})

describe('runImport — parse failure rolls back the copy', () => {
  it('removes the copied file and returns stage: parse', async () => {
    const failingFormats = {
      getBookData: vi.fn(async () => {
        throw new Error('bad zip')
      }),
      getPdfData: vi.fn(),
      getMobiData: vi.fn(),
      getDjvuData: vi.fn()
    }
    const { fs, removeCalls } = makeFs()
    const { db, savedBooks } = makeDbForImport()
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats: failingFormats, fs, db, fileSync, config: baseConfig },
      '/Downloads/broken.epub',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.stage).toBe('parse')
    expect(removeCalls).toEqual(['/userData/broken.epub'])
    expect(savedBooks).toEqual([])
    expect(events.map((e) => e.kind)).toEqual(['copying', 'parsing', 'failed'])
  })
})

describe('runImport — save failure does NOT roll back copy', () => {
  it('returns stage: save and leaves the copied file on disk', async () => {
    const { formats } = makeFormats()
    const { fs, removeCalls } = makeFs()
    const { db } = makeDbForImport({ failOn: 'saveBook' })
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/book.epub',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.stage).toBe('save')
    expect(removeCalls).toEqual([])
    expect(events.map((e) => e.kind)).toEqual(['copying', 'parsing', 'saving', 'failed'])
  })
})

describe('runImport — upload failure does NOT affect result', () => {
  it('returns ok and emits upload-failed asynchronously', async () => {
    const { formats } = makeFormats()
    const { fs } = makeFs()
    const { db } = makeDbForImport()
    const fileSync = makeFileSync({ throwOn: 'upload' })
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/book.epub',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(true)
    // `done` fires synchronously after save; `upload-failed` arrives on the next tick.
    await new Promise((r) => setTimeout(r, 0))
    const kinds = events.map((e) => e.kind)
    expect(kinds).toContain('upload-started')
    expect(kinds).toContain('upload-failed')
    // `done` must come before `upload-failed`.
    expect(kinds.indexOf('done')).toBeLessThan(kinds.indexOf('upload-failed'))
  })
})
```

- [ ] **Step 7: Run — expect 6 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/importer.test.ts
```

- [ ] **Step 8: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/importer.test.ts
git commit -m "test(book-import): runImport unsupported/copy-fail/parse-rollback/save-fail/upload-fire-and-forget"
```

---

## Task 6: Scanner adapter (`scanner-adapter.ts`)

Internal helper that wraps the existing `window.electron.on('scan-result'|'scan-progress'|'scan-complete', ...)` IPC events into the `ScannerPort` shape. The service consumes only the `ScannerPort` interface; tests inject a `makeScanner()` fake directly. The adapter exists so the wiring site in `services/index.ts` does not have to inline three `window.electron.on` calls.

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.ts`

- [ ] **Step 1: Write the failing test for the adapter**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import type { DiscoveredBook, ScanProgress } from './types'
import { createScannerPort, type ScannerIpc, type WindowEventsOn } from './scanner-adapter'

/**
 * Build a fake `window.electron` IPC + on() wrapper.
 * `emit(channel, payload)` simulates an IPC event from main.
 */
function makeFakeIpc(): {
  ipc: ScannerIpc
  on: WindowEventsOn
  emit(channel: 'scan-result' | 'scan-progress' | 'scan-complete', payload?: unknown): void
  startCalls(): string[]
  cancelCalls(): number
} {
  const startCalls: string[] = []
  let cancelCount = 0
  const listeners = new Map<string, Set<(...args: unknown[]) => void>>()

  const ipc: ScannerIpc = {
    scanForBooks: vi.fn(async (mode: string) => {
      startCalls.push(mode)
    }),
    cancelScan: vi.fn(async () => {
      cancelCount++
    })
  }

  const on: WindowEventsOn = (channel, listener) => {
    if (!listeners.has(channel)) listeners.set(channel, new Set())
    listeners.get(channel)!.add(listener)
    return () => {
      listeners.get(channel)?.delete(listener)
    }
  }

  return {
    ipc,
    on,
    emit(channel, payload) {
      for (const l of listeners.get(channel) ?? []) l(payload)
    },
    startCalls: () => startCalls,
    cancelCalls: () => cancelCount
  }
}

describe('createScannerPort', () => {
  it('forwards start(mode) to ipc.scanForBooks and cancel() to ipc.cancelScan', async () => {
    const fake = makeFakeIpc()
    const scanner = createScannerPort(fake.ipc, fake.on)

    await scanner.start('default')
    await scanner.cancel()

    expect(fake.startCalls()).toEqual(['default'])
    expect(fake.cancelCalls()).toBe(1)
  })

  it('on("result") delivers DiscoveredBook payloads from the scan-result channel', () => {
    const fake = makeFakeIpc()
    const scanner = createScannerPort(fake.ipc, fake.on)
    const received: DiscoveredBook[] = []
    scanner.on('result', (b) => received.push(b))

    const book: DiscoveredBook = {
      filepath: '/Books/sample.epub',
      filename: 'sample.epub',
      title: 'Sample',
      author: 'A',
      format: 'epub',
      fileSize: 1024,
      folder: '/Books',
      fileHash: null
    }
    fake.emit('scan-result', book)

    expect(received).toEqual([book])
  })

  it('on("progress") delivers ScanProgress; on("complete") fires with no arg; unsubscribe stops delivery', () => {
    const fake = makeFakeIpc()
    const scanner = createScannerPort(fake.ipc, fake.on)
    const progress: ScanProgress[] = []
    const completes: number[] = []
    const unsubProgress = scanner.on('progress', (p) => progress.push(p))
    scanner.on('complete', () => completes.push(1))

    fake.emit('scan-progress', { folder: '/Books', scanned: 1, total: 10 })
    fake.emit('scan-complete')

    expect(progress).toEqual([{ folder: '/Books', scanned: 1, total: 10 }])
    expect(completes).toEqual([1])

    unsubProgress()
    fake.emit('scan-progress', { folder: '/Books', scanned: 2, total: 10 })
    expect(progress).toEqual([{ folder: '/Books', scanned: 1, total: 10 }]) // unchanged
  })
})
```

- [ ] **Step 2: Run — expect RED**

```bash
pnpm vitest run src/renderer/src/services/book-import/scanner-adapter.test.ts
```

Expected: 3 tests fail — `Cannot find module './scanner-adapter'`.

- [ ] **Step 3: Implement `createScannerPort` (GREEN)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.ts`:

```ts
import type { DiscoveredBook, ScanProgress, ScannerPort } from './types'

/** Minimal slice of `window.electron` the adapter needs. */
export interface ScannerIpc {
  scanForBooks(mode: 'default' | 'full'): Promise<void>
  cancelScan(): Promise<void>
}

/** Shape of `window.electron.on` we depend on (returns an unsubscribe). */
export type WindowEventsOn = (
  channel: 'scan-result' | 'scan-progress' | 'scan-complete',
  listener: (...args: unknown[]) => void
) => () => void

/**
 * Wrap the raw IPC + event channels into a typed `ScannerPort`. Used by the
 * wiring site in `services/index.ts`; tests inject `makeScanner()` directly.
 */
export function createScannerPort(ipc: ScannerIpc, on: WindowEventsOn): ScannerPort {
  return {
    start: (mode) => ipc.scanForBooks(mode),
    cancel: () => ipc.cancelScan(),
    on(kind: 'result' | 'progress' | 'complete', listener: (...args: unknown[]) => void) {
      const channel =
        kind === 'result' ? 'scan-result' : kind === 'progress' ? 'scan-progress' : 'scan-complete'
      return on(channel, (...args: unknown[]) => {
        if (kind === 'complete') (listener as () => void)()
        else if (kind === 'result') (listener as (b: DiscoveredBook) => void)(args[0] as DiscoveredBook)
        else (listener as (p: ScanProgress) => void)(args[0] as ScanProgress)
      })
    }
  } as ScannerPort
}
```

- [ ] **Step 4: Run — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/scanner-adapter.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.ts \
        apps/rishi-electron/src/renderer/src/services/book-import/scanner-adapter.test.ts
git commit -m "test(book-import): scanner-adapter wraps IPC + on() into a typed ScannerPort

Internal helper used at the wiring site so services/index.ts does not
inline the three window.electron.on calls. The service consumes only
the ScannerPort interface; tests use makeScanner() in service.test.ts."
```

---

## Task 7: Service factory (`service.ts`)

Top-level factory. Composes the importer, indexer, dispatch, scanner subscription, progress emitter, and discovery emitter. All boundary tests live in `service.test.ts`.

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/book-import/service.ts`

- [ ] **Step 1: Write the shared test helpers + first failing test (importFromPath happy path)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import type {
  BookImportServiceDeps,
  DiscoveredBook,
  DiscoveryEvent,
  ImportProgressEvent,
  ScannerPort,
  ScanProgress
} from './types'
import { createBookImportService } from './service'
import { makeFormats } from './dispatch.test'
import { makeDb as makeRagDb, makeRag, makeEmbed } from './indexer.test'
import { makeFs, makeDbForImport, makeFileSync, baseConfig } from './importer.test'

/**
 * In-memory scanner fake. `emit(...)` simulates the three IPC events.
 */
export function makeScanner(): ScannerPort & {
  emit(
    event:
      | { kind: 'result'; book: DiscoveredBook }
      | { kind: 'progress'; progress: ScanProgress }
      | { kind: 'complete' }
  ): void
  startCount(): number
  cancelCount(): number
  lastMode(): 'default' | 'full' | null
} {
  let startCalls = 0
  let cancelCalls = 0
  let lastMode: 'default' | 'full' | null = null
  const resultListeners = new Set<(b: DiscoveredBook) => void>()
  const progressListeners = new Set<(p: ScanProgress) => void>()
  const completeListeners = new Set<() => void>()

  return {
    start: vi.fn(async (mode: 'default' | 'full') => {
      startCalls++
      lastMode = mode
    }),
    cancel: vi.fn(async () => {
      cancelCalls++
    }),
    on(kind: 'result' | 'progress' | 'complete', listener: unknown) {
      if (kind === 'result') {
        const l = listener as (b: DiscoveredBook) => void
        resultListeners.add(l)
        return () => {
          resultListeners.delete(l)
        }
      }
      if (kind === 'progress') {
        const l = listener as (p: ScanProgress) => void
        progressListeners.add(l)
        return () => {
          progressListeners.delete(l)
        }
      }
      const l = listener as () => void
      completeListeners.add(l)
      return () => {
        completeListeners.delete(l)
      }
    },
    emit(event) {
      if (event.kind === 'result') for (const l of resultListeners) l(event.book)
      else if (event.kind === 'progress') for (const l of progressListeners) l(event.progress)
      else for (const l of completeListeners) l()
    },
    startCount: () => startCalls,
    cancelCount: () => cancelCalls,
    lastMode: () => lastMode
  } as unknown as ScannerPort & {
    emit(
      event:
        | { kind: 'result'; book: DiscoveredBook }
        | { kind: 'progress'; progress: ScanProgress }
        | { kind: 'complete' }
    ): void
    startCount(): number
    cancelCount(): number
    lastMode(): 'default' | 'full' | null
  }
}

/** Compose a full deps object with sensible defaults. */
export function makeDeps(overrides: Partial<BookImportServiceDeps> = {}): BookImportServiceDeps {
  const formats = overrides.formats ?? makeFormats().formats
  const fs = overrides.fs ?? makeFs().fs
  const db = overrides.db ?? makeDbForImport().db
  const fileSync = overrides.fileSync ?? makeFileSync()
  const rag = overrides.rag ?? makeRag()
  const embed = overrides.embed ?? makeEmbed()
  const scanner = overrides.scanner ?? makeScanner()
  return {
    formats,
    fs,
    db,
    fileSync,
    rag,
    embed,
    scanner,
    config: overrides.config ?? baseConfig
  }
}

describe('BookImportService.importFromPath — happy path', () => {
  it('returns ok and emits copying -> parsing -> saving -> done', async () => {
    const deps = makeDeps()
    const service = createBookImportService(deps)
    const events: ImportProgressEvent[] = []
    service.onImportProgress((e) => events.push(e))

    const result = await service.importFromPath('/Downloads/sample.epub')

    expect(result.ok).toBe(true)
    if (result.ok) expect(result.format).toBe('epub')
    expect(events.map((e) => e.kind)).toEqual([
      'copying',
      'parsing',
      'saving',
      'done',
      // upload-started fires sync after done; upload-failed is unreachable here
      'upload-started'
    ])
  })
})
```

> Note: `makeDb` is exported from `indexer.test.ts` as a generic store fake (covers `hasSavedEpubData` + `getAllPageDataByBookId` + `saveVectors`); `makeDbForImport` from `importer.test.ts` returns one tuned for `saveBook`. Service tests pick whichever shape they need; nothing prevents composing both via `makeDeps({ db: ... })`.

- [ ] **Step 2: Run — expect RED**

```bash
pnpm vitest run src/renderer/src/services/book-import/service.test.ts
```

Expected: fails — `Cannot find module './service'`.

- [ ] **Step 3: Implement `createBookImportService` (GREEN)**

Create `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/service.ts`:

```ts
import type {
  BookImportService,
  BookImportServiceDeps,
  DiscoveryEvent,
  ImportProgressEvent,
  ImportResult,
  PageDataInsertable
} from './types'
import { createEmitter } from './emitter'
import { runImport } from './importer'
import { indexBook as runIndex } from './indexer'

export function createBookImportService(deps: BookImportServiceDeps): BookImportService {
  const progress = createEmitter<ImportProgressEvent>()
  const discovery = createEmitter<DiscoveryEvent>()

  let activeUnsubs: Array<() => void> = []
  let scanRunning = false

  function teardownScanSubscriptions(): void {
    for (const u of activeUnsubs) u()
    activeUnsubs = []
  }

  function setupScanSubscriptions(): void {
    teardownScanSubscriptions()
    activeUnsubs.push(
      deps.scanner.on('result', (book) => discovery.emit({ kind: 'book-found', book }))
    )
    activeUnsubs.push(
      deps.scanner.on('progress', (p) => discovery.emit({ kind: 'progress', progress: p }))
    )
    activeUnsubs.push(
      deps.scanner.on('complete', () => {
        scanRunning = false
        discovery.emit({ kind: 'complete', cancelled: false })
        teardownScanSubscriptions()
      })
    )
  }

  async function importFromPath(filePath: string): Promise<ImportResult> {
    return runImport(
      {
        formats: deps.formats,
        fs: deps.fs,
        db: deps.db,
        fileSync: deps.fileSync,
        config: deps.config
      },
      filePath,
      (e) => progress.emit(e)
    )
  }

  async function importBatch(filePaths: string[]): Promise<ImportResult[]> {
    const results: ImportResult[] = []
    for (const fp of filePaths) {
      results.push(await importFromPath(fp))
    }
    return results
  }

  async function indexBook(bookId: number, pageData?: PageDataInsertable[]): Promise<void> {
    await runIndex(
      { db: deps.db, rag: deps.rag, embed: deps.embed, embedBatchSize: deps.config.embedBatchSize },
      bookId,
      pageData,
      (e) => progress.emit(e)
    )
  }

  function startDiscovery(mode: 'default' | 'full'): void {
    // Single-flight: cancel any in-flight scan first.
    if (scanRunning) {
      void deps.scanner.cancel()
    }
    setupScanSubscriptions()
    scanRunning = true
    void deps.scanner.start(mode)
  }

  async function cancelDiscovery(): Promise<void> {
    if (!scanRunning) return
    await deps.scanner.cancel()
    scanRunning = false
    discovery.emit({ kind: 'complete', cancelled: true })
    teardownScanSubscriptions()
  }

  return {
    importFromPath,
    importBatch,
    indexBook,
    startDiscovery,
    cancelDiscovery,
    onDiscoveryEvent: (listener) => discovery.on(listener),
    onImportProgress: (listener) => progress.on(listener)
  }
}
```

- [ ] **Step 4: Run — expect 1 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/service.test.ts
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/service.ts \
        apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts
git commit -m "test(book-import): service.importFromPath happy path emits stage events

createBookImportService composes runImport + indexBook + scanner
subscriptions + the two emitters. Importer/indexer internals already
have unit coverage; the service layer tests pin the public surface."
```

- [ ] **Step 6: Add boundary tests — batch resilience + batch order**

Append to `service.test.ts`:

```ts
describe('BookImportService.importBatch', () => {
  it('continues after one failure and returns results in input order', async () => {
    // The middle path has an unsupported extension; the others succeed.
    const deps = makeDeps()
    const service = createBookImportService(deps)
    const events: ImportProgressEvent[] = []
    service.onImportProgress((e) => events.push(e))

    const results = await service.importBatch([
      '/Downloads/one.epub',
      '/Downloads/middle.unknownext',
      '/Downloads/three.pdf'
    ])

    expect(results).toHaveLength(3)
    expect(results[0].ok).toBe(true)
    expect(results[1].ok).toBe(false)
    if (!results[1].ok) expect(results[1].stage).toBe('unsupported')
    expect(results[2].ok).toBe(true)
  })
})
```

- [ ] **Step 7: Run — expect 2 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/service.test.ts
```

- [ ] **Step 8: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts
git commit -m "test(book-import): importBatch isolates failures and preserves input order"
```

- [ ] **Step 9: Add boundary tests — indexBook surface (skip / full / re-embed / db-fallback)**

Append to `service.test.ts`:

```ts
describe('BookImportService.indexBook', () => {
  it('skips when chunks AND vectors exist (delegates to indexer)', async () => {
    const { db } = makeRagDb({ chunksExist: true })
    const rag = makeRag({ indexedBookIds: new Set([42]) })
    const embed = makeEmbed()
    const service = createBookImportService(makeDeps({ db, rag, embed }))

    await service.indexBook(42, [{ id: 1, pageNumber: 1, bookId: 42, data: 'A' }])

    expect(db.savePageDataMany).not.toHaveBeenCalled()
    expect(db.saveVectors).not.toHaveBeenCalled()
    expect(embed).not.toHaveBeenCalled()
  })

  it('runs the full pipeline when neither chunks nor vectors exist', async () => {
    const { db } = makeRagDb({ chunksExist: false })
    const rag = makeRag()
    const embed = makeEmbed()
    const events: ImportProgressEvent[] = []
    const service = createBookImportService(makeDeps({ db, rag, embed }))
    service.onImportProgress((e) => events.push(e))

    await service.indexBook(42, [
      { id: 1, pageNumber: 1, bookId: 42, data: 'A' },
      { id: 2, pageNumber: 2, bookId: 42, data: 'B' }
    ])

    expect(db.savePageDataMany).toHaveBeenCalledTimes(1)
    expect(db.saveVectors).toHaveBeenCalledTimes(1)
    expect(events).toContainEqual({ kind: 'indexing', bookId: 42, reason: 'chunks-missing' })
  })

  it('re-embeds when chunks exist but vectors are missing (regression)', async () => {
    const { db } = makeRagDb({ chunksExist: true })
    const rag = makeRag() // not indexed
    const embed = makeEmbed()
    const events: ImportProgressEvent[] = []
    const service = createBookImportService(makeDeps({ db, rag, embed }))
    service.onImportProgress((e) => events.push(e))

    await service.indexBook(42, [
      { id: 1, pageNumber: 1, bookId: 42, data: 'A' }
    ])

    expect(db.savePageDataMany).not.toHaveBeenCalled()
    expect(db.saveVectors).toHaveBeenCalledTimes(1)
    expect(events).toContainEqual({ kind: 'indexing', bookId: 42, reason: 'vectors-missing' })
  })

  it('falls back to db.getAllPageDataByBookId when pageData omitted', async () => {
    const { db } = makeRagDb({
      chunksExist: true,
      pageData: [{ id: 1, pageNumber: 1, bookId: 42, data: 'from-db' }]
    })
    const rag = makeRag()
    const embed = makeEmbed()
    const service = createBookImportService(makeDeps({ db, rag, embed }))

    await service.indexBook(42)

    expect(db.getAllPageDataByBookId).toHaveBeenCalledWith(42)
    expect(db.saveVectors).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 10: Run — expect 6 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/service.test.ts
```

- [ ] **Step 11: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts
git commit -m "test(book-import): indexBook public surface (skip / full / re-embed / db-fallback)"
```

- [ ] **Step 12: Add boundary tests — discovery (event streaming, single-flight, cancel)**

Append to `service.test.ts`:

```ts
describe('BookImportService.startDiscovery', () => {
  it('streams scanner events through onDiscoveryEvent', () => {
    const scanner = makeScanner()
    const service = createBookImportService(makeDeps({ scanner }))
    const events: DiscoveryEvent[] = []
    service.onDiscoveryEvent((e) => events.push(e))

    service.startDiscovery('default')

    const book: DiscoveredBook = {
      filepath: '/B/a.epub',
      filename: 'a.epub',
      title: null,
      author: null,
      format: 'epub',
      fileSize: 1,
      folder: '/B',
      fileHash: null
    }
    scanner.emit({ kind: 'result', book })
    scanner.emit({ kind: 'result', book: { ...book, filepath: '/B/b.epub', filename: 'b.epub' } })
    scanner.emit({ kind: 'progress', progress: { folder: '/B', scanned: 2, total: 10 } })
    scanner.emit({ kind: 'complete' })

    expect(scanner.startCount()).toBe(1)
    expect(scanner.lastMode()).toBe('default')
    expect(events.map((e) => e.kind)).toEqual([
      'book-found',
      'book-found',
      'progress',
      'complete'
    ])
    const completeEvent = events.find((e) => e.kind === 'complete')
    expect(completeEvent).toEqual({ kind: 'complete', cancelled: false })
  })

  it('single-flight: starting while running cancels the prior scan first', () => {
    const scanner = makeScanner()
    const service = createBookImportService(makeDeps({ scanner }))

    service.startDiscovery('default')
    service.startDiscovery('full')

    expect(scanner.cancelCount()).toBe(1)
    expect(scanner.startCount()).toBe(2)
    expect(scanner.lastMode()).toBe('full')
  })

  it('cancelDiscovery propagates to scanner.cancel and emits complete with cancelled=true', async () => {
    const scanner = makeScanner()
    const service = createBookImportService(makeDeps({ scanner }))
    const events: DiscoveryEvent[] = []
    service.onDiscoveryEvent((e) => events.push(e))

    service.startDiscovery('default')
    await service.cancelDiscovery()

    expect(scanner.cancelCount()).toBe(1)
    expect(events).toContainEqual({ kind: 'complete', cancelled: true })
  })

  it('cancelDiscovery is a no-op when nothing is running', async () => {
    const scanner = makeScanner()
    const service = createBookImportService(makeDeps({ scanner }))

    await service.cancelDiscovery()

    expect(scanner.cancelCount()).toBe(0)
  })
})
```

- [ ] **Step 13: Run — expect 10 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/service.test.ts
```

- [ ] **Step 14: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts
git commit -m "test(book-import): discovery streams, single-flight start, cancel propagation"
```

- [ ] **Step 15: Add boundary test — `onImportProgress` unsubscribe**

Append to `service.test.ts`:

```ts
describe('BookImportService.onImportProgress', () => {
  it('unsubscribe stops further events from being delivered', async () => {
    const service = createBookImportService(makeDeps())
    const seen: ImportProgressEvent[] = []
    const unsub = service.onImportProgress((e) => seen.push(e))

    await service.importFromPath('/Downloads/a.epub')
    const seenAfterFirst = seen.length
    expect(seenAfterFirst).toBeGreaterThan(0)

    unsub()
    await service.importFromPath('/Downloads/b.epub')

    expect(seen.length).toBe(seenAfterFirst) // unchanged after unsubscribe
  })
})
```

- [ ] **Step 16: Run — expect 11 GREEN**

```bash
pnpm vitest run src/renderer/src/services/book-import/service.test.ts
```

- [ ] **Step 17: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/service.test.ts
git commit -m "test(book-import): onImportProgress unsubscribe stops delivery"
```

---

## Task 8: Public exports (`index.ts`)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/book-import/index.ts`

- [ ] **Step 1: Replace the placeholder with re-exports of the public surface only**

Replace the contents of `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/book-import/index.ts`:

```ts
export { createBookImportService } from './service'
export { createScannerPort } from './scanner-adapter'
export type {
  BookFormat,
  BookDataParsed,
  BookImportConfig,
  BookImportService,
  BookImportServiceDeps,
  BookStoreIpc,
  DiscoveredBook,
  DiscoveryEvent,
  FileSyncIpc,
  FormatsIpc,
  FsIpc,
  ImportFailure,
  ImportProgressEvent,
  ImportResult,
  ImportSuccess,
  PageDataInsertable,
  ScanProgress,
  ScannerPort
} from './types'
```

Do **not** export `createEmitter`, `dispatchFormatExtraction`, `runImport`, or `indexBook` — those are internals.

- [ ] **Step 2: Sanity-grep that internals are NOT re-exported**

```bash
cd /tmp/rishi-book-import-refactor
grep -nE "createEmitter|dispatchFormatExtraction|runImport|^export .* from .'\\./importer|from .'\\./indexer'" \
  apps/rishi-electron/src/renderer/src/services/book-import/index.ts
```

Expected: no matches.

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
```

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/book-import/index.ts
git commit -m "refactor(book-import): export only the public surface

createBookImportService + createScannerPort (wiring helper) + the public
types. Importer / indexer / dispatch / emitter stay internal."
```

---

## Task 9: Wire `getBookImportService` in `services/index.ts`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/index.ts`

- [ ] **Step 1: Append the lazy `getBookImportService()` singleton**

Replace the contents of `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/services/index.ts` with:

```ts
import { createRagService, type RagService } from './rag'
import { createTtsService, type AuthHeader, type TtsService } from './tts'
import {
  createBookImportService,
  createScannerPort,
  type BookImportService,
  type ScannerPort
} from './book-import'
import { embedSingleText, embedWithFallback } from '@/modules/embed-fallback'
import { hashBookFile, uploadBookFile } from '@/modules/file-sync'
import { copyBookToAppData } from '@/modules/books'
import { getAuthToken } from '@/modules/auth'
import config from '@/config.json'

let _rag: RagService | null = null

export function getRagService(): RagService {
  if (!_rag) {
    _rag = createRagService({
      ipc: {
        searchVectors: window.electron.searchVectors,
        getTextFromVectorId: window.electron.getTextFromVectorId,
        searchBookText: window.electron.searchBookText,
        hasVectorsForBook: window.electron.hasVectorsForBook
      },
      embed: embedSingleText
    })
  }
  return _rag
}

let _tts: TtsService | null = null

async function resolveTtsAuth(): Promise<AuthHeader> {
  const token = await getAuthToken()
  if (token) return { kind: 'bearer', token }
  const devBypassSecret = await window.electron.getDevBypassSecret()
  if (devBypassSecret) return { kind: 'dev-bypass', secret: devBypassSecret }
  throw new Error('Not authenticated -- sign in to use text-to-speech')
}

export function getTtsService(): TtsService {
  if (!_tts) {
    _tts = createTtsService({
      ipc: {
        mkdir: window.electron.mkdir,
        exists: window.electron.exists,
        writeFile: window.electron.writeFile,
        readFile: window.electron.readFile,
        copyFile: window.electron.copyFile,
        removeFile: window.electron.removeFile,
        getDirSize: window.electron.getDirSize,
        getCacheFileStats: window.electron.getCacheFileStats,
        getAppDataPath: window.electron.getAppDataPath
      },
      fetch: globalThis.fetch.bind(globalThis),
      getAuthToken: resolveTtsAuth,
      config: {
        audioWorkerUrl: config.production.audio_worker_url,
        cacheMaxBytes: 500 * 1024 * 1024,
        maxConcurrent: 8
      }
    })
  }
  return _tts
}

let _import: BookImportService | null = null

export function getBookImportService(): BookImportService {
  if (!_import) {
    const scanner: ScannerPort = createScannerPort(
      {
        scanForBooks: (mode) => window.electron.scanForBooks(mode),
        cancelScan: () => window.electron.cancelScan()
      },
      (channel, listener) =>
        window.electron.on(channel, (...args: unknown[]) =>
          (listener as (...a: unknown[]) => void)(...args)
        )
    )

    _import = createBookImportService({
      formats: {
        getBookData: (path) => window.electron.getBookData(path),
        getPdfData: (path) => window.electron.getPdfData(path),
        getMobiData: (path) => window.electron.getMobiData(path),
        getDjvuData: (path) => window.electron.getDjvuData(path)
      },
      db: {
        saveBook: (b) => window.electron.saveBook(b),
        savePageDataMany: (rows) => window.electron.savePageDataMany(rows),
        getAllPageDataByBookId: (bookId) => window.electron.getAllPageDataByBookId(bookId),
        hasSavedEpubData: (bookId) => window.electron.hasSavedEpubData(bookId),
        saveVectors: (name, dim, vectors) => window.electron.saveVectors(name, dim, vectors)
      },
      fs: {
        copyBookToAppData,
        removeFile: (path) => window.electron.removeFile(path),
        getAppDataPath: () => window.electron.getAppDataPath()
      },
      fileSync: {
        hashBookFile,
        uploadBookFile,
        booksUpdateFileHash: (bookId, hash, r2Key) =>
          window.electron.booksUpdateFileHash(bookId, hash, r2Key)
      },
      rag: getRagService(),
      embed: embedWithFallback,
      scanner,
      config: {
        copyTimeoutMs: 2 * 60 * 1000,
        parseTimeoutMs: 60 * 1000,
        saveTimeoutMs: 30 * 1000,
        embedBatchSize: 2
      }
    })
  }
  return _import
}
```

> If `window.electron.getBookData` / `saveBook` / `savePageDataMany` / `getAllPageDataByBookId` / `hasSavedEpubData` / `saveVectors` / `booksUpdateFileHash` are not present on the typed `Electron` preload surface (they should be — they back the current `@/lib/api` calls), thin one-line adapters around the existing `@/lib/api` named functions are an acceptable substitute (`saveBook: (b) => api.saveBook({ book: b })`, etc.). The shape required by `BookStoreIpc` is the only contract — wherever the bytes come from is the wiring site's concern.

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
```

If the typecheck fails on a `window.electron.*` member, switch that line to the `@/lib/api` wrapper as described above.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "feat(book-import): wire production getBookImportService singleton

Composes window.electron (formats / db / fs / scanner IPC), the
existing copyBookToAppData / hashBookFile / uploadBookFile / embedWithFallback
helpers, and getRagService() for the rag port. createScannerPort
wraps window.electron.on('scan-*', ...) at the wiring boundary."
```

---

## Task 10: Migrate `FileComponent`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/FileComponent.tsx`

- [ ] **Step 1: Replace the imports**

In `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/components/FileComponent.tsx`, remove these imports:

```ts
import {
  Book,
  deleteBook,
  getBookData,
  getBooks,
  getDjvuData,
  getMobiData,
  getPdfData,
  saveBook
} from '@/lib/api'
import { copyBookToAppData } from '@/modules/books'
import { hashBookFile, uploadBookFile } from '@/modules/file-sync'
```

Replace with (keep `Book`, `deleteBook`, `getBooks` since they're still used):

```ts
import { Book, deleteBook, getBooks } from '@/lib/api'
import { getBookImportService } from '@/services'
```

- [ ] **Step 2: Delete the inline pipeline + helpers**

Remove the entire block from `function withTimeout` through `const SAVE_TIMEOUT = 30 * 1000` (lines roughly 31–52 in the current file). Also remove the `importBook` function (lines roughly 163–233) and replace `processFilePaths` with a service-driven version:

```ts
  const processFilePaths = async (filePaths: string[]) => {
    const svc = getBookImportService()
    const results = await svc.importBatch(filePaths)

    let lastSuccess: { ok: true; bookId: number } | null = null
    for (const r of results) {
      if (!r.ok) {
        toast.error(`Failed to import ${r.filePath}: ${r.error}`)
        continue
      }
      lastSuccess = { ok: true, bookId: r.bookId }
    }

    await queryClient.invalidateQueries({ queryKey: ['books'] })
    if (lastSuccess) {
      setNewBookId(null)
      setTimeout(() => setNewBookId(String(lastSuccess!.bookId)), 0)
    }
  }
```

- [ ] **Step 3: Confirm no stale references remain**

```bash
cd /tmp/rishi-book-import-refactor
grep -n "withTimeout\|COPY_TIMEOUT\|EXTRACT_TIMEOUT\|SAVE_TIMEOUT\|importBook\|copyBookToAppData\|hashBookFile\|uploadBookFile\|getBookData\|getPdfData\|getMobiData\|getDjvuData\|saveBook" \
  apps/rishi-electron/src/renderer/src/components/FileComponent.tsx
```

Expected: no matches.

- [ ] **Step 4: Verify typecheck passes**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/components/FileComponent.tsx
git commit -m "refactor(book-import): migrate FileComponent to getBookImportService().importBatch

Drops ~80 LOC of inline pipeline (withTimeout helper, 3 timeout
constants, 4-branch extension switch, hash+upload try/catch). Toast
on failure + react-query invalidation + new-book navigation remain in
the component as composition concerns above the service."
```

---

## Task 11: Migrate `BookDiscoveryModal`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx`

- [ ] **Step 1: Replace the imports + the `BookDiscoveryModalProps` shape**

In `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx`, replace:

```ts
import { cancelScan } from '@/lib/api'
import { chooseFiles } from '@/modules/chooseFiles'
```

with:

```ts
import { chooseFiles } from '@/modules/chooseFiles'
import { getBookImportService, type DiscoveredBook, type ScanProgress } from '@/services'
```

> The local `DiscoveredBook` / `ScanProgress` interfaces at the top of the file should be deleted in favor of the types re-exported from `@/services`.

Update the `BookDiscoveryModalProps` interface to drop the `onImport` / `onImportFiles` props (the modal now owns its imports):

```ts
interface BookDiscoveryModalProps {
  open: boolean
  onClose: () => void
}
```

- [ ] **Step 2: Replace the scan effect + the import callbacks**

Replace the existing `unsubRefs` / `cleanupListeners` / `startScan` / `useEffect` block with a service-driven version:

```tsx
  useEffect(() => {
    if (!open) return
    const svc = getBookImportService()

    setBooks([])
    setProgress(null)
    setScanComplete(false)
    setScanning(true)

    const unsub = svc.onDiscoveryEvent((event) => {
      if (event.kind === 'book-found') {
        setBooks((prev) => [...prev, event.book])
      } else if (event.kind === 'progress') {
        setProgress(event.progress)
      } else if (event.kind === 'complete') {
        setScanning(false)
        setScanComplete(true)
        setProgress(null)
      } else if (event.kind === 'error') {
        console.error('[discovery] scanner error:', event.error)
        setScanning(false)
      }
    })

    svc.startDiscovery(mode)

    return () => {
      unsub()
      void svc.cancelDiscovery()
    }
  }, [open, mode])
```

Replace `handleBrowseFiles` body:

```ts
  const handleBrowseFiles = async () => {
    try {
      const filePaths = await chooseFiles()
      if (filePaths.length > 0) {
        void getBookImportService().importBatch(filePaths)
        handleClose()
      }
    } catch (err) {
      console.error('Failed to open file picker:', err)
    }
  }
```

Replace `handleImport` and `handleImportAll`:

```ts
  const handleImport = (filepath: string) => {
    setImportingPaths((prev) => new Set(prev).add(filepath))
    setBooks((prev) => prev.filter((b) => b.filepath !== filepath))
    void getBookImportService().importBatch([filepath])
  }

  const handleImportAll = () => {
    const toImport = filteredBooks
    const newPaths = new Set(importingPaths)
    toImport.forEach((b) => newPaths.add(b.filepath))
    setImportingPaths(newPaths)
    setBooks((prev) => prev.filter((b) => !newPaths.has(b.filepath)))
    void getBookImportService().importBatch(toImport.map((b) => b.filepath))
  }
```

Replace `handleClose`:

```ts
  const handleClose = async () => {
    await getBookImportService().cancelDiscovery()
    setBooks([])
    setFilter('')
    setScanning(false)
    setScanComplete(false)
    setProgress(null)
    setImportingPaths(new Set())
    onClose()
  }
```

Replace `handleModeChange` (the service is single-flight, so we no longer cancel manually):

```ts
  const handleModeChange = (newMode: ScanMode) => {
    if (newMode === mode) return
    setMode(newMode) // useEffect on `mode` will restart discovery
  }
```

- [ ] **Step 3: Update `FileComponent` to drop the modal callback props**

In `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/components/FileComponent.tsx`, change:

```tsx
      <BookDiscoveryModal
        open={discoveryOpen}
        onClose={() => setDiscoveryOpen(false)}
        onImport={(fp) => processFilePaths([fp])}
        onImportFiles={processFilePaths}
      />
```

to:

```tsx
      <BookDiscoveryModal open={discoveryOpen} onClose={() => setDiscoveryOpen(false)} />
```

The `processFilePaths` function from Task 10 is now only used by drag-drop — keep it.

- [ ] **Step 4: Sanity-grep**

```bash
cd /tmp/rishi-book-import-refactor
grep -n "window.electron.on\|window.electron.scanForBooks\|cancelScan\|unsubRefs\|onImport\|onImportFiles" \
  apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx
```

Expected: no matches (or only matches that are unrelated to scan, such as the `<input onChange>` for filter — those are fine).

- [ ] **Step 5: Verify typecheck passes**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
```

- [ ] **Step 6: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/components/BookDiscoveryModal.tsx \
        apps/rishi-electron/src/renderer/src/components/FileComponent.tsx
git commit -m "refactor(book-import): migrate BookDiscoveryModal to getBookImportService

Drops the 3 window.electron.on('scan-*', ...) listeners, the unsubRefs
ref + cleanupListeners callback, the cancelScan import from @/lib/api,
and the onImport / onImportFiles prop interface. The modal now owns
its imports via svc.importBatch(). The local DiscoveredBook /
ScanProgress interfaces are replaced by the service's public types."
```

---

## Task 12: Migrate viewer `processEpubJob` callers

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/mobi/MobiView.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/components/djvu/DjvuView.tsx`
- Modify: `apps/rishi-electron/src/renderer/src/stores/epubStore.ts`

- [ ] **Step 1: Inventory call sites**

```bash
cd /tmp/rishi-book-import-refactor
grep -rn "processEpubJob\|from '@/modules/process_epub'" \
  apps/rishi-electron/src/renderer/src
```

Expected: three callers (`MobiView`, `DjvuView`, `epubStore`) plus the module file + its test.

- [ ] **Step 2: Update `MobiView`**

In `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/components/mobi/MobiView.tsx`, replace:

```ts
import { processEpubJob } from '@/modules/process_epub'
```

with:

```ts
import { getBookImportService } from '@/services'
```

Replace:

```ts
          await processEpubJob(book.id, allPageData)
```

with:

```ts
          await getBookImportService().indexBook(book.id, allPageData)
```

- [ ] **Step 3: Update `DjvuView`**

Same swap as Step 2 for `apps/rishi-electron/src/renderer/src/components/djvu/DjvuView.tsx`.

- [ ] **Step 4: Update `epubStore`**

In `/tmp/rishi-book-import-refactor/apps/rishi-electron/src/renderer/src/stores/epubStore.ts`, replace:

```ts
import { processEpubJob } from '@/modules/process_epub'
import { hasSavedEpubData, type BookOutline } from '@/lib/api'
```

with:

```ts
import { type BookOutline } from '@/lib/api'
import { getBookImportService } from '@/services'
```

Then replace the subscription body that currently reads:

```ts
          void hasSavedEpubData({ bookId: Number(bookId) })
            .then((hasSaved) => {
              if (!hasSaved) {
                void getAllParagraphsForBook(paragraphRendition, bookId)
                  .then((paragraphs) => {
                    void processEpubJob(Number(bookId), paragraphs)
                  })
                  .catch((err) => captureError(err, { operation: 'epub', step: 'get_paragraphs' }))
              }
            })
            .catch((err) => captureError(err, { operation: 'epub', step: 'check_saved_data' }))
```

with the simpler service-call form — `indexBook` already handles the chunks-exist short-circuit internally, so the `hasSavedEpubData` pre-check is redundant:

```ts
          void getAllParagraphsForBook(paragraphRendition, bookId)
            .then((paragraphs) =>
              getBookImportService().indexBook(Number(bookId), paragraphs)
            )
            .catch((err) => captureError(err, { operation: 'epub', step: 'index_book' }))
```

- [ ] **Step 5: Sanity-grep**

```bash
cd /tmp/rishi-book-import-refactor
grep -rn "processEpubJob\|from '@/modules/process_epub'" \
  apps/rishi-electron/src/renderer/src
```

Expected: matches only inside `modules/process_epub.ts` (definition) and `modules/__tests__/process_epub.recovery.test.ts` (test) — both deleted in Task 13.

- [ ] **Step 6: Verify typecheck passes**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
```

- [ ] **Step 7: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git add apps/rishi-electron/src/renderer/src/components/mobi/MobiView.tsx \
        apps/rishi-electron/src/renderer/src/components/djvu/DjvuView.tsx \
        apps/rishi-electron/src/renderer/src/stores/epubStore.ts
git commit -m "refactor(book-import): migrate MobiView / DjvuView / epubStore to indexBook

processEpubJob -> getBookImportService().indexBook(bookId, pageData).
In epubStore the redundant hasSavedEpubData pre-check is dropped —
indexBook owns the skip-when-done branch internally."
```

---

## Task 13: Delete legacy modules + tests

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/modules/process_epub.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/__tests__/process_epub.recovery.test.ts`

KEEP: `apps/rishi-electron/src/renderer/src/modules/embed-fallback.ts` — consumed via the `embed` port by both the RAG service and the book-import service.
KEEP: `apps/rishi-electron/src/renderer/src/modules/books.ts` — `copyBookToAppData` is consumed via the `fs` port.
KEEP: `apps/rishi-electron/src/renderer/src/modules/file-sync.ts` — `hashBookFile` and `uploadBookFile` are consumed via the `fileSync` port.

- [ ] **Step 1: Confirm no remaining imports of the old names**

```bash
cd /tmp/rishi-book-import-refactor
git grep -nE "from '@/modules/process_epub'|from '\\./process_epub'" \
  apps/rishi-electron/src/renderer/src
```

Expected: only matches inside the two files we are about to delete. If any external caller still imports `processEpubJob`, return to Task 12 and complete the migration before continuing.

- [ ] **Step 2: Delete the two files**

```bash
cd /tmp/rishi-book-import-refactor
git rm apps/rishi-electron/src/renderer/src/modules/process_epub.ts \
       apps/rishi-electron/src/renderer/src/modules/__tests__/process_epub.recovery.test.ts
```

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
```

- [ ] **Step 4: Run the book-import service test suite**

```bash
pnpm vitest run src/renderer/src/services/book-import/
```

Expected: all book-import service tests pass — emitter (3), dispatch (7), indexer (5), importer (6), scanner-adapter (3), service (11). 35 total.

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-book-import-refactor
git commit -m "refactor(book-import): delete legacy process_epub module + recovery test

2 files removed. embed-fallback / books / file-sync stay (consumed via
ports by the service). Per meta-spec's no-shims rule: one PR, one
source of truth. All indexing flows through
getBookImportService().indexBook()."
```

---

## Task 14: Final verification & PR

**Files:** none (verification only).

- [ ] **Step 1: Run typecheck, lint, and the full test suite**

```bash
cd /tmp/rishi-book-import-refactor/apps/rishi-electron
pnpm typecheck
pnpm lint
pnpm vitest run
```

Expected: all three pass *for the book-import-touched surface*. The following pre-existing failures are out of scope and must NOT be touched:
- `src/main/**` typecheck errors (sqlite/electron typing drift, unrelated to the renderer)
- `stores/navStore.test.ts` typecheck error (unrelated)
- `queries.outline*` runtime test failures from a better-sqlite3 native binding mismatch in the worktree

If a *new* failure appears that is clearly caused by book-import changes (any test file under `services/book-import/`, or any of the five migrated callers), fix it in a follow-up commit (`fix(book-import): ...`) before opening the PR.

- [ ] **Step 2: Sanity-check `services/index.ts` is the only wiring site**

```bash
cd /tmp/rishi-book-import-refactor
grep -rn "createBookImportService" apps/rishi-electron/src/
```

Expected: matches only in `services/book-import/service.ts` (definition), `services/book-import/index.ts` (re-export), `services/index.ts` (wiring), and `services/book-import/service.test.ts` (test usage). No other call sites.

- [ ] **Step 3: Sanity-check internals are not externally imported**

```bash
cd /tmp/rishi-book-import-refactor
grep -rnE "from '@/services/book-import/dispatch'|from '@/services/book-import/importer'|from '@/services/book-import/indexer'|from '@/services/book-import/emitter'|from '@/services/book-import/scanner-adapter'|from '@/services/book-import/service'|from '@/services/book-import/types'" \
  apps/rishi-electron/src/
```

Expected: no matches outside `apps/rishi-electron/src/renderer/src/services/book-import/`.

- [ ] **Step 4: Push the branch and open the PR**

```bash
cd /tmp/rishi-book-import-refactor
git push -u origin refactor/book-import-service
gh pr create --title "refactor(book-import): collapse import/discovery/indexing into services/book-import deep module" --body "$(cat <<'EOF'
## Summary
- New `BookImportService` at `apps/rishi-electron/src/renderer/src/services/book-import/` collapses `FileComponent`'s inline `importBook` orchestration, `BookDiscoveryModal`'s scanner-listener wiring, `modules/process_epub.ts`'s post-open indexing, and the loose IPC wrappers in `lib/api.ts` behind a typed factory boundary.
- 8 ports injected at the wiring site: `formats`, `db`, `fs`, `fileSync`, `rag`, `embed`, `scanner`, `config`. The just-shipped `RagService` is consumed via the `rag` port; `embed-fallback.ts` stays as a helper consumed via the `embed` port.
- Public surface is 5 methods + 2 subscriptions: `importFromPath`, `importBatch`, `indexBook`, `startDiscovery`, `cancelDiscovery`, `onDiscoveryEvent` (unsubscribe), `onImportProgress` (unsubscribe). Discriminated `ImportResult` centralizes per-stage error classification.
- Callers migrated (5 files): `FileComponent` (drops ~80 LOC of inline pipeline), `BookDiscoveryModal` (drops 3 `window.electron.on` listeners + `unsubRefs` + the `onImport*` prop interface), `MobiView`, `DjvuView`, `epubStore`.
- 2 legacy files deleted (`process_epub.ts` + its recovery test). No shims.
- TDD throughout: red → green → commit per behavior. 35 new boundary tests.

Spec: `docs/superpowers/specs/2026-05-11-book-import-service-design.md`
Meta-spec: `docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md` (Wave 2, service 1 of 2)

## Test plan
- [ ] `pnpm typecheck` clean for the book-import surface (pre-existing `src/main/**` and `navStore.test.ts` errors are out of scope)
- [ ] `pnpm lint` clean
- [ ] `pnpm vitest run src/renderer/src/services/book-import/` — emitter (3), dispatch (7), indexer (5), importer (6), scanner-adapter (3), service (11) = 35 new boundary tests pass
- [ ] Manual: drag-drop a `.epub` into the library; observe toast on success and navigation to the new book
- [ ] Manual: drag-drop a `.txt` file; observe "Unsupported format" toast and no orphan files in `userData/`
- [ ] Manual: drag-drop a corrupt `.epub`; observe parse-failure toast AND no orphan copied file in `userData/` (rollback)
- [ ] Manual: open the discovery modal, switch from "Common folders" to "Search entire computer"; observe the prior scan cancels and the new mode starts
- [ ] Manual: open the modal, click "Import All" on a multi-book result; observe each book imports independently and failures don't stop the batch
- [ ] Manual: open a MOBI book; observe the embedding pipeline runs (no console errors) and `processEpubJob` is no longer in the call stack
- [ ] Manual: open an EPUB book whose chunks were saved but whose vectors are missing (regression case from e44ab1b9); observe re-embedding runs and `vectors-missing` event fires
EOF
)"
```

---

## Summary

After all tasks complete:

- **~22 commits** on the `refactor/book-import-service` branch in the `/tmp/rishi-book-import-refactor` worktree.
- **35 new boundary tests** across `services/book-import/{emitter,dispatch,indexer,importer,scanner-adapter,service}.test.ts` — all using hand-rolled adapter helpers (`makeFormats`, `makeDb`, `makeFs`, `makeDbForImport`, `makeRag`, `makeEmbed`, `makeFileSync`, `makeScanner`, `makeDeps`), no `vi.mock`, no `vi.resetModules`.
- **Net diff (approximate):** +1100 lines added (service + tests + types + emitter + dispatch + indexer + importer + scanner-adapter + wiring), −250 lines removed (`process_epub.ts` + its test + the inline import / discovery code in `FileComponent` / `BookDiscoveryModal` + the `onImport*` prop interface). Moderately positive.
- **No internals exported.** The public surface from `services/book-import/index.ts` is `createBookImportService` + `createScannerPort` (wiring-site helper) + 18 public types. Dispatch, importer, indexer, emitter, and scanner-adapter internals stay strictly internal.
- **RagService is consumed.** `indexBook` uses `rag.isIndexed(bookId)` as the chunks-already-indexed check. No new `hasVectorsForBook` calls; the just-shipped Wave 1 service is the single source of truth for "is this book indexed."
- **Embedding fallback stays a helper.** `embed-fallback.ts` is reused unchanged via the `embed` port. The book-import service does NOT own the on-device/server fallback logic — that responsibility stays in the helper, also consumed by the RAG service.
- **Scanner port adapter is internal but exported from `book-import/index.ts`** as a wiring-site helper (`createScannerPort`) so `services/index.ts` does not inline three `window.electron.on(...)` calls.
- All 17 boundary scenarios from the spec's Test Strategy section are covered across the 35 tests (importFromPath happy path, extension routing × 5, unsupported, copy failure, parse-rollback, save failure, upload fire-and-forget, importBatch resilience, importBatch order, indexBook skip / full / re-embed regression / swallow / db-fallback, discovery streaming, single-flight start, cancel propagation, onImportProgress unsubscribe).
