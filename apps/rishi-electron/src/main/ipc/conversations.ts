import { ipcMain } from 'electron'
import { eq, and, desc, asc } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { conversations, messages, chunkData } from '../database/schema.js'

export function registerConversationHandlers(): void {
  // Find the most recent non-deleted conversation for a book
  ipcMain.handle('conversations:findForBook', async (_event, bookSyncId: string) => {
    const db = getDrizzle()
    const rows = await db
      .select()
      .from(conversations)
      .where(and(eq(conversations.bookId, bookSyncId), eq(conversations.isDeleted, 0)))
      .orderBy(desc(conversations.updatedAt))
      .limit(1)
      .all()
    return rows.length > 0 ? rows[0] : null
  })

  // Create a new conversation
  ipcMain.handle(
    'conversations:create',
    async (_event, params: { id: string; bookId: string; title: string }): Promise<void> => {
      const db = getDrizzle()
      const now = Date.now()
      await db.insert(conversations).values({
        id: params.id,
        bookId: params.bookId,
        title: params.title,
        createdAt: String(now),
        updatedAt: now,
        syncVersion: 0,
        isDirty: 1,
        isDeleted: 0
      })
    }
  )

  // Update a conversation's timestamp
  ipcMain.handle(
    'conversations:updateTimestamp',
    async (_event, conversationId: string): Promise<void> => {
      const db = getDrizzle()
      await db
        .update(conversations)
        .set({ updatedAt: Date.now(), isDirty: 1 })
        .where(eq(conversations.id, conversationId))
    }
  )

  // List all non-deleted messages for a conversation, ordered by created_at ASC
  ipcMain.handle('messages:list', async (_event, conversationId: string) => {
    const db = getDrizzle()
    return db
      .select()
      .from(messages)
      .where(and(eq(messages.conversationId, conversationId), eq(messages.isDeleted, 0)))
      .orderBy(asc(messages.createdAt))
      .all()
  })

  // Create a new message
  ipcMain.handle(
    'messages:create',
    async (
      _event,
      params: {
        id: string
        conversationId: string
        role: string
        content: string
        sourceChunks?: string
      }
    ): Promise<void> => {
      const db = getDrizzle()
      const now = Date.now()
      await db.insert(messages).values({
        id: params.id,
        conversationId: params.conversationId,
        role: params.role,
        content: params.content,
        sourceChunks: params.sourceChunks ?? null,
        createdAt: String(now),
        updatedAt: now,
        syncVersion: 0,
        isDirty: 1,
        isDeleted: 0
      })
    }
  )

  // Look up the page number for a chunk of text in a book
  ipcMain.handle(
    'messages:getChunkPage',
    async (_event, bookId: number, text: string): Promise<number | null> => {
      const db = getDrizzle()
      const rows = await db
        .select({ pageNumber: chunkData.pageNumber })
        .from(chunkData)
        .where(and(eq(chunkData.bookId, bookId), eq(chunkData.data, text)))
        .limit(1)
        .all()
      return rows.length > 0 ? rows[0].pageNumber : null
    }
  )
}
