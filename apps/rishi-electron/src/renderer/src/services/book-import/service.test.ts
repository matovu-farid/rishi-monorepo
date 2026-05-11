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
    // `upload-started` may arrive on next tick; wait for it.
    await new Promise((r) => setTimeout(r, 0))
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
