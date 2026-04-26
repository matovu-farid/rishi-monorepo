/**
 * Sync adapter -- uses typed Electron IPC handlers for DB access.
 * Mirrors the Tauri version's SyncDbAdapter interface from @rishi/shared/sync-adapter.
 */
import type {
  SyncDbAdapter,
  SyncBook,
  SyncHighlight,
  SyncConversation,
  SyncMessage
} from '@rishi/shared/sync-adapter'

/** Safely coerce a DB timestamp value (Date, number, or string) to epoch ms. */
function toTimestamp(val: unknown): number {
  if (val instanceof Date) return val.getTime()
  if (typeof val === 'number') return val
  if (typeof val === 'string') return new Date(val).getTime()
  return Date.now()
}

export class DesktopSyncAdapter implements SyncDbAdapter {
  async getDirtyBooks(): Promise<SyncBook[]> {
    const rows = (await window.electron.syncGetDirtyBooks()) as any[]

    return rows.map((row) => ({
      id: row.syncId!,
      title: row.title,
      author: row.author,
      format: row.format ?? row.kind,
      currentCfi: row.currentCfi,
      currentPage: row.currentPage,
      fileHash: row.fileHash,
      fileR2Key: row.fileR2Key,
      coverR2Key: row.coverR2Key,
      createdAt: toTimestamp(row.createdAt),
      updatedAt: toTimestamp(row.updatedAt),
      syncVersion: row.syncVersion,
      isDirty: true,
      isDeleted: row.isDeleted === 1
    }))
  }

  async getDirtyHighlights(): Promise<SyncHighlight[]> {
    const rows = (await window.electron.syncGetDirtyHighlights()) as any[]

    return rows.map((row) => ({
      id: row.id,
      bookId: row.bookId,
      cfiRange: row.cfiRange,
      text: row.text,
      color: row.color,
      note: row.note,
      chapter: row.chapter,
      createdAt: toTimestamp(row.createdAt),
      updatedAt: toTimestamp(row.updatedAt),
      syncVersion: row.syncVersion,
      isDirty: true,
      isDeleted: row.isDeleted === 1
    }))
  }

  async getDirtyConversations(): Promise<SyncConversation[]> {
    const rows = (await window.electron.syncGetDirtyConversations()) as any[]

    return rows.map((row) => ({
      id: row.id,
      bookId: row.bookId,
      title: row.title,
      createdAt: toTimestamp(row.createdAt),
      updatedAt: toTimestamp(row.updatedAt),
      syncVersion: row.syncVersion,
      isDirty: true,
      isDeleted: row.isDeleted === 1
    }))
  }

  async getDirtyMessages(): Promise<SyncMessage[]> {
    const rows = (await window.electron.syncGetDirtyMessages()) as any[]

    return rows.map((row) => ({
      id: row.id,
      conversationId: row.conversationId,
      role: row.role,
      content: row.content,
      sourceChunks: row.sourceChunks,
      createdAt: toTimestamp(row.createdAt),
      updatedAt: toTimestamp(row.updatedAt),
      syncVersion: row.syncVersion,
      isDirty: true,
      isDeleted: row.isDeleted === 1
    }))
  }

  async getLastSyncVersion(): Promise<number> {
    return await window.electron.syncGetLastVersion()
  }

  // -- Conflict handlers --

  async applyBookConflict(c: Record<string, unknown>, syncVersion: number): Promise<void> {
    await window.electron.syncApplyBookConflict(c, syncVersion)
  }

  async applyHighlightConflict(c: Record<string, unknown>, syncVersion: number): Promise<void> {
    await window.electron.syncApplyHighlightConflict(c, syncVersion)
  }

  async applyConversationConflict(c: Record<string, unknown>, syncVersion: number): Promise<void> {
    await window.electron.syncApplyConversationConflict(c, syncVersion)
  }

  // -- Mark clean --

  async markBooksClean(ids: string[], syncVersion: number): Promise<void> {
    await window.electron.syncMarkBooksClean(ids, syncVersion)
  }

  async markHighlightsClean(ids: string[], syncVersion: number): Promise<void> {
    await window.electron.syncMarkHighlightsClean(ids, syncVersion)
  }

  async markConversationsClean(ids: string[], syncVersion: number): Promise<void> {
    await window.electron.syncMarkConversationsClean(ids, syncVersion)
  }

  async markMessagesClean(ids: string[], syncVersion: number): Promise<void> {
    await window.electron.syncMarkMessagesClean(ids, syncVersion)
  }

  // -- Pull: upsert remote records --

  async upsertRemoteBook(remote: Record<string, unknown>): Promise<void> {
    await window.electron.syncUpsertBook(remote)
  }

  async upsertRemoteHighlight(remote: Record<string, unknown>): Promise<void> {
    await window.electron.syncUpsertHighlight(remote)
  }

  async upsertRemoteConversation(remote: Record<string, unknown>): Promise<void> {
    await window.electron.syncUpsertConversation(remote)
  }

  async insertRemoteMessage(remote: Record<string, unknown>): Promise<void> {
    await window.electron.syncInsertMessage(remote)
  }

  async updateLastSyncVersion(version: number): Promise<void> {
    await window.electron.syncUpdateLastVersion(version)
  }
}
