import { describe, it, expect, vi } from 'vitest'
import type { SyncIpcChannels } from './types'
import { makeAdapter } from './adapter'

/**
 * Build an in-memory SyncIpcChannels backed by per-channel arrays/values.
 * Exposes vi.fn spies on every method so tests can assert call args.
 */
export function makeIpc(initial?: {
  books?: unknown[]
  highlights?: unknown[]
  conversations?: unknown[]
  messages?: unknown[]
  lastVersion?: number
}): SyncIpcChannels {
  return {
    syncGetDirtyBooks: vi.fn(async () => initial?.books ?? []),
    syncGetDirtyHighlights: vi.fn(async () => initial?.highlights ?? []),
    syncGetDirtyConversations: vi.fn(async () => initial?.conversations ?? []),
    syncGetDirtyMessages: vi.fn(async () => initial?.messages ?? []),
    syncGetLastVersion: vi.fn(async () => initial?.lastVersion ?? 0),
    syncMarkBooksClean: vi.fn(async () => {}),
    syncMarkHighlightsClean: vi.fn(async () => {}),
    syncMarkConversationsClean: vi.fn(async () => {}),
    syncMarkMessagesClean: vi.fn(async () => {}),
    syncApplyBookConflict: vi.fn(async () => {}),
    syncApplyHighlightConflict: vi.fn(async () => {}),
    syncApplyConversationConflict: vi.fn(async () => {}),
    syncUpsertBook: vi.fn(async () => {}),
    syncUpsertHighlight: vi.fn(async () => {}),
    syncUpsertConversation: vi.fn(async () => {}),
    syncInsertMessage: vi.fn(async () => {}),
    syncUpdateLastVersion: vi.fn(async () => {})
  }
}

describe('adapter.getDirtyBooks', () => {
  it('coerces a row with a Date updatedAt into epoch ms and forwards every field', async () => {
    const ipc = makeIpc({
      books: [
        {
          syncId: 'book-1',
          title: 'Title',
          author: 'Author',
          format: 'epub',
          currentCfi: 'epubcfi(/6)',
          currentPage: 12,
          fileHash: 'abc',
          fileR2Key: 'r2/key',
          coverR2Key: 'r2/cover',
          createdAt: new Date(1_700_000_000_000),
          updatedAt: 1_700_000_001_000,
          syncVersion: 3,
          isDeleted: 0
        }
      ]
    })
    const adapter = makeAdapter(ipc)

    const rows = await adapter.getDirtyBooks()

    expect(rows).toHaveLength(1)
    expect(rows[0]).toEqual({
      id: 'book-1',
      title: 'Title',
      author: 'Author',
      format: 'epub',
      currentCfi: 'epubcfi(/6)',
      currentPage: 12,
      fileHash: 'abc',
      fileR2Key: 'r2/key',
      coverR2Key: 'r2/cover',
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_001_000,
      syncVersion: 3,
      isDirty: true,
      isDeleted: false
    })
  })
})

describe('adapter pass-through', () => {
  it('markHighlightsClean forwards ids + version verbatim to ipc', async () => {
    const ipc = makeIpc()
    const adapter = makeAdapter(ipc)

    await adapter.markHighlightsClean(['h-1', 'h-2'], 7)

    expect(ipc.syncMarkHighlightsClean).toHaveBeenCalledTimes(1)
    expect(ipc.syncMarkHighlightsClean).toHaveBeenCalledWith(['h-1', 'h-2'], 7)
  })

  it('applyBookConflict forwards the conflict object + version verbatim', async () => {
    const ipc = makeIpc()
    const adapter = makeAdapter(ipc)
    const conflict = { id: 'b-1', updatedAt: 9 }

    await adapter.applyBookConflict(conflict, 12)

    expect(ipc.syncApplyBookConflict).toHaveBeenCalledWith(conflict, 12)
  })

  it('upsertRemoteHighlight forwards the remote record + updateLastSyncVersion forwards the version', async () => {
    const ipc = makeIpc()
    const adapter = makeAdapter(ipc)
    const remote = { id: 'h-9', text: 'remote text' }

    await adapter.upsertRemoteHighlight(remote)
    await adapter.updateLastSyncVersion(99)

    expect(ipc.syncUpsertHighlight).toHaveBeenCalledWith(remote)
    expect(ipc.syncUpdateLastVersion).toHaveBeenCalledWith(99)
  })
})
