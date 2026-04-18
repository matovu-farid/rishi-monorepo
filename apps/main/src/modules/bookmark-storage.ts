import { db } from './kysley';

export async function saveBookmark(params: {
  bookSyncId: string;
  location: string;
  label?: string;
}): Promise<string> {
  const id = crypto.randomUUID();
  const now = Date.now();

  await db.insertInto('bookmarks')
    .values({
      id,
      book_id: params.bookSyncId,
      location: params.location,
      label: params.label ?? null,
      created_at: now,
      updated_at: now,
      sync_version: 0,
      is_dirty: 1,
      is_deleted: 0,
    })
    .execute();

  return id;
}

export async function getBookmarksForBook(bookSyncId: string) {
  return db
    .selectFrom('bookmarks')
    .selectAll()
    .where('book_id', '=', bookSyncId)
    .where('is_deleted', '=', 0)
    .orderBy('created_at', 'desc')
    .execute();
}

export async function deleteBookmark(bookmarkId: string): Promise<void> {
  await db.updateTable('bookmarks')
    .set({ is_deleted: 1, is_dirty: 1, updated_at: Date.now() })
    .where('id', '=', bookmarkId)
    .execute();
}

export async function getBookmarkAtLocation(bookSyncId: string, location: string) {
  return db
    .selectFrom('bookmarks')
    .selectAll()
    .where('book_id', '=', bookSyncId)
    .where('location', '=', location)
    .where('is_deleted', '=', 0)
    .executeTakeFirst();
}

export async function toggleBookmark(params: {
  bookSyncId: string;
  location: string;
  label?: string;
}): Promise<{ action: 'created' | 'deleted'; id: string }> {
  const existing = await getBookmarkAtLocation(params.bookSyncId, params.location);

  if (existing) {
    await deleteBookmark(existing.id);
    return { action: 'deleted', id: existing.id };
  }

  const id = await saveBookmark(params);
  return { action: 'created', id };
}
