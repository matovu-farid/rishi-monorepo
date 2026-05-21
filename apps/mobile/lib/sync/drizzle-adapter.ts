/**
 * Mobile drizzle-backed SyncDbAdapter.
 *
 * Implements the shared `SyncDbAdapter` interface from
 * `@rishi/shared/sync-adapter` against the mobile expo-sqlite drizzle
 * database. All the SQL that used to live inline in
 * `apps/mobile/lib/sync/engine.ts` now lives here, so the engine itself
 * can be the platform-agnostic implementation from
 * `@rishi/shared/sync-engine`.
 *
 * Behaviour quirks preserved from the original engine:
 *   - upsertRemoteBook never overwrites local `filePath` or `coverPath`.
 *   - upsertRemoteHighlight applies LWW per field (skip when local
 *     `updatedAt` is newer than remote).
 *   - upsertRemoteConversation applies LWW per record.
 *   - insertRemoteMessage is append-only — existing messages are never
 *     updated.
 *   - All upsert paths skip locally-dirty rows so unpushed local changes
 *     take precedence until the next push cycle.
 */
import { eq } from 'drizzle-orm'
import {
  books,
  highlights,
  conversations,
  messages,
  syncMeta,
} from '@rishi/shared/schema'
import type {
  SyncDbAdapter,
  SyncBook,
  SyncHighlight,
  SyncConversation,
  SyncMessage,
} from '@rishi/shared/sync-adapter'
import { db } from '@/lib/db'

export function createMobileDrizzleAdapter(): SyncDbAdapter {
  return {
    // ── Push: read dirty records ─────────────────────────────────────────
    async getDirtyBooks(): Promise<SyncBook[]> {
      return db
        .select()
        .from(books)
        .where(eq(books.isDirty, true))
        .all() as unknown as SyncBook[]
    },

    async getDirtyHighlights(): Promise<SyncHighlight[]> {
      return db
        .select()
        .from(highlights)
        .where(eq(highlights.isDirty, true))
        .all() as unknown as SyncHighlight[]
    },

    async getDirtyConversations(): Promise<SyncConversation[]> {
      return db
        .select()
        .from(conversations)
        .where(eq(conversations.isDirty, true))
        .all() as unknown as SyncConversation[]
    },

    async getDirtyMessages(): Promise<SyncMessage[]> {
      return db
        .select()
        .from(messages)
        .where(eq(messages.isDirty, true))
        .all() as unknown as SyncMessage[]
    },

    async getLastSyncVersion(): Promise<number> {
      const row = db
        .select()
        .from(syncMeta)
        .where(eq(syncMeta.id, 'default'))
        .get()
      return row?.lastSyncVersion ?? 0
    },

    // ── Push: handle conflicts from server ───────────────────────────────
    async applyBookConflict(c, syncVersion) {
      const id = c.id as string
      if (!id) return
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
          syncVersion,
          isDirty: false,
          isDeleted: (c.isDeleted as boolean) ?? false,
        })
        .where(eq(books.id, id))
        .run()
    },

    async applyHighlightConflict(c, syncVersion) {
      const id = c.id as string
      if (!id) return
      db.update(highlights)
        .set({
          text: c.text as string,
          color: c.color as string,
          note: (c.note as string) ?? null,
          chapter: (c.chapter as string) ?? null,
          cfiRange: c.cfiRange as string,
          createdAt: c.createdAt as number,
          updatedAt: c.updatedAt as number,
          syncVersion,
          isDirty: false,
          isDeleted: (c.isDeleted as boolean) ?? false,
        })
        .where(eq(highlights.id, id))
        .run()
    },

    async applyConversationConflict(c, syncVersion) {
      const id = c.id as string
      if (!id) return
      db.update(conversations)
        .set({
          title: c.title as string,
          bookId: c.bookId as string,
          createdAt: c.createdAt as number,
          updatedAt: c.updatedAt as number,
          syncVersion,
          isDirty: false,
          isDeleted: (c.isDeleted as boolean) ?? false,
        })
        .where(eq(conversations.id, id))
        .run()
    },

    // ── Push: mark pushed records clean ──────────────────────────────────
    async markBooksClean(ids, syncVersion) {
      for (const id of ids) {
        db.update(books)
          .set({ isDirty: false, syncVersion })
          .where(eq(books.id, id))
          .run()
      }
    },

    async markHighlightsClean(ids, syncVersion) {
      for (const id of ids) {
        db.update(highlights)
          .set({ isDirty: false, syncVersion })
          .where(eq(highlights.id, id))
          .run()
      }
    },

    async markConversationsClean(ids, syncVersion) {
      for (const id of ids) {
        db.update(conversations)
          .set({ isDirty: false, syncVersion })
          .where(eq(conversations.id, id))
          .run()
      }
    },

    async markMessagesClean(ids, syncVersion) {
      for (const id of ids) {
        db.update(messages)
          .set({ isDirty: false, syncVersion })
          .where(eq(messages.id, id))
          .run()
      }
    },

    // ── Pull: upsert remote records ──────────────────────────────────────
    async upsertRemoteBook(remote) {
      const r = remote
      const id = r.id as string
      if (!id) return
      const local = db
        .select()
        .from(books)
        .where(eq(books.id, id))
        .get() as { isDirty?: boolean | null } | undefined

      if (local) {
        if (local.isDirty) return // local takes precedence until pushed
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
          .where(eq(books.id, id))
          .run()
      } else {
        db.insert(books)
          .values({
            id,
            title: r.title as string,
            author: (r.author as string) ?? 'Unknown',
            filePath: '', // not yet downloaded
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
    },

    async upsertRemoteHighlight(remote) {
      const r = remote
      const id = r.id as string
      if (!id) return
      const local = db
        .select()
        .from(highlights)
        .where(eq(highlights.id, id))
        .get() as { isDirty?: boolean | null; updatedAt?: number } | undefined

      if (local) {
        if (local.isDirty) return
        const remoteUpdatedAt = (r.updatedAt as number) ?? 0
        if (remoteUpdatedAt < (local.updatedAt ?? 0)) return
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
          .where(eq(highlights.id, id))
          .run()
      } else {
        db.insert(highlights)
          .values({
            id,
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
    },

    async upsertRemoteConversation(remote) {
      const r = remote
      const id = r.id as string
      if (!id) return
      const local = db
        .select()
        .from(conversations)
        .where(eq(conversations.id, id))
        .get() as { isDirty?: boolean | null; updatedAt?: number } | undefined

      if (local) {
        if (local.isDirty) return
        const remoteUpdatedAt = (r.updatedAt as number) ?? 0
        if (remoteUpdatedAt < (local.updatedAt ?? 0)) return
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
          .where(eq(conversations.id, id))
          .run()
      } else {
        db.insert(conversations)
          .values({
            id,
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
    },

    async insertRemoteMessage(remote) {
      const r = remote
      const id = r.id as string
      if (!id) return
      const local = db
        .select()
        .from(messages)
        .where(eq(messages.id, id))
        .get()
      if (local) return // append-only — never update existing messages
      db.insert(messages)
        .values({
          id,
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
    },

    async updateLastSyncVersion(version) {
      db.update(syncMeta)
        .set({
          lastSyncVersion: version,
          lastSyncAt: Date.now(),
        })
        .where(eq(syncMeta.id, 'default'))
        .run()
    },
  }
}
