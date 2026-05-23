import { eq, and, isNotNull } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { books, highlights, conversations, messages, syncMeta } from '../database/schema.js'
import { handle } from '../../preload/ipc-contract.js'
import {
  bookConflictSchema,
  highlightConflictSchema,
  conversationConflictSchema,
  bookUpsertSchema,
  highlightUpsertSchema,
  conversationUpsertSchema,
  messageInsertSchema
} from './sync.schemas.js'

/**
 * Drizzle BetterSqlite3 instance type. Helper functions accept this so they
 * can be unit-tested against an in-memory database without invoking the IPC
 * layer.
 */
type Db = ReturnType<typeof getDrizzle>

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
 * Convert a `string | number` (from `asStringOrNumber`) to a plain string.
 */
function stringFrom(v: string | number): string {
  return typeof v === 'string' ? v : v.toString()
}

// ===========================================================================
// Pure helpers (exported with `_` prefix for testing)
//
// Each helper takes an explicit `db` so unit tests can pass an in-memory
// drizzle instance without monkey-patching the singleton in `./drizzle.js`.
// Multi-statement helpers wrap their writes in `db.transaction(...)` so a
// partial failure rolls back (#167).
// ===========================================================================

// ---------------------------------------------------------------------------
// Mark-clean loops (wrapped in transactions: #167)
// ---------------------------------------------------------------------------

export function _markBooksCleanWithDb(db: Db, ids: string[], syncVersion: number): void {
  db.transaction((tx) => {
    for (const syncId of ids) {
      tx.update(books).set({ isDirty: 0, syncVersion }).where(eq(books.syncId, syncId)).run()
    }
  })
}

export function _markHighlightsCleanWithDb(db: Db, ids: string[], syncVersion: number): void {
  db.transaction((tx) => {
    for (const id of ids) {
      tx.update(highlights).set({ isDirty: 0, syncVersion }).where(eq(highlights.id, id)).run()
    }
  })
}

export function _markConversationsCleanWithDb(
  db: Db,
  ids: string[],
  syncVersion: number
): void {
  db.transaction((tx) => {
    for (const id of ids) {
      tx.update(conversations)
        .set({ isDirty: 0, syncVersion })
        .where(eq(conversations.id, id))
        .run()
    }
  })
}

export function _markMessagesCleanWithDb(db: Db, ids: string[], syncVersion: number): void {
  db.transaction((tx) => {
    for (const id of ids) {
      tx.update(messages).set({ isDirty: 0, syncVersion }).where(eq(messages.id, id)).run()
    }
  })
}

// ---------------------------------------------------------------------------
// Conflict handlers (validated + transactional: #166 + #167)
// ---------------------------------------------------------------------------

export function _applyBookConflictWithDb(
  db: Db,
  conflict: unknown,
  syncVersion: number
): void {
  const parsed = bookConflictSchema.safeParse(conflict)
  if (!parsed.success) {
    // Malformed payload — silently skip (matches existing defensive pattern
    // in `_upsertBookWithDb`). Logging would be nicer but the existing
    // handlers do not log, so we preserve behaviour.
    return
  }
  const c = parsed.data
  db.transaction((tx) => {
    tx.update(books)
      .set({
        title: c.title,
        author: c.author,
        format: c.format,
        currentCfi: c.currentCfi,
        currentPage: c.currentPage,
        fileHash: c.fileHash,
        fileR2Key: c.fileR2Key,
        coverR2Key: c.coverR2Key,
        syncVersion,
        isDirty: 0,
        isDeleted: c.isDeleted
      })
      .where(eq(books.syncId, c.id))
      .run()
  })
}

export function _applyHighlightConflictWithDb(
  db: Db,
  conflict: unknown,
  syncVersion: number
): void {
  const parsed = highlightConflictSchema.safeParse(conflict)
  if (!parsed.success) return
  const c = parsed.data
  db.transaction((tx) => {
    tx.update(highlights)
      .set({
        text: c.text,
        color: c.color,
        note: c.note,
        chapter: c.chapter,
        cfiRange: c.cfiRange,
        syncVersion,
        isDirty: 0,
        isDeleted: c.isDeleted
      })
      .where(eq(highlights.id, c.id))
      .run()
  })
}

export function _applyConversationConflictWithDb(
  db: Db,
  conflict: unknown,
  syncVersion: number
): void {
  const parsed = conversationConflictSchema.safeParse(conflict)
  if (!parsed.success) return
  const c = parsed.data
  db.transaction((tx) => {
    tx.update(conversations)
      .set({
        title: c.title,
        bookId: c.bookId,
        syncVersion,
        isDirty: 0,
        isDeleted: c.isDeleted
      })
      .where(eq(conversations.id, c.id))
      .run()
  })
}

// ---------------------------------------------------------------------------
// Upsert handlers (validated + transactional: #166 + #167)
// ---------------------------------------------------------------------------

export function _upsertBookWithDb(db: Db, remote: unknown): void {
  const parsed = bookUpsertSchema.safeParse(remote)
  if (!parsed.success) return
  const r = parsed.data
  const syncId = r.id

  db.transaction((tx) => {
    const local = tx.select().from(books).where(eq(books.syncId, syncId)).get()

    if (local) {
      if (local.isDirty === 1) return // locally dirty takes precedence

      tx.update(books)
        .set({
          title: r.title ?? local.title,
          author: r.author ?? local.author,
          format: r.format ?? local.format,
          currentCfi: r.currentCfi,
          currentPage: r.currentPage,
          fileHash: r.fileHash,
          fileR2Key: r.fileR2Key,
          coverR2Key: r.coverR2Key,
          fileSize: r.fileSize ?? local.fileSize,
          syncVersion: r.syncVersion,
          isDirty: 0,
          isDeleted: r.isDeleted
        })
        .where(eq(books.syncId, syncId))
        .run()
    } else {
      // New remote book — insert with empty local file (needs download)
      const newTitle = r.title ?? 'Unknown'
      const newAuthor = r.author ?? 'Unknown'
      const newFormat = r.format ?? 'epub'

      tx.insert(books)
        .values({
          kind: newFormat,
          cover: Buffer.alloc(0),
          title: newTitle,
          author: newAuthor,
          publisher: '',
          filepath: '',
          location: r.currentCfi ?? '',
          coverKind: 'png',
          version: 0,
          syncId,
          format: newFormat,
          currentCfi: r.currentCfi,
          currentPage: r.currentPage,
          fileHash: r.fileHash,
          fileR2Key: r.fileR2Key,
          coverR2Key: r.coverR2Key,
          fileSize: r.fileSize ?? 0,
          syncVersion: r.syncVersion,
          isDirty: 0,
          isDeleted: r.isDeleted
        })
        .run()
    }
  })
}

export function _upsertHighlightWithDb(db: Db, remote: unknown): void {
  const parsed = highlightUpsertSchema.safeParse(remote)
  if (!parsed.success) return
  const r = parsed.data

  db.transaction((tx) => {
    const local = tx.select().from(highlights).where(eq(highlights.id, r.id)).get()

    if (local) {
      if (local.isDirty === 1) return
      const remoteUpdatedAt = r.updatedAt ?? 0
      if (remoteUpdatedAt < (local.updatedAt ?? 0)) return // LWW guard

      tx.update(highlights)
        .set({
          text: r.text ?? local.text,
          color: r.color ?? local.color,
          note: r.note ?? '',
          chapter: r.chapter,
          cfiRange: r.cfiRange ?? '',
          bookId: r.bookId ?? local.bookId,
          createdAt: stringFrom(asStringOrNumber(r.createdAt, '')),
          updatedAt: r.updatedAt ?? local.updatedAt,
          syncVersion: r.syncVersion,
          isDirty: 0,
          isDeleted: r.isDeleted
        })
        .where(eq(highlights.id, r.id))
        .run()
    } else {
      tx.insert(highlights)
        .values({
          id: r.id,
          bookId: r.bookId ?? '',
          text: r.text ?? '',
          color: r.color ?? 'yellow',
          note: r.note ?? '',
          chapter: r.chapter,
          cfiRange: r.cfiRange ?? '',
          createdAt: stringFrom(asStringOrNumber(r.createdAt, Date.now())),
          updatedAt: r.updatedAt ?? Date.now(),
          syncVersion: r.syncVersion,
          isDirty: 0,
          isDeleted: r.isDeleted
        })
        .run()
    }
  })
}

export function _upsertConversationWithDb(db: Db, remote: unknown): void {
  const parsed = conversationUpsertSchema.safeParse(remote)
  if (!parsed.success) return
  const r = parsed.data

  db.transaction((tx) => {
    const local = tx.select().from(conversations).where(eq(conversations.id, r.id)).get()

    if (local) {
      if (local.isDirty === 1) return
      const remoteUpdatedAt = r.updatedAt ?? 0
      if (remoteUpdatedAt < (local.updatedAt ?? 0)) return // LWW guard

      tx.update(conversations)
        .set({
          title: r.title ?? local.title,
          bookId: r.bookId ?? local.bookId,
          createdAt: stringFrom(asStringOrNumber(r.createdAt, '')),
          updatedAt: r.updatedAt ?? local.updatedAt,
          syncVersion: r.syncVersion,
          isDirty: 0,
          isDeleted: r.isDeleted
        })
        .where(eq(conversations.id, r.id))
        .run()
    } else {
      tx.insert(conversations)
        .values({
          id: r.id,
          bookId: r.bookId ?? '',
          title: r.title ?? 'New conversation',
          createdAt: stringFrom(asStringOrNumber(r.createdAt, Date.now())),
          updatedAt: r.updatedAt ?? Date.now(),
          syncVersion: r.syncVersion,
          isDirty: 0,
          isDeleted: r.isDeleted
        })
        .run()
    }
  })
}

export function _insertMessageWithDb(db: Db, remote: unknown): void {
  const parsed = messageInsertSchema.safeParse(remote)
  if (!parsed.success) return
  const r = parsed.data

  db.transaction((tx) => {
    const existing = tx.select().from(messages).where(eq(messages.id, r.id)).get()
    if (existing) return // append-only: never update existing messages

    tx.insert(messages)
      .values({
        id: r.id,
        conversationId: r.conversationId ?? '',
        role: r.role ?? 'user',
        content: r.content ?? '',
        sourceChunks: r.sourceChunks,
        createdAt: stringFrom(asStringOrNumber(r.createdAt, Date.now())),
        updatedAt: r.updatedAt ?? Date.now(),
        syncVersion: r.syncVersion,
        isDirty: 0,
        isDeleted: r.isDeleted
      })
      .run()
  })
}

export function _updateLastVersionWithDb(db: Db, version: number): void {
  db.transaction((tx) => {
    const existing = tx.select().from(syncMeta).limit(1).get()
    const now = new Date().toISOString()
    if (existing) {
      tx.update(syncMeta)
        .set({ lastSyncVersion: version, lastSyncAt: now })
        .where(eq(syncMeta.id, existing.id))
        .run()
    } else {
      tx.insert(syncMeta).values({ lastSyncVersion: version, lastSyncAt: now }).run()
    }
  })
}

// ===========================================================================
// IPC registration — thin adapters around the helpers above.
// ===========================================================================

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
    _markBooksCleanWithDb(getDrizzle(), ids, syncVersion)
  })

  handle('sync:markHighlightsClean', (_event, ids, syncVersion) => {
    _markHighlightsCleanWithDb(getDrizzle(), ids, syncVersion)
  })

  handle('sync:markConversationsClean', (_event, ids, syncVersion) => {
    _markConversationsCleanWithDb(getDrizzle(), ids, syncVersion)
  })

  handle('sync:markMessagesClean', (_event, ids, syncVersion) => {
    _markMessagesCleanWithDb(getDrizzle(), ids, syncVersion)
  })

  // -----------------------------------------------------------------------
  // Push: handle conflicts from server
  // -----------------------------------------------------------------------

  handle('sync:applyBookConflict', (_event, conflict, syncVersion) => {
    _applyBookConflictWithDb(getDrizzle(), conflict, syncVersion)
  })

  handle('sync:applyHighlightConflict', (_event, conflict, syncVersion) => {
    _applyHighlightConflictWithDb(getDrizzle(), conflict, syncVersion)
  })

  handle('sync:applyConversationConflict', (_event, conflict, syncVersion) => {
    _applyConversationConflictWithDb(getDrizzle(), conflict, syncVersion)
  })

  // -----------------------------------------------------------------------
  // Pull: upsert remote records
  // -----------------------------------------------------------------------

  handle('sync:upsertBook', (_event, remote) => {
    _upsertBookWithDb(getDrizzle(), remote)
  })

  handle('sync:upsertHighlight', (_event, remote) => {
    _upsertHighlightWithDb(getDrizzle(), remote)
  })

  handle('sync:upsertConversation', (_event, remote) => {
    _upsertConversationWithDb(getDrizzle(), remote)
  })

  handle('sync:insertMessage', (_event, remote) => {
    _insertMessageWithDb(getDrizzle(), remote)
  })

  // -----------------------------------------------------------------------
  // Pull: update last sync version
  // -----------------------------------------------------------------------

  handle('sync:updateLastVersion', (_event, version) => {
    _updateLastVersionWithDb(getDrizzle(), version)
  })
}
