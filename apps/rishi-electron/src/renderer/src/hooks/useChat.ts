import { useState, useCallback, useRef, useEffect } from 'react';
import { getContextForQuery } from '@/lib/api';
import { getAuthToken } from '@/modules/auth';
import { triggerSyncOnWrite } from '@/modules/sync-triggers';
import type { Message, SourceChunk } from '@/types/conversation';

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev';

interface UseChatReturn {
  messages: Message[];
  isLoading: boolean;
  error: string | null;
  sendMessage: (text: string) => Promise<void>;
  conversationId: string | null;
}

export function useChat(bookId: number, bookSyncId: string, bookTitle?: string): UseChatReturn {
  const [messages, setMessages] = useState<Message[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [conversationId, setConversationId] = useState<string | null>(null);
  const initialized = useRef(false);

  // Reset initialization and clear stale state when book/bookSyncId changes.
  useEffect(() => {
    if (!bookSyncId) {
      setMessages([]);
      setConversationId(null);
    }
    initialized.current = false;
  }, [bookId, bookSyncId]);

  // Load or create conversation on mount
  useEffect(() => {
    if (initialized.current || !bookSyncId) return;
    initialized.current = true;

    let cancelled = false;

    void (async () => {
      try {
        // Find existing conversation for this book
        const existingRows = (await window.electron.dbQuery(
          `SELECT * FROM conversations WHERE book_id = ? AND is_deleted = 0 ORDER BY updated_at DESC LIMIT 1`,
          [bookSyncId]
        )) as Array<{ id: string; book_id: string; title: string; created_at: number; updated_at: number }>;

        if (cancelled) return;

        let convId: string;

        if (existingRows.length > 0) {
          convId = existingRows[0].id;
        } else {
          // Create new conversation
          convId = crypto.randomUUID();
          const now = Date.now();
          await window.electron.dbRun(
            `INSERT INTO conversations (id, book_id, user_id, title, created_at, updated_at, sync_version, is_dirty, is_deleted)
             VALUES (?, ?, NULL, ?, ?, ?, 0, 1, 0)`,
            [convId, bookSyncId, bookTitle ? `Chat about ${bookTitle}` : 'Chat about this book', now, now]
          );
        }

        if (cancelled) return;

        setConversationId(convId);

        // Load existing messages
        const rows = (await window.electron.dbQuery(
          `SELECT * FROM messages WHERE conversation_id = ? AND is_deleted = 0 ORDER BY created_at ASC`,
          [convId]
        )) as Array<{ id: string; conversation_id: string; role: string; content: string; source_chunks: string | null; created_at: number }>;

        if (cancelled) return;

        const loadedMessages: Message[] = rows.map((row) => ({
          id: row.id,
          conversationId: row.conversation_id,
          role: row.role as 'user' | 'assistant',
          content: row.content,
          sourceChunks: row.source_chunks
            ? (() => {
                try {
                  return JSON.parse(row.source_chunks) as SourceChunk[];
                } catch {
                  return null;
                }
              })()
            : null,
          createdAt: row.created_at,
        }));

        setMessages(loadedMessages);
      } catch (err) {
        if (cancelled) return;
        console.error('[useChat] Failed to initialize conversation:', err);
        setError('Failed to load conversation');
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [bookSyncId, bookTitle]);

  const sendMessage = useCallback(
    async (text: string) => {
      if (!conversationId || !text.trim()) return;

      setError(null);
      setIsLoading(true);

      try {
        // 1. Save user message to DB
        const userMsgId = crypto.randomUUID();
        const now = Date.now();
        await window.electron.dbRun(
          `INSERT INTO messages (id, conversation_id, role, content, source_chunks, created_at, updated_at, sync_version, is_dirty, is_deleted)
           VALUES (?, ?, 'user', ?, NULL, ?, ?, 0, 1, 0)`,
          [userMsgId, conversationId, text, now, now]
        );

        // 2. Optimistically add to local state
        const userMessage: Message = {
          id: userMsgId,
          conversationId,
          role: 'user',
          content: text,
          sourceChunks: null,
          createdAt: now,
        };
        setMessages((prev) => [...prev, userMessage]);

        // 3. RAG retrieval
        const contextTexts = await getContextForQuery({
          queryText: text,
          bookId,
          k: 5,
        });

        // 4. Get source chunk metadata from chunk_data table
        const sourceChunks: SourceChunk[] = [];
        for (const contextText of contextTexts) {
          const chunks = (await window.electron.dbQuery(
            `SELECT id, page_number, data FROM chunk_data WHERE book_id = ? AND data = ? LIMIT 1`,
            [bookId, contextText]
          )) as Array<{ id: number; page_number: number; data: string }>;
          if (chunks.length > 0) {
            sourceChunks.push({
              id: chunks[0].id,
              text: contextText.substring(0, 200),
              pageNumber: chunks[0].page_number,
            });
          }
        }

        // 5. Build system prompt with RAG context
        const systemPrompt = `You are a helpful AI assistant that answers questions about books. Use the following context from the book to answer the user's question. If the context doesn't contain relevant information, say so.\n\nContext:\n${contextTexts.join('\n\n')}`;

        // 6. Get recent conversation history (last 6 messages)
        const recentMessages = messages.slice(-6);

        // 7. Call Worker LLM endpoint
        const token = await getAuthToken();
        const completionController = new AbortController();
        const completionTimeout = setTimeout(() => completionController.abort(), 60_000);
        let response: Response;
        try {
          response = await fetch(`${WORKER_URL}/api/text/completions`, {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${token}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({
              input: [
                { role: 'system', content: systemPrompt },
                ...recentMessages.map((m) => ({ role: m.role, content: m.content })),
                { role: 'user', content: text },
              ],
            }),
            signal: completionController.signal,
          });
        } catch (err) {
          if (completionController.signal.aborted) {
            throw new Error('LLM request timed out after 60 seconds');
          }
          throw err;
        } finally {
          clearTimeout(completionTimeout);
        }

        if (!response.ok) {
          throw new Error(`LLM request failed: ${response.status}`);
        }

        const data = (await response.json()) as string;

        // 8. Save assistant message to DB
        const assistantMsgId = crypto.randomUUID();
        const assistantNow = Date.now();
        await window.electron.dbRun(
          `INSERT INTO messages (id, conversation_id, role, content, source_chunks, created_at, updated_at, sync_version, is_dirty, is_deleted)
           VALUES (?, ?, 'assistant', ?, ?, ?, ?, 0, 1, 0)`,
          [assistantMsgId, conversationId, data, JSON.stringify(sourceChunks), assistantNow, assistantNow]
        );

        // 9. Update conversation updated_at
        await window.electron.dbRun(
          `UPDATE conversations SET updated_at = ?, is_dirty = 1 WHERE id = ?`,
          [assistantNow, conversationId]
        );

        // 10. Add assistant message to state
        const assistantMessage: Message = {
          id: assistantMsgId,
          conversationId,
          role: 'assistant',
          content: data,
          sourceChunks: sourceChunks.length > 0 ? sourceChunks : null,
          createdAt: assistantNow,
        };
        setMessages((prev) => [...prev, assistantMessage]);

        // 11. Trigger sync
        triggerSyncOnWrite();
      } catch (err) {
        console.error('[useChat] sendMessage failed:', err);
        setError('Message failed to send. Check your connection and try again.');
      } finally {
        setIsLoading(false);
      }
    },
    [conversationId, bookId, messages]
  );

  return { messages, isLoading, error, sendMessage, conversationId };
}
