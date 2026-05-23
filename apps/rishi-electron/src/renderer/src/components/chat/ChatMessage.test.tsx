import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ChatMessage } from './ChatMessage'
import type { Message } from '@/types/conversation'

function makeMessage(overrides: Partial<Message>): Message {
  return {
    id: 'm1',
    conversationId: 'c1',
    role: 'assistant',
    content: '',
    sourceChunks: null,
    createdAt: 0,
    ...overrides
  }
}

describe('ChatMessage — markdown rendering (CHT-015)', () => {
  it('renders **bold** content as a <strong> element, not raw text', () => {
    const message = makeMessage({ content: '**hello world**' })
    const { container } = render(<ChatMessage message={message} onSourceNavigate={() => {}} />)

    expect(container.querySelector('strong')).not.toBeNull()
    expect(container.querySelector('strong')?.textContent).toBe('hello world')
    // The raw asterisks must not survive in the DOM text.
    expect(container.textContent ?? '').not.toContain('**hello world**')
  })

  it('renders inline `code` as <code> element', () => {
    const message = makeMessage({ content: 'Try `npm install` to begin' })
    const { container } = render(<ChatMessage message={message} onSourceNavigate={() => {}} />)
    const codeEl = container.querySelector('code')
    expect(codeEl).not.toBeNull()
    expect(codeEl?.textContent).toBe('npm install')
  })

  it('renders markdown links as <a> elements with href', () => {
    const message = makeMessage({ content: 'See [the docs](https://example.com)' })
    const { container } = render(<ChatMessage message={message} onSourceNavigate={() => {}} />)
    const link = container.querySelector('a')
    expect(link).not.toBeNull()
    expect(link?.getAttribute('href')).toBe('https://example.com')
    expect(link?.textContent).toBe('the docs')
  })

  it('renders `# heading` as an <h1> element (acceptance criterion)', () => {
    const message = makeMessage({ content: '# Big heading' })
    const { container } = render(<ChatMessage message={message} onSourceNavigate={() => {}} />)
    const h1 = container.querySelector('h1')
    expect(h1).not.toBeNull()
    expect(h1?.textContent).toBe('Big heading')
  })

  it('renders fenced code blocks inside <pre><code>', () => {
    const message = makeMessage({ content: '```\nconst x = 1\n```' })
    const { container } = render(<ChatMessage message={message} onSourceNavigate={() => {}} />)
    const pre = container.querySelector('pre')
    expect(pre).not.toBeNull()
    expect(pre?.querySelector('code')).not.toBeNull()
  })

  it('sanitises raw <script> tags from assistant output', () => {
    const message = makeMessage({ content: 'safe text <script>alert(1)</script> more text' })
    const { container } = render(<ChatMessage message={message} onSourceNavigate={() => {}} />)
    // No <script> element should make it into the DOM.
    expect(container.querySelector('script')).toBeNull()
  })

  it('still renders plain text for messages without markdown', () => {
    const message = makeMessage({ content: 'just plain text' })
    render(<ChatMessage message={message} onSourceNavigate={() => {}} />)
    expect(screen.getByText('just plain text')).toBeTruthy()
  })

  it('renders user messages as markdown too (consistency)', () => {
    const message = makeMessage({ role: 'user', content: '**emphasis**' })
    const { container } = render(<ChatMessage message={message} onSourceNavigate={() => {}} />)
    expect(container.querySelector('strong')).not.toBeNull()
  })
})
