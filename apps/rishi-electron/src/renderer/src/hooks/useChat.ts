import { useState, useCallback, useRef, useEffect } from 'react'
import { getRagService } from '@/services'
import { getAuthToken } from '@/modules/auth'
import { triggerSyncOnWrite } from '@/modules/sync-triggers'
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

  // Reset initialization and clear stale state when book/bookSyncId changes.
  useEffect(() => {
    if (!bookSyncId) {
      setMessages([])
      setConversationId(null)
    }
    initialized.current = false
  }, [bookId, bookSyncId])

  // Load or create conversation on mount
  useEffect(() => {
    if (initialized.current || !bookSyncId) return
    initialized.current = true

    let cancelled = false

    void (async () => {
      try {
        // Find existing conversation for this book
        const existing = await window.electron.conversationsFindForBook(bookSyncId)

        if (cancelled) return

        let convId: string

        if (existing) {
          convId = existing.id
        } else {
          // Create new conversation
          convId = crypto.randomUUID()
          await window.electron.conversationsCreate({
            id: convId,
            bookId: bookSyncId,
            title: bookTitle ? `Chat about ${bookTitle}` : 'Chat about this book'
          })
        }

        if (cancelled) return

        setConversationId(convId)

        // Load existing messages
        const rows = await window.electron.messagesList(convId)

        if (cancelled) return

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
        if (cancelled) return
        console.error('[useChat] Failed to initialize conversation:', err)
        setError('Failed to load conversation')
      }
    })()

    return () => {
      cancelled = true
    }
  }, [bookSyncId, bookTitle])

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
          pageNumber: c.pageNumber,
        }))

        // 5. Build system prompt with RAG context
        const systemPrompt = `You are a helpful AI assistant that answers questions about books. Use the following context from the book to answer the user's question. If the context doesn't contain relevant information, say so.\n\nContext:\n${chunks.map((c) => c.text).join('\n\n')}`

        // 6. Get recent conversation history (last 6 messages)
        const recentMessages = messages.slice(-6)

        // 7. Call Worker LLM endpoint
        const token = await getAuthToken()
        const completionController = new AbortController()
        const completionTimeout = setTimeout(() => completionController.abort(), 60_000)
        let response: Response
        try {
          response = await fetch(`${WORKER_URL}/api/text/completions`, {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${token}`,
              'Content-Type': 'application/json'
            },
            body: JSON.stringify({
              input: [
                { role: 'system', content: systemPrompt },
                ...recentMessages.map((m) => ({ role: m.role, content: m.content })),
                { role: 'user', content: text }
              ]
            }),
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
        triggerSyncOnWrite()
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
