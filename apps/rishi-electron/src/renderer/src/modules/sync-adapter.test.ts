import { describe, it, expect, vi, beforeEach } from 'vitest'
import { DesktopSyncAdapter } from './sync-adapter'

describe('DesktopSyncAdapter', () => {
  let adapter: DesktopSyncAdapter

  beforeEach(() => {
    vi.clearAllMocks()
    adapter = new DesktopSyncAdapter()
  })

  it('getDirtyBooks returns mapped rows from IPC', async () => {
    vi.mocked(window.electron.syncGetDirtyBooks).mockResolvedValueOnce([
      {
        id: 1,
        syncId: 's1',
        title: 'Test',
        author: 'Author',
        format: 'epub',
        isDirty: 1,
        isDeleted: 0,
        kind: 'epub',
        syncVersion: 0
      }
    ])

    const result = await adapter.getDirtyBooks()

    expect(window.electron.syncGetDirtyBooks).toHaveBeenCalled()
    expect(result).toHaveLength(1)
    expect(result[0].id).toBe('s1')
    expect(result[0].isDirty).toBe(true)
  })

  it('markBooksClean calls syncMarkBooksClean with ids and syncVersion', async () => {
    vi.mocked(window.electron.syncMarkBooksClean).mockResolvedValue(undefined)

    await adapter.markBooksClean(['sync-id-1'], 5)

    expect(window.electron.syncMarkBooksClean).toHaveBeenCalledWith(['sync-id-1'], 5)
  })

  it('markBooksClean passes empty array for empty ids', async () => {
    vi.mocked(window.electron.syncMarkBooksClean).mockResolvedValue(undefined)

    await adapter.markBooksClean([], 1)

    expect(window.electron.syncMarkBooksClean).toHaveBeenCalledWith([], 1)
  })

  it('markHighlightsClean calls syncMarkHighlightsClean', async () => {
    vi.mocked(window.electron.syncMarkHighlightsClean).mockResolvedValue(undefined)

    await adapter.markHighlightsClean(['hl-1'], 5)

    expect(window.electron.syncMarkHighlightsClean).toHaveBeenCalledWith(['hl-1'], 5)
  })

  it('getDirtyHighlights calls syncGetDirtyHighlights', async () => {
    vi.mocked(window.electron.syncGetDirtyHighlights).mockResolvedValueOnce([])
    const result = await adapter.getDirtyHighlights()
    expect(window.electron.syncGetDirtyHighlights).toHaveBeenCalled()
    expect(result).toEqual([])
  })

  it('getDirtyConversations calls syncGetDirtyConversations', async () => {
    vi.mocked(window.electron.syncGetDirtyConversations).mockResolvedValueOnce([])
    const result = await adapter.getDirtyConversations()
    expect(window.electron.syncGetDirtyConversations).toHaveBeenCalled()
    expect(result).toEqual([])
  })

  it('getDirtyMessages calls syncGetDirtyMessages', async () => {
    vi.mocked(window.electron.syncGetDirtyMessages).mockResolvedValueOnce([])
    const result = await adapter.getDirtyMessages()
    expect(window.electron.syncGetDirtyMessages).toHaveBeenCalled()
    expect(result).toEqual([])
  })

  it('getLastSyncVersion returns 0 when no rows exist', async () => {
    vi.mocked(window.electron.syncGetLastVersion).mockResolvedValueOnce(0)
    const version = await adapter.getLastSyncVersion()
    expect(version).toBe(0)
  })

  it('getLastSyncVersion returns stored version', async () => {
    vi.mocked(window.electron.syncGetLastVersion).mockResolvedValueOnce(42)
    const version = await adapter.getLastSyncVersion()
    expect(version).toBe(42)
  })

  it('updateLastSyncVersion calls syncUpdateLastVersion', async () => {
    vi.mocked(window.electron.syncUpdateLastVersion).mockResolvedValueOnce(undefined)
    await adapter.updateLastSyncVersion(10)
    expect(window.electron.syncUpdateLastVersion).toHaveBeenCalledWith(10)
  })

  it('applyBookConflict delegates to syncApplyBookConflict', async () => {
    vi.mocked(window.electron.syncApplyBookConflict).mockResolvedValueOnce(undefined)
    const conflict = { id: 's1', title: 'New Title' }
    await adapter.applyBookConflict(conflict, 5)
    expect(window.electron.syncApplyBookConflict).toHaveBeenCalledWith(conflict, 5)
  })

  it('upsertRemoteBook delegates to syncUpsertBook', async () => {
    vi.mocked(window.electron.syncUpsertBook).mockResolvedValueOnce(undefined)
    const remote = { id: 'r1', title: 'Remote Book' }
    await adapter.upsertRemoteBook(remote)
    expect(window.electron.syncUpsertBook).toHaveBeenCalledWith(remote)
  })

  it('insertRemoteMessage delegates to syncInsertMessage', async () => {
    vi.mocked(window.electron.syncInsertMessage).mockResolvedValueOnce(undefined)
    const remote = { id: 'm1', content: 'Hello' }
    await adapter.insertRemoteMessage(remote)
    expect(window.electron.syncInsertMessage).toHaveBeenCalledWith(remote)
  })
})
