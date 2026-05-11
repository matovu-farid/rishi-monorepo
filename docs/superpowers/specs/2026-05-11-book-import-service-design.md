# Book Import service — design

**Status:** draft 2026-05-11
**Parent:** [`2026-05-11-services-and-effect-adoption-design.md`](./2026-05-11-services-and-effect-adoption-design.md) (meta-spec)
**Scope:** Wave 2, service #1 of 2 (Voice Chat is the other). Stage 1 only (plain TypeScript). `apps/rishi-electron` renderer-side service that consolidates the import / discovery / post-import indexing orchestration currently scattered across `FileComponent.tsx`, `BookDiscoveryModal.tsx`, and `modules/process_epub.ts`.

## Goal

Collapse the renderer-side book import pipeline — drag-drop + browse + scanner-driven bulk import + per-file copy → parse → save → kick-async-index flow — plus the post-open RAG indexing recovery path (`processEpubJob`) into one cohesive renderer-side service exposed through a small, typed interface. Hide format dispatch (`.epub` / `.pdf` / `.mobi` / `.azw3` / `.djvu` → which `getXData` IPC), the per-stage timeouts, the file-hash + R2 upload best-effort step, the scanner event subscription, the chunks-vs-vectors recovery logic, and the embedding fallback (on-device → server) behind a ~6-method facade. Callers stop juggling three modules; they call `getBookImportService().importFromPath(...)`, `.importBatch(...)`, `.indexBook(...)`, `.startDiscovery(...)`, `.cancelDiscovery()`, `.onDiscoveryEvent(...)`, `.onImportProgress(...)`.

## Background

Book import today is split across three renderer-side surfaces plus several call sites:

- **`components/FileComponent.tsx`** (~437 LOC) — owns the drag-drop dropzone, the `importBook(filePath)` orchestrator (extension dispatch → `copyBookToAppData` → `getXData` → `saveBook` → best-effort `hashBookFile` + `uploadBookFile` + `booksUpdateFileHash` → react-query invalidation → navigate to new book), three module-scoped per-stage timeout constants (`COPY_TIMEOUT=120s`, `EXTRACT_TIMEOUT=60s`, `SAVE_TIMEOUT=30s`), and a `withTimeout` helper used inline. The `processFilePaths` function is bulk-import (forEach over `importBook`).
- **`components/BookDiscoveryModal.tsx`** (~362 LOC) — owns the scanner lifecycle (`startScan` calls `window.electron.scanForBooks(mode)`, then subscribes to three `window.electron.on('scan-result' | 'scan-progress' | 'scan-complete')` channels), the cancellation path (`cancelScan` IPC + listener unsubscribe + state reset), the "Import All" / "Import" bulk-import handoff back to `FileComponent` via `onImport` / `onImportFiles` props, and an in-memory cache of discovered books with mode/filter UI state.
- **`modules/process_epub.ts`** (~92 LOC) — owns the post-open RAG indexing pipeline: `processEpubJob(bookId, pageData)` checks `hasSavedEpubData(bookId)` + `hasVectorsForBook(bookId)`, saves chunks if missing, batches into pairs of 2, calls `embedWithFallback` for each batch, saves vectors. The chunks-exist-but-vectors-missing recovery path is baked in. Three viewers (`MobiView`, `DjvuView`) and the `epubStore` call this directly.
- **`modules/embed-fallback.ts`** — owns the embed strategy: try on-device via `window.electron.embed`, fall back to `POST ${WORKER_URL}/api/embed` with the same bearer/dev-bypass header dance the TTS service used to inline. Exports `embedWithFallback` (batch) and `embedSingleText` (used by the just-shipped RAG service).

Symptoms that motivated the meta-spec:

- **Format dispatch is duplicated and inline.** `FileComponent.importBook` has a 4-branch `if/else if` on the file extension picking which `getXData` to call, each branch wrapping the call in `withTimeout(..., EXTRACT_TIMEOUT, 'Extracting metadata')`. Adding a new format requires editing this branch in `FileComponent`. There is no per-format adapter abstraction.
- **`processEpubJob` is misnamed and overloaded.** It runs for EPUB *and* MOBI *and* DJVU (the viewers pre-compute `pageData` from format-specific text streams and hand it off). The function name lies. The job has two responsibilities — save chunks if needed, re-embed if needed — driven by two `hasX` checks. Both are tested today in `process_epub.recovery.test.ts`; the second was a regression caught in commit `e44ab1b9`.
- **`window.electron.on('scan-result'|'scan-progress'|'scan-complete')` is reached into from a component.** `BookDiscoveryModal` registers three listeners, stores the unsubscribers in a ref, and runs them in a cleanup callback. There is no abstraction over "subscribe to scanner events" — every consumer of scan results would have to reproduce this pattern.
- **The bulk-import handoff is prop-drilled.** `FileComponent` passes `onImport` and `onImportFiles` callbacks to `BookDiscoveryModal`; the modal calls them with raw paths; `FileComponent` then iterates and calls `importBook` for each — a free-function defined inside the component. There is no single owner of "import these N files."
- **The best-effort R2 upload is sandwiched into `importBook`.** `hashBookFile` + `uploadBookFile` + `booksUpdateFileHash` are inline in `FileComponent`, wrapped in a try/catch that swallows the error with a `console.warn`. The hash + upload step has no test, no telemetry, no observability beyond the warn.
- **The post-import indexing trigger is ambiguous.** `FileComponent` does *not* trigger indexing after save — indexing is kicked by the viewers on open (`MobiView`, `DjvuView`, `epubStore`). That coupling is implicit; nothing enforces it. If a viewer forgets to call `processEpubJob`, the book is never indexed and RAG fails silently for that book.
- **No single owner of "import this file; make it a usable, indexed book."** Every layer assembles part of the pipeline. The meta-spec called this out explicitly as Wave 2's natural cap.

This refactor introduces a single renderer-side Book Import service that wraps format dispatch + per-stage timeouts + file-hash + R2 upload + scanner event subscription + cancellation + post-import indexing + recovery + embedding fallback, exposes a small typed interface plus two subscription APIs, and replaces every caller's import. The format-specific parsers in `src/main/ipc/formats.ts` (1003 LOC) stay where they are; the renderer service consumes them via an injected `formats` port. The just-shipped RAG service is consumed for the "is this book indexed" check.

## Non-goals

- Changing the main-process format parsers (`extractEpubData`, `extractPdfData`, `extractMobiData`, `extractDjvuData`). Their IPC surface stays as-is; the service consumes them through an injected `formats` port.
- Changing the main-process scanner (`scanForBooks`, `cancelScan`, and the `scan-result` / `scan-progress` / `scan-complete` IPC events). The service consumes them through an injected `scanner` port.
- Changing the embedding semantics (on-device → server fallback, batching by pairs of 2, the worker URL `https://api.fidexa.org/api/embed`). Behavior preserved.
- Adding a URL-import path. Open question — leans separate-adapter that produces a `filePath` and then calls `importFromPath`; not in this spec.
- Replacing react-query / the `usePdfStore` / the navigation-to-new-book behavior. Those stay in `FileComponent` as composition concerns above the service.
- Adding new product features (per-format pre-flight validation, duplicate detection, conflict resolution UI, parallel batch with rate limiting). Scope guard per meta-spec.
- Migrating to Effect-TS. Stage 1 is plain TypeScript. Effect is a Stage 2 candidate (see "Stage 2 outlook" below).

## Decision summary

| Question | Decision |
|---|---|
| Service scope | Format dispatch + copy → parse → save → kick-async-index pipeline + best-effort upload + scanner lifecycle + post-import indexing + recovery + embedding fallback orchestration. |
| Boundary | One module: `services/book-import/`. Single factory `createBookImportService(deps)`. |
| Public interface size | 5 methods + 2 subscribe APIs. No free functions, no prop-drilled callbacks, no `window.electron.on(...)` in callers. |
| Return shape | `importFromPath` → `Promise<ImportResult>`. `importBatch` → `Promise<ImportResult[]>` (settles, never rejects on a single failure). `indexBook` → `Promise<void>`. `startDiscovery` → `void` (results stream via event). `cancelDiscovery` → `Promise<void>`. Subscriptions return unsubscribe handles. |
| `indexBook` visibility | **Public.** Viewers (`MobiView`, `DjvuView`, `epubStore`) explicitly request indexing — they know when the book is "open enough" to warrant indexing. Recovery logic baked in. (Lean from the open questions.) |
| Format dispatch | Centralized in `service.ts`. Single `formatFor(ext)` mapping `.epub` / `.pdf` / `.mobi` / `.azw3` / `.djvu` → format adapter. Adding a format is one entry in one switch. |
| Embedding fallback | `embed-fallback.ts` stays as a renderer-side helper. The service consumes it through an injected `embed` port (`(params: EmbedParam[]) => Promise<EmbedResult[]>`). The wiring site composes `embedWithFallback` from the existing helper. Not exposed on the service surface. |
| Format-specific parsers | Stay in `main/ipc/formats.ts`. Service consumes them via injected `formats` port — five methods (`getBookData` for EPUB, `getPdfData`, `getMobiData`, `getDjvuData`, plus the `copyFile` from FS port). |
| Scanner | Injected `scanner` port: `{ start(mode), cancel(), on(kind, listener) }`. Wraps `window.electron.scanForBooks` + `cancelScan` + the three IPC events into a typed subscribe-style adapter. Service exposes results via `onDiscoveryEvent`. |
| FS | Injected `fs` port — `copyFile`, `mkdir`, `exists`, `removeFile`, `getAppDataPath`, `checkFileSize`. The `copyBookToAppData` helper currently in `modules/books.ts` is absorbed into the service (production wiring passes `window.electron.copyBookToAppData` directly, OR the service builds the same target path from `getAppDataPath` — pick the former for behavior parity). |
| RAG dependency | Injected `rag: RagService` port — the just-shipped Wave 1 service. Used by `indexBook` to check `rag.isIndexed(bookId)` before running the chunks/vectors save. Natural Wave-1 reuse. |
| File-hash + upload | Stays best-effort inside `importFromPath`. Failures are swallowed (today's behavior), but emit an `onImportProgress` event with `{ kind: 'upload-failed', filePath, bookId, error }` for observability. The hash + upload helpers themselves stay in `modules/file-sync.ts` and are consumed through an injected `fileSync` port. |
| Per-stage timeouts | Injected via `config` port — `copyTimeoutMs`, `parseTimeoutMs`, `saveTimeoutMs`. Defaults match today (`120s`, `60s`, `30s`). |
| Error model | `Promise` rejections with `Error` subclasses inside `importFromPath`. `importBatch` resolves with an array of `ImportResult` (success or failure per item) — never rejects. `indexBook` resolves `void` on success, throws on un-recoverable failure (current behavior of `processEpubJob`). No typed error channel in Stage 1. |
| Event surface | Small `Emitter<T>` pattern from TTS / Sync — `service.onDiscoveryEvent(cb)` and `service.onImportProgress(cb)` return `() => void` unsubscribe. Events are typed discriminated unions. |
| Wiring site | `src/renderer/src/services/index.ts` (alongside RAG / TTS / Sync). Lazy singleton via `getBookImportService()`. |
| Test placement | One file: `src/renderer/src/services/book-import/service.test.ts`. Existing `process_epub.recovery.test.ts` deleted; its 5 scenarios are absorbed into the new boundary tests. |
| Effect adoption (Stage 2) | Strong. Predicted 4 of 5 axes (concurrency for batch, retry for indexing fallback, composed async pipeline, typed errors per-stage). Internal-only adoption; public interface stays plain TS. |

## Boundary

### What the service owns

- The end-to-end import pipeline: format detection from extension → copy to app data → parse via format port → save via DB port → fire-and-forget best-effort upload → emit `done` event.
- The per-stage timeouts (copy / parse / save). One config object, one `withTimeout` helper, applied uniformly.
- The bulk import driver — `importBatch` iterates, calls `importFromPath` per file, settles independently per item, never short-circuits.
- The post-import indexing pipeline: `indexBook(bookId)` looks up chunks/vectors state via the `rag` port + DB port, saves chunks if missing, batches `pageData` into pairs of 2, calls embed (via `embed` port), saves vectors. Recovery (chunks-exist-but-vectors-missing) baked in.
- The scanner lifecycle subscription — wraps the `scanner` port's three event channels into one typed `DiscoveryEvent` stream.
- The cancellation policy — `cancelDiscovery()` calls the scanner port's `cancel`, clears the local discovered-books buffer (caller maintains its own state), and emits a `complete` event with `cancelled: true`.
- The per-import progress emission — every stage transition (`copying` → `parsing` → `saving` → `indexing` → `done` / `failed`) fans out via `onImportProgress`.

### What stays outside

- **The main-process format parsers** (`main/ipc/formats.ts`). They stay; the service consumes them via the `formats` port.
- **The main-process scanner** (`main/ipc/scanner.ts`). It stays; the service consumes it via the `scanner` port.
- **The page-data extraction inside the viewers.** `MobiView` / `DjvuView` build `PageDataInsertable[]` from format-specific text streams, then hand it to `indexBook(bookId, pageData)`. The viewers know which format-specific pagination to use; the service does not. The viewer-side pageData construction stays in the viewers.
- **The EPUB paragraph extraction** (`getAllParagraphsForBook` inside `epubStore`). Stays in the store; passed into `indexBook(bookId, paragraphs)` like the viewers.
- **The react-query cache invalidation.** `FileComponent` invalidates the `['books']` query *after* `importFromPath` resolves. The service does not know about react-query.
- **The navigation to the new book.** `FileComponent` reads the result and navigates. The service does not know about routing.
- **The embedding implementation.** `embedWithFallback` and `embedSingleText` stay in `modules/embed-fallback.ts`. The service consumes them via the `embed` port.
- **The file-hash + R2 upload implementation.** `hashBookFile` and `uploadBookFile` stay in `modules/file-sync.ts`. The service consumes them via the `fileSync` port.
- **The `usePdfStore` PDF-id registry.** `FileComponent` populates it from `getBooks()`; the service does not know about it.
- **The drag-and-drop / dropzone UI.** `react-dropzone` stays in `FileComponent`; it just produces a `string[]` and calls `importBatch`.

### What's hidden behind the interface

Callers don't see: the 4-branch extension switch, the three timeout constants, the `withTimeout` helper, the `copyBookToAppData` indirection, the three IPC event channel names (`scan-result` / `scan-progress` / `scan-complete`), the `MAX_BATCH_SIZE=2` embedding batch size, the `hasSavedEpubData` + `hasVectorsForBook` recovery branch, the file-hash + R2 upload best-effort flow, the `EmbedParam` / `EmbedResult` / `Vector` shape, the scanner's `cancelScan` IPC, the three viewer-specific call sites for `processEpubJob`.

## Dependencies

All eight dependencies are categorized per the meta-spec.

| Dep | Category | What the service uses | Production adapter | Test adapter |
|---|---|---|---|---|
| `formats` | Remote-but-owned (port + adapter) | `getBookData(path)`, `getPdfData(path)`, `getMobiData(path)`, `getDjvuData(path)` | `{ getBookData: window.electron.getBookData, ... }` (direct passthrough) | `makeFormats({ epubReturns?, pdfReturns?, mobiReturns?, djvuReturns?, throwOn?: string })` — in-memory canned responses keyed by ext or path |
| `db` | Remote-but-owned (port + adapter) | `saveBook(book)`, `savePageDataMany(pageData)`, `getAllPageDataByBookId(bookId)`, `hasSavedEpubData(bookId)`, `saveVectors(name, dim, vectors)` | `{ saveBook: (b) => window.electron.saveBook(b), ... }` | `makeDb({ books, pageData, vectors })` — in-memory stores with sync semantics |
| `fs` | Remote-but-owned (port + adapter) | `copyBookToAppData(path)`, `mkdir(path)`, `exists(path)`, `removeFile(path)`, `getAppDataPath()`, `checkFileSize(path, format)` | `{ copyBookToAppData: copyBookToAppData, mkdir: window.electron.mkdir, ... }` | `makeFs({ files: Map<string, Uint8Array>, appDataPath })` — in-memory FS with `.setFileSize(path, n)` helper |
| `rag` | In-process (service-to-service) | `rag.isIndexed(bookId): Promise<boolean>` | `getRagService()` from `@/services` | `makeRag({ indexedBookIds: Set<number> })` — returns the just-shipped `RagService` shape |
| `embed` | In-process | `(params: EmbedParam[]) => Promise<EmbedResult[]>` | `embedWithFallback` from `@/modules/embed-fallback` | `makeEmbed({ vectorsByText, failNTimes? })` |
| `fileSync` | In-process | `hashBookFile(path)`, `uploadBookFile(path, hash, format)`, `booksUpdateFileHash(bookId, hash, r2Key)` | `{ hashBookFile, uploadBookFile, booksUpdateFileHash: window.electron.booksUpdateFileHash }` | `makeFileSync({ hashImpl?, uploadImpl?, throwOn? })` |
| `scanner` | Remote-but-owned (port + adapter) | `{ start(mode), cancel(), on(kind, listener): unsubscribe }` | Built at the wiring site from `window.electron.scanForBooks`, `window.electron.cancelScan`, and `window.electron.on('scan-result' | 'scan-progress' | 'scan-complete', ...)` | `makeScanner()` — exposes `.emit({ kind, ... })`, `.startCount()`, `.cancelCount()` |
| `config` | In-process | `{ copyTimeoutMs, parseTimeoutMs, saveTimeoutMs, embedBatchSize }` | Literal object at wiring site | Literal object in tests |

The service is testable as plain code under vitest. No Electron runtime, no real IPC, no real network.

### Scanner port

The scanner port shape:

```ts
export type DiscoveredBook = {
  filepath: string
  filename: string
  title: string | null
  author: string | null
  format: string
  fileSize: number
  folder: string
  fileHash: string | null
}

export type ScanProgress = { folder: string; scanned: number; total: number }

export interface ScannerPort {
  start(mode: 'default' | 'full'): Promise<void>
  cancel(): Promise<void>
  on(kind: 'result', listener: (book: DiscoveredBook) => void): () => void
  on(kind: 'progress', listener: (progress: ScanProgress) => void): () => void
  on(kind: 'complete', listener: () => void): () => void
}
```

The wiring site builds this from `window.electron`:

```ts
const scanner: ScannerPort = {
  start: (mode) => window.electron.scanForBooks(mode),
  cancel: () => window.electron.cancelScan(),
  on: (kind, listener) => {
    const channel =
      kind === 'result' ? 'scan-result' : kind === 'progress' ? 'scan-progress' : 'scan-complete'
    return window.electron.on(channel, (...args: unknown[]) =>
      (listener as (a: unknown) => void)(args[0])
    )
  }
}
```

## Public interface

### Types

```ts
// src/renderer/src/services/book-import/types.ts

export type BookFormat = 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'

export interface ImportSuccess {
  ok: true
  bookId: number
  filePath: string
  format: BookFormat
}

export interface ImportFailure {
  ok: false
  filePath: string
  /** Which stage failed: 'unsupported' | 'copy' | 'parse' | 'save' | 'unknown'. */
  stage: 'unsupported' | 'copy' | 'parse' | 'save' | 'unknown'
  error: string
}

export type ImportResult = ImportSuccess | ImportFailure

export interface PageDataInsertable {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

export type ImportProgressEvent =
  | { kind: 'copying'; filePath: string }
  | { kind: 'parsing'; filePath: string; format: BookFormat }
  | { kind: 'saving'; filePath: string; format: BookFormat }
  | { kind: 'upload-started'; filePath: string; bookId: number }
  | { kind: 'upload-failed'; filePath: string; bookId: number; error: string }
  | { kind: 'indexing'; bookId: number; reason: 'chunks-missing' | 'vectors-missing' }
  | { kind: 'done'; filePath: string; bookId: number; format: BookFormat }
  | { kind: 'failed'; filePath: string; stage: ImportFailure['stage']; error: string }

export type DiscoveredBookFound = { kind: 'book-found'; book: DiscoveredBook }
export type DiscoveryProgress = { kind: 'progress'; progress: ScanProgress }
export type DiscoveryComplete = { kind: 'complete'; cancelled: boolean }
export type DiscoveryError = { kind: 'error'; error: string }

export type DiscoveryEvent =
  | DiscoveredBookFound
  | DiscoveryProgress
  | DiscoveryComplete
  | DiscoveryError

export interface FormatsIpc {
  getBookData(path: string): Promise<BookDataParsed>
  getPdfData(path: string): Promise<BookDataParsed>
  getMobiData(path: string): Promise<BookDataParsed>
  getDjvuData(path: string): Promise<BookDataParsed>
}

export interface BookStoreIpc {
  saveBook(book: BookInsertable): Promise<Book>
  savePageDataMany(pageData: ChunkDataInsertable[]): Promise<void>
  getAllPageDataByBookId(bookId: number): Promise<PageData[]>
  hasSavedEpubData(bookId: number): Promise<boolean>
  saveVectors(name: string, dim: number, vectors: Vector[]): Promise<void>
}

export interface FsIpc {
  copyBookToAppData(filePath: string): Promise<string>
  mkdir(path: string): Promise<void>
  exists(path: string): Promise<boolean>
  removeFile(path: string): Promise<void>
  getAppDataPath(): Promise<string>
  checkFileSize(path: string, format: string): Promise<{ allowed: boolean; size?: number; error?: string | null }>
}

export interface FileSyncIpc {
  hashBookFile(filePath: string): Promise<string>
  uploadBookFile(filePath: string, hash: string, format: 'epub' | 'pdf' | 'mobi' | 'djvu'): Promise<{ r2Key: string }>
  booksUpdateFileHash(bookId: number, hash: string, r2Key: string): Promise<void>
}

export interface BookImportConfig {
  /** Per-stage timeouts. Defaults: 120_000 / 60_000 / 30_000 ms. */
  copyTimeoutMs: number
  parseTimeoutMs: number
  saveTimeoutMs: number
  /** Embedding batch size. Default 2 (matches today's behavior). */
  embedBatchSize: number
}

export interface BookImportServiceDeps {
  formats: FormatsIpc
  db: BookStoreIpc
  fs: FsIpc
  fileSync: FileSyncIpc
  rag: import('../rag').RagService
  embed: (params: EmbedParam[]) => Promise<EmbedResult[]>
  scanner: ScannerPort
  config: BookImportConfig
}
```

### Service interface

```ts
// src/renderer/src/services/book-import/index.ts

export interface BookImportService {
  /**
   * Import a single file. Pipeline: copy → parse (by extension) → save → fire
   * best-effort hash+upload → emit done. Per-stage timeouts applied from
   * config. Emits `ImportProgressEvent`s for each stage.
   *
   * Resolves with `{ ok: true, bookId, ... }` on success or
   * `{ ok: false, stage, error }` on failure (per-stage classified). Does NOT
   * reject for known failure modes; callers branch on `.ok`. Rejects only on
   * truly unexpected errors (programmer errors, port misconfigurations).
   *
   * Does NOT trigger indexing — viewers call `indexBook(bookId)` explicitly on
   * open. (See open questions.)
   */
  importFromPath(filePath: string): Promise<ImportResult>

  /**
   * Import multiple files. Each is processed via `importFromPath`; failures
   * are isolated — one bad file does not stop the others. Resolves with an
   * array of `ImportResult` in input order. Never rejects.
   *
   * Stage 1 implementation: sequential. (Stage 2 candidate: bounded
   * concurrency via Effect.Semaphore.)
   */
  importBatch(filePaths: string[]): Promise<ImportResult[]>

  /**
   * Trigger RAG indexing for a book the caller knows is "open enough" — page
   * data has been extracted, the book row exists, vectors may or may not. If
   * `pageData` is provided, it is the source of truth (viewer-side extracted).
   * If omitted, the service reads chunks from the DB via the `db` port.
   *
   * Recovery semantics: skips entirely if chunks AND vectors exist; saves
   * chunks if missing; re-embeds if chunks exist but vectors are missing.
   * Embedding failure is swallowed (best-effort, matches today's
   * `processEpubJob` behavior). Emits `{ kind: 'indexing', bookId, reason }`
   * when work is performed.
   *
   * @throws Error on un-recoverable failure (page-data save fails, etc.).
   */
  indexBook(bookId: number, pageData?: PageDataInsertable[]): Promise<void>

  /**
   * Start the scanner in the given mode. Returns immediately; results stream
   * via `onDiscoveryEvent`. Calling `startDiscovery` while a scan is already
   * running first cancels the in-flight scan (mirrors today's mode-switch
   * behavior in `BookDiscoveryModal`).
   */
  startDiscovery(mode: 'default' | 'full'): void

  /**
   * Abort the running scan. Resolves once the underlying scanner has
   * acknowledged the cancel. Emits a `{ kind: 'complete', cancelled: true }`
   * event. Safe to call when no scan is active (no-op).
   */
  cancelDiscovery(): Promise<void>

  /**
   * Subscribe to discovery (scanner) events. Returns an unsubscribe function.
   */
  onDiscoveryEvent(listener: (event: DiscoveryEvent) => void): () => void

  /**
   * Subscribe to per-file import progress events. Returns an unsubscribe
   * function. Fires for every `importFromPath` call (including those issued
   * inside `importBatch`).
   */
  onImportProgress(listener: (event: ImportProgressEvent) => void): () => void
}

export function createBookImportService(deps: BookImportServiceDeps): BookImportService
```

### Shape notes

- **`importFromPath` returns `ImportResult`, does not reject.** Today's `FileComponent.importBook` catches and toasts. The discriminated-union return centralizes that error classification and lets bulk callers handle per-item failure without try/catch noise.
- **`importBatch` returns an array, settles independently per item.** Mirrors the current `processFilePaths` semantics (forEach + void) but in a single awaitable.
- **`indexBook(bookId, pageData?)` accepts optional `pageData`.** Viewers (`MobiView`, `DjvuView`) pre-build it; `epubStore` pre-builds it from `getAllParagraphsForBook`. If the caller has it, pass it; if not, the service reads from the DB (path used by future post-import auto-indexing or background re-indexing). Public flag (resolves the open question — public, viewers call explicitly).
- **No `getDiscoveredBooks()` snapshot method.** Callers maintain their own list from the event stream. Matches today's `BookDiscoveryModal` which keeps a `useState<DiscoveredBook[]>` populated from `scan-result` events.
- **No `cancelImport(filePath)` method.** Per-import cancellation isn't supported today and no caller demands it. Stage 2 candidate if needed.
- **No `clock` port.** Per-stage timeouts use the real `setTimeout` directly. Tests use vitest's `vi.useFakeTimers()` if they need to assert timeout behavior (one test does). The cost of a `clock` port for a feature that exists only to surface stuck IPC isn't justified.
- **No `windowEvents` port.** No window-level / document-level listeners inside the service. Drag-drop stays in `FileComponent`. Discovery cancellation on modal close stays in `BookDiscoveryModal` (caller-side; service offers `cancelDiscovery()`).

### Usage example — wiring site

```ts
// src/renderer/src/services/index.ts (appended after getSyncService)
import {
  createBookImportService,
  type BookImportService,
  type ScannerPort
} from './book-import'
import { embedWithFallback } from '@/modules/embed-fallback'
import { hashBookFile, uploadBookFile } from '@/modules/file-sync'
import { copyBookToAppData } from '@/modules/books'

let _import: BookImportService | null = null

export function getBookImportService(): BookImportService {
  if (!_import) {
    const scanner: ScannerPort = {
      start: (mode) => window.electron.scanForBooks(mode),
      cancel: () => window.electron.cancelScan(),
      on: (kind, listener) => {
        const channel =
          kind === 'result'
            ? 'scan-result'
            : kind === 'progress'
              ? 'scan-progress'
              : 'scan-complete'
        return window.electron.on(channel, (...args: unknown[]) =>
          (listener as (a: unknown) => void)(args[0])
        )
      }
    }

    _import = createBookImportService({
      formats: {
        getBookData: window.electron.getBookData,
        getPdfData: window.electron.getPdfData,
        getMobiData: window.electron.getMobiData,
        getDjvuData: window.electron.getDjvuData
      },
      db: {
        saveBook: window.electron.saveBook,
        savePageDataMany: window.electron.savePageDataMany,
        getAllPageDataByBookId: window.electron.getAllPageDataByBookId,
        hasSavedEpubData: window.electron.hasSavedEpubData,
        saveVectors: window.electron.saveVectors
      },
      fs: {
        copyBookToAppData,
        mkdir: window.electron.mkdir,
        exists: window.electron.exists,
        removeFile: window.electron.removeFile,
        getAppDataPath: window.electron.getAppDataPath,
        checkFileSize: window.electron.checkFileSize
      },
      fileSync: {
        hashBookFile,
        uploadBookFile,
        booksUpdateFileHash: window.electron.booksUpdateFileHash
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

### Usage example — most common callers

```ts
// components/FileComponent.tsx (after migration)
import { getBookImportService } from '@/services'

const processFilePaths = async (filePaths: string[]) => {
  const results = await getBookImportService().importBatch(filePaths)
  for (const r of results) {
    if (!r.ok) {
      toast.error(`Failed to import ${r.filePath}: ${r.error}`)
      continue
    }
    if (lastResult === undefined) lastResult = r
  }
  await queryClient.invalidateQueries({ queryKey: ['books'] })
  if (lastResult?.ok) {
    setNewBookId(null)
    setTimeout(() => setNewBookId(String(lastResult.bookId)), 0)
  }
}
```

```ts
// components/BookDiscoveryModal.tsx (after migration)
import { getBookImportService } from '@/services'

useEffect(() => {
  if (!open) return
  const svc = getBookImportService()
  const unsub = svc.onDiscoveryEvent((event) => {
    if (event.kind === 'book-found') setBooks((prev) => [...prev, event.book])
    else if (event.kind === 'progress') setProgress(event.progress)
    else if (event.kind === 'complete') {
      setScanning(false)
      setScanComplete(true)
      setProgress(null)
    }
  })
  svc.startDiscovery('default')
  return () => {
    unsub()
    void svc.cancelDiscovery()
  }
}, [open])
```

```ts
// components/mobi/MobiView.tsx (after migration)
import { getBookImportService } from '@/services'

// ... after building allPageData ...
if (allPageData.length > 0) {
  await getBookImportService().indexBook(book.id, allPageData)
}
```

## File structure & module layout

```
src/renderer/src/services/
├── index.ts                 # wiring site — appends getBookImportService()
├── rag/                     # Wave 1
├── tts/                     # Wave 1
├── sync/                    # Wave 1
└── book-import/
    ├── index.ts             # re-export: createBookImportService, types, BookImportService
    ├── types.ts             # all types in the "Types" section above
    ├── service.ts           # createBookImportService — top-level wiring
    ├── pipeline.ts          # internal: makePipeline(deps) — importFromPath stages
    ├── indexer.ts           # internal: makeIndexer(deps) — indexBook recovery + embed batching
    ├── discovery.ts         # internal: makeDiscovery(scanner, emitter) — scanner subscription
    ├── format-dispatch.ts   # internal: formatFor(ext) → format adapter
    ├── emitter.ts           # internal: createEmitter<T>() — same shape as TTS / Sync
    └── service.test.ts      # boundary tests
```

The internal modules (`pipeline.ts`, `indexer.ts`, `discovery.ts`, `format-dispatch.ts`, `emitter.ts`) are not re-exported from `index.ts`. Refactoring convenience only — Ousterhout's "deep module": small interface, larger implementation.

## Internals (orchestration flow)

### `importFromPath` pipeline

```ts
// pipeline.ts (illustrative — final implementation may differ)

export async function runImport(deps, filePath, progressEmit): Promise<ImportResult> {
  const ext = filePath.split('.').pop()?.toLowerCase() as BookFormat | undefined
  const format = formatFor(ext)
  if (!format) {
    progressEmit({ kind: 'failed', filePath, stage: 'unsupported', error: `Unsupported: .${ext}` })
    return { ok: false, filePath, stage: 'unsupported', error: `Unsupported format: .${ext}` }
  }

  progressEmit({ kind: 'copying', filePath })
  let bookPath: string
  try {
    bookPath = await withTimeout(deps.fs.copyBookToAppData(filePath), deps.config.copyTimeoutMs, 'Copying file')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Copy failed'
    progressEmit({ kind: 'failed', filePath, stage: 'copy', error: msg })
    return { ok: false, filePath, stage: 'copy', error: msg }
  }

  progressEmit({ kind: 'parsing', filePath, format })
  let bookData
  try {
    bookData = await withTimeout(format.parse(deps.formats, bookPath), deps.config.parseTimeoutMs, 'Extracting metadata')
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Parse failed'
    progressEmit({ kind: 'failed', filePath, stage: 'parse', error: msg })
    // Rollback the copy (open question #3 resolution: yes, clean up the orphan file).
    try { await deps.fs.removeFile(bookPath) } catch { /* swallow */ }
    return { ok: false, filePath, stage: 'parse', error: msg }
  }

  progressEmit({ kind: 'saving', filePath, format })
  let book
  try {
    book = await withTimeout(
      deps.db.saveBook({ ...bookData, filepath: bookPath, location: format.initialLocation, version: 0 }),
      deps.config.saveTimeoutMs,
      'Saving to library'
    )
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Save failed'
    progressEmit({ kind: 'failed', filePath, stage: 'save', error: msg })
    return { ok: false, filePath, stage: 'save', error: msg }
  }

  // Best-effort upload (never blocks success).
  void runUpload(deps, book, bookPath, format, progressEmit)

  progressEmit({ kind: 'done', filePath, bookId: book.id, format })
  return { ok: true, bookId: book.id, filePath, format }
}
```

### `indexBook` recovery flow

```ts
// indexer.ts (illustrative)

export async function runIndex(deps, bookId, pageDataOpt, progressEmit): Promise<void> {
  // Skip entirely if both chunks and vectors exist.
  const [chunksExist, vectorsExist] = await Promise.all([
    deps.db.hasSavedEpubData(bookId),
    deps.rag.isIndexed(bookId)
  ])
  if (chunksExist && vectorsExist) return

  const pageData = pageDataOpt ?? (chunksExist
    ? (await deps.db.getAllPageDataByBookId(bookId)).map((p) => ({ id: p.id, pageNumber: p.pageNumber, bookId: p.bookId, data: p.data }))
    : [])
  if (pageData.length === 0) return

  if (!chunksExist) {
    progressEmit({ kind: 'indexing', bookId, reason: 'chunks-missing' })
    await deps.db.savePageDataMany(pageData)
  } else {
    progressEmit({ kind: 'indexing', bookId, reason: 'vectors-missing' })
  }

  try {
    const batches = chunkArray(pageData, deps.config.embedBatchSize).map((batch) =>
      batch.map((p) => ({ text: p.data, metadata: { id: p.id, pageNumber: p.pageNumber, bookId } }))
    )
    for (const batch of batches) {
      const results = await deps.embed(batch)
      const vectors = results.map((r) => ({ id: r.metadata.id, vector: r.embedding }))
      if (vectors.length > 0) {
        await deps.db.saveVectors(`${bookId}-vectordb`, results[0].embedding.length, vectors)
      }
    }
  } catch (err) {
    console.error('[book-import] embedding/vector save failed, will retry on next open:', err)
    // Swallow — page data is saved, vectors retry next call. Matches today.
  }
}
```

### Behavioral notes baked into the contract

- **`importFromPath` is sequential per file.** No concurrency inside one import.
- **`importBatch` is sequential across files.** Stage 1 keeps today's behavior (forEach + await). Stage 2 candidate: bounded concurrency.
- **Parse-failure rollback** removes the copied file (`fs.removeFile`). New behavior; today the copied file is orphaned in the app data folder. Failure of the removal is swallowed (best-effort).
- **Upload is fire-and-forget.** `importFromPath` resolves *before* upload completes. Upload failure emits an `upload-failed` event but does not affect the return value.
- **`indexBook` is idempotent.** Calling it on a fully-indexed book is a no-op. Calling it during in-flight indexing is unguarded in Stage 1 — duplicate work is wasteful but correct.
- **`indexBook` swallows embed failures.** Matches today's `processEpubJob`. The next call retries.
- **`startDiscovery` is single-flight.** Calling start while a scan is running cancels the prior scan first (mirrors today's `handleModeChange`).
- **`cancelDiscovery` is idempotent.** Calling cancel when no scan is running is a no-op; the scanner port's `cancel()` is expected to be safe to call repeatedly.

### Explicitly NOT added (YAGNI per the meta-spec scope guard)

- No URL-import path. Open question — separate adapter.
- No duplicate detection (file-hash matching across the library at import time).
- No format pre-flight via `checkFileSize` — the port is exposed for future use but not invoked in Stage 1 (today's `FileComponent` does not call it).
- No per-import cancellation.
- No retry on transient parse/save failures. Today's `withTimeout` is a one-shot.
- No telemetry/Sentry capture — composition concern at the caller boundary if needed.

## Boundary test scenarios

All tests at the public interface. One file, `src/renderer/src/services/book-import/service.test.ts`. Tests construct the service with fakes — no module-level mocks, no `vi.resetModules` between tests, no `window` polyfill, no real IPC.

### Test helpers (planned shape)

```ts
function makeFormats(opts?: {
  epubReturns?: BookDataParsed
  pdfReturns?: BookDataParsed
  mobiReturns?: BookDataParsed
  djvuReturns?: BookDataParsed
  throwOn?: { ext: BookFormat; error: Error }
}): { formats: FormatsIpc; callLog: Array<{ method: keyof FormatsIpc; path: string }> }

function makeDb(opts?: {
  books?: Book[]
  pageData?: PageData[]
  vectors?: Map<string, Vector[]>
  hasSavedEpubData?: (bookId: number) => boolean
  failOn?: keyof BookStoreIpc
}): { db: BookStoreIpc; books: Book[]; vectors: Map<string, Vector[]> }

function makeFs(opts?: { initialFiles?: Map<string, Uint8Array>; throwOn?: keyof FsIpc }): {
  fs: FsIpc
  files: Map<string, Uint8Array>
  removeCount: () => number
}

function makeRag(opts?: { indexedBookIds?: Set<number> }): RagService

function makeEmbed(opts?: { vectorByText?: Record<string, number[]>; failNTimes?: number }):
  (params: EmbedParam[]) => Promise<EmbedResult[]>

function makeFileSync(opts?: { hashImpl?: (p: string) => Promise<string>; throwOn?: 'upload' | 'updateHash' }):
  FileSyncIpc

function makeScanner(): ScannerPort & {
  emit(event: { kind: 'result'; book: DiscoveredBook } | { kind: 'progress'; progress: ScanProgress } | { kind: 'complete' }): void
  startCount(): number
  cancelCount(): number
}
```

The fakes are ~200 lines total — trivial.

### Boundary test scenarios (committed)

Minimum 12 tests, covering the major behaviors.

1. **`importFromPath` happy path (EPUB).** Setup: `fs.copyBookToAppData` returns a target path; `formats.getBookData` returns a parsed book; `db.saveBook` returns `{ id: 42 }`. Assert: result is `{ ok: true, bookId: 42, filePath, format: 'epub' }`; `formats.getBookData` called once with the target path; `db.saveBook` called with the parsed data + target path; progress events fire in order `[copying, parsing, saving, done]`.
2. **`importFromPath` dispatches by extension to the right format port.** Setup: parameterize over `.epub` / `.pdf` / `.mobi` / `.azw3` / `.djvu`. Assert: each extension routes to the corresponding `formats.getXData` method; `.azw3` routes to `formats.getMobiData` (today's behavior).
3. **`importFromPath` returns `unsupported` for unknown extensions.** Setup: input is `/tmp/foo.txt`. Assert: result is `{ ok: false, filePath, stage: 'unsupported', error: ... }`; no FS / format / DB calls.
4. **`importFromPath` parse failure rolls back the copy.** Setup: `fs.copyBookToAppData` succeeds; `formats.getBookData` rejects with `Error('bad zip')`. Assert: result is `{ ok: false, stage: 'parse', ... }`; `fs.removeFile` called once with the copied path; `db.saveBook` never called; emitted events include `[copying, parsing, failed]`.
5. **`importFromPath` save failure surfaces but does NOT roll back copy.** Setup: `db.saveBook` rejects. Assert: result is `{ ok: false, stage: 'save', ... }`; `fs.removeFile` not called for this case (the copied file stays — caller can retry); emitted events include `[copying, parsing, saving, failed]`.
6. **`importFromPath` upload is fire-and-forget; failure does not affect result.** Setup: happy path through save; `fileSync.uploadBookFile` rejects. Assert: result is `{ ok: true, ... }`; an `upload-failed` event is emitted asynchronously; `done` event fires before any upload event resolution.
7. **`importBatch` resilience — one fails, others continue.** Setup: 3 paths; the second's `formats.getBookData` rejects. Assert: result is `[ok, failed, ok]`; all three were attempted; emitted events show two `done`s and one `failed`.
8. **`importBatch` returns results in input order.** Setup: 3 paths with varying simulated parse delays. Assert: result array's order matches input order, not completion order.
9. **`indexBook` skip when fully indexed.** Setup: `db.hasSavedEpubData(42) → true`, `rag.isIndexed(42) → true`. Assert: `db.savePageDataMany` never called; `embed` never called; `db.saveVectors` never called.
10. **`indexBook` runs full pipeline when neither chunks nor vectors exist.** Setup: both checks return false; pageData passed in. Assert: `db.savePageDataMany` called once; `embed` called with batches of size 2; `db.saveVectors` called with `name = '42-vectordb'`; `indexing` event with `reason: 'chunks-missing'`.
11. **`indexBook` re-embeds when chunks exist but vectors are missing (regression).** Setup: `db.hasSavedEpubData(42) → true`, `rag.isIndexed(42) → false`; pageData passed in. Assert: `db.savePageDataMany` NOT called (don't re-save chunks); `embed` called; `db.saveVectors` called; `indexing` event with `reason: 'vectors-missing'`. (Preserves the regression caught in commit `e44ab1b9`.)
12. **`indexBook` swallows embed failure after chunks saved.** Setup: chunks missing; `embed` rejects with `Error('sharp broke')`. Assert: `db.savePageDataMany` called; `db.saveVectors` NOT called; promise resolves `undefined` (does not reject).
13. **`indexBook` falls back to reading pageData from DB when omitted.** Setup: `db.hasSavedEpubData(42) → true`, vectors missing; `pageData` argument omitted; `db.getAllPageDataByBookId(42)` returns 3 rows. Assert: `db.getAllPageDataByBookId` called; embed called with the DB-sourced rows.
14. **`startDiscovery` event streaming.** Setup: subscribe via `onDiscoveryEvent`; call `startDiscovery('default')`. Use `scanner.emit({ kind: 'result', book: ... })` 3×, then `emit({ kind: 'progress', ... })`, then `emit({ kind: 'complete' })`. Assert: listener received 3 `book-found`, 1 `progress`, 1 `complete` with `cancelled: false`; `scanner.start('default')` called once.
15. **`startDiscovery` while running cancels prior scan first.** Setup: `startDiscovery('default')`, then immediately `startDiscovery('full')`. Assert: `scanner.cancelCount() === 1`; `scanner.startCount() === 2`; the second start used mode `'full'`.
16. **`cancelDiscovery` propagation.** Setup: `startDiscovery('default')`, then `cancelDiscovery()`. Assert: `scanner.cancel` called once; `complete` event with `cancelled: true` emitted.
17. **`onImportProgress` unsubscribe stops further events.** Setup: subscribe, call `importFromPath` once (assert events received), unsubscribe, call `importFromPath` again. Assert: listener call count from second import is zero.

### Tests we explicitly do NOT add

- Per-method `formats` IPC contract (`getBookData` returns the right shape). The main-process parsers have their own coverage.
- Per-method `scanner` IPC contract. The main-process scanner has its own coverage.
- Per-format pre-flight via `checkFileSize`. Port exposed; not invoked in Stage 1.
- Per-stage timeout firing at exactly `120s` / `60s` / `30s`. Tested with small `copyTimeoutMs: 50` and a deliberately-slow fake.
- Sentry capture / telemetry. Composition concern.
- The `usePdfStore` PDF-id registry. Caller-side composition.

### What inherited tests get deleted

- `src/renderer/src/modules/__tests__/process_epub.recovery.test.ts` (5 tests). Replaced by tests #9-12 + #13 in the new boundary suite. Same behaviors, cleaner fakes (no `vi.hoisted` + `vi.mock`).

## Caller migration

| File | Current | After |
|---|---|---|
| `src/renderer/src/components/FileComponent.tsx` | Inline `importBook(filePath)` with 4-branch `if/else` + `withTimeout` + `copyBookToAppData` + `getXData` + `saveBook` + `hashBookFile` + `uploadBookFile` + `booksUpdateFileHash`; `processFilePaths` iterates `importBook`; passes `onImport` / `onImportFiles` callbacks to `BookDiscoveryModal`; imports `prefetchTTSForBooks` from `@/modules/ttsPrefetch` (TTS migration target, handled by TTS PR) | `import { getBookImportService } from '@/services'` + `processFilePaths = async (paths) => await getBookImportService().importBatch(paths)` + iterate results for toast / navigation. Drops `withTimeout`, `COPY_TIMEOUT` / `EXTRACT_TIMEOUT` / `SAVE_TIMEOUT` constants, the four-branch extension switch, and the upload try/catch. ~80 LOC removed. |
| `src/renderer/src/components/BookDiscoveryModal.tsx` | `window.electron.on('scan-result' \| 'scan-progress' \| 'scan-complete', ...)` (3 listeners) + `window.electron.scanForBooks(mode)` + `cancelScan()` from `@/lib/api` + manual unsub ref management; receives `onImport` / `onImportFiles` props from `FileComponent` and forwards file paths back | `import { getBookImportService } from '@/services'` + `const svc = getBookImportService()` + `svc.onDiscoveryEvent(handler)` + `svc.startDiscovery(mode)` + `svc.cancelDiscovery()`. Drops the three `window.electron.on` calls, the unsub ref, the prop-drilling. Import callback (single-file from row) becomes `void svc.importBatch([book.filepath])`; "Import All" becomes `void svc.importBatch(toImport.map((b) => b.filepath))`. The `onImport`/`onImportFiles` props go away — the modal owns its imports directly. |
| `src/renderer/src/components/mobi/MobiView.tsx` | `import { processEpubJob } from '@/modules/process_epub'` + `await processEpubJob(book.id, allPageData)` | `import { getBookImportService } from '@/services'` + `await getBookImportService().indexBook(book.id, allPageData)` |
| `src/renderer/src/components/djvu/DjvuView.tsx` | Same as MobiView | Same swap |
| `src/renderer/src/stores/epubStore.ts` | `import { processEpubJob } from '@/modules/process_epub'` + `void processEpubJob(Number(bookId), paragraphs)` (called inside a subscribe handler after `getAllParagraphsForBook`) | `import { getBookImportService } from '@/services'` + `void getBookImportService().indexBook(Number(bookId), paragraphs)`. The `hasSavedEpubData` pre-check at the call site is REMOVED — `indexBook` handles the skip internally. |
| `src/renderer/src/test-setup.ts` | Has `vi.mock`-style stubs for `getBookData` / `getPdfData` / `getMobiData` / `getDjvuData` (used by some component tests). | Unchanged — these are window.electron stubs at a different layer. Tests of the service use the in-memory `makeFormats` helper, bypassing this. |

Total: 5 caller files touched (excluding `test-setup.ts` which stays as-is). The `FileComponent` and `BookDiscoveryModal` changes are non-trivial (the `onImport` / `onImportFiles` prop interface goes away); the three viewer-side / store-side changes are mechanical.

## Files / code to delete

| Location | What to remove |
|---|---|
| `src/renderer/src/modules/process_epub.ts` | Entire file — absorbed into `services/book-import/indexer.ts` (internal) |
| `src/renderer/src/modules/__tests__/process_epub.recovery.test.ts` | Replaced by tests #9-13 in `services/book-import/service.test.ts` |
| `src/renderer/src/components/FileComponent.tsx` — `importBook`, `processFilePaths`, `withTimeout`, `COPY_TIMEOUT` / `EXTRACT_TIMEOUT` / `SAVE_TIMEOUT` constants, `getBookData` / `getPdfData` / `getMobiData` / `getDjvuData` / `saveBook` imports, `copyBookToAppData` import, `hashBookFile` / `uploadBookFile` imports | Removed inline (file stays — just shorter) |
| `src/renderer/src/components/BookDiscoveryModal.tsx` — `cancelScan` import, the three `window.electron.on(...)` listeners, the `unsubRefs` ref + `cleanupListeners`, the `startScan` function (its body moves into a `useEffect`), the `onImport` / `onImportFiles` prop interface | Removed inline (file stays — restructured) |
| `src/renderer/src/modules/embed-fallback.ts` — `embedSingleText` export | Stays — the RAG service consumes it; do NOT delete |
| `src/renderer/src/modules/embed-fallback.ts` — `embedWithFallback` export | Stays — the book-import service consumes it; do NOT delete |
| `src/renderer/src/modules/books.ts` — `copyBookToAppData` | Stays — the service consumes it; do NOT delete |
| `src/renderer/src/modules/file-sync.ts` — `hashBookFile`, `uploadBookFile` | Stay — the service consumes them; do NOT delete |

Per the meta-spec's *no shims* rule: no compatibility re-exports of `processEpubJob`. One PR, one source of truth.

## Out of scope

- **Main-process IPC handlers** (`src/main/ipc/formats.ts`, `src/main/ipc/scanner.ts`) — untouched. Their surface stays as-is.
- **`@xenova/transformers` on-device embedding** — owned by the main process, consumed via `window.electron.embed`. The service consumes it through the `embed-fallback.ts` helper.
- **URL-import path** — flagged as an open question; lean is a separate adapter that produces a `filePath` and calls `importFromPath`.
- **Orphan cleanup for partial-failure books** — `indexBook` already handles "book row exists but vectors missing". `importFromPath` parse-failure rollback removes the orphan copied file. Beyond that, no library-wide orphan sweep — future spec if needed.
- **`prefetchTTSForBooks` integration** — `FileComponent` calls `prefetchTTSForBooks` after `getBooks()` resolves. That stays as-is (TTS service's concern). The import service does not trigger TTS prefetch.

## Development workflow — TDD

Strict TDD: red → green → commit per behavior. Each test-implementation pair is its own commit. No "implement everything then write tests" commits.

### PR commit sequence

1. **Scaffold.** Create `services/book-import/` folder with `types.ts` (full type definitions), `emitter.ts` (copy from `services/tts/emitter.ts` or `services/sync/emitter.ts`), and empty stubs in `service.ts`, `pipeline.ts`, `indexer.ts`, `discovery.ts`, `format-dispatch.ts` that throw "not implemented" from each method. Set up `service.test.ts` with `makeFormats()`, `makeDb()`, `makeFs()`, `makeRag()`, `makeEmbed()`, `makeFileSync()`, `makeScanner()` helpers. Commit.
2. **Test 1 + impl (`importFromPath` happy path EPUB).** Red. Implement pipeline copy → parse → save flow + `emitter` wiring. Green. Commit.
3. **Test 2 + impl (extension dispatch).** Red. Implement `format-dispatch.ts`. Green. Commit.
4. **Test 3 + impl (unsupported extension).** Red. Add the `formatFor` null branch + `unsupported` ImportResult. Green. Commit.
5. **Test 4 + impl (parse failure rollback).** Red. Add try/catch around parse + `fs.removeFile` on failure. Green. Commit.
6. **Test 5 + impl (save failure no rollback).** Red. Add try/catch around save. Green. Commit.
7. **Test 6 + impl (upload fire-and-forget).** Red. Implement `runUpload` async branch + `upload-failed` event. Green. Commit.
8. **Test 7 + impl (`importBatch` resilience).** Red. Implement `importBatch` as sequential `importFromPath` over the input array. Green. Commit.
9. **Test 8 + impl (`importBatch` result order).** Red. Already satisfied by sequential implementation; assert in test. Commit.
10. **Test 9 + impl (`indexBook` skip-when-done).** Red. Implement chunks+vectors check + early return. Green. Commit.
11. **Test 10 + impl (`indexBook` full pipeline).** Red. Implement savePageDataMany + batched embed + saveVectors. Green. Commit.
12. **Test 11 + impl (`indexBook` re-embed regression).** Red. Add the chunks-exist-but-vectors-missing branch. Green. Commit.
13. **Test 12 + impl (`indexBook` embed failure swallowed).** Red. Add try/catch around the embed loop. Green. Commit.
14. **Test 13 + impl (`indexBook` reads pageData from DB when omitted).** Red. Implement the optional pageData fallback. Green. Commit.
15. **Test 14 + impl (`startDiscovery` event streaming).** Red. Implement `makeDiscovery(scanner, emitter)` — wire scanner.on(kind, ...) to emit DiscoveryEvent. Green. Commit.
16. **Test 15 + impl (`startDiscovery` single-flight cancels prior).** Red. Add the cancel-before-start guard. Green. Commit.
17. **Test 16 + impl (`cancelDiscovery` propagation).** Red. Implement cancel + `complete { cancelled: true }` event. Green. Commit.
18. **Test 17 + impl (`onImportProgress` unsubscribe).** Red. Verify emitter unsubscribe semantics (already implemented; just assert at the boundary). Commit.
19. **Wiring + caller migrations.** Add `getBookImportService()` to `services/index.ts`; migrate the 5 callers (`FileComponent`, `BookDiscoveryModal`, `MobiView`, `DjvuView`, `epubStore`); drop `processEpubJob` import from each. No new tests (composition, not behavior). Commit.
20. **Delete old files + tests** in one commit: `process_epub.ts`, `__tests__/process_epub.recovery.test.ts`, and the inline import code in `FileComponent.tsx` / `BookDiscoveryModal.tsx`.
21. **Final verification.** `tsc` / `eslint` / `vitest` clean across the app.

Each step is one commit. Steps 2-18 are red-green pairs; the rest are mechanical.

### Expected diff

- **Added:** ~1100 lines (service + tests + types + emitter + pipeline + indexer + discovery + format-dispatch + wiring).
- **Removed:** ~250 lines (`process_epub.ts` + its test + the inline import / discovery code in the two components + dispatch branches).
- **Net:** moderately positive. The deep-module discipline trades inline-component-code for explicit-port-driven service code; line count grows, testability grows much more.

## Open questions

These are open design questions the implementation plan should resolve. They are flagged but **not** decided in this spec.

1. **Should the URL-import path live inside the service or as a separate adapter?** *Lean: separate adapter — the service stays format-agnostic about how the file got there. A URL-import adapter downloads to a temp path and then calls `importFromPath(tempPath)`. The service's contract is "given a local file path, import it"; widening to URLs blurs the boundary.* Revisit if a real URL-import caller arrives.
2. **Should `indexBook` be public (called by viewers) or private (auto-triggered after `importFromPath`)?** *Lean: public — viewers explicitly request indexing because they know when the book is "open enough" to warrant indexing (pageData is constructed inside the viewer for MOBI/DJVU, inside the store for EPUB). Auto-triggering from `importFromPath` would require the service to know how to extract pageData per format, which couples it to format-specific text streams that don't exist at parse-time.* This spec assumes the public lean and locks it in. The plan can revisit.
3. **Should the service own the orphan-cleanup story (book row exists but chunks/vectors missing after partial failure)?** *Lean: yes — `indexBook` already has recovery (chunks-exist-but-vectors-missing → re-embed). `importFromPath` adds parse-failure rollback to remove the orphan copied file. Beyond that, no library-wide orphan sweep — out of scope.* This spec assumes the lean.
4. **Is the tiny `createEmitter<T>` duplicated or imported from `services/tts/emitter.ts` or `services/sync/emitter.ts`?** *Lean: duplicate it inside `services/book-import/emitter.ts`* — services should not depend on each other's internals. ~20 lines. If a fourth service wants the same primitive, lift to `services/_shared/emitter.ts`.
5. **Is `embedWithFallback` a port consumed by the service, or does the service own the on-device-then-server fallback internally?** *Lean: port. The fallback logic stays in `embed-fallback.ts` (also consumed by the RAG service as `embedSingleText`); the book-import service is one consumer.* This avoids duplicating the auth header + worker URL logic between two services.
6. **Should `importBatch` be sequential or bounded-concurrent in Stage 1?** *Lean: sequential — matches today's behavior (forEach + void). Stage 2 candidate via `Effect.Semaphore`.* No production caller demands concurrency today.

## Stage 2 outlook

Stage 2 is explicit Effect-TS adoption *inside* a service, after Stage 1 ships. The meta-spec sets a rubric: Effect goes into a service only if it scores positively on ≥2 of 5 axes.

### Scoring Book Import against the rubric

| Axis | Score | Why |
|---|---|---|
| **Concurrency** | YES | `importBatch` is the obvious case — bounded concurrency via `Effect.Semaphore` (e.g., 3 parallel imports). Discovery cancellation propagation across the scanner + the pending discovery-event listener handlers is a `Scope` fit. |
| **Retry / scheduling** | YES | `indexBook`'s embed step is best-effort today; with `Schedule.exponential` it becomes "try on-device, retry server with backoff, then fail." Per-stage parse failures could retry on transient errors (filesystem flake) — currently they don't. |
| **Resource lifecycle** | YES | The parse-failure rollback (`fs.removeFile` on the copied file) is a textbook `acquireRelease` — `acquire = copyBookToAppData`, `release = removeFile`. The scanner subscription registration → cancellation is another `Scope` fit. |
| **Typed error channels** | YES | Three error categories per import (`copy` / `parse` / `save`) plus `unsupported` plus upload failure. Effect's `Effect.catchTags` lets callers exhaustively switch on the stage tag instead of `if (!result.ok && result.stage === 'parse')`. |
| **Composed async pipeline** | YES | The copy → parse → save → upload → done pipeline + the chunks-check → save-chunks → embed-batch → save-vectors pipeline are both long sequential pipelines with branching. `Effect.gen` is more readable than nested try/catch. |

**Score:** 5 of 5 axes (very strong yes). Book Import is the third-strongest Stage 2 candidate after TTS and Sync, and arguably ties with Sync because it touches all five axes — the per-stage error channel + the structured rollback are particularly compelling.

### Stage 2 sketch

The public interface stays plain TS (`Promise<ImportResult>` from `importFromPath`, callback-based subscriptions). Internally:

- **`pipeline.ts` → `Effect.gen` with `acquireRelease`.** copy → parse → save becomes one `Effect.gen` with `acquireRelease` around the copy step. Rollback on parse failure is automatic via `Scope.close`. The per-stage `withTimeout` becomes `Effect.timeout`.
- **Error model → tagged union of `CopyError`, `ParseError`, `SaveError`, `UnsupportedError`.** `Effect.catchTag` lets the wrapper at the boundary classify into the `ImportResult` discriminated union. The hand-rolled try/catch chain disappears.
- **`importBatch` → `Effect.forEach` with `concurrency: 3`.** Replaces today's sequential forEach. Failure isolation is built in.
- **`indexBook` → `Effect.gen` + `Schedule`.** The chunks/vectors recovery branch becomes one `Effect.if`; the embed retry policy becomes one `Schedule` value passed to `Effect.retry`.
- **Discovery → `Stream<DiscoveryEvent>`.** The scanner subscription becomes a `Stream` consumed by the emitter; `cancelDiscovery` becomes `Stream.interrupt`. The 3-listener ref dance disappears.
- **Public boundary.** `Effect.runPromise(importEffect)` at `importFromPath`; `Effect.runFork(discoveryEffect)` at `startDiscovery`. Callers don't change.

The interface contract from Stage 1 is preserved exactly. The internals shrink. The per-stage error classification + rollback + batch isolation + recovery branching becomes a ~60-line Effect program.

### Stage 2 trigger

Per the meta-spec, Stage 2 starts only after **all six Stage 1 services have shipped**. This spec commits no Stage 2 work. The sketch above exists so the team can validate the public interface won't need to break when Stage 2 lands.

### Stopping rule

Per the meta-spec: if Stage 2 ergonomics are painful when TTS is retrofitted first, Effect is dropped from Stage 2 entirely and Book Import stays plain TS. The Stage 1 service from this spec is *unaffected* by that outcome — its public interface is the durable artifact.

## Definition of done

Per the meta-spec's standard. This service refactor ships when:

1. `src/renderer/src/services/book-import/index.ts` is the single public-facing module exporting `createBookImportService`, `BookImportService`, and the public types.
2. `src/renderer/src/services/index.ts` exports a `getBookImportService()` lazy singleton.
3. All 5 caller files (`FileComponent.tsx`, `BookDiscoveryModal.tsx`, `MobiView.tsx`, `DjvuView.tsx`, `epubStore.ts`) import from `@/services`.
4. The old `modules/process_epub.ts` file plus its test file are **deleted**, not kept as shims.
5. The inline `importBook` / `processFilePaths` / `withTimeout` code in `FileComponent.tsx` and the inline scanner-listener code in `BookDiscoveryModal.tsx` are removed.
6. All 17 boundary tests pass.
7. `tsc`, `eslint`, `vitest` clean across the app.
