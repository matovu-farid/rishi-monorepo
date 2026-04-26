import { ipcMain } from 'electron'
import { eq, and, isNotNull } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { books, highlights, conversations, messages, syncMeta } from '../database/schema.js'

export function registerSyncHandlers(): void {
  // -----------------------------------------------------------------------
  // Push: get dirty records
  // -----------------------------------------------------------------------

  ipcMain.handle('sync:getDirtyBooks', async () => {
    const db = getDrizzle()
    return db
      .select()
      .from(books)
      .where(and(eq(books.isDirty, 1), isNotNull(books.syncId)))
      .all()
  })

  ipcMain.handle('sync:getDirtyHighlights', async () => {
    const db = getDrizzle()
    return db.select().from(highlights).where(eq(highlights.isDirty, 1)).all()
  })

  ipcMain.handle('sync:getDirtyConversations', async () => {
    const db = getDrizzle()
    return db.select().from(conversations).where(eq(conversations.isDirty, 1)).all()
  })

  ipcMain.handle('sync:getDirtyMessages', async () => {
    const db = getDrizzle()
    return db.select().from(messages).where(eq(messages.isDirty, 1)).all()
  })

  ipcMain.handle('sync:getLastVersion', async () => {
    const db = getDrizzle()
    const row = db.select().from(syncMeta).limit(1).get()
    return row?.lastSyncVersion ?? 0
  })

  // -----------------------------------------------------------------------
  // Push: mark pushed records clean
  // -----------------------------------------------------------------------

  ipcMain.handle(
    'sync:markBooksClean',
    async (_event, params: { ids: string[]; syncVersion: number }): Promise<void> => {
      const db = getDrizzle()
      for (const syncId of params.ids) {
        db.update(books)
          .set({ isDirty: 0, syncVersion: params.syncVersion })
          .where(eq(books.syncId, syncId))
          .run()
      }
    }
  )

  ipcMain.handle(
    'sync:markHighlightsClean',
    async (_event, params: { ids: string[]; syncVersion: number }): Promise<void> => {
      const db = getDrizzle()
      for (const id of params.ids) {
        db.update(highlights)
          .set({ isDirty: 0, syncVersion: params.syncVersion })
          .where(eq(highlights.id, id))
          .run()
      }
    }
  )

  ipcMain.handle(
    'sync:markConversationsClean',
    async (_event, params: { ids: string[]; syncVersion: number }): Promise<void> => {
      const db = getDrizzle()
      for (const id of params.ids) {
        db.update(conversations)
          .set({ isDirty: 0, syncVersion: params.syncVersion })
          .where(eq(conversations.id, id))
          .run()
      }
    }
  )

  ipcMain.handle(
    'sync:markMessagesClean',
    async (_event, params: { ids: string[]; syncVersion: number }): Promise<void> => {
      const db = getDrizzle()
      for (const id of params.ids) {
        db.update(messages)
          .set({ isDirty: 0, syncVersion: params.syncVersion })
          .where(eq(messages.id, id))
          .run()
      }
    }
  )

  // -----------------------------------------------------------------------
  // Push: handle conflicts from server
  // -----------------------------------------------------------------------

  ipcMain.handle(
    'sync:applyBookConflict',
    async (
      _event,
      params: { conflict: Record<string, unknown>; syncVersion: number }
    ): Promise<void> => {
      const { conflict: c, syncVersion } = params
      const db = getDrizzle()
      const syncId = c.id as string
      db.update(books)
        .set({
          title: c.title as string,
          author: c.author as string,
          format: c.format as string,
          currentCfi: (c.currentCfi as string) ?? null,
          currentPage: (c.currentPage as number) ?? null,
          fileHash: (c.fileHash as string) ?? null,
          fileR2Key: (c.fileR2Key as string) ?? null,
          coverR2Key: (c.coverR2Key as string) ?? null,
          syncVersion,
          isDirty: 0,
          isDeleted: (c.isDeleted as boolean) ? 1 : 0
        })
        .where(eq(books.syncId, syncId))
        .run()
    }
  )

  ipcMain.handle(
    'sync:applyHighlightConflict',
    async (
      _event,
      params: { conflict: Record<string, unknown>; syncVersion: number }
    ): Promise<void> => {
      const { conflict: c, syncVersion } = params
      const db = getDrizzle()
      db.update(highlights)
        .set({
          text: c.text as string,
          color: c.color as string,
          note: (c.note as string) ?? '',
          chapter: (c.chapter as string) ?? null,
          cfiRange: c.cfiRange as string,
          syncVersion,
          isDirty: 0,
          isDeleted: (c.isDeleted as boolean) ? 1 : 0
        })
        .where(eq(highlights.id, c.id as string))
        .run()
    }
  )

  ipcMain.handle(
    'sync:applyConversationConflict',
    async (
      _event,
      params: { conflict: Record<string, unknown>; syncVersion: number }
    ): Promise<void> => {
      const { conflict: c, syncVersion } = params
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
    }
  )

  // -----------------------------------------------------------------------
  // Pull: upsert remote records
  // -----------------------------------------------------------------------

  ipcMain.handle(
    'sync:upsertBook',
    async (_event, params: { remote: Record<string, unknown> }): Promise<void> => {
      const { remote } = params
      const syncId = remote.id as string
      if (!syncId) return

      const db = getDrizzle()
      const local = db.select().from(books).where(eq(books.syncId, syncId)).get()

      if (local) {
        if (local.isDirty === 1) return // locally dirty takes precedence

        const title = typeof remote.title === 'string' ? remote.title : (local.title ?? '')
        const author = typeof remote.author === 'string' ? remote.author : (local.author ?? '')
        const format =
          typeof remote.format === 'string' ? remote.format : (local.format ?? local.kind ?? 'epub')

        db.update(books)
          .set({
            title,
            author,
            format,
            currentCfi: (remote.currentCfi as string) ?? null,
            currentPage: (remote.currentPage as number) ?? null,
            fileHash: (remote.fileHash as string) ?? null,
            fileR2Key: (remote.fileR2Key as string) ?? null,
            coverR2Key: (remote.coverR2Key as string) ?? null,
            syncVersion: (remote.syncVersion as number) ?? 0,
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
            location: (remote.currentCfi as string) ?? '',
            coverKind: 'png',
            version: 0,
            syncId,
            format: newFormat,
            currentCfi: (remote.currentCfi as string) ?? null,
            currentPage: (remote.currentPage as number) ?? null,
            fileHash: (remote.fileHash as string) ?? null,
            fileR2Key: (remote.fileR2Key as string) ?? null,
            coverR2Key: (remote.coverR2Key as string) ?? null,
            syncVersion: (remote.syncVersion as number) ?? 0,
            isDirty: 0,
            isDeleted: (remote.isDeleted as boolean) ? 1 : 0
          })
          .run()
      }
    }
  )

  ipcMain.handle(
    'sync:upsertHighlight',
    async (_event, params: { remote: Record<string, unknown> }): Promise<void> => {
      const { remote } = params
      const remoteId = remote.id as string
      if (!remoteId) return

      const db = getDrizzle()
      const local = db.select().from(highlights).where(eq(highlights.id, remoteId)).get()

      if (local) {
        if (local.isDirty === 1) return
        const remoteUpdatedAt = (remote.updatedAt as number) ?? 0
        if (remoteUpdatedAt < (local.updatedAt ?? 0)) return // LWW guard

        const hlText = typeof remote.text === 'string' ? remote.text : (local.text ?? '')
        const hlColor = typeof remote.color === 'string' ? remote.color : (local.color ?? 'yellow')

        db.update(highlights)
          .set({
            text: hlText,
            color: hlColor,
            note: (remote.note as string) ?? '',
            chapter: (remote.chapter as string) ?? null,
            cfiRange: remote.cfiRange as string,
            bookId: remote.bookId as string,
            createdAt: String(remote.createdAt ?? ''),
            updatedAt: remote.updatedAt as number,
            syncVersion: (remote.syncVersion as number) ?? 0,
            isDirty: 0,
            isDeleted: (remote.isDeleted as boolean) ? 1 : 0
          })
          .where(eq(highlights.id, remoteId))
          .run()
      } else {
        db.insert(highlights)
          .values({
            id: remoteId,
            bookId: (remote.bookId as string) ?? '',
            text: (remote.text as string) ?? '',
            color: (remote.color as string) ?? 'yellow',
            note: (remote.note as string) ?? '',
            chapter: (remote.chapter as string) ?? null,
            cfiRange: (remote.cfiRange as string) ?? '',
            createdAt: String(remote.createdAt ?? Date.now()),
            updatedAt: (remote.updatedAt as number) ?? Date.now(),
            syncVersion: (remote.syncVersion as number) ?? 0,
            isDirty: 0,
            isDeleted: (remote.isDeleted as boolean) ? 1 : 0
          })
          .run()
      }
    }
  )

  ipcMain.handle(
    'sync:upsertConversation',
    async (_event, params: { remote: Record<string, unknown> }): Promise<void> => {
      const { remote } = params
      const remoteId = remote.id as string
      if (!remoteId) return

      const db = getDrizzle()
      const local = db.select().from(conversations).where(eq(conversations.id, remoteId)).get()

      if (local) {
        if (local.isDirty === 1) return
        const remoteUpdatedAt = (remote.updatedAt as number) ?? 0
        if (remoteUpdatedAt < (local.updatedAt ?? 0)) return // LWW guard

        const convTitle =
          typeof remote.title === 'string' ? remote.title : (local.title ?? 'New conversation')
        const convBookId = remote.bookId != null ? (remote.bookId as string) : local.bookId

        db.update(conversations)
          .set({
            title: convTitle,
            bookId: convBookId,
            createdAt: String(remote.createdAt ?? ''),
            updatedAt: remote.updatedAt as number,
            syncVersion: (remote.syncVersion as number) ?? 0,
            isDirty: 0,
            isDeleted: (remote.isDeleted as boolean) ? 1 : 0
          })
          .where(eq(conversations.id, remoteId))
          .run()
      } else {
        db.insert(conversations)
          .values({
            id: remoteId,
            bookId: (remote.bookId as string) ?? '',
            title: (remote.title as string) ?? 'New conversation',
            createdAt: String(remote.createdAt ?? Date.now()),
            updatedAt: (remote.updatedAt as number) ?? Date.now(),
            syncVersion: (remote.syncVersion as number) ?? 0,
            isDirty: 0,
            isDeleted: (remote.isDeleted as boolean) ? 1 : 0
          })
          .run()
      }
    }
  )

  ipcMain.handle(
    'sync:insertMessage',
    async (_event, params: { remote: Record<string, unknown> }): Promise<void> => {
      const { remote } = params
      const remoteId = remote.id as string
      if (!remoteId) return

      const db = getDrizzle()
      const existing = db.select().from(messages).where(eq(messages.id, remoteId)).get()
      if (existing) return // append-only: never update existing messages

      db.insert(messages)
        .values({
          id: remoteId,
          conversationId: (remote.conversationId as string) ?? '',
          role: (remote.role as string) ?? 'user',
          content: (remote.content as string) ?? '',
          sourceChunks: (remote.sourceChunks as string) ?? null,
          createdAt: String(remote.createdAt ?? Date.now()),
          updatedAt: (remote.updatedAt as number) ?? Date.now(),
          syncVersion: (remote.syncVersion as number) ?? 0,
          isDirty: 0,
          isDeleted: (remote.isDeleted as boolean) ? 1 : 0
        })
        .run()
    }
  )

  // -----------------------------------------------------------------------
  // Pull: update last sync version
  // -----------------------------------------------------------------------

  ipcMain.handle('sync:updateLastVersion', async (_event, version: number): Promise<void> => {
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
