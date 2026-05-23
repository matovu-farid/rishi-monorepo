/**
 * DAT-016 (#128) tests for conversation-storage.mapRowToMessage's handling
 * of malformed `sourceChunks` JSON. Lives in __tests__/storage/ so it's
 * partitioned with the other sync-storage critic-sweep fixes.
 *
 * The full CRUD surface is already covered by __tests__/conversation.test.ts;
 * this file focuses on the malformed-JSON surface.
 */

const fakeTable = () =>
  new Proxy({} as Record<string, unknown>, {
    get: (_t, prop: string) => prop,
  })

jest.mock('@rishi/shared/schema', () => ({
  books: fakeTable(),
  highlights: fakeTable(),
  conversations: fakeTable(),
  messages: fakeTable(),
  syncMeta: fakeTable(),
}))

jest.mock('drizzle-orm', () => ({
  eq: jest.fn((_col, _val) => ({ eq: [_col, _val] })),
  and: jest.fn((...args: unknown[]) => ({ and: args })),
  desc: jest.fn((_col) => ({ desc: _col })),
  asc: jest.fn((_col) => ({ asc: _col })),
}))

// ── db mock — only `select(...).from(...).where(...).orderBy(...).all()` is
//   exercised by `getMessages`. We script the `.all()` return per test.
const allReturn: { rows: unknown[] } = { rows: [] }
const orderByMock = jest.fn().mockReturnValue({ all: () => allReturn.rows })
const whereMock = jest.fn().mockReturnValue({ orderBy: orderByMock })
const fromMock = jest.fn().mockReturnValue({ where: whereMock })

const mockDb = {
  select: jest.fn().mockReturnValue({ from: fromMock }),
  insert: jest.fn(),
  update: jest.fn(),
}

jest.mock('@/lib/db', () => ({
  db: mockDb,
  // DAT-015 (#127): conversation-storage now stamps writes via the
  // monotonic helper from db.ts; the test mock must export it too.
  nextLocalTimestamp: jest.fn(() => Date.now()),
}))

jest.mock('@/lib/sync/triggers', () => ({
  triggerSyncOnWrite: jest.fn(),
}))

jest.mock('expo-crypto', () => ({
  randomUUID: jest.fn().mockReturnValue('test-uuid'),
}))

// ── Imports after mocks ─────────────────────────────────────────────────────
import { getMessages } from '@/lib/conversation-storage'

describe('DAT-016 (#128) — getMessages surfaces malformed sourceChunks', () => {
  let warnSpy: jest.SpyInstance

  beforeEach(() => {
    warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => undefined)
    allReturn.rows = []
    mockDb.select.mockClear()
  })

  afterEach(() => {
    warnSpy.mockRestore()
  })

  function setRows(rows: unknown[]): void {
    allReturn.rows = rows
  }

  it('logs a warning with the offending message id when sourceChunks is not valid JSON', () => {
    setRows([
      {
        id: 'msg-bad',
        conversationId: 'conv-1',
        role: 'assistant',
        content: 'Answer',
        // Truncated JSON — a real failure mode if the embedder crashes
        // mid-write.
        sourceChunks: '[{"chunkId":"c1","text":',
        createdAt: 1000,
        updatedAt: 1000,
        syncVersion: 0,
        isDirty: false,
        isDeleted: false,
      },
    ])

    const messages = getMessages('conv-1')
    expect(messages).toHaveLength(1)
    // The corrupted row still renders (content is still useful), but its
    // sourceChunks degrade to null instead of crashing the screen…
    expect(messages[0].sourceChunks).toBeNull()
    // …AND we log so the dev error dump catches the corruption.
    expect(warnSpy).toHaveBeenCalled()
    const allWarnArgs = warnSpy.mock.calls.flat().map((v) => String(v)).join(' ')
    expect(allWarnArgs).toMatch(/sourceChunks/i)
    expect(allWarnArgs).toMatch(/msg-bad/)
  })

  it('surfaces a sourceChunksCorrupted flag on the returned Message', () => {
    setRows([
      {
        id: 'msg-corrupt',
        conversationId: 'conv-1',
        role: 'assistant',
        content: 'Answer',
        sourceChunks: 'not-json-at-all',
        createdAt: 1,
        updatedAt: 1,
        syncVersion: 0,
        isDirty: false,
        isDeleted: false,
      },
    ])

    const [m] = getMessages('conv-1') as Array<{
      sourceChunks: unknown
      sourceChunksCorrupted?: boolean
    }>
    expect(m.sourceChunks).toBeNull()
    expect(m.sourceChunksCorrupted).toBe(true)
  })

  it('does NOT flag well-formed payloads as corrupted', () => {
    const chunks = [{ chunkId: 'c1', text: 'hi', chapter: null }]
    setRows([
      {
        id: 'msg-ok',
        conversationId: 'conv-1',
        role: 'assistant',
        content: 'Answer',
        sourceChunks: JSON.stringify(chunks),
        createdAt: 1,
        updatedAt: 1,
        syncVersion: 0,
        isDirty: false,
        isDeleted: false,
      },
    ])

    const [m] = getMessages('conv-1') as Array<{
      sourceChunks: unknown
      sourceChunksCorrupted?: boolean
    }>
    expect(m.sourceChunks).toEqual(chunks)
    expect(m.sourceChunksCorrupted).toBeFalsy()
    expect(warnSpy).not.toHaveBeenCalled()
  })

  it('does NOT log when sourceChunks is null (no payload to parse)', () => {
    setRows([
      {
        id: 'msg-no-chunks',
        conversationId: 'conv-1',
        role: 'user',
        content: 'Hi',
        sourceChunks: null,
        createdAt: 1,
        updatedAt: 1,
        syncVersion: 0,
        isDirty: false,
        isDeleted: false,
      },
    ])

    const [m] = getMessages('conv-1')
    expect(m.sourceChunks).toBeNull()
    expect(warnSpy).not.toHaveBeenCalled()
  })
})
