import { describe, it, expect, vi } from 'vitest'
import { buildRealtimeAgent } from './buildRealtimeAgent'

vi.mock('@/lib/api', () => ({
  getContextForQuery: vi.fn().mockResolvedValue(['stub'])
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
    const { getContextForQuery } = await import('@/lib/api')
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
    await bookContextTool.execute({ queryText: 'who is the protagonist?' })
    expect(getContextForQuery).toHaveBeenCalledWith({
      bookId: 42,
      queryText: 'who is the protagonist?',
      k: 3
    })
  })
})
