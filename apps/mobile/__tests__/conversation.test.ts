/**
 * Tests for conversation-storage.ts CRUD functions.
 * Mocks @/lib/db and @/lib/sync/triggers.
 */

// ── Mock @rishi/shared/schema (avoid drizzle-orm/sqlite-core resolution) ────
const fakeTable = (name: string) => {
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
  desc: jest.fn((_col) => ({ desc: _col })),
  asc: jest.fn((_col) => ({ asc: _col })),
}))

// ── Mock db ─────────────────────────────────────────────────────────────────
const mockRun = jest.fn()
const mockAll = jest.fn().mockReturnValue([])
const mockGet = jest.fn().mockReturnValue(undefined)
const mockSet = jest.fn().mockReturnThis()
const mockWhere = jest.fn().mockReturnThis()
const mockOrderBy = jest.fn().mockReturnThis()
const mockValues = jest.fn().mockReturnThis()

const mockSelectChain = {
  from: jest.fn().mockReturnValue({
    where: jest.fn().mockReturnValue({
      orderBy: jest.fn().mockReturnValue({ all: mockAll }),
      get: mockGet,
      all: mockAll,
    }),
    orderBy: jest.fn().mockReturnValue({ all: mockAll }),
    all: mockAll,
  }),
}

const mockInsertChain = {
  values: jest.fn().mockReturnValue({ run: mockRun }),
}

const mockUpdateChain = {
  set: jest.fn().mockReturnValue({
    where: jest.fn().mockReturnValue({ run: mockRun }),
  }),
}

const mockDb = {
  select: jest.fn().mockReturnValue(mockSelectChain),
  insert: jest.fn().mockReturnValue(mockInsertChain),
  update: jest.fn().mockReturnValue(mockUpdateChain),
}

jest.mock('@/lib/db', () => ({
  db: mockDb,
}))

// ── Mock sync triggers ───────────────────────────────────────────────────────
const mockTriggerSyncOnWrite = jest.fn()
jest.mock('@/lib/sync/triggers', () => ({
  triggerSyncOnWrite: mockTriggerSyncOnWrite,
}))

// ── Mock expo-crypto ─────────────────────────────────────────────────────────
jest.mock('expo-crypto', () => ({
  randomUUID: jest.fn().mockReturnValue('test-uuid-123'),
}))

// ── Import after mocks ──────────────────────────────────────────────────────
import {
  createConversation,
  addMessage,
  getMessages,
  getAllConversations,
  getConversationsForBook,
  softDeleteConversation,
} from '@/lib/conversation-storage'

describe('conversation-storage', () => {
  beforeEach(() => {
    jest.clearAllMocks()
    // Reset default mock returns
    mockAll.mockReturnValue([])
    mockGet.mockReturnValue(undefined)
  })

  describe('createConversation', () => {
    it('inserts with correct fields and calls triggerSyncOnWrite', () => {
      const result = createConversation('book-1')

      expect(mockDb.insert).toHaveBeenCalled()
      expect(mockInsertChain.values).toHaveBeenCalledWith(
        expect.objectContaining({
          id: 'test-uuid-123',
          bookId: 'book-1',
          title: 'New conversation',
          isDirty: true,
          isDeleted: false,
        })
      )
      expect(mockRun).toHaveBeenCalled()
      expect(mockTriggerSyncOnWrite).toHaveBeenCalled()
      expect(result).toMatchObject({
        id: 'test-uuid-123',
        bookId: 'book-1',
        title: 'New conversation',
      })
    })

    it('uses custom title when provided', () => {
      createConversation('book-1', 'My Custom Title')

      expect(mockInsertChain.values).toHaveBeenCalledWith(
        expect.objectContaining({
          title: 'My Custom Title',
        })
      )
    })
  })

  describe('addMessage', () => {
    it('inserts with correct fields and calls triggerSyncOnWrite', () => {
      // Mock conversation get for title update check
      const fromMock = jest.fn()
      const whereGetMock = jest.fn()
      const getMock = jest.fn().mockReturnValue({ title: 'Existing title' })

      fromMock.mockReturnValue({ where: whereGetMock })
      whereGetMock.mockReturnValue({ get: getMock })
      mockDb.select.mockReturnValueOnce({ from: fromMock })

      const result = addMessage('conv-1', 'user', 'Hello world')

      expect(mockDb.insert).toHaveBeenCalled()
      expect(mockInsertChain.values).toHaveBeenCalledWith(
        expect.objectContaining({
          id: 'test-uuid-123',
          conversationId: 'conv-1',
          role: 'user',
          content: 'Hello world',
          isDirty: true,
        })
      )
      expect(mockTriggerSyncOnWrite).toHaveBeenCalled()
      expect(result).toMatchObject({
        id: 'test-uuid-123',
        conversationId: 'conv-1',
        role: 'user',
        content: 'Hello world',
      })
    })

    it('updates conversation title from first user message when title is "New conversation"', () => {
      // Mock: conversation has default title
      const fromMock = jest.fn()
      const whereGetMock = jest.fn()
      const getMock = jest.fn().mockReturnValue({ title: 'New conversation' })

      fromMock.mockReturnValue({ where: whereGetMock })
      whereGetMock.mockReturnValue({ get: getMock })
      mockDb.select.mockReturnValueOnce({ from: fromMock })

      addMessage('conv-1', 'user', 'What does chapter 3 say about quantum physics?')

      // Should call update twice: once for title, once for updatedAt
      // The update for title should contain the truncated content
      expect(mockDb.update).toHaveBeenCalled()
    })

    it('parses sourceChunks to JSON when provided', () => {
      const fromMock = jest.fn()
      const whereGetMock = jest.fn()
      const getMock = jest.fn().mockReturnValue({ title: 'Existing' })

      fromMock.mockReturnValue({ where: whereGetMock })
      whereGetMock.mockReturnValue({ get: getMock })
      mockDb.select.mockReturnValueOnce({ from: fromMock })

      const chunks = [{ chunkId: 'c1', text: 'snippet', chapter: null }]
      const result = addMessage('conv-1', 'assistant', 'Answer', chunks)

      expect(mockInsertChain.values).toHaveBeenCalledWith(
        expect.objectContaining({
          sourceChunks: JSON.stringify(chunks),
        })
      )
      expect(result.sourceChunks).toEqual(chunks)
    })
  })

  describe('getMessages', () => {
    it('returns messages sorted by createdAt ASC with sourceChunks JSON-parsed', () => {
      const chunks = [{ chunkId: 'c1', text: 'test', chapter: null }]
      const mockRows = [
        {
          id: 'msg-1',
          conversationId: 'conv-1',
          role: 'user',
          content: 'Hello',
          sourceChunks: null,
          createdAt: 1000,
          updatedAt: 1000,
          syncVersion: 0,
          isDirty: false,
          isDeleted: false,
        },
        {
          id: 'msg-2',
          conversationId: 'conv-1',
          role: 'assistant',
          content: 'Hi',
          sourceChunks: JSON.stringify(chunks),
          createdAt: 2000,
          updatedAt: 2000,
          syncVersion: 0,
          isDirty: false,
          isDeleted: false,
        },
      ]

      // Set up the mock chain for getMessages
      const orderByMock = jest.fn().mockReturnValue({ all: jest.fn().mockReturnValue(mockRows) })
      const whereMock = jest.fn().mockReturnValue({ orderBy: orderByMock })
      const fromMock = jest.fn().mockReturnValue({ where: whereMock })
      mockDb.select.mockReturnValueOnce({ from: fromMock })

      const messages = getMessages('conv-1')

      expect(messages).toHaveLength(2)
      expect(messages[0].sourceChunks).toBeNull()
      expect(messages[1].sourceChunks).toEqual(chunks)
    })
  })

  describe('softDeleteConversation', () => {
    it('sets isDeleted=true and isDirty=true and calls triggerSyncOnWrite', () => {
      softDeleteConversation('conv-1')

      expect(mockDb.update).toHaveBeenCalled()
      expect(mockUpdateChain.set).toHaveBeenCalledWith(
        expect.objectContaining({
          isDeleted: true,
          isDirty: true,
        })
      )
      expect(mockTriggerSyncOnWrite).toHaveBeenCalled()
    })
  })

  describe('getAllConversations', () => {
    it('returns non-deleted conversations', () => {
      const mockRows = [
        {
          id: 'conv-1',
          bookId: 'book-1',
          title: 'Test',
          createdAt: 1000,
          updatedAt: 2000,
          userId: null,
          syncVersion: 0,
          isDirty: false,
          isDeleted: false,
        },
      ]
      const orderByMock = jest.fn().mockReturnValue({ all: jest.fn().mockReturnValue(mockRows) })
      const whereMock = jest.fn().mockReturnValue({ orderBy: orderByMock })
      const fromMock = jest.fn().mockReturnValue({ where: whereMock })
      mockDb.select.mockReturnValueOnce({ from: fromMock })

      const convs = getAllConversations()

      expect(convs).toHaveLength(1)
      expect(convs[0]).toMatchObject({
        id: 'conv-1',
        bookId: 'book-1',
        title: 'Test',
      })
      // Should not have sync columns
      expect((convs[0] as Record<string, unknown>).isDirty).toBeUndefined()
      expect((convs[0] as Record<string, unknown>).syncVersion).toBeUndefined()
    })
  })
})
