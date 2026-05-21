import { describe, it, expect, vi } from 'vitest'
import type { BookStoreIpc, PageDataInsertable, ImportProgressEvent } from './types'
import type { RagService } from '../rag'
import type { EmbedParam, EmbedResult, PageData } from '@/lib/api'
import { indexBook } from './indexer'

type ChunkRecord = { id?: number | null; pageNumber: number; bookId: number; data: string }
type SaveVectorsCall = { name: string; dim: number; vectors: { id: number; vector: number[] }[] }

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
    findBookByHash: vi.fn(async () => null),
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
  return vi.fn(async (params: EmbedParam[]) => {
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

    await indexBook({ db, rag, embed, embedBatchSize: 2 }, 42, samplePageData, (e) =>
      events.push(e)
    )

    expect(savePageDataCalls).toEqual([])
    expect(saveVectorsCalls).toEqual([])
    expect(embed).not.toHaveBeenCalled()
    expect(events).toEqual([])
  })
})

describe('indexBook — full pipeline (chunks + vectors)', () => {
  it('saves chunks, embeds in batches of 2, and saves vectors with name "<bookId>-vectordb"', async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({ chunksExist: false })
    const rag = makeRag()
    const embed = makeEmbed()
    const events: ImportProgressEvent[] = []

    await indexBook({ db, rag, embed, embedBatchSize: 2 }, 42, samplePageData, (e) =>
      events.push(e)
    )

    expect(savePageDataCalls).toHaveLength(2)
    expect(saveVectorsCalls).toHaveLength(1)
    expect(saveVectorsCalls[0].name).toBe('42-vectordb')
    expect(saveVectorsCalls[0].dim).toBe(3)
    expect(events).toEqual([
      { kind: 'indexing', bookId: 42, reason: 'chunks-missing' },
      { kind: 'indexed', bookId: 42, ok: true }
    ])
  })
})

describe('indexBook — re-embed regression (chunks exist, vectors missing)', () => {
  it('does NOT re-save chunks; DOES embed and save vectors', async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({ chunksExist: true })
    const rag = makeRag() // not indexed
    const embed = makeEmbed()
    const events: ImportProgressEvent[] = []

    await indexBook({ db, rag, embed, embedBatchSize: 2 }, 42, samplePageData, (e) =>
      events.push(e)
    )

    expect(savePageDataCalls).toEqual([])
    expect(saveVectorsCalls).toHaveLength(1)
    expect(saveVectorsCalls[0].name).toBe('42-vectordb')
    expect(events).toEqual([
      { kind: 'indexing', bookId: 42, reason: 'vectors-missing' },
      { kind: 'indexed', bookId: 42, ok: true }
    ])
  })
})

describe('indexBook — embed failure is swallowed', () => {
  it('saves chunks but resolves void when embed throws', async () => {
    const { db, savePageDataCalls, saveVectorsCalls } = makeDb({ chunksExist: false })
    const rag = makeRag()
    const embed = makeEmbed({ failNTimes: 1 })
    const events: ImportProgressEvent[] = []

    await expect(
      indexBook({ db, rag, embed, embedBatchSize: 2 }, 42, samplePageData, (e) => events.push(e))
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
    expect(events).toEqual([
      { kind: 'indexing', bookId: 42, reason: 'vectors-missing' },
      { kind: 'indexed', bookId: 42, ok: true }
    ])
  })
})

describe('indexBook — emits `indexed: ok=false` on embed failure', () => {
  it('still emits the final indexed event so listeners (e.g. UI indicators) can clear', async () => {
    const { db } = makeDb({ chunksExist: false })
    const rag = makeRag()
    const embed = makeEmbed({ failNTimes: 1 })
    const events: ImportProgressEvent[] = []

    await indexBook({ db, rag, embed, embedBatchSize: 2 }, 42, samplePageData, (e) =>
      events.push(e)
    )

    const indexed = events.find((e) => e.kind === 'indexed')
    expect(indexed).toEqual({ kind: 'indexed', bookId: 42, ok: false })
  })
})
