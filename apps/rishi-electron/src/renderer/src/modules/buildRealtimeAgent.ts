import { getRagService, getBookImportService } from '@/services'
import type { BookOutline } from '@/lib/api'
import type { RagService } from '@/services/rag'
import { RealtimeAgent, tool } from '@openai/agents/realtime'
import { z } from 'zod'
import { Effect } from 'effect'
import { captureError } from '@/utils/sentry'

/**
 * Runs a realtime-agent tool execute under Effect so its outcome is
 * observable in three places at once (console, local error-dump file,
 * Sentry on error) instead of being silently swallowed by the OpenAI agents
 * library. The tool still resolves with `fallback` on error so the agent
 * can keep the conversation flowing.
 *
 * Three outcomes get logged:
 *   - `error`  → console.error + dumpError + captureError, return fallback
 *   - `empty`  → console.warn + dumpError (no Sentry), return real result
 *   - `ok`     → console.info only
 *
 * "Empty" is opt-in via the optional `inspect` arg — the caller decides
 * what counts as an empty result for that tool (e.g., `[].length === 0`
 * for bookContext). Knowing the difference between "tool errored" and
 * "tool returned 0 hits" is the most common debugging question.
 *
 * Effect is here (vs plain try/catch) because tool calls are the most
 * error-prone surface in the voice-chat flow — IPC, network, and provider
 * latency all converge — and we want the option to add `Effect.timeout` /
 * retry later without restructuring.
 */
function runToolCall<T>(
  toolName: string,
  fallback: T,
  task: () => Promise<T>,
  inspect?: {
    isEmpty: (result: T) => boolean
    contextOnEmpty: () => string
  }
): Promise<T> {
  const program = Effect.tryPromise({
    try: task,
    catch: (err) => (err instanceof Error ? err : new Error(String(err)))
  }).pipe(
    Effect.tap((result) =>
      Effect.sync(() => {
        if (inspect?.isEmpty(result)) {
          console.warn(
            `[voice-chat] tool '${toolName}' returned empty result. context:`,
            inspect.contextOnEmpty()
          )
          void window.electron
            .dumpError({
              source: 'voice-chat-agent',
              location: `realtimeAgent.tools.${toolName}`,
              error: 'empty result',
              stack: null,
              context: inspect.contextOnEmpty()
            })
            .catch(() => undefined)
        } else {
          console.info(`[voice-chat] tool '${toolName}' ok`)
        }
      })
    ),
    Effect.catchAll((err) =>
      Effect.sync(() => {
        console.error(`[voice-chat] tool '${toolName}' failed:`, err)
        void window.electron
          .dumpError({
            source: 'voice-chat-agent',
            location: `realtimeAgent.tools.${toolName}`,
            error: err.message,
            stack: err.stack ?? null,
            context: null
          })
          .catch(() => undefined)
        captureError(err, { operation: 'realtime', step: `${toolName}_tool` })
        return fallback
      })
    )
  )
  return Effect.runPromise(program)
}

export interface BuildAgentOptions {
  bookId: number
  pageText: string
  outline?: BookOutline
  /** The paragraph TTS was reading aloud at chat-start. Helps the model resolve deictic references. */
  activeParagraphText?: string
  onEndConversation: (reason: string) => void
  /**
   * Optional RAG service for bookContext tool calls. When omitted, falls
   * back to `getRagService()` for backwards compatibility with the legacy
   * module-scoped `voiceChatService.ts`. The new `services/voice-chat/`
   * factory always supplies this dep explicitly.
   */
  rag?: RagService
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

function renderActiveParagraphSection(activeParagraphText: string | undefined): string {
  if (!activeParagraphText) return ''
  return `## What the user just heard
The user was just listening to this passage being read aloud:
"""
${activeParagraphText}
"""
This is part of the current page above. If they say "this", "that", "what you just read", or otherwise refer back to what they heard, they mean this passage.

`
}

const INSTRUCTIONS_TEMPLATE = (
  pageText: string,
  outline?: BookOutline,
  activeParagraphText?: string
) => `## Role
You are a teaching assistant helping the user understand the book they're reading. Make complex ideas accessible and answer questions in a way that aids comprehension.

${renderOutlineSection(outline)}## Current Page Content
"""
${pageText || '(No page text available)'}
"""
If the question is answerable from this page, answer directly. Use the bookContext tool only for content outside this page.

${renderActiveParagraphSection(activeParagraphText)}

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
  activeParagraphText,
  onEndConversation,
  rag
}: BuildAgentOptions): RealtimeAgent {
  const ragService: RagService = rag ?? getRagService()
  const bookContextExecute = ({ queryText }: { queryText: string }) =>
    runToolCall<string[]>(
      'bookContext',
      ['Unable to retrieve book context at this time.'],
      async () => {
        // If indexing is still in flight for this book, the vector store
        // doesn't have all embeddings yet — searchSemantic would return a
        // partial or empty result. Return a sentinel instruction that the
        // agent reads aloud so the user knows to wait a moment.
        if (getBookImportService().isIndexing(bookId)) {
          return ["I'm still indexing this book — please give me a moment and try asking again."]
        }
        const chunks = await ragService.searchSemantic(queryText, bookId, 3)
        return chunks.map((c) => c.text)
      },
      {
        isEmpty: (chunks) => chunks.length === 0,
        contextOnEmpty: () => `bookId=${bookId} queryText=${JSON.stringify(queryText)}`
      }
    )

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

  const endConversationExecute = ({ reason }: { reason: string }) =>
    runToolCall<void>('endConversation', undefined, () => {
      onEndConversation(reason)
      return Promise.resolve()
    })

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
    instructions: INSTRUCTIONS_TEMPLATE(pageText, outline, activeParagraphText),
    tools: [bookContextTool, endConversationTool]
  })
}
