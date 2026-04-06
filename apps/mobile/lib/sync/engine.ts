import { db } from '@/lib/db'
import { books, highlights, conversations, messages, syncMeta } from '@rishi/shared/schema'
import { eq } from 'drizzle-orm'
import { apiClient } from '@/lib/api'
import type { PushResponse, PullResponse } from '@rishi/shared/sync-types'

let isSyncing = false

/**
 * Run a full push-then-pull sync cycle.
 * All errors are caught internally -- this function never throws.
 */
export async function sync(): Promise<void> {
  if (isSyncing) return
  isSyncing = true
  try {
    await push()
    await pull()
  } catch (error) {
    console.warn('[sync] cycle failed:', error)
  } finally {
    isSyncing = false
  }
}

/**
 * Push all locally dirty records (books + highlights) to the server.
 */
async function push(): Promise<void> {
  const dirtyBooks = db
    .select()
    .from(books)
    .where(eq(books.isDirty, true))
    .all()

  const dirtyHighlights = db
    .select()
    .from(highlights)
    .where(eq(highlights.isDirty, true))
    .all()

  const dirtyConversations = db
    .select()
    .from(conversations)
    .where(eq(conversations.isDirty, true))
    .all()

  const dirtyMessages = db
    .select()
    .from(messages)
    .where(eq(messages.isDirty, true))
    .all()

  if (
    dirtyBooks.length === 0 &&
    dirtyHighlights.length === 0 &&
    dirtyConversations.length === 0 &&
    dirtyMessages.length === 0
  ) return

  const response = await apiClient('/api/sync/push', {
    method: 'POST',
    body: JSON.stringify({
      changes: {
        books: dirtyBooks,
        highlights: dirtyHighlights,
        conversations: dirtyConversations,
        messages: dirtyMessages,
      },
    }),
  })

  if (!response.ok) {
    console.warn('[sync:push] server responded', response.status)
    return
  }

  const data: PushResponse = await response.json()

  // Apply conflict resolutions from server
  for (const conflict of data.conflicts) {
    const c = conflict as Record<string, unknown>
    if (typeof c.id !== 'string') continue

    if ('cfiRange' in c) {
      // Highlight conflict -- server version wins, apply it locally
      db.update(highlights)
        .set({
          text: c.text as string,
          color: c.color as string,
          note: (c.note as string) ?? null,
          chapter: (c.chapter as string) ?? null,
          cfiRange: c.cfiRange as string,
          createdAt: c.createdAt as number,
          updatedAt: c.updatedAt as number,
          syncVersion: data.syncVersion,
          isDirty: false,
          isDeleted: (c.isDeleted as boolean) ?? false,
        })
        .where(eq(highlights.id, c.id))
        .run()
    } else if ('title' in c && 'bookId' in c && !('filePath' in c)) {
      // Conversation conflict -- server version wins (LWW)
      db.update(conversations)
        .set({
          title: c.title as string,
          bookId: c.bookId as string,
          createdAt: c.createdAt as number,
          updatedAt: c.updatedAt as number,
          syncVersion: data.syncVersion,
          isDirty: false,
          isDeleted: (c.isDeleted as boolean) ?? false,
        })
        .where(eq(conversations.id, c.id))
        .run()
    } else {
      // Book conflict -- existing logic
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
          createdAt: c.createdAt as number,
          updatedAt: c.updatedAt as number,
          syncVersion: data.syncVersion,
          isDirty: false,
          isDeleted: (c.isDeleted as boolean) ?? false,
        })
        .where(eq(books.id, c.id))
        .run()
    }
  }

  // Mark all pushed books as clean
  const pushedBookIds = dirtyBooks.map((b) => b.id)
  for (const id of pushedBookIds) {
    db.update(books)
      .set({ isDirty: false, syncVersion: data.syncVersion })
      .where(eq(books.id, id))
      .run()
  }

  // Mark all pushed highlights as clean
  const pushedHighlightIds = dirtyHighlights.map((h) => h.id)
  for (const id of pushedHighlightIds) {
    db.update(highlights)
      .set({ isDirty: false, syncVersion: data.syncVersion })
      .where(eq(highlights.id, id))
      .run()
  }

  // Mark all pushed conversations as clean
  const pushedConversationIds = dirtyConversations.map((c) => c.id)
  for (const id of pushedConversationIds) {
    db.update(conversations)
      .set({ isDirty: false, syncVersion: data.syncVersion })
      .where(eq(conversations.id, id))
      .run()
  }

  // Mark all pushed messages as clean
  const pushedMessageIds = dirtyMessages.map((m) => m.id)
  for (const id of pushedMessageIds) {
    db.update(messages)
      .set({ isDirty: false, syncVersion: data.syncVersion })
      .where(eq(messages.id, id))
      .run()
  }
}

/**
 * Pull remote changes since the last known sync version.
 * Never overwrites local filePath or coverPath with remote values.
 * Skips records that are locally dirty (local changes take precedence).
 */
async function pull(): Promise<void> {
  const meta = db
    .select()
    .from(syncMeta)
    .where(eq(syncMeta.id, 'default'))
    .get()

  const lastVersion = meta?.lastSyncVersion ?? 0

  const response = await apiClient(
    `/api/sync/pull?since_version=${lastVersion}`,
    { method: 'GET' }
  )

  if (!response.ok) {
    console.warn('[sync:pull] server responded', response.status)
    return
  }

  const data: PullResponse = await response.json()

  // ── Pull books ──────────────────────────────────────────────────────────────
  for (const remote of data.changes.books) {
    const r = remote as Record<string, unknown>
    const remoteId = r.id as string
    if (!remoteId) continue

    const local = db
      .select()
      .from(books)
      .where(eq(books.id, remoteId))
      .get()

    if (local) {
      // Skip locally dirty records -- local changes take precedence until pushed
      if (local.isDirty) continue

      // Update metadata fields only -- NEVER overwrite filePath or coverPath
      db.update(books)
        .set({
          title: r.title as string,
          author: r.author as string,
          format: r.format as string,
          currentCfi: (r.currentCfi as string) ?? null,
          currentPage: (r.currentPage as number) ?? null,
          fileHash: (r.fileHash as string) ?? null,
          fileR2Key: (r.fileR2Key as string) ?? null,
          coverR2Key: (r.coverR2Key as string) ?? null,
          createdAt: r.createdAt as number,
          updatedAt: r.updatedAt as number,
          syncVersion: (r.syncVersion as number) ?? 0,
          isDirty: false,
          isDeleted: (r.isDeleted as boolean) ?? false,
        })
        .where(eq(books.id, remoteId))
        .run()
    } else {
      // New remote book -- insert with empty local paths (file not downloaded yet)
      db.insert(books)
        .values({
          id: remoteId,
          title: r.title as string,
          author: (r.author as string) ?? 'Unknown',
          filePath: '', // file not downloaded yet
          coverPath: null,
          format: (r.format as string) ?? 'epub',
          currentCfi: (r.currentCfi as string) ?? null,
          currentPage: (r.currentPage as number) ?? null,
          fileHash: (r.fileHash as string) ?? null,
          fileR2Key: (r.fileR2Key as string) ?? null,
          coverR2Key: (r.coverR2Key as string) ?? null,
          createdAt: (r.createdAt as number) ?? Date.now(),
          updatedAt: (r.updatedAt as number) ?? Date.now(),
          syncVersion: (r.syncVersion as number) ?? 0,
          isDirty: false,
          isDeleted: (r.isDeleted as boolean) ?? false,
        })
        .run()
    }
  }

  // ── Pull highlights (union merge) ──────────────────────────────────────────
  for (const remote of data.changes.highlights ?? []) {
    const r = remote as Record<string, unknown>
    const remoteId = r.id as string
    if (!remoteId) continue

    const local = db
      .select()
      .from(highlights)
      .where(eq(highlights.id, remoteId))
      .get()

    if (local) {
      // Skip locally dirty -- local changes take precedence until pushed
      if (local.isDirty) continue

      // LWW guard: only apply remote update if remote is newer or equal
      const remoteUpdatedAt = (r.updatedAt as number) ?? 0
      if (remoteUpdatedAt < (local.updatedAt ?? 0)) continue

      // LWW per field: update with remote values
      db.update(highlights)
        .set({
          text: r.text as string,
          color: r.color as string,
          note: (r.note as string) ?? null,
          chapter: (r.chapter as string) ?? null,
          cfiRange: r.cfiRange as string,
          bookId: r.bookId as string,
          createdAt: r.createdAt as number,
          updatedAt: r.updatedAt as number,
          syncVersion: (r.syncVersion as number) ?? 0,
          isDirty: false,
          isDeleted: (r.isDeleted as boolean) ?? false,
        })
        .where(eq(highlights.id, remoteId))
        .run()
    } else {
      // New remote highlight -- insert (union merge: always accept new highlights)
      db.insert(highlights)
        .values({
          id: remoteId,
          bookId: (r.bookId as string) ?? '',
          text: (r.text as string) ?? '',
          color: (r.color as string) ?? 'yellow',
          note: (r.note as string) ?? null,
          chapter: (r.chapter as string) ?? null,
          cfiRange: (r.cfiRange as string) ?? '',
          createdAt: (r.createdAt as number) ?? Date.now(),
          updatedAt: (r.updatedAt as number) ?? Date.now(),
          syncVersion: (r.syncVersion as number) ?? 0,
          isDirty: false,
          isDeleted: (r.isDeleted as boolean) ?? false,
        })
        .run()
    }
  }

  // ── Pull conversations (LWW merge) ────────────────────────────────────────
  for (const remote of data.changes.conversations ?? []) {
    const r = remote as Record<string, unknown>
    const remoteId = r.id as string
    if (!remoteId) continue

    const local = db
      .select()
      .from(conversations)
      .where(eq(conversations.id, remoteId))
      .get()

    if (local) {
      // Skip locally dirty -- local changes take precedence until pushed
      if (local.isDirty) continue

      // LWW guard: only apply remote update if remote is newer or equal
      const remoteUpdatedAt = (r.updatedAt as number) ?? 0
      if (remoteUpdatedAt < (local.updatedAt ?? 0)) continue

      db.update(conversations)
        .set({
          title: r.title as string,
          bookId: r.bookId as string,
          createdAt: r.createdAt as number,
          updatedAt: r.updatedAt as number,
          syncVersion: (r.syncVersion as number) ?? 0,
          isDirty: false,
          isDeleted: (r.isDeleted as boolean) ?? false,
        })
        .where(eq(conversations.id, remoteId))
        .run()
    } else {
      // New remote conversation -- insert
      db.insert(conversations)
        .values({
          id: remoteId,
          bookId: (r.bookId as string) ?? '',
          title: (r.title as string) ?? 'New conversation',
          createdAt: (r.createdAt as number) ?? Date.now(),
          updatedAt: (r.updatedAt as number) ?? Date.now(),
          syncVersion: (r.syncVersion as number) ?? 0,
          isDirty: false,
          isDeleted: (r.isDeleted as boolean) ?? false,
        })
        .run()
    }
  }

  // ── Pull messages (append-only merge) ────────────────────────────────────
  for (const remote of data.changes.messages ?? []) {
    const r = remote as Record<string, unknown>
    const remoteId = r.id as string
    if (!remoteId) continue

    const local = db
      .select()
      .from(messages)
      .where(eq(messages.id, remoteId))
      .get()

    if (local) {
      // Append-only: never update existing messages, skip entirely
      continue
    }

    // New remote message -- insert with isDirty=false
    db.insert(messages)
      .values({
        id: remoteId,
        conversationId: (r.conversationId as string) ?? '',
        role: (r.role as string) ?? 'user',
        content: (r.content as string) ?? '',
        sourceChunks: (r.sourceChunks as string) ?? null,
        createdAt: (r.createdAt as number) ?? Date.now(),
        updatedAt: (r.updatedAt as number) ?? Date.now(),
        syncVersion: (r.syncVersion as number) ?? 0,
        isDirty: false,
        isDeleted: (r.isDeleted as boolean) ?? false,
      })
      .run()
  }

  // Update sync metadata
  db.update(syncMeta)
    .set({
      lastSyncVersion: data.syncVersion,
      lastSyncAt: Date.now(),
    })
    .where(eq(syncMeta.id, 'default'))
    .run()
}
