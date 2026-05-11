import { describe, it, expect, vi } from 'vitest'
import { buildRealtimeAgent } from './buildRealtimeAgent'

const searchSemanticMock = vi.fn().mockResolvedValue([{ text: 'stub', vectorId: 1, score: 0.9 }])

vi.mock('@/services', () => ({
  getRagService: () => ({
    searchSemantic: searchSemanticMock
  })
}))

describe('buildRealtimeAgent', () => {
  it('embeds the current page text into the instructions', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'The quick brown fox jumped over the lazy dog.',
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('The quick brown fox jumped over the lazy dog.')
  })

  it('uses a placeholder when page text is empty', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: '',
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('(No page text available)')
  })

  it('exposes two tools: bookContext and endConversation', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn()
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
      onEndConversation: onEnd
    })
    const endTool = agent.tools.find((t: { name: string }) => t.name === 'endConversation') as unknown as {
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
      onEndConversation: vi.fn()
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
      onEndConversation: vi.fn()
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
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('Foreword')
    expect(agent.instructions).toContain('Chapter 1: Beginnings')
    expect(agent.instructions).toContain('Chapter 2: Middles')
  })

  it('omits the outline section when outline is not provided', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).not.toContain('## Book Outline')
  })

  it('handles outline with null author gracefully', () => {
    const agent = buildRealtimeAgent({
      bookId: 42,
      pageText: 'x',
      outline: { title: 'Anon Book', author: null, chapters: [] },
      onEndConversation: vi.fn()
    })
    expect(agent.instructions).toContain('Anon Book')
    expect(agent.instructions).not.toContain('null')
    expect(agent.instructions).not.toContain('undefined')
  })
})
