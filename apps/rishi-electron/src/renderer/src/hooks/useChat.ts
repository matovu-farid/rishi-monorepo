import { useState, useCallback, useRef, useEffect } from 'react'
import { getRagService, getSyncService } from '@/services'
import { getAuthToken } from '@/modules/auth'
import type { Message, SourceChunk } from '@/types/conversation'

const WORKER_URL = 'https://api.fidexa.org'

interface UseChatReturn {
  messages: Message[]
  isLoading: boolean
  error: string | null
  sendMessage: (text: string) => Promise<void>
  conversationId: string | null
}

export function useChat(bookId: number, bookSyncId: string, bookTitle?: string): UseChatReturn {
  const [messages, setMessages] = useState<Message[]>([])
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [conversationId, setConversationId] = useState<string | null>(null)
  const initialized = useRef(false)

  // Reset initialization and clear stale state when the book changes.
  // Why: bookId is an external prop; switching books must clear prior conversation state and force re-initialization of the async load below.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setMessages([])
    setConversationId(null)
    initialized.current = false
  }, [bookId])

  // Load or create conversation on mount
  useEffect(() => {
    if (initialized.current) return
    initialized.current = true

    // Use an object so the inner async closure observes mutations made by
    // the cleanup. A primitive `let` would be narrowed by TS to its initial
    // value within the closure, making the post-await guards appear dead.
    const state: { cancelled: boolean } = { cancelled: false }
    const isCancelled = (): boolean => state.cancelled

    void (async () => {
      try {
        // Conversations are keyed by syncId. Fresh imports may not have one
        // yet — generate-and-persist on demand so chat works before the first
        // sync push completes.
        let effectiveSyncId = bookSyncId
        if (!effectiveSyncId) {
          const fromDb = await window.electron.booksGetSyncId(bookId)
          if (isCancelled()) return
          if (fromDb) {
            effectiveSyncId = fromDb
          } else {
            const book = await window.electron.getBook(bookId)
            if (isCancelled()) return
            if (!book) throw new Error(`Book ${bookId} not found`)
            effectiveSyncId = crypto.randomUUID()
            await window.electron.saveBook({ ...book, syncId: effectiveSyncId, isDirty: 1 })
            if (isCancelled()) return
          }
        }

        // Find existing conversation for this book
        const existing = await window.electron.conversationsFindForBook(effectiveSyncId)

        if (isCancelled()) return

        let convId: string

        if (existing) {
          convId = existing.id
        } else {
          // Create new conversation
          convId = crypto.randomUUID()
          await window.electron.conversationsCreate({
            id: convId,
            bookId: effectiveSyncId,
            title: bookTitle ? `Chat about ${bookTitle}` : 'Chat about this book'
          })
        }

        if (isCancelled()) return

        setConversationId(convId)

        // Load existing messages
        const rows = await window.electron.messagesList(convId)

        if (isCancelled()) return

        const loadedMessages: Message[] = rows.map((row) => ({
          id: row.id,
          conversationId: row.conversationId,
          role: row.role as 'user' | 'assistant',
          content: row.content,
          sourceChunks: row.sourceChunks
            ? (() => {
                try {
                  return JSON.parse(row.sourceChunks) as SourceChunk[]
                } catch {
                  return null
                }
              })()
            : null,
          createdAt:
            typeof row.createdAt === 'string'
              ? Number(row.createdAt)
              : (row.createdAt as unknown as number)
        }))

        setMessages(loadedMessages)
      } catch (err) {
        if (isCancelled()) return
        console.error('[useChat] Failed to initialize conversation:', err)
        const detail = err instanceof Error ? err.message : String(err)
        setError(`Failed to load conversation: ${detail}`)
      }
    })()

    return () => {
      state.cancelled = true
    }
  }, [bookId, bookSyncId, bookTitle])

  const sendMessage = useCallback(
    async (text: string) => {
      if (!conversationId || !text.trim()) return

      setError(null)
      setIsLoading(true)

      try {
        // 1. Save user message to DB
        const userMsgId = crypto.randomUUID()
        const now = Date.now()
        await window.electron.messagesCreate({
          id: userMsgId,
          conversationId,
          role: 'user',
          content: text
        })

        // 2. Optimistically add to local state
        const userMessage: Message = {
          id: userMsgId,
          conversationId,
          role: 'user',
          content: text,
          sourceChunks: null,
          createdAt: now
        }
        setMessages((prev) => [...prev, userMessage])

        // 3. RAG retrieval
        const chunks = await getRagService().searchSemantic(text, bookId, 5)

        // 4. Map directly to source chunk metadata — pageNumber arrives with the chunk
        const sourceChunks: SourceChunk[] = chunks.map((c) => ({
          id: c.chunkId,
          text: c.text.substring(0, 200),
          pageNumber: c.pageNumber
        }))

        // 5. Build the prompt. The Worker proxies OpenAI's Responses API and
        // accepts `input` as a single string, so we flatten system prompt,
        // recent history, and the new question into one transcript.
        const contextBlock = chunks.map((c) => c.text).join('\n\n')
        const historyBlock = messages
          .slice(-6)
          .map((m) => `${m.role === 'user' ? 'User' : 'Assistant'}: ${m.content}`)
          .join('\n\n')
        const sections = [
          "You are a helpful AI assistant that answers questions about books. Use the following context from the book to answer the user's question. If the context doesn't contain relevant information, say so.",
          `Context:\n${contextBlock}`,
          historyBlock,
          `User: ${text}\nAssistant:`
        ].filter((s) => s.length > 0)
        const promptString = sections.join('\n\n')

        // 6. Auth — prefer the Better Auth bearer; fall back to dev-bypass
        // in dev builds so chat works without a signed-in session.
        const token = await getAuthToken()
        const headers: Record<string, string> = { 'Content-Type': 'application/json' }
        if (token) {
          headers.Authorization = `Bearer ${token}`
        } else {
          const devBypass = await window.electron.getDevBypassSecret()
          if (devBypass) {
            headers['X-Dev-Bypass'] = devBypass
          } else {
            throw new Error('Not authenticated — sign in to use chat')
          }
        }

        // 7. Call Worker LLM endpoint
        const completionController = new AbortController()
        const completionTimeout = setTimeout(() => completionController.abort(), 60_000)
        let response: Response
        try {
          response = await fetch(`${WORKER_URL}/api/text/completions`, {
            method: 'POST',
            headers,
            body: JSON.stringify({ input: promptString }),
            signal: completionController.signal
          })
        } catch (err) {
          if (completionController.signal.aborted) {
            throw new Error('LLM request timed out after 60 seconds')
          }
          throw err
        } finally {
          clearTimeout(completionTimeout)
        }

        if (!response.ok) {
          throw new Error(`LLM request failed: ${response.status}`)
        }

        const data = (await response.json()) as string

        // 8. Save assistant message to DB
        const assistantMsgId = crypto.randomUUID()
        const assistantNow = Date.now()
        await window.electron.messagesCreate({
          id: assistantMsgId,
          conversationId,
          role: 'assistant',
          content: data,
          sourceChunks: JSON.stringify(sourceChunks)
        })

        // 9. Update conversation updated_at
        await window.electron.conversationsUpdateTimestamp(conversationId)

        // 10. Add assistant message to state
        const assistantMessage: Message = {
          id: assistantMsgId,
          conversationId,
          role: 'assistant',
          content: data,
          sourceChunks: sourceChunks.length > 0 ? sourceChunks : null,
          createdAt: assistantNow
        }
        setMessages((prev) => [...prev, assistantMessage])

        // 11. Trigger sync
        getSyncService().triggerWrite()
      } catch (err) {
        console.error('[useChat] sendMessage failed:', err)
        setError('Message failed to send. Check your connection and try again.')
      } finally {
        setIsLoading(false)
      }
    },
    [conversationId, bookId, messages]
  )

  return { messages, isLoading, error, sendMessage, conversationId }
}
