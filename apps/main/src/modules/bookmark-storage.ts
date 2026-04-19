import { db } from './kysley';

/**
 * Extract the spine prefix from an EPUB CFI for fuzzy matching.
 * e.g. "epubcfi(/6/8!/4/2/2)" → "epubcfi(/6/8!"
 * Returns null for non-EPUB locations (page numbers etc).
 */
export function getSpinePrefix(location: string): string | null {
  if (!location.startsWith('epubcfi(')) return null;
  const bangIndex = location.indexOf('!');
  if (bangIndex === -1) return null;
  return location.slice(0, bangIndex + 1);
}

export function locationsMatch(a: string, b: string): boolean {
  const prefixA = getSpinePrefix(a);
  const prefixB = getSpinePrefix(b);
  if (prefixA && prefixB) {
    return prefixA === prefixB;
  }
  return a === b;
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

export async function deleteBookmark(bookmarkId: string): Promise<void> {
  await db.updateTable('bookmarks')
    .set({ is_deleted: 1, is_dirty: 1, updated_at: Date.now() })
    .where('id', '=', bookmarkId)
    .execute();
}

export async function toggleBookmark(params: {
  bookSyncId: string;
  location: string;
  label?: string;
}): Promise<{ action: 'created' | 'deleted' }> {
  // Fetch all bookmarks once
  const allBookmarks = await getBookmarksForBook(params.bookSyncId);

  // Find ALL that match this location (cleans up duplicates)
  const matching = allBookmarks.filter(b => locationsMatch(b.location, params.location));

  if (matching.length > 0) {
    // Delete all matching (handles duplicates)
    for (const bookmark of matching) {
      await deleteBookmark(bookmark.id);
    }
    return { action: 'deleted' };
  }

  await saveBookmark(params);
  return { action: 'created' };
}
