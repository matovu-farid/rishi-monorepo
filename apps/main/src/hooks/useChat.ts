import { useState, useCallback, useRef, useEffect } from 'react';
import { db } from '@/modules/kysley';
import { getContextForQuery } from '@/generated/commands';
import { load } from '@tauri-apps/plugin-store';
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

  // Load or create conversation on mount
  useEffect(() => {
    if (initialized.current || !bookSyncId) return;
    initialized.current = true;

    (async () => {
      try {
        // Find existing conversation for this book
        const existing = await db.selectFrom('conversations')
          .selectAll()
          .where('book_id', '=', bookSyncId)
          .where('is_deleted', '=', 0)
          .orderBy('updated_at', 'desc')
          .executeTakeFirst();

        let convId: string;

        if (existing) {
          convId = existing.id;
        } else {
          // Create new conversation
          convId = crypto.randomUUID();
          const now = Date.now();
          await db.insertInto('conversations').values({
            id: convId,
            book_id: bookSyncId,
            user_id: null,
            title: bookTitle ? `Chat about ${bookTitle}` : 'Chat about this book',
            created_at: now,
            updated_at: now,
            sync_version: 0,
            is_dirty: 1,
            is_deleted: 0,
          }).execute();
        }

        setConversationId(convId);

        // Load existing messages
        const rows = await db.selectFrom('messages')
          .selectAll()
          .where('conversation_id', '=', convId)
          .where('is_deleted', '=', 0)
          .orderBy('created_at', 'asc')
          .execute();

        const loadedMessages: Message[] = rows.map((row) => ({
          id: row.id,
          conversationId: row.conversation_id,
          role: row.role as 'user' | 'assistant',
          content: row.content,
          sourceChunks: row.source_chunks ? JSON.parse(row.source_chunks) as SourceChunk[] : null,
          createdAt: row.created_at,
        }));

        setMessages(loadedMessages);
      } catch (err) {
        console.error('[useChat] Failed to initialize conversation:', err);
        setError('Failed to load conversation');
      }
    })();
  }, [bookSyncId, bookTitle]);

  const sendMessage = useCallback(async (text: string) => {
    if (!conversationId || !text.trim()) return;

    setError(null);
    setIsLoading(true);

    try {
      // 1. Save user message to DB
      const userMsgId = crypto.randomUUID();
      const now = Date.now();
      await db.insertInto('messages').values({
        id: userMsgId,
        conversation_id: conversationId,
        role: 'user',
        content: text,
        source_chunks: null,
        created_at: now,
        updated_at: now,
        sync_version: 0,
        is_dirty: 1,
        is_deleted: 0,
      }).execute();

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
        const chunk = await db.selectFrom('chunk_data')
          .select(['id', 'pageNumber', 'data'])
          .where('bookId', '=', bookId)
          .where('data', '=', contextText)
          .executeTakeFirst();
        if (chunk) {
          sourceChunks.push({
            id: chunk.id,
            text: contextText.substring(0, 200),
            pageNumber: chunk.pageNumber,
          });
        }
      }

      // 5. Build system prompt with RAG context
      const systemPrompt = `You are a helpful AI assistant that answers questions about books. Use the following context from the book to answer the user's question. If the context doesn't contain relevant information, say so.\n\nContext:\n${contextTexts.join('\n\n')}`;

      // 6. Get recent conversation history (last 6 messages)
      const recentMessages = messages.slice(-6);

      // 7. Call Worker LLM endpoint
      const store = await load('store.json');
      const token = await store.get<string>('auth_token');
      const response = await fetch(`${WORKER_URL}/api/text/completions`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          messages: [
            { role: 'system', content: systemPrompt },
            ...recentMessages.map((m) => ({ role: m.role, content: m.content })),
            { role: 'user', content: text },
          ],
        }),
      });

      if (!response.ok) {
        throw new Error(`LLM request failed: ${response.status}`);
      }

      const data = await response.json() as { message: string };

      // 8. Save assistant message to DB
      const assistantMsgId = crypto.randomUUID();
      const assistantNow = Date.now();
      await db.insertInto('messages').values({
        id: assistantMsgId,
        conversation_id: conversationId,
        role: 'assistant',
        content: data.message,
        source_chunks: JSON.stringify(sourceChunks),
        created_at: assistantNow,
        updated_at: assistantNow,
        sync_version: 0,
        is_dirty: 1,
        is_deleted: 0,
      }).execute();

      // 9. Update conversation updated_at
      await db.updateTable('conversations')
        .set({ updated_at: assistantNow, is_dirty: 1 })
        .where('id', '=', conversationId)
        .execute();

      // 10. Add assistant message to state
      const assistantMessage: Message = {
        id: assistantMsgId,
        conversationId,
        role: 'assistant',
        content: data.message,
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
  }, [conversationId, bookId, messages]);

  return { messages, isLoading, error, sendMessage, conversationId };
}
