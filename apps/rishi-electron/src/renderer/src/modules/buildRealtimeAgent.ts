import { getRagService, getBookImportService } from '@/services'
import type { BookOutline } from '@/lib/api'
import type { VisualSummary } from '@/lib/visualHeuristic'
import type { RagService } from '@/services/rag'
import { RealtimeAgent, tool } from '@openai/agents/realtime'
import { z } from 'zod'
import { Effect } from 'effect'
import { captureError } from '@/utils/sentry'
import { captureCurrentPage, type CaptureResult } from '@/modules/pageCapture'
import { renderRealtimeInstructions } from '@rishi/shared/voice-chat'

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
  /** ISO-639-1 code for the language the agent must respond in. */
  language: string
  /**
   * Optional RAG service for bookContext tool calls. When omitted, falls
   * back to `getRagService()` for backwards compatibility with the legacy
   * module-scoped `voiceChatService.ts`. The new `services/voice-chat/`
   * factory always supplies this dep explicitly.
   */
  rag?: RagService
  /** Optional summary of visual content on the current page. */
  visualSummary?: VisualSummary
  /**
   * Called when the inspect tool successfully captures an image. The caller
   * (service.ts) uses this hook to inject the image into the realtime
   * conversation via the session transport.
   */
  onInspectImage?: (image: CaptureResult) => void
}

// Prompt-rendering helpers (renderOutlineSection, renderActiveParagraphSection,
// renderVisualSection, renderLanguageSection, INSTRUCTIONS_TEMPLATE) were
// migrated to `@rishi/shared/voice-chat` (renderRealtimeInstructions) so
// electron and mobile produce identical system prompts. See SPEC §3.6
// (DRY-004) and `packages/shared/src/voice-chat/build-realtime-agent.ts`.

export function buildRealtimeAgent({
  bookId,
  pageText,
  outline,
  activeParagraphText,
  onEndConversation,
  language,
  rag,
  visualSummary,
  onInspectImage
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

  const inspectCurrentPageExecute = ({ detail }: { detail: 'low' | 'high' }) =>
    runToolCall<string>(
      'inspectCurrentPage',
      'Page image is currently unavailable; the text context still applies.',
      async () => {
        const image = await captureCurrentPage({ detail })
        onInspectImage?.(image)
        return `Page image captured at ${image.width}x${image.height} (${detail} detail). Attached to the conversation.`
      }
    )

  const inspectCurrentPageTool = Object.assign(
    tool({
      name: 'inspectCurrentPage',
      description:
        "Capture a screenshot of the page the user is currently looking at. Use 'low' detail by default; use 'high' only when you need to read small text inside the image such as equations, captions, or axis labels.",
      parameters: z.object({
        detail: z.enum(['low', 'high']).default('low')
      }),
      execute: inspectCurrentPageExecute
    }),
    { execute: inspectCurrentPageExecute }
  )

  const tools: unknown[] = [bookContextTool, endConversationTool]
  if (visualSummary !== undefined) tools.push(inspectCurrentPageTool)

  return new RealtimeAgent({
    name: 'Assistant',
    voice: 'alloy',
    instructions: renderRealtimeInstructions({
      pageText,
      language,
      outline,
      activeParagraphText,
      visualSummary
    }),
    tools: tools as never
  })
}
