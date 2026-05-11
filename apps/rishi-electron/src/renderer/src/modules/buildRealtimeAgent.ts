import { getRagService } from '@/services'
import type { BookOutline } from '@/lib/api'
import { RealtimeAgent, tool } from '@openai/agents/realtime'
import { z } from 'zod'
import { captureError } from '@/utils/sentry'

export interface BuildAgentOptions {
  bookId: number
  pageText: string
  outline?: BookOutline
  onEndConversation: (reason: string) => void
}

function renderOutlineSection(outline: BookOutline | undefined): string {
  if (!outline) return ''
  const authorLine = outline.author ? `**Author:** ${outline.author}\n` : ''
  const chapterLines =
    outline.chapters.length > 0
      ? `**Chapters:**\n${outline.chapters.map((c) => `- ${c}`).join('\n')}\n`
      : ''
  return `## Book Outline
**Title:** ${outline.title}
${authorLine}${chapterLines}
Use this outline to orient the user across the book. If they ask about a specific chapter that isn't on their current page, you may use the bookContext tool to retrieve relevant passages from that chapter.

`
}

const INSTRUCTIONS_TEMPLATE = (pageText: string, outline?: BookOutline) => `## Role
You are a teaching assistant helping the user understand the book they're reading. Make complex ideas accessible and answer questions in a way that aids comprehension.

${renderOutlineSection(outline)}## Current Page Content
"""
${pageText || '(No page text available)'}
"""
If the question is answerable from this page, answer directly. Use the bookContext tool only for content outside this page.

## Rules
- Vary phrasing — never repeat the same sentence verbatim in a single response.
- Stay conversational; avoid scripted-sounding language.
- Before calling a tool, say one short line previewing what you're doing (5-12 words).
- Stay focused on the book, but allow natural chat flow.

## Tools

### bookContext
For content NOT visible on the current page. Provide a brief preamble before calling. Do not call if the answer is already in the current page text.

### endConversation
When the user clearly signals they're done (e.g., "thanks, that's all", "goodbye"), respond with a warm closing and call this tool. If the signal is ambiguous, confirm first. Provide a clear \`reason\` describing why the conversation is ending.

## Style notes
- First message: if the user asks a question, answer it directly. If they greet, respond briefly and ask how you can help.
- When explaining concepts, break down complexity and use analogies. Briefly check understanding before moving on.
- Keep responses concise unless depth is requested.`

export function buildRealtimeAgent({
  bookId,
  pageText,
  outline,
  onEndConversation
}: BuildAgentOptions): RealtimeAgent {
  const bookContextExecute = async ({ queryText }: { queryText: string }) => {
    try {
      const chunks = await getRagService().searchSemantic(queryText, bookId, 3)
      return chunks.map((c) => c.text)
    } catch (err) {
      captureError(err, { operation: 'realtime', step: 'bookContext_tool' })
      return ['Unable to retrieve book context at this time.']
    }
  }

  const bookContextTool = Object.assign(
    tool({
      name: 'bookContext',
      description:
        'Retrieve information from OTHER parts of the book beyond the current page. Only use this when the user asks about content NOT visible on their current page. Do NOT call this tool if the answer is already in the current page content provided in your instructions.',
      parameters: z.object({
        queryText: z.string()
      }),
      execute: bookContextExecute
    }),
    { execute: bookContextExecute }
  )

  const endConversationExecute = async ({ reason }: { reason: string }) => {
    onEndConversation(reason)
  }

  const endConversationTool = Object.assign(
    tool({
      name: 'endConversation',
      description: 'End the conversation with the user.',
      parameters: z.object({
        reason: z.string()
      }),
      execute: endConversationExecute
    }),
    { execute: endConversationExecute }
  )

  return new RealtimeAgent({
    name: 'Assistant',
    voice: 'alloy',
    instructions: INSTRUCTIONS_TEMPLATE(pageText, outline),
    tools: [bookContextTool, endConversationTool]
  })
}
