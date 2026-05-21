/**
 * Tests for the mobile drizzle-backed SyncDbAdapter.
 *
 * Verifies the adapter satisfies the shared `SyncDbAdapter` contract by
 * mocking drizzle's select / update / insert chains and asserting each
 * adapter method funnels the right calls.
 *
 * This is the new test boundary now that the engine logic lives in
 * `@rishi/shared/sync-engine` and the per-adapter SQL lives here.
 */

// ── Mock @rishi/shared/schema ────────────────────────────────────────────────
const fakeTable = (_name: string) => {
  return new Proxy({} as Record<string, unknown>, {
    get: (_target, prop: string) => prop,
  })
}
jest.mock('@rishi/shared/schema', () => ({
  books: fakeTable('books'),
  highlights: fakeTable('highlights'),
  conversations: fakeTable('conversations'),
  messages: fakeTable('messages'),
  syncMeta: fakeTable('sync_meta'),
}))

// ── Mock drizzle-orm operators ───────────────────────────────────────────────
jest.mock('drizzle-orm', () => ({
  eq: jest.fn((_col, _val) => ({ eq: [_col, _val] })),
  and: jest.fn((...args: unknown[]) => ({ and: args })),
  gt: jest.fn((_col, _val) => ({ gt: [_col, _val] })),
}))

// ── Mock db ─────────────────────────────────────────────────────────────────
const mockRun = jest.fn()

function chain(allResult: unknown[] = [], getResult: unknown = undefined) {
  return {
    from: jest.fn().mockReturnValue({
      where: jest.fn().mockReturnValue({
        all: jest.fn().mockReturnValue(allResult),
        get: jest.fn().mockReturnValue(getResult),
        orderBy: jest.fn().mockReturnValue({ all: jest.fn().mockReturnValue(allResult) }),
      }),
      all: jest.fn().mockReturnValue(allResult),
    }),
  }
}

const updateChain = {
  set: jest.fn().mockReturnValue({
    where: jest.fn().mockReturnValue({ run: mockRun }),
  }),
}

const insertChain = {
  values: jest.fn().mockReturnValue({ run: mockRun }),
}

const mockDb = {
  select: jest.fn().mockReturnValue(chain()),
  insert: jest.fn().mockReturnValue(insertChain),
  update: jest.fn().mockReturnValue(updateChain),
}

jest.mock('@/lib/db', () => ({ db: mockDb }))

import { createMobileDrizzleAdapter } from '@/lib/sync/drizzle-adapter'

describe('mobileDrizzleAdapter', () => {
  beforeEach(() => {
    jest.clearAllMocks()
  })

  it('getDirtyBooks queries the books table with isDirty=true', async () => {
    const dirty = [{ id: 'b1', isDirty: true }]
    mockDb.select.mockReturnValueOnce(chain(dirty))
    const adapter = createMobileDrizzleAdapter()
    const result = await adapter.getDirtyBooks()
    expect(result).toEqual(dirty)
    expect(mockDb.select).toHaveBeenCalled()
  })

  it('getDirtyHighlights / getDirtyConversations / getDirtyMessages all query the right table', async () => {
    const fakeRows = [{ id: 'x' }]
    mockDb.select
      .mockReturnValueOnce(chain(fakeRows))
      .mockReturnValueOnce(chain(fakeRows))
      .mockReturnValueOnce(chain(fakeRows))
    const adapter = createMobileDrizzleAdapter()
    expect(await adapter.getDirtyHighlights()).toEqual(fakeRows)
    expect(await adapter.getDirtyConversations()).toEqual(fakeRows)
    expect(await adapter.getDirtyMessages()).toEqual(fakeRows)
  })

  it('getLastSyncVersion reads sync_meta and falls back to 0', async () => {
    mockDb.select.mockReturnValueOnce(chain([], { lastSyncVersion: 17 }))
    const adapter = createMobileDrizzleAdapter()
    expect(await adapter.getLastSyncVersion()).toBe(17)

    mockDb.select.mockReturnValueOnce(chain([], undefined))
    expect(await adapter.getLastSyncVersion()).toBe(0)
  })

  it('markBooksClean updates each id with isDirty=false + syncVersion', async () => {
    const adapter = createMobileDrizzleAdapter()
    await adapter.markBooksClean(['a', 'b', 'c'], 5)
    expect(mockDb.update).toHaveBeenCalledTimes(3)
    expect(updateChain.set).toHaveBeenCalledWith({ isDirty: false, syncVersion: 5 })
    expect(mockRun).toHaveBeenCalledTimes(3)
  })

  it('markHighlightsClean / markConversationsClean / markMessagesClean apply the same shape', async () => {
    const adapter = createMobileDrizzleAdapter()
    await adapter.markHighlightsClean(['h1'], 9)
    await adapter.markConversationsClean(['c1'], 9)
    await adapter.markMessagesClean(['m1'], 9)
    expect(mockDb.update).toHaveBeenCalledTimes(3)
  })

  it('applyBookConflict updates the local book with server-supplied fields', async () => {
    const adapter = createMobileDrizzleAdapter()
    await adapter.applyBookConflict(
      {
        id: 'b1',
        title: 'T',
        author: 'A',
        format: 'epub',
        currentCfi: null,
        currentPage: null,
        fileHash: null,
        fileR2Key: null,
        coverR2Key: null,
        createdAt: 100,
        updatedAt: 200,
        isDeleted: false,
      },
      7,
    )
    expect(mockDb.update).toHaveBeenCalled()
    expect(updateChain.set).toHaveBeenCalledWith(
      expect.objectContaining({
        title: 'T',
        author: 'A',
        syncVersion: 7,
        isDirty: false,
      }),
    )
  })

  it('upsertRemoteBook inserts when local row is missing', async () => {
    // First select returns no local row
    mockDb.select.mockReturnValueOnce(chain([], undefined))
    const adapter = createMobileDrizzleAdapter()
    await adapter.upsertRemoteBook({
      id: 'rb1',
      title: 'Remote',
      author: 'X',
      format: 'pdf',
    })
    expect(mockDb.insert).toHaveBeenCalled()
    expect(insertChain.values).toHaveBeenCalledWith(
      expect.objectContaining({
        id: 'rb1',
        title: 'Remote',
        filePath: '', // not downloaded yet
        coverPath: null,
      }),
    )
  })

  it('upsertRemoteBook skips when local row is dirty', async () => {
    mockDb.select.mockReturnValueOnce(chain([], { id: 'rb1', isDirty: true }))
    const adapter = createMobileDrizzleAdapter()
    await adapter.upsertRemoteBook({ id: 'rb1', updatedAt: 999 })
    expect(mockDb.update).not.toHaveBeenCalled()
    expect(mockDb.insert).not.toHaveBeenCalled()
  })

  it('insertRemoteMessage appends new messages and skips existing ones', async () => {
    // First call: local exists → skip
    mockDb.select.mockReturnValueOnce(chain([], { id: 'm1' }))
    const adapter = createMobileDrizzleAdapter()
    await adapter.insertRemoteMessage({ id: 'm1' })
    expect(mockDb.insert).not.toHaveBeenCalled()

    // Second call: local missing → insert
    mockDb.select.mockReturnValueOnce(chain([], undefined))
    await adapter.insertRemoteMessage({
      id: 'm2',
      conversationId: 'c1',
      role: 'user',
      content: 'hi',
    })
    expect(mockDb.insert).toHaveBeenCalled()
  })

  it('updateLastSyncVersion updates sync_meta with the new version + timestamp', async () => {
    const adapter = createMobileDrizzleAdapter()
    await adapter.updateLastSyncVersion(42)
    expect(mockDb.update).toHaveBeenCalled()
    expect(updateChain.set).toHaveBeenCalledWith(
      expect.objectContaining({ lastSyncVersion: 42, lastSyncAt: expect.any(Number) }),
    )
  })
})
