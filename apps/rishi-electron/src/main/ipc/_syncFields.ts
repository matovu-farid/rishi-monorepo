/**
 * Sync-tracking column defaults shared by IPC handlers that insert into
 * sync-aware tables (bookmarks, highlights, conversations, messages).
 *
 * New rows are always dirty (need to be pushed) with syncVersion 0 and
 * isDeleted 0. Tombstones flip isDeleted=1 + isDirty=1 so the sync engine
 * propagates the deletion.
 */
export const defaultSyncFields = {
  syncVersion: 0,
  isDirty: 1,
  isDeleted: 0
} as const

/** Soft-delete patch: marks the row deleted, dirty, and stamps `updatedAt`. */
export function softDeleteFields(): { isDeleted: 1; isDirty: 1; updatedAt: number } {
  return { isDeleted: 1, isDirty: 1, updatedAt: Date.now() }
}
