/**
 * Sync adapter -- uses Electron IPC (window.electron.dbQuery/dbRun) for DB access.
 * Mirrors the Tauri version's SyncDbAdapter interface from @rishi/shared/sync-adapter.
 */
import type {
  SyncDbAdapter,
  SyncBook,
  SyncHighlight,
  SyncConversation,
  SyncMessage,
} from "@rishi/shared/sync-adapter";

/** Safely coerce a DB timestamp value (Date, number, or string) to epoch ms. */
function toTimestamp(val: unknown): number {
  if (val instanceof Date) return val.getTime();
  if (typeof val === "number") return val;
  if (typeof val === "string") return new Date(val).getTime();
  return Date.now();
}

export class DesktopSyncAdapter implements SyncDbAdapter {
  async getDirtyBooks(): Promise<SyncBook[]> {
    const rows = (await window.electron.dbQuery(
      "SELECT * FROM books WHERE is_dirty = 1 AND sync_id IS NOT NULL"
    )) as any[];

    return rows.map((row) => ({
      id: row.sync_id!,
      title: row.title,
      author: row.author,
      format: row.format ?? row.kind,
      currentCfi: row.current_cfi,
      currentPage: row.current_page,
      fileHash: row.file_hash,
      fileR2Key: row.file_r2_key,
      coverR2Key: row.cover_r2_key,
      createdAt: toTimestamp(row.created_at),
      updatedAt: toTimestamp(row.updated_at),
      syncVersion: row.sync_version,
      isDirty: true,
      isDeleted: row.is_deleted === 1,
    }));
  }

  async getDirtyHighlights(): Promise<SyncHighlight[]> {
    const rows = (await window.electron.dbQuery(
      "SELECT * FROM highlights WHERE is_dirty = 1"
    )) as any[];

    return rows.map((row) => ({
      id: row.id,
      bookId: row.book_id,
      cfiRange: row.cfi_range,
      text: row.text,
      color: row.color,
      note: row.note,
      chapter: row.chapter,
      createdAt: toTimestamp(row.created_at),
      updatedAt: toTimestamp(row.updated_at),
      syncVersion: row.sync_version,
      isDirty: true,
      isDeleted: row.is_deleted === 1,
    }));
  }

  async getDirtyConversations(): Promise<SyncConversation[]> {
    const rows = (await window.electron.dbQuery(
      "SELECT * FROM conversations WHERE is_dirty = 1"
    )) as any[];

    return rows.map((row) => ({
      id: row.id,
      bookId: row.book_id,
      title: row.title,
      createdAt: toTimestamp(row.created_at),
      updatedAt: toTimestamp(row.updated_at),
      syncVersion: row.sync_version,
      isDirty: true,
      isDeleted: row.is_deleted === 1,
    }));
  }

  async getDirtyMessages(): Promise<SyncMessage[]> {
    const rows = (await window.electron.dbQuery(
      "SELECT * FROM messages WHERE is_dirty = 1"
    )) as any[];

    return rows.map((row) => ({
      id: row.id,
      conversationId: row.conversation_id,
      role: row.role,
      content: row.content,
      sourceChunks: row.source_chunks,
      createdAt: toTimestamp(row.created_at),
      updatedAt: toTimestamp(row.updated_at),
      syncVersion: row.sync_version,
      isDirty: true,
      isDeleted: row.is_deleted === 1,
    }));
  }

  async getLastSyncVersion(): Promise<number> {
    const rows = (await window.electron.dbQuery(
      "SELECT last_sync_version FROM sync_meta WHERE id = 'default'"
    )) as any[];
    return rows.length > 0 ? (rows[0].last_sync_version ?? 0) : 0;
  }

  // -- Conflict handlers --

  async applyBookConflict(
    c: Record<string, unknown>,
    syncVersion: number
  ): Promise<void> {
    const syncId = c.id as string;
    await window.electron.dbRun(
      `UPDATE books SET title = ?, author = ?, format = ?, current_cfi = ?, current_page = ?,
       file_hash = ?, file_r2_key = ?, cover_r2_key = ?, sync_version = ?, is_dirty = 0,
       is_deleted = ? WHERE sync_id = ?`,
      [
        c.title as string,
        c.author as string,
        c.format as string,
        (c.currentCfi as string) ?? null,
        (c.currentPage as number) ?? null,
        (c.fileHash as string) ?? null,
        (c.fileR2Key as string) ?? null,
        (c.coverR2Key as string) ?? null,
        syncVersion,
        (c.isDeleted as boolean) ? 1 : 0,
        syncId,
      ]
    );
  }

  async applyHighlightConflict(
    c: Record<string, unknown>,
    syncVersion: number
  ): Promise<void> {
    await window.electron.dbRun(
      `UPDATE highlights SET text = ?, color = ?, note = ?, chapter = ?, cfi_range = ?,
       sync_version = ?, is_dirty = 0, is_deleted = ? WHERE id = ?`,
      [
        c.text as string,
        c.color as string,
        (c.note as string) ?? null,
        (c.chapter as string) ?? null,
        c.cfiRange as string,
        syncVersion,
        (c.isDeleted as boolean) ? 1 : 0,
        c.id as string,
      ]
    );
  }

  async applyConversationConflict(
    c: Record<string, unknown>,
    syncVersion: number
  ): Promise<void> {
    await window.electron.dbRun(
      `UPDATE conversations SET title = ?, book_id = ?, sync_version = ?, is_dirty = 0,
       is_deleted = ? WHERE id = ?`,
      [
        c.title as string,
        c.bookId as string,
        syncVersion,
        (c.isDeleted as boolean) ? 1 : 0,
        c.id as string,
      ]
    );
  }

  // -- Mark clean --

  async markBooksClean(ids: string[], syncVersion: number): Promise<void> {
    for (const syncId of ids) {
      await window.electron.dbRun(
        `UPDATE books SET is_dirty = 0, sync_version = ? WHERE sync_id = ?`,
        [syncVersion, syncId]
      );
    }
  }

  async markHighlightsClean(ids: string[], syncVersion: number): Promise<void> {
    for (const id of ids) {
      await window.electron.dbRun(
        `UPDATE highlights SET is_dirty = 0, sync_version = ? WHERE id = ?`,
        [syncVersion, id]
      );
    }
  }

  async markConversationsClean(ids: string[], syncVersion: number): Promise<void> {
    for (const id of ids) {
      await window.electron.dbRun(
        `UPDATE conversations SET is_dirty = 0, sync_version = ? WHERE id = ?`,
        [syncVersion, id]
      );
    }
  }

  async markMessagesClean(ids: string[], syncVersion: number): Promise<void> {
    for (const id of ids) {
      await window.electron.dbRun(
        `UPDATE messages SET is_dirty = 0, sync_version = ? WHERE id = ?`,
        [syncVersion, id]
      );
    }
  }

  // -- Pull: upsert remote records --

  async upsertRemoteBook(remote: Record<string, unknown>): Promise<void> {
    const syncId = remote.id as string;
    if (!syncId) return;

    const rows = (await window.electron.dbQuery(
      "SELECT * FROM books WHERE sync_id = ?",
      [syncId]
    )) as any[];
    const local = rows.length > 0 ? rows[0] : null;

    if (local) {
      if (local.is_dirty === 1) return; // locally dirty takes precedence

      const title = typeof remote.title === "string" ? remote.title : (local.title ?? "");
      const author = typeof remote.author === "string" ? remote.author : (local.author ?? "");
      const format = typeof remote.format === "string" ? remote.format : (local.format ?? local.kind ?? "epub");

      await window.electron.dbRun(
        `UPDATE books SET title = ?, author = ?, format = ?, current_cfi = ?, current_page = ?,
         file_hash = ?, file_r2_key = ?, cover_r2_key = ?, sync_version = ?, is_dirty = 0,
         is_deleted = ? WHERE sync_id = ?`,
        [
          title, author, format,
          (remote.currentCfi as string) ?? null,
          (remote.currentPage as number) ?? null,
          (remote.fileHash as string) ?? null,
          (remote.fileR2Key as string) ?? null,
          (remote.coverR2Key as string) ?? null,
          (remote.syncVersion as number) ?? 0,
          (remote.isDeleted as boolean) ? 1 : 0,
          syncId,
        ]
      );
    } else {
      // New remote book -- insert with empty local file (needs download)
      const newTitle = typeof remote.title === "string" ? remote.title : "Unknown";
      const newAuthor = typeof remote.author === "string" ? remote.author : "Unknown";
      const newFormat = typeof remote.format === "string" ? remote.format : "epub";

      await window.electron.dbRun(
        `INSERT INTO books (kind, cover, title, author, publisher, filepath, location, cover_kind,
         version, sync_id, format, current_cfi, current_page, file_hash, file_r2_key, cover_r2_key,
         sync_version, is_dirty, is_deleted)
         VALUES (?, X'', ?, ?, '', '', ?, '', 0, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)`,
        [
          newFormat, newTitle, newAuthor,
          (remote.currentCfi as string) ?? "",
          syncId, newFormat,
          (remote.currentCfi as string) ?? null,
          (remote.currentPage as number) ?? null,
          (remote.fileHash as string) ?? null,
          (remote.fileR2Key as string) ?? null,
          (remote.coverR2Key as string) ?? null,
          (remote.syncVersion as number) ?? 0,
          (remote.isDeleted as boolean) ? 1 : 0,
        ]
      );
    }
  }

  async upsertRemoteHighlight(remote: Record<string, unknown>): Promise<void> {
    const remoteId = remote.id as string;
    if (!remoteId) return;

    const rows = (await window.electron.dbQuery(
      "SELECT * FROM highlights WHERE id = ?",
      [remoteId]
    )) as any[];
    const local = rows.length > 0 ? rows[0] : null;

    if (local) {
      if (local.is_dirty === 1) return;
      const remoteUpdatedAt = (remote.updatedAt as number) ?? 0;
      if (remoteUpdatedAt < local.updated_at) return; // LWW guard

      const hlText = typeof remote.text === "string" ? remote.text : (local.text ?? "");
      const hlColor = typeof remote.color === "string" ? remote.color : (local.color ?? "yellow");

      await window.electron.dbRun(
        `UPDATE highlights SET text = ?, color = ?, note = ?, chapter = ?, cfi_range = ?,
         book_id = ?, created_at = ?, updated_at = ?, sync_version = ?, is_dirty = 0,
         is_deleted = ? WHERE id = ?`,
        [
          hlText, hlColor,
          (remote.note as string) ?? null,
          (remote.chapter as string) ?? null,
          remote.cfiRange as string,
          remote.bookId as string,
          remote.createdAt as number,
          remote.updatedAt as number,
          (remote.syncVersion as number) ?? 0,
          (remote.isDeleted as boolean) ? 1 : 0,
          remoteId,
        ]
      );
    } else {
      await window.electron.dbRun(
        `INSERT INTO highlights (id, book_id, text, color, note, chapter, cfi_range,
         created_at, updated_at, sync_version, is_dirty, is_deleted)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)`,
        [
          remoteId,
          (remote.bookId as string) ?? "",
          (remote.text as string) ?? "",
          (remote.color as string) ?? "yellow",
          (remote.note as string) ?? null,
          (remote.chapter as string) ?? null,
          (remote.cfiRange as string) ?? "",
          (remote.createdAt as number) ?? Date.now(),
          (remote.updatedAt as number) ?? Date.now(),
          (remote.syncVersion as number) ?? 0,
          (remote.isDeleted as boolean) ? 1 : 0,
        ]
      );
    }
  }

  async upsertRemoteConversation(remote: Record<string, unknown>): Promise<void> {
    const remoteId = remote.id as string;
    if (!remoteId) return;

    const rows = (await window.electron.dbQuery(
      "SELECT * FROM conversations WHERE id = ?",
      [remoteId]
    )) as any[];
    const local = rows.length > 0 ? rows[0] : null;

    if (local) {
      if (local.is_dirty === 1) return;
      const remoteUpdatedAt = (remote.updatedAt as number) ?? 0;
      if (remoteUpdatedAt < local.updated_at) return;

      const convTitle = typeof remote.title === "string" ? remote.title : (local.title ?? "New conversation");
      const convBookId = typeof remote.bookId === "string" ? remote.bookId : (local.book_id ?? "");

      await window.electron.dbRun(
        `UPDATE conversations SET title = ?, book_id = ?, created_at = ?, updated_at = ?,
         sync_version = ?, is_dirty = 0, is_deleted = ? WHERE id = ?`,
        [
          convTitle, convBookId,
          remote.createdAt as number,
          remote.updatedAt as number,
          (remote.syncVersion as number) ?? 0,
          (remote.isDeleted as boolean) ? 1 : 0,
          remoteId,
        ]
      );
    } else {
      await window.electron.dbRun(
        `INSERT INTO conversations (id, book_id, title, created_at, updated_at,
         sync_version, is_dirty, is_deleted)
         VALUES (?, ?, ?, ?, ?, ?, 0, ?)`,
        [
          remoteId,
          (remote.bookId as string) ?? "",
          (remote.title as string) ?? "New conversation",
          (remote.createdAt as number) ?? Date.now(),
          (remote.updatedAt as number) ?? Date.now(),
          (remote.syncVersion as number) ?? 0,
          (remote.isDeleted as boolean) ? 1 : 0,
        ]
      );
    }
  }

  async insertRemoteMessage(remote: Record<string, unknown>): Promise<void> {
    const remoteId = remote.id as string;
    if (!remoteId) return;

    const rows = (await window.electron.dbQuery(
      "SELECT id FROM messages WHERE id = ?",
      [remoteId]
    )) as any[];
    if (rows.length > 0) return; // append-only: never update existing messages

    const msgConvId = typeof remote.conversationId === "string" ? remote.conversationId : "";
    const msgRole = typeof remote.role === "string" ? remote.role : "user";
    const msgContent = typeof remote.content === "string" ? remote.content : "";

    await window.electron.dbRun(
      `INSERT INTO messages (id, conversation_id, role, content, source_chunks,
       created_at, updated_at, sync_version, is_dirty, is_deleted)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)`,
      [
        remoteId,
        msgConvId,
        msgRole,
        msgContent,
        (remote.sourceChunks as string) ?? null,
        (remote.createdAt as number) ?? Date.now(),
        (remote.updatedAt as number) ?? Date.now(),
        (remote.syncVersion as number) ?? 0,
        (remote.isDeleted as boolean) ? 1 : 0,
      ]
    );
  }

  async updateLastSyncVersion(version: number): Promise<void> {
    await window.electron.dbRun(
      `UPDATE sync_meta SET last_sync_version = ?, last_sync_at = ? WHERE id = 'default'`,
      [version, Date.now()]
    );
  }
}
