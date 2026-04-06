/**
 * Tests for sync engine conversation/message push/pull extensions.
 * Mocks apiClient and db.
 */

// ── Mock @rishi/shared/schema (avoid drizzle-orm/sqlite-core resolution) ────
const fakeTable = (name: string) => {
  const col = (colName: string) => ({ [colName]: colName })
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
const mockAll = jest.fn().mockReturnValue([])
const mockGet = jest.fn().mockReturnValue(undefined)

function createSelectChain(allResult: unknown[] = [], getResult: unknown = undefined) {
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

const mockUpdateChain = {
  set: jest.fn().mockReturnValue({
    where: jest.fn().mockReturnValue({ run: mockRun }),
  }),
}

const mockInsertChain = {
  values: jest.fn().mockReturnValue({ run: mockRun }),
}

const mockDb = {
  select: jest.fn().mockReturnValue(createSelectChain()),
  insert: jest.fn().mockReturnValue(mockInsertChain),
  update: jest.fn().mockReturnValue(mockUpdateChain),
}

jest.mock('@/lib/db', () => ({
  db: mockDb,
}))

// ── Mock apiClient ───────────────────────────────────────────────────────────
const mockApiClient = jest.fn()
jest.mock('@/lib/api', () => ({
  apiClient: mockApiClient,
}))

// ── Import after mocks ──────────────────────────────────────────────────────
import { sync } from '@/lib/sync/engine'

describe('sync engine - conversations and messages', () => {
  beforeEach(() => {
    jest.clearAllMocks()
  })

  it('push includes dirty conversations and messages', async () => {
    const dirtyBooks: unknown[] = []
    const dirtyHighlights: unknown[] = []
    const dirtyConversations = [{ id: 'conv-1', bookId: 'book-1', isDirty: true }]
    const dirtyMessages = [{ id: 'msg-1', conversationId: 'conv-1', isDirty: true }]

    // Mock select calls in push() order: books, highlights, conversations, messages
    let selectCallCount = 0
    mockDb.select.mockImplementation(() => {
      selectCallCount++
      if (selectCallCount === 1) return createSelectChain(dirtyBooks)
      if (selectCallCount === 2) return createSelectChain(dirtyHighlights)
      if (selectCallCount === 3) return createSelectChain(dirtyConversations)
      if (selectCallCount === 4) return createSelectChain(dirtyMessages)
      // pull() calls
      return createSelectChain([], { lastSyncVersion: 0 })
    })

    // Mock push response
    mockApiClient.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ conflicts: [], syncVersion: 5 }),
    })
    // Mock pull response
    mockApiClient.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        changes: { books: [], highlights: [], conversations: [], messages: [] },
        syncVersion: 5,
      }),
    })

    await sync()

    // Verify push was called with conversations and messages
    expect(mockApiClient).toHaveBeenCalledWith(
      '/api/sync/push',
      expect.objectContaining({
        method: 'POST',
        body: expect.stringContaining('"conversations"'),
      })
    )
    const pushBody = JSON.parse(
      (mockApiClient.mock.calls[0][1] as { body: string }).body
    )
    expect(pushBody.changes.conversations).toEqual(dirtyConversations)
    expect(pushBody.changes.messages).toEqual(dirtyMessages)
  })

  it('pull processes remote conversations and messages', async () => {
    // All select calls return empty (nothing dirty for push)
    mockDb.select.mockImplementation(() => createSelectChain([], { lastSyncVersion: 0 }))

    // Push: nothing dirty, so push should be skipped or return quickly
    // Pull response with conversations and messages
    mockApiClient.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        changes: {
          books: [],
          highlights: [],
          conversations: [
            { id: 'remote-conv-1', bookId: 'book-1', title: 'Remote', createdAt: 1000, updatedAt: 2000, syncVersion: 3, isDeleted: false },
          ],
          messages: [
            { id: 'remote-msg-1', conversationId: 'remote-conv-1', role: 'user', content: 'Hello', createdAt: 1000, updatedAt: 1000, syncVersion: 3, isDeleted: false },
          ],
        },
        syncVersion: 3,
      }),
    })

    await sync()

    // Verify that insert was called for conversations and messages
    expect(mockDb.insert).toHaveBeenCalled()
  })
})
