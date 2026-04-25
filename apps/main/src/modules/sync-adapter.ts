import { db } from "./kysley";
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
    const rows = await db
      .selectFrom("books")
      .selectAll()
      .where("is_dirty", "=", 1)
      .where("sync_id", "is not", null)
      .execute();

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
    const rows = await db
      .selectFrom("highlights")
      .selectAll()
      .where("is_dirty", "=", 1)
      .execute();

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
    const rows = await db
      .selectFrom("conversations")
      .selectAll()
      .where("is_dirty", "=", 1)
      .execute();

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
    const rows = await db
      .selectFrom("messages")
      .selectAll()
      .where("is_dirty", "=", 1)
      .execute();

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
    const row = await db
      .selectFrom("sync_meta")
      .select("last_sync_version")
      .where("id", "=", "default")
      .executeTakeFirst();
    return row?.last_sync_version ?? 0;
  }

  // -- Conflict handlers --

  async applyBookConflict(
    c: Record<string, unknown>,
    syncVersion: number,
  ): Promise<void> {
    const syncId = c.id as string;
    await db
      .updateTable("books")
      .set({
        title: c.title as string,
        author: c.author as string,
        format: c.format as string,
        current_cfi: (c.currentCfi as string) ?? null,
        current_page: (c.currentPage as number) ?? null,
        file_hash: (c.fileHash as string) ?? null,
        file_r2_key: (c.fileR2Key as string) ?? null,
        cover_r2_key: (c.coverR2Key as string) ?? null,
        sync_version: syncVersion,
        is_dirty: 0,
        is_deleted: (c.isDeleted as boolean) ? 1 : 0,
      })
      .where("sync_id", "=", syncId)
      .execute();
  }

  async applyHighlightConflict(
    c: Record<string, unknown>,
    syncVersion: number,
  ): Promise<void> {
    await db
      .updateTable("highlights")
      .set({
        text: c.text as string,
        color: c.color as string,
        note: (c.note as string) ?? null,
        chapter: (c.chapter as string) ?? null,
        cfi_range: c.cfiRange as string,
        sync_version: syncVersion,
        is_dirty: 0,
        is_deleted: (c.isDeleted as boolean) ? 1 : 0,
      })
      .where("id", "=", c.id as string)
      .execute();
  }

  async applyConversationConflict(
    c: Record<string, unknown>,
    syncVersion: number,
  ): Promise<void> {
    await db
      .updateTable("conversations")
      .set({
        title: c.title as string,
        book_id: c.bookId as string,
        sync_version: syncVersion,
        is_dirty: 0,
        is_deleted: (c.isDeleted as boolean) ? 1 : 0,
      })
      .where("id", "=", c.id as string)
      .execute();
  }

  // -- Mark clean --

  async markBooksClean(
    ids: string[],
    syncVersion: number,
  ): Promise<void> {
    for (const syncId of ids) {
      await db
        .updateTable("books")
        .set({ is_dirty: 0, sync_version: syncVersion })
        .where("sync_id", "=", syncId)
        .execute();
    }
  }

  async markHighlightsClean(
    ids: string[],
    syncVersion: number,
  ): Promise<void> {
    for (const id of ids) {
      await db
        .updateTable("highlights")
        .set({ is_dirty: 0, sync_version: syncVersion })
        .where("id", "=", id)
        .execute();
    }
  }

  async markConversationsClean(
    ids: string[],
    syncVersion: number,
  ): Promise<void> {
    for (const id of ids) {
      await db
        .updateTable("conversations")
        .set({ is_dirty: 0, sync_version: syncVersion })
        .where("id", "=", id)
        .execute();
    }
  }

  async markMessagesClean(
    ids: string[],
    syncVersion: number,
  ): Promise<void> {
    for (const id of ids) {
      await db
        .updateTable("messages")
        .set({ is_dirty: 0, sync_version: syncVersion })
        .where("id", "=", id)
        .execute();
    }
  }

  // -- Pull: upsert remote records --

  async upsertRemoteBook(remote: Record<string, unknown>): Promise<void> {
    const syncId = remote.id as string;
    if (!syncId) return;

    // Check if book exists by sync_id
    const local = await db
      .selectFrom("books")
      .selectAll()
      .where("sync_id", "=", syncId)
      .executeTakeFirst();

    if (local) {
      if (local.is_dirty === 1) return; // locally dirty takes precedence

      const title = typeof remote.title === 'string' ? remote.title : (local.title ?? '');
      const author = typeof remote.author === 'string' ? remote.author : (local.author ?? '');
      const format = typeof remote.format === 'string' ? remote.format : (local.format ?? local.kind ?? 'epub');

      await db
        .updateTable("books")
        .set({
          title,
          author,
          format,
          current_cfi: (remote.currentCfi as string) ?? null,
          current_page: (remote.currentPage as number) ?? null,
          file_hash: (remote.fileHash as string) ?? null,
          file_r2_key: (remote.fileR2Key as string) ?? null,
          cover_r2_key: (remote.coverR2Key as string) ?? null,
          sync_version: (remote.syncVersion as number) ?? 0,
          is_dirty: 0,
          is_deleted: (remote.isDeleted as boolean) ? 1 : 0,
        })
        .where("sync_id", "=", syncId)
        .execute();
    } else {
      // New remote book -- insert with empty local file (needs download)
      const newTitle = typeof remote.title === 'string' ? remote.title : 'Unknown';
      const newAuthor = typeof remote.author === 'string' ? remote.author : 'Unknown';
      const newFormat = typeof remote.format === 'string' ? remote.format : 'epub';

      await db
        .insertInto("books")
        .values({
          kind: newFormat,
          cover: new Uint8Array(0) as unknown as number[],
          title: newTitle,
          author: newAuthor,
          publisher: "",
          filepath: "", // no local file yet
          location: (remote.currentCfi as string) ?? "",
          cover_kind: "",
          version: 0,
          sync_id: syncId,
          format: newFormat,
          current_cfi: (remote.currentCfi as string) ?? null,
          current_page: (remote.currentPage as number) ?? null,
          file_hash: (remote.fileHash as string) ?? null,
          file_r2_key: (remote.fileR2Key as string) ?? null,
          cover_r2_key: (remote.coverR2Key as string) ?? null,
          sync_version: (remote.syncVersion as number) ?? 0,
          is_dirty: 0,
          is_deleted: (remote.isDeleted as boolean) ? 1 : 0,
        })
        .execute();
    }
  }

  async upsertRemoteHighlight(
    remote: Record<string, unknown>,
  ): Promise<void> {
    const remoteId = remote.id as string;
    if (!remoteId) return;

    const local = await db
      .selectFrom("highlights")
      .selectAll()
      .where("id", "=", remoteId)
      .executeTakeFirst();

    if (local) {
      if (local.is_dirty === 1) return;
      const remoteUpdatedAt = (remote.updatedAt as number) ?? 0;
      if (remoteUpdatedAt < local.updated_at) return; // LWW guard

      const hlText = typeof remote.text === 'string' ? remote.text : (local.text ?? '');
      const hlColor = typeof remote.color === 'string' ? remote.color : (local.color ?? 'yellow');

      await db
        .updateTable("highlights")
        .set({
          text: hlText,
          color: hlColor,
          note: (remote.note as string) ?? null,
          chapter: (remote.chapter as string) ?? null,
          cfi_range: remote.cfiRange as string,
          book_id: remote.bookId as string,
          created_at: remote.createdAt as number,
          updated_at: remote.updatedAt as number,
          sync_version: (remote.syncVersion as number) ?? 0,
          is_dirty: 0,
          is_deleted: (remote.isDeleted as boolean) ? 1 : 0,
        })
        .where("id", "=", remoteId)
        .execute();
    } else {
      await db
        .insertInto("highlights")
        .values({
          id: remoteId,
          book_id: (remote.bookId as string) ?? "",
          text: (remote.text as string) ?? "",
          color: (remote.color as string) ?? "yellow",
          note: (remote.note as string) ?? null,
          chapter: (remote.chapter as string) ?? null,
          cfi_range: (remote.cfiRange as string) ?? "",
          created_at: (remote.createdAt as number) ?? Date.now(),
          updated_at: (remote.updatedAt as number) ?? Date.now(),
          sync_version: (remote.syncVersion as number) ?? 0,
          is_dirty: 0,
          is_deleted: (remote.isDeleted as boolean) ? 1 : 0,
        })
        .execute();
    }
  }

  async upsertRemoteConversation(
    remote: Record<string, unknown>,
  ): Promise<void> {
    const remoteId = remote.id as string;
    if (!remoteId) return;

    const local = await db
      .selectFrom("conversations")
      .selectAll()
      .where("id", "=", remoteId)
      .executeTakeFirst();

    if (local) {
      if (local.is_dirty === 1) return;
      const remoteUpdatedAt = (remote.updatedAt as number) ?? 0;
      if (remoteUpdatedAt < local.updated_at) return;

      const convTitle = typeof remote.title === 'string' ? remote.title : (local.title ?? 'New conversation');
      const convBookId = typeof remote.bookId === 'string' ? remote.bookId : (local.book_id ?? '');

      await db
        .updateTable("conversations")
        .set({
          title: convTitle,
          book_id: convBookId,
          created_at: remote.createdAt as number,
          updated_at: remote.updatedAt as number,
          sync_version: (remote.syncVersion as number) ?? 0,
          is_dirty: 0,
          is_deleted: (remote.isDeleted as boolean) ? 1 : 0,
        })
        .where("id", "=", remoteId)
        .execute();
    } else {
      await db
        .insertInto("conversations")
        .values({
          id: remoteId,
          book_id: (remote.bookId as string) ?? "",
          title: (remote.title as string) ?? "New conversation",
          created_at: (remote.createdAt as number) ?? Date.now(),
          updated_at: (remote.updatedAt as number) ?? Date.now(),
          sync_version: (remote.syncVersion as number) ?? 0,
          is_dirty: 0,
          is_deleted: (remote.isDeleted as boolean) ? 1 : 0,
        })
        .execute();
    }
  }

  async insertRemoteMessage(
    remote: Record<string, unknown>,
  ): Promise<void> {
    const remoteId = remote.id as string;
    if (!remoteId) return;

    const local = await db
      .selectFrom("messages")
      .selectAll()
      .where("id", "=", remoteId)
      .executeTakeFirst();

    if (local) return; // append-only: never update existing messages

    const msgConvId = typeof remote.conversationId === 'string' ? remote.conversationId : '';
    const msgRole = typeof remote.role === 'string' ? remote.role : 'user';
    const msgContent = typeof remote.content === 'string' ? remote.content : '';

    await db
      .insertInto("messages")
      .values({
        id: remoteId,
        conversation_id: msgConvId,
        role: msgRole,
        content: msgContent,
        source_chunks: (remote.sourceChunks as string) ?? null,
        created_at: (remote.createdAt as number) ?? Date.now(),
        updated_at: (remote.updatedAt as number) ?? Date.now(),
        sync_version: (remote.syncVersion as number) ?? 0,
        is_dirty: 0,
        is_deleted: (remote.isDeleted as boolean) ? 1 : 0,
      })
      .execute();
  }

  async updateLastSyncVersion(version: number): Promise<void> {
    await db
      .updateTable("sync_meta")
      .set({
        last_sync_version: version,
        last_sync_at: Date.now(),
      })
      .where("id", "=", "default")
      .execute();
  }
}
