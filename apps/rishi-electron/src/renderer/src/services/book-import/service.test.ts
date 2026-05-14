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
    emit(
      event:
        | { kind: 'result'; book: DiscoveredBook }
        | { kind: 'progress'; progress: ScanProgress }
        | { kind: 'complete' }
    ) {
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
    // `upload-started` may arrive on next tick; wait for it.
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    expect(events.map((e) => e.kind)).toEqual([
      'copying',
      'parsing',
      'saving',
      'done',
      'upload-started'
    ])
  })
})

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

    await service.indexBook(42, [{ id: 1, pageNumber: 1, bookId: 42, data: 'A' }])

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

  it('isIndexing reflects in-flight state: false → true during run → false after', async () => {
    const { db } = makeRagDb({ chunksExist: false })
    const rag = makeRag()
    // Use a deferred embed so we can observe the in-flight state mid-call.
    let resolveEmbed!: (value: never[]) => void
    const embedDeferred = new Promise<never[]>((res) => {
      resolveEmbed = res as (v: never[]) => void
    })
    const embed = vi.fn(() => embedDeferred) as unknown as ReturnType<typeof makeEmbed>
    const service = createBookImportService(makeDeps({ db, rag, embed }))

    expect(service.isIndexing(42)).toBe(false)

    const inflight = service.indexBook(42, [{ id: 1, pageNumber: 1, bookId: 42, data: 'A' }])
    // Yield once so the indexer reaches its await on embed().
    await Promise.resolve()
    expect(service.isIndexing(42)).toBe(true)
    expect(service.isIndexing(99)).toBe(false)

    resolveEmbed([] as never[])
    await inflight
    expect(service.isIndexing(42)).toBe(false)
  })
})

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
    expect(events.map((e) => e.kind)).toEqual(['book-found', 'book-found', 'progress', 'complete'])
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
