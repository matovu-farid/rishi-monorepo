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

  const indexingBookIds = new Set<number>()

  async function indexBook(bookId: number, pageData?: PageDataInsertable[]): Promise<void> {
    indexingBookIds.add(bookId)
    try {
      await runIndex(
        {
          db: deps.db,
          rag: deps.rag,
          embed: deps.embed,
          embedBatchSize: deps.config.embedBatchSize
        },
        bookId,
        pageData,
        (e) => progress.emit(e)
      )
    } finally {
      indexingBookIds.delete(bookId)
    }
  }

  function isIndexing(bookId: number): boolean {
    return indexingBookIds.has(bookId)
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
    // Why: single-flight cancel. The early-return guards against concurrent
    // cancels; the scanner.complete listener also clears scanRunning serially.
    // eslint-disable-next-line require-atomic-updates
    scanRunning = false
    discovery.emit({ kind: 'complete', cancelled: true })
    teardownScanSubscriptions()
  }

  return {
    importFromPath,
    importBatch,
    indexBook,
    isIndexing,
    startDiscovery,
    cancelDiscovery,
    onDiscoveryEvent: (listener) => discovery.on(listener),
    onImportProgress: (listener) => progress.on(listener)
  }
}
