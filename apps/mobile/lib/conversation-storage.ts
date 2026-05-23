import * as Crypto from 'expo-crypto'
import { db } from '@/lib/db'
import { conversations, messages } from '@rishi/shared/schema'
import { eq, and, desc, asc } from 'drizzle-orm'
import { triggerSyncOnWrite } from '@/lib/sync/triggers'
import type { Conversation, Message, SourceChunk } from '@/types/conversation'

// ─── Conversation CRUD ──────────────────────────────────────────────────────

/**
 * Create a new conversation for a book.
 * Generates UUID, sets timestamps, marks dirty, triggers sync.
 */
export function createConversation(bookId: string, title?: string): Conversation {
  const now = Date.now()
  const id = Crypto.randomUUID()

  db.insert(conversations)
    .values({
      id,
      bookId,
      title: title ?? 'New conversation',
      createdAt: now,
      updatedAt: now,
      isDirty: true,
      isDeleted: false,
    })
    .run()

  triggerSyncOnWrite()

  return {
    id,
    bookId,
    title: title ?? 'New conversation',
    createdAt: now,
    updatedAt: now,
  }
}

/**
 * Get a single conversation by ID (non-deleted only).
 */
export function getConversation(id: string): Conversation | undefined {
  const row = db
    .select()
    .from(conversations)
    .where(and(eq(conversations.id, id), eq(conversations.isDeleted, false)))
    .get()

  return row ? mapRowToConversation(row) : undefined
}

/**
 * Get all non-deleted conversations for a book, ordered by most recent first.
 */
export function getConversationsForBook(bookId: string): Conversation[] {
  const rows = db
    .select()
    .from(conversations)
    .where(and(eq(conversations.bookId, bookId), eq(conversations.isDeleted, false)))
    .orderBy(desc(conversations.updatedAt))
    .all()

  return rows.map(mapRowToConversation)
}

/**
 * Get all non-deleted conversations, ordered by most recent first.
 */
export function getAllConversations(): Conversation[] {
  const rows = db
    .select()
    .from(conversations)
    .where(eq(conversations.isDeleted, false))
    .orderBy(desc(conversations.updatedAt))
    .all()

  return rows.map(mapRowToConversation)
}

// ─── Message CRUD ───────────────────────────────────────────────────────────

/**
 * Add a message to a conversation.
 * Updates conversation.updatedAt and auto-titles from first user message.
 * Marks message dirty and triggers sync.
 */
export function addMessage(
  conversationId: string,
  role: 'user' | 'assistant',
  content: string,
  sourceChunks?: SourceChunk[] | null
): Message {
  const now = Date.now()
  const id = Crypto.randomUUID()

  db.insert(messages)
    .values({
      id,
      conversationId,
      role,
      content,
      sourceChunks: sourceChunks ? JSON.stringify(sourceChunks) : null,
      createdAt: now,
      updatedAt: now,
      isDirty: true,
      isDeleted: false,
    })
    .run()

  // Auto-title: set conversation title from first user message content
  const conv = db
    .select()
    .from(conversations)
    .where(eq(conversations.id, conversationId))
    .get()

  if (conv && conv.title === 'New conversation' && role === 'user') {
    db.update(conversations)
      .set({
        title: content.slice(0, 50),
        updatedAt: now,
        isDirty: true,
      })
      .where(eq(conversations.id, conversationId))
      .run()
  } else {
    // Always update conversation updatedAt
    db.update(conversations)
      .set({ updatedAt: now, isDirty: true })
      .where(eq(conversations.id, conversationId))
      .run()
  }

  triggerSyncOnWrite()

  return {
    id,
    conversationId,
    role,
    content,
    sourceChunks: sourceChunks ?? null,
    createdAt: now,
    updatedAt: now,
  }
}

/**
 * Get all non-deleted messages for a conversation, sorted by createdAt ASC.
 * Parses sourceChunks JSON strings back to SourceChunk[].
 */
export function getMessages(conversationId: string): Message[] {
  const rows = db
    .select()
    .from(messages)
    .where(and(eq(messages.conversationId, conversationId), eq(messages.isDeleted, false)))
    .orderBy(asc(messages.createdAt))
    .all()

  return rows.map(mapRowToMessage)
}

// ─── Soft delete ────────────────────────────────────────────────────────────

/**
 * Soft-delete a conversation. Sets isDeleted=true, isDirty=true.
 */
export function softDeleteConversation(id: string): void {
  db.update(conversations)
    .set({
      isDeleted: true,
      isDirty: true,
      updatedAt: Date.now(),
    })
    .where(eq(conversations.id, id))
    .run()

  triggerSyncOnWrite()
}

// ─── Row mappers ────────────────────────────────────────────────────────────

function mapRowToConversation(row: typeof conversations.$inferSelect): Conversation {
  return {
    id: row.id,
    bookId: row.bookId,
    title: row.title,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  }
}

function mapRowToMessage(row: typeof messages.$inferSelect): Message {
  let parsed: SourceChunk[] | null = null
  let corrupted = false
  if (row.sourceChunks) {
    try {
      parsed = JSON.parse(row.sourceChunks) as SourceChunk[]
    } catch (err) {
      // DAT-016 (#128): the previous behaviour was a silent fall-through to
      // `parsed = null`. That hides corruption from the dev error dump AND
      // from the user, who sees an assistant message with no citations
      // and assumes the model just didn't ground its answer. We now:
      //   - log the message id + a payload snippet so the dev error dump
      //     surfaces a pattern of corruption (e.g. a buggy embedder
      //     truncating writes);
      //   - set a `sourceChunksCorrupted` flag on the returned object so a
      //     UI can render a "Source data corrupted" badge.
      // The `parsed` value remains null so the rest of the surface keeps
      // working — corruption MUST NOT prevent the row from rendering.
      const snippet =
        row.sourceChunks.length > 60
          ? row.sourceChunks.slice(0, 60) + '…'
          : row.sourceChunks
      // eslint-disable-next-line no-console
      console.warn(
        `[conversation-storage] failed to parse sourceChunks for message ${row.id}; ` +
          `length=${row.sourceChunks.length}, snippet=${snippet}`,
        err,
      )
      parsed = null
      corrupted = true
    }
  }

  // We attach `sourceChunksCorrupted` as a runtime-only extension to the
  // returned Message. The base Message type in `types/conversation.ts` is
  // owned by a sibling slot and we don't extend it here; consumers that
  // care (chat row UI) read the property via duck typing.
  const out: Message & { sourceChunksCorrupted?: boolean } = {
    id: row.id,
    conversationId: row.conversationId,
    role: row.role as 'user' | 'assistant',
    content: row.content,
    sourceChunks: parsed,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  }
  if (corrupted) out.sourceChunksCorrupted = true
  return out
}
