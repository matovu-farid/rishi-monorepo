import { describe, it, expect } from 'vitest'
import {
  renderRealtimeInstructions,
  renderOutlineSection,
  renderActiveParagraphSection,
  renderVisualSection,
  renderLanguageSection,
  BOOK_CONTEXT_TOOL_SPEC,
  END_CONVERSATION_TOOL_SPEC,
  INSPECT_CURRENT_PAGE_TOOL_SPEC
} from './build-realtime-agent'

describe('renderLanguageSection', () => {
  it('uses the label for a known language code', () => {
    expect(renderLanguageSection('en')).toContain('Always respond in English')
    expect(renderLanguageSection('es')).toContain('Always respond in Spanish')
    expect(renderLanguageSection('ja')).toContain('Always respond in Japanese')
  })

  it('falls back to English for an unknown code', () => {
    expect(renderLanguageSection('xx')).toContain('Always respond in English')
  })
})

describe('renderOutlineSection', () => {
  it('returns empty string when outline is undefined', () => {
    expect(renderOutlineSection(undefined)).toBe('')
  })

  it('omits the author line when author is null', () => {
    const out = renderOutlineSection({
      title: 'Test Book',
      author: null,
      chapters: ['Chapter 1']
    })
    expect(out).toContain('**Title:** Test Book')
    expect(out).not.toContain('Author')
    expect(out).toContain('- Chapter 1')
  })

  it('includes all chapters as bullet list', () => {
    const out = renderOutlineSection({
      title: 'Book',
      author: 'Author',
      chapters: ['One', 'Two', 'Three']
    })
    expect(out).toContain('**Author:** Author')
    expect(out).toContain('- One')
    expect(out).toContain('- Two')
    expect(out).toContain('- Three')
  })

  it('omits the chapters block when chapters is empty', () => {
    const out = renderOutlineSection({
      title: 'Book',
      author: 'Author',
      chapters: []
    })
    expect(out).not.toContain('**Chapters:**')
  })
})

describe('renderActiveParagraphSection', () => {
  it('returns empty string when activeParagraphText is undefined', () => {
    expect(renderActiveParagraphSection(undefined)).toBe('')
  })

  it('wraps the paragraph in triple quotes and references deictics', () => {
    const out = renderActiveParagraphSection('the cat sat on the mat')
    expect(out).toContain('"""\nthe cat sat on the mat\n"""')
    expect(out).toContain('"this", "that", "what you just read"')
  })
})

describe('renderVisualSection', () => {
  it('returns empty string when visualSummary is undefined', () => {
    expect(renderVisualSection(undefined)).toBe('')
  })

  it('guides quiet visual inspection without exposing the mechanism', () => {
    const out = renderVisualSection({ equations: 1, figures: 0, images: 0 })
    expect(out).toContain('quietly inspect the page')
    expect(out).toContain('Do not inspect it on every turn')
    expect(out).toContain('do not mention the inspection mechanism')
    expect(out).not.toContain('inspectCurrentPage')
  })

  it('uses singular/plural correctly', () => {
    expect(renderVisualSection({ equations: 1, figures: 0, images: 0 })).toContain('1 equation')
    expect(renderVisualSection({ equations: 2, figures: 0, images: 0 })).toContain('2 equations')
    expect(renderVisualSection({ equations: 0, figures: 1, images: 0 })).toContain('1 figure')
    expect(renderVisualSection({ equations: 0, figures: 0, images: 3 })).toContain('3 images')
  })

  it('uses "no visual content" when all counts are zero', () => {
    expect(renderVisualSection({ equations: 0, figures: 0, images: 0 })).toContain(
      'no visual content (text-only page)'
    )
  })

  it('joins multiple kinds with " and "', () => {
    const out = renderVisualSection({ equations: 2, figures: 1, images: 3 })
    expect(out).toContain('2 equations and 1 figure and 3 images')
  })
})

describe('renderRealtimeInstructions', () => {
  it('keeps retrieval mechanics out of user-facing voice guidance', () => {
    const out = renderRealtimeInstructions({ pageText: 'p', language: 'en' })
    expect(out).toContain('Never mention tools')
    expect(out).toContain('Let me check the book')
    expect(out).not.toContain('Before calling a tool')
    expect(out).not.toContain('Use the bookContext tool')
  })

  it('matches snapshot for the minimal English/no-outline/no-paragraph/no-visual case', () => {
    const out = renderRealtimeInstructions({
      pageText: 'The rain in Spain falls mainly on the plain.',
      language: 'en'
    })
    expect(out).toMatchInlineSnapshot(`
      "## Role
      You are the user's personal teacher for this book — a knowledgeable, patient tutor guiding them through it. Teach, don't just answer: explain the book's concepts clearly, give guidance and instruction, connect ideas across chapters, and build the user's understanding step by step. Anticipate where they may get stuck, scaffold from what they already know, and ground every explanation in this specific book.

      ## Language
      Always respond in English regardless of the user's accent or pronunciation. Treat all input as English unless the user explicitly switches mid-conversation.

      ## Current Page Content
      """
      The rain in Spain falls mainly on the plain.
      """
      If the question is answerable from this page, answer directly. Quietly check the book only for content outside this page.



      ## Rules
      - Vary phrasing — never repeat the same sentence verbatim in a single response.
      - Stay conversational; avoid scripted-sounding language.
      - Never mention tools, function calls, retrieval, indexing, embeddings, context windows, prompts, or internal systems to the user.
      - If checking the book would help, you may briefly say something natural such as “Let me check the book,” then continue with the answer.
      - Stay focused on the book, but allow natural chat flow.

      ## Book lookup

      Use the book lookup capability for content NOT visible on the current page. Do not use it if the answer is already in the current page text. Keep this capability invisible to the user.

      ### Ending the conversation
      When the user clearly signals they're done (e.g., "thanks, that's all", "goodbye"), respond with a warm closing and end the session. If the signal is ambiguous, confirm first. Keep the internal close action invisible to the user.

      ## Style notes
      - First message: if the user asks a question, answer it directly. If they greet, respond briefly and ask how you can help.
      - When explaining concepts, break down complexity and use analogies. Briefly check understanding before moving on.
      - Keep responses concise unless depth is requested."
    `)
  })

  it('falls back to a "(No page text available)" placeholder when pageText is empty', () => {
    const out = renderRealtimeInstructions({ pageText: '', language: 'en' })
    expect(out).toContain('(No page text available)')
  })

  it('includes the Book Outline section when outline is provided', () => {
    const out = renderRealtimeInstructions({
      pageText: 'p',
      language: 'en',
      outline: { title: 'T', author: 'A', chapters: ['Ch1'] }
    })
    expect(out).toContain('## Book Outline')
    expect(out).toContain('**Title:** T')
    expect(out).toContain('**Author:** A')
  })

  it('includes the activeParagraphText section when provided', () => {
    const out = renderRealtimeInstructions({
      pageText: 'p',
      language: 'en',
      activeParagraphText: 'this was just read aloud'
    })
    expect(out).toContain('## What the user just heard')
    expect(out).toContain('this was just read aloud')
  })

  it('includes the Visual context section when visualSummary is provided', () => {
    const out = renderRealtimeInstructions({
      pageText: 'p',
      language: 'en',
      visualSummary: { equations: 1, figures: 0, images: 0 }
    })
    expect(out).toContain('## Visual context')
    expect(out).toContain('quietly inspect the page')
  })

  it('omits the Visual context section when visualSummary is undefined', () => {
    const out = renderRealtimeInstructions({ pageText: 'p', language: 'en' })
    expect(out).not.toContain('## Visual context')
    expect(out).not.toContain('inspectCurrentPage')
  })

  it('uses the requested language label even for non-English', () => {
    const out = renderRealtimeInstructions({ pageText: 'p', language: 'fr' })
    expect(out).toContain('Always respond in French')
  })
})

describe('tool specs', () => {
  it('bookContext tool spec has the correct shape', () => {
    expect(BOOK_CONTEXT_TOOL_SPEC.name).toBe('bookContext')
    expect(BOOK_CONTEXT_TOOL_SPEC.parameters.required).toEqual(['queryText'])
  })

  it('endConversation tool spec has the correct shape', () => {
    expect(END_CONVERSATION_TOOL_SPEC.name).toBe('endConversation')
    expect(END_CONVERSATION_TOOL_SPEC.parameters.required).toEqual(['reason'])
  })

  it('inspectCurrentPage tool spec accepts low/high detail', () => {
    expect(INSPECT_CURRENT_PAGE_TOOL_SPEC.name).toBe('inspectCurrentPage')
    expect(INSPECT_CURRENT_PAGE_TOOL_SPEC.parameters.properties.detail.enum).toEqual([
      'low',
      'high'
    ])
  })
})
