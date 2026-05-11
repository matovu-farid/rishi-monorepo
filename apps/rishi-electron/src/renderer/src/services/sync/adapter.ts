/**
 * Sync adapter — marshals raw IPC payloads into the typed SyncDbAdapter
 * shape expected by `@rishi/shared/sync-engine`. Internal to the service;
 * not exported from `index.ts`.
 *
 * Replaces the class-based `modules/sync-adapter.ts`. Stateless — every
 * method is a one-line `await ipc.X(...)` plus row coercion.
 */
import type {
  SyncDbAdapter,
  SyncBook,
  SyncHighlight,
  SyncConversation,
  SyncMessage
} from '@rishi/shared/sync-adapter'
import type { SyncIpcChannels } from './types'

/** Coerce Date | number | string to epoch ms. Falls back to `Date.now()`. */
function toTimestamp(val: unknown): number {
  if (val instanceof Date) return val.getTime()
  if (typeof val === 'number') return val
  if (typeof val === 'string') return new Date(val).getTime()
  return Date.now()
}

export function makeAdapter(ipc: SyncIpcChannels): SyncDbAdapter {
  return {
    async getDirtyBooks(): Promise<SyncBook[]> {
      const rows = (await ipc.syncGetDirtyBooks()) as Array<Record<string, unknown>>
      return rows.map((row) => ({
        id: row.syncId as string,
        title: row.title as string,
        author: row.author as string,
        format: (row.format ?? row.kind) as string,
        currentCfi: row.currentCfi as string | null,
        currentPage: row.currentPage as number | null,
        fileHash: row.fileHash as string,
        fileR2Key: row.fileR2Key as string | null,
        coverR2Key: row.coverR2Key as string | null,
        createdAt: toTimestamp(row.createdAt),
        updatedAt: toTimestamp(row.updatedAt),
        syncVersion: row.syncVersion as number,
        isDirty: true,
        isDeleted: row.isDeleted === 1
      }))
    },

    async getDirtyHighlights(): Promise<SyncHighlight[]> {
      const rows = (await ipc.syncGetDirtyHighlights()) as Array<Record<string, unknown>>
      return rows.map((row) => ({
        id: row.id as string,
        bookId: row.bookId as string,
        cfiRange: row.cfiRange as string,
        text: row.text as string,
        color: row.color as string,
        note: row.note as string | null,
        chapter: row.chapter as string | null,
        createdAt: toTimestamp(row.createdAt),
        updatedAt: toTimestamp(row.updatedAt),
        syncVersion: row.syncVersion as number,
        isDirty: true,
        isDeleted: row.isDeleted === 1
      }))
    },

    async getDirtyConversations(): Promise<SyncConversation[]> {
      const rows = (await ipc.syncGetDirtyConversations()) as Array<Record<string, unknown>>
      return rows.map((row) => ({
        id: row.id as string,
        bookId: row.bookId as string,
        title: row.title as string,
        createdAt: toTimestamp(row.createdAt),
        updatedAt: toTimestamp(row.updatedAt),
        syncVersion: row.syncVersion as number,
        isDirty: true,
        isDeleted: row.isDeleted === 1
      }))
    },

    async getDirtyMessages(): Promise<SyncMessage[]> {
      const rows = (await ipc.syncGetDirtyMessages()) as Array<Record<string, unknown>>
      return rows.map((row) => ({
        id: row.id as string,
        conversationId: row.conversationId as string,
        role: row.role as string,
        content: row.content as string,
        sourceChunks: row.sourceChunks as string | null,
        createdAt: toTimestamp(row.createdAt),
        updatedAt: toTimestamp(row.updatedAt),
        syncVersion: row.syncVersion as number,
        isDirty: true,
        isDeleted: row.isDeleted === 1
      }))
    },

    async getLastSyncVersion(): Promise<number> {
      return ipc.syncGetLastVersion()
    },

    async applyBookConflict(c, syncVersion) {
      await ipc.syncApplyBookConflict(c, syncVersion)
    },
    async applyHighlightConflict(c, syncVersion) {
      await ipc.syncApplyHighlightConflict(c, syncVersion)
    },
    async applyConversationConflict(c, syncVersion) {
      await ipc.syncApplyConversationConflict(c, syncVersion)
    },

    async markBooksClean(ids, syncVersion) {
      await ipc.syncMarkBooksClean(ids, syncVersion)
    },
    async markHighlightsClean(ids, syncVersion) {
      await ipc.syncMarkHighlightsClean(ids, syncVersion)
    },
    async markConversationsClean(ids, syncVersion) {
      await ipc.syncMarkConversationsClean(ids, syncVersion)
    },
    async markMessagesClean(ids, syncVersion) {
      await ipc.syncMarkMessagesClean(ids, syncVersion)
    },

    async upsertRemoteBook(remote) {
      await ipc.syncUpsertBook(remote)
    },
    async upsertRemoteHighlight(remote) {
      await ipc.syncUpsertHighlight(remote)
    },
    async upsertRemoteConversation(remote) {
      await ipc.syncUpsertConversation(remote)
    },
    async insertRemoteMessage(remote) {
      await ipc.syncInsertMessage(remote)
    },

    async updateLastSyncVersion(version) {
      await ipc.syncUpdateLastVersion(version)
    }
  }
}
