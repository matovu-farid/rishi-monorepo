import { eq, and, isNotNull } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { books, highlights, conversations, messages, syncMeta } from '../database/schema.js'
import { handle } from '../../preload/ipc-contract.js'

/**
 * Narrow an unknown value to a stringifiable primitive (string or number).
 * Used when pulling remote sync records — fields typed as `unknown` need an
 * explicit guard before being interpolated into a string, otherwise objects
 * would stringify to `[object Object]`.
 */
function asStringOrNumber(v: unknown, fallback: string | number): string | number {
  return typeof v === 'string' || typeof v === 'number' ? v : fallback
}

/**
 * Convert a `string | number` (from `asStringOrNumber`) to a plain string —
 * needed because several sync columns are stored as TEXT but the remote
 * payload may deliver the same field as either a string or a number.
 * Avoids `String()` on `unknown`, which would tip into [object Object].
 */
function stringFrom(v: string | number): string {
  return typeof v === 'string' ? v : v.toString()
}

export function registerSyncHandlers(): void {
  // -----------------------------------------------------------------------
  // Push: get dirty records
  // -----------------------------------------------------------------------

  handle('sync:getDirtyBooks', () => {
    const db = getDrizzle()
    return db
      .select()
      .from(books)
      .where(and(eq(books.isDirty, 1), isNotNull(books.syncId)))
      .all()
  })

  handle('sync:getDirtyHighlights', () => {
    const db = getDrizzle()
    return db.select().from(highlights).where(eq(highlights.isDirty, 1)).all()
  })

  handle('sync:getDirtyConversations', () => {
    const db = getDrizzle()
    return db.select().from(conversations).where(eq(conversations.isDirty, 1)).all()
  })

  handle('sync:getDirtyMessages', () => {
    const db = getDrizzle()
    return db.select().from(messages).where(eq(messages.isDirty, 1)).all()
  })

  handle('sync:getLastVersion', () => {
    const db = getDrizzle()
    const row = db.select().from(syncMeta).limit(1).get()
    return row?.lastSyncVersion ?? 0
  })

  // -----------------------------------------------------------------------
  // Push: mark pushed records clean
  // -----------------------------------------------------------------------

  handle('sync:markBooksClean', (_event, ids, syncVersion) => {
    const db = getDrizzle()
    for (const syncId of ids) {
      db.update(books).set({ isDirty: 0, syncVersion }).where(eq(books.syncId, syncId)).run()
    }
  })

  handle('sync:markHighlightsClean', (_event, ids, syncVersion) => {
    const db = getDrizzle()
    for (const id of ids) {
      db.update(highlights).set({ isDirty: 0, syncVersion }).where(eq(highlights.id, id)).run()
    }
  })

  handle('sync:markConversationsClean', (_event, ids, syncVersion) => {
    const db = getDrizzle()
    for (const id of ids) {
      db.update(conversations)
        .set({ isDirty: 0, syncVersion })
        .where(eq(conversations.id, id))
        .run()
    }
  })

  handle('sync:markMessagesClean', (_event, ids, syncVersion) => {
    const db = getDrizzle()
    for (const id of ids) {
      db.update(messages).set({ isDirty: 0, syncVersion }).where(eq(messages.id, id)).run()
    }
  })

  // -----------------------------------------------------------------------
  // Push: handle conflicts from server
  // -----------------------------------------------------------------------

  handle('sync:applyBookConflict', (_event, conflict, syncVersion) => {
    const c = conflict
    const db = getDrizzle()
    const syncId = c.id as string
    db.update(books)
      .set({
        title: c.title as string,
        author: c.author as string,
        format: c.format as string,
        currentCfi: (c.currentCfi as string | null) ?? null,
        currentPage: (c.currentPage as number | null) ?? null,
        fileHash: (c.fileHash as string | null) ?? null,
        fileR2Key: (c.fileR2Key as string | null) ?? null,
        coverR2Key: (c.coverR2Key as string | null) ?? null,
        syncVersion,
        isDirty: 0,
        isDeleted: (c.isDeleted as boolean) ? 1 : 0
      })
      .where(eq(books.syncId, syncId))
      .run()
  })

  handle('sync:applyHighlightConflict', (_event, conflict, syncVersion) => {
    const c = conflict
    const db = getDrizzle()
    db.update(highlights)
      .set({
        text: c.text as string,
        color: c.color as string,
        note: (c.note as string | null) ?? '',
        chapter: (c.chapter as string | null) ?? null,
        cfiRange: c.cfiRange as string,
        syncVersion,
        isDirty: 0,
        isDeleted: (c.isDeleted as boolean) ? 1 : 0
      })
      .where(eq(highlights.id, c.id as string))
      .run()
  })

  handle('sync:applyConversationConflict', (_event, conflict, syncVersion) => {
    const c = conflict
    const db = getDrizzle()
    db.update(conversations)
      .set({
        title: c.title as string,
        bookId: c.bookId as string,
        syncVersion,
        isDirty: 0,
        isDeleted: (c.isDeleted as boolean) ? 1 : 0
      })
      .where(eq(conversations.id, c.id as string))
      .run()
  })

  // -----------------------------------------------------------------------
  // Pull: upsert remote records
  // -----------------------------------------------------------------------

  handle('sync:upsertBook', (_event, remote) => {
    const syncId = remote.id as string
    if (!syncId) return

    const db = getDrizzle()
    const local = db.select().from(books).where(eq(books.syncId, syncId)).get()

    if (local) {
      if (local.isDirty === 1) return // locally dirty takes precedence

      const title = typeof remote.title === 'string' ? remote.title : local.title
      const author = typeof remote.author === 'string' ? remote.author : local.author
      const format =
        typeof remote.format === 'string' ? remote.format : local.format

      db.update(books)
        .set({
          title,
          author,
          format,
          currentCfi: (remote.currentCfi as string | null) ?? null,
          currentPage: (remote.currentPage as number | null) ?? null,
          fileHash: (remote.fileHash as string | null) ?? null,
          fileR2Key: (remote.fileR2Key as string | null) ?? null,
          coverR2Key: (remote.coverR2Key as string | null) ?? null,
          syncVersion: (remote.syncVersion as number | null) ?? 0,
          isDirty: 0,
          isDeleted: (remote.isDeleted as boolean) ? 1 : 0
        })
        .where(eq(books.syncId, syncId))
        .run()
    } else {
      // New remote book -- insert with empty local file (needs download)
      const newTitle = typeof remote.title === 'string' ? remote.title : 'Unknown'
      const newAuthor = typeof remote.author === 'string' ? remote.author : 'Unknown'
      const newFormat = typeof remote.format === 'string' ? remote.format : 'epub'

      db.insert(books)
        .values({
          kind: newFormat,
          cover: Buffer.alloc(0),
          title: newTitle,
          author: newAuthor,
          publisher: '',
          filepath: '',
          location: (remote.currentCfi as string | null) ?? '',
          coverKind: 'png',
          version: 0,
          syncId,
          format: newFormat,
          currentCfi: (remote.currentCfi as string | null) ?? null,
          currentPage: (remote.currentPage as number | null) ?? null,
          fileHash: (remote.fileHash as string | null) ?? null,
          fileR2Key: (remote.fileR2Key as string | null) ?? null,
          coverR2Key: (remote.coverR2Key as string | null) ?? null,
          syncVersion: (remote.syncVersion as number | null) ?? 0,
          isDirty: 0,
          isDeleted: (remote.isDeleted as boolean) ? 1 : 0
        })
        .run()
    }
  })

  handle('sync:upsertHighlight', (_event, remote) => {
    const remoteId = remote.id as string
    if (!remoteId) return

    const db = getDrizzle()
    const local = db.select().from(highlights).where(eq(highlights.id, remoteId)).get()

    if (local) {
      if (local.isDirty === 1) return
      const remoteUpdatedAt = (remote.updatedAt as number | null) ?? 0
      if (remoteUpdatedAt < (local.updatedAt ?? 0)) return // LWW guard

      const hlText = typeof remote.text === 'string' ? remote.text : local.text
      const hlColor = typeof remote.color === 'string' ? remote.color : local.color

      db.update(highlights)
        .set({
          text: hlText,
          color: hlColor,
          note: (remote.note as string | null) ?? '',
          chapter: (remote.chapter as string | null) ?? null,
          cfiRange: remote.cfiRange as string,
          bookId: remote.bookId as string,
          createdAt: stringFrom(asStringOrNumber(remote.createdAt, '')),
          updatedAt: remote.updatedAt as number,
          syncVersion: (remote.syncVersion as number | null) ?? 0,
          isDirty: 0,
          isDeleted: (remote.isDeleted as boolean) ? 1 : 0
        })
        .where(eq(highlights.id, remoteId))
        .run()
    } else {
      db.insert(highlights)
        .values({
          id: remoteId,
          bookId: (remote.bookId as string | null) ?? '',
          text: (remote.text as string | null) ?? '',
          color: (remote.color as string | null) ?? 'yellow',
          note: (remote.note as string | null) ?? '',
          chapter: (remote.chapter as string | null) ?? null,
          cfiRange: (remote.cfiRange as string | null) ?? '',
          createdAt: stringFrom(asStringOrNumber(remote.createdAt, Date.now())),
          updatedAt: (remote.updatedAt as number | null) ?? Date.now(),
          syncVersion: (remote.syncVersion as number | null) ?? 0,
          isDirty: 0,
          isDeleted: (remote.isDeleted as boolean) ? 1 : 0
        })
        .run()
    }
  })

  handle('sync:upsertConversation', (_event, remote) => {
    const remoteId = remote.id as string
    if (!remoteId) return

    const db = getDrizzle()
    const local = db.select().from(conversations).where(eq(conversations.id, remoteId)).get()

    if (local) {
      if (local.isDirty === 1) return
      const remoteUpdatedAt = (remote.updatedAt as number | null) ?? 0
      if (remoteUpdatedAt < (local.updatedAt ?? 0)) return // LWW guard

      const convTitle = typeof remote.title === 'string' ? remote.title : local.title
      const convBookId = remote.bookId != null ? (remote.bookId as string) : local.bookId

      db.update(conversations)
        .set({
          title: convTitle,
          bookId: convBookId,
          createdAt: stringFrom(asStringOrNumber(remote.createdAt, '')),
          updatedAt: remote.updatedAt as number,
          syncVersion: (remote.syncVersion as number | null) ?? 0,
          isDirty: 0,
          isDeleted: (remote.isDeleted as boolean) ? 1 : 0
        })
        .where(eq(conversations.id, remoteId))
        .run()
    } else {
      db.insert(conversations)
        .values({
          id: remoteId,
          bookId: (remote.bookId as string | null) ?? '',
          title: (remote.title as string | null) ?? 'New conversation',
          createdAt: stringFrom(asStringOrNumber(remote.createdAt, Date.now())),
          updatedAt: (remote.updatedAt as number | null) ?? Date.now(),
          syncVersion: (remote.syncVersion as number | null) ?? 0,
          isDirty: 0,
          isDeleted: (remote.isDeleted as boolean) ? 1 : 0
        })
        .run()
    }
  })

  handle('sync:insertMessage', (_event, remote) => {
    const remoteId = remote.id as string
    if (!remoteId) return

    const db = getDrizzle()
    const existing = db.select().from(messages).where(eq(messages.id, remoteId)).get()
    if (existing) return // append-only: never update existing messages

    db.insert(messages)
      .values({
        id: remoteId,
        conversationId: (remote.conversationId as string | null) ?? '',
        role: (remote.role as string | null) ?? 'user',
        content: (remote.content as string | null) ?? '',
        sourceChunks: (remote.sourceChunks as string | null) ?? null,
        createdAt: stringFrom(asStringOrNumber(remote.createdAt, Date.now())),
        updatedAt: (remote.updatedAt as number | null) ?? Date.now(),
        syncVersion: (remote.syncVersion as number | null) ?? 0,
        isDirty: 0,
        isDeleted: (remote.isDeleted as boolean) ? 1 : 0
      })
      .run()
  })

  // -----------------------------------------------------------------------
  // Pull: update last sync version
  // -----------------------------------------------------------------------

  handle('sync:updateLastVersion', (_event, version) => {
    const db = getDrizzle()
    const existing = db.select().from(syncMeta).limit(1).get()
    const now = new Date().toISOString()
    if (existing) {
      db.update(syncMeta)
        .set({ lastSyncVersion: version, lastSyncAt: now })
        .where(eq(syncMeta.id, existing.id))
        .run()
    } else {
      db.insert(syncMeta).values({ lastSyncVersion: version, lastSyncAt: now }).run()
    }
  })
}
