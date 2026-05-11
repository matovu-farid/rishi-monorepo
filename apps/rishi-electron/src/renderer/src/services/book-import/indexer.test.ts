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
