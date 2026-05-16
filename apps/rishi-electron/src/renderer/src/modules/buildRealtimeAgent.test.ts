import { describe, it, expect, vi, beforeEach } from 'vitest'
import { buildRealtimeAgent } from './buildRealtimeAgent'

const searchSemanticMock = vi.fn().mockResolvedValue([{ text: 'stub', vectorId: 1, score: 0.9 }])
const isIndexingMock = vi.fn().mockReturnValue(false)

vi.mock('@/services', () => ({
  getRagService: () => ({
    searchSemantic: searchSemanticMock
  }),
  getBookImportService: () => ({
    isIndexing: isIndexingMock
  })
}))

const captureErrorMock = vi.fn()
vi.mock('@/utils/sentry', () => ({
  captureError: (...args: unknown[]) => captureErrorMock(...args)
}))

describe('buildRealtimeAgent', () => {
  beforeEach(() => {
    captureErrorMock.mockClear()
    isIndexingMock.mockReturnValue(false)
    ;(window.electron.dumpError as ReturnType<typeof vi.fn>).mockClear()
  })
  it('embeds the current page text into the instructions', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'The quick brown fox jumped over the lazy dog.',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).toContain('The quick brown fox jumped over the lazy dog.')
  })

  it('uses a placeholder when page text is empty', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: '',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).toContain('(No page text available)')
  })

  it('embeds the active paragraph (what user just heard) into instructions when provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'Page text including the active sentence and more.',
      activeParagraphText: 'the active sentence',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).toMatch(/just heard|just read|currently/i)
    expect(agent.instructions).toContain('the active sentence')
  })

  it('omits the "just heard" section when activeParagraphText is not provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).not.toMatch(/just heard/i)
  })

  it('exposes two tools: bookContext and endConversation', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    const toolNames = agent.tools.map((t: { name: string }) => t.name)
    expect(toolNames).toContain('bookContext')
    expect(toolNames).toContain('endConversation')
  })

  it('endConversation tool invokes the provided callback', async () => {
    const onEnd = vi.fn()
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: onEnd,
      language: 'en'
    })
    const endTool = agent.tools.find(
      (t: { name: string }) => t.name === 'endConversation'
    ) as unknown as {
      execute: (args: { reason: string }) => Promise<unknown>
    }
    await endTool.execute({ reason: 'user said bye' })
    expect(onEnd).toHaveBeenCalledWith('user said bye')
  })

  it('bookContext tool queries with the captured bookId', async () => {
    searchSemanticMock.mockClear()
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    const bookContextTool = agent.tools.find(
      (t: { name: string }) => t.name === 'bookContext'
    ) as unknown as {
      execute: (args: { queryText: string }) => Promise<unknown>
    }
    const result = await bookContextTool.execute({ queryText: 'who is the protagonist?' })
    expect(searchSemanticMock).toHaveBeenCalledWith('who is the protagonist?', 42, 3)
    expect(result).toEqual(['stub'])
  })

  it('embeds book title and author into instructions when outline is provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      outline: {
        title: 'The Pragmatic Programmer',
        author: 'Hunt and Thomas',
        chapters: ['Introduction', 'Chapter 1']
      },
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).toContain('The Pragmatic Programmer')
    expect(agent.instructions).toContain('Hunt and Thomas')
  })

  it('embeds the chapter list into instructions when outline is provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      outline: {
        title: 'Book',
        author: null,
        chapters: ['Foreword', 'Chapter 1: Beginnings', 'Chapter 2: Middles']
      },
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).toContain('Foreword')
    expect(agent.instructions).toContain('Chapter 1: Beginnings')
    expect(agent.instructions).toContain('Chapter 2: Middles')
  })

  it('omits the outline section when outline is not provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).not.toContain('## Book Outline')
  })

  it('handles outline with null author gracefully', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      outline: { title: 'Anon Book', author: null, chapters: [] },
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).toContain('Anon Book')
    expect(agent.instructions).not.toContain('null')
    expect(agent.instructions).not.toContain('undefined')
  })

  it('bookContext while indexing: returns wait-message, does NOT call searchSemantic', async () => {
    isIndexingMock.mockReturnValue(true)
    searchSemanticMock.mockClear()

    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    const bookContextTool = agent.tools.find(
      (t: { name: string }) => t.name === 'bookContext'
    ) as unknown as {
      execute: (args: { queryText: string }) => Promise<unknown>
    }

    const result = (await bookContextTool.execute({
      queryText: 'what does chapter 3 say'
    })) as string[]

    expect(searchSemanticMock).not.toHaveBeenCalled()
    expect(result).toHaveLength(1)
    expect(result[0]).toMatch(/still indexing/i)
  })

  it('bookContext empty result: dumps with context, warns to console, returns the empty array', async () => {
    const consoleWarnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    searchSemanticMock.mockResolvedValueOnce([])

    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    const bookContextTool = agent.tools.find(
      (t: { name: string }) => t.name === 'bookContext'
    ) as unknown as {
      execute: (args: { queryText: string }) => Promise<unknown>
    }

    const result = await bookContextTool.execute({ queryText: 'what is X' })
    expect(result).toEqual([])

    expect(consoleWarnSpy).toHaveBeenCalledWith(
      "[voice-chat] tool 'bookContext' returned empty result. context:",
      'bookId=42 queryText="what is X"'
    )
    expect(window.electron.dumpError).toHaveBeenCalledWith(
      expect.objectContaining({
        source: 'voice-chat-agent',
        location: 'realtimeAgent.tools.bookContext',
        error: 'empty result',
        context: 'bookId=42 queryText="what is X"'
      })
    )
    // Sentry should NOT fire on empty — only on real errors.
    expect(captureErrorMock).not.toHaveBeenCalled()

    consoleWarnSpy.mockRestore()
  })

  it('bookContext failure: dumps to error file, logs to console, returns fallback', async () => {
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    searchSemanticMock.mockRejectedValueOnce(new Error('rag exploded'))

    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    const bookContextTool = agent.tools.find(
      (t: { name: string }) => t.name === 'bookContext'
    ) as unknown as {
      execute: (args: { queryText: string }) => Promise<unknown>
    }

    const result = await bookContextTool.execute({ queryText: 'anything' })
    expect(result).toEqual(['Unable to retrieve book context at this time.'])

    expect(consoleErrorSpy).toHaveBeenCalledWith(
      "[voice-chat] tool 'bookContext' failed:",
      expect.objectContaining({ message: 'rag exploded' })
    )
    expect(window.electron.dumpError).toHaveBeenCalledWith(
      expect.objectContaining({
        source: 'voice-chat-agent',
        location: 'realtimeAgent.tools.bookContext',
        error: 'rag exploded'
      })
    )
    expect(captureErrorMock).toHaveBeenCalledWith(
      expect.objectContaining({ message: 'rag exploded' }),
      expect.objectContaining({ operation: 'realtime', step: 'bookContext_tool' })
    )

    consoleErrorSpy.mockRestore()
  })

  it('endConversation failure: callback throw still dumps + logs + does not propagate', async () => {
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const onEnd = vi.fn().mockImplementation(() => {
      throw new Error('callback boom')
    })

    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: onEnd,
      language: 'en'
    })
    const endTool = agent.tools.find(
      (t: { name: string }) => t.name === 'endConversation'
    ) as unknown as {
      execute: (args: { reason: string }) => Promise<unknown>
    }

    // Must not throw — the agent infra would otherwise be unable to advance.
    await expect(endTool.execute({ reason: 'bye' })).resolves.toBeUndefined()

    expect(window.electron.dumpError).toHaveBeenCalledWith(
      expect.objectContaining({
        source: 'voice-chat-agent',
        location: 'realtimeAgent.tools.endConversation',
        error: 'callback boom'
      })
    )
    expect(captureErrorMock).toHaveBeenCalled()

    consoleErrorSpy.mockRestore()
  })

  it('embeds the chosen language label into instructions (English)', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'en'
    })
    expect(agent.instructions).toMatch(/Always respond in English/)
  })

  it('embeds the chosen language label into instructions (Spanish)', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'es'
    })
    expect(agent.instructions).toMatch(/Always respond in Spanish/)
  })

  it('falls back to English label for an unknown language code', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn(),
      language: 'xx'
    })
    expect(agent.instructions).toMatch(/Always respond in English/)
  })
})
