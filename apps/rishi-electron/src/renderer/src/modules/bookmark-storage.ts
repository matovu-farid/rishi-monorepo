/**
 * Bookmark storage module using Electron IPC (window.electron.dbQuery/dbRun).
 * Mirrors the Tauri Kysely-based bookmark-storage.ts.
 */

export interface BookmarkRow {
  id: string;
  book_id: string;
  location: string;
  label: string | null;
  created_at: number;
  updated_at: number;
  sync_version: number;
  is_dirty: number;
  is_deleted: number;
}

/**
 * Extract the spine prefix from an EPUB CFI for fuzzy matching.
 * e.g. "epubcfi(/6/8!/4/2/2)" -> "epubcfi(/6/8!"
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

export async function getBookmarksForBook(bookSyncId: string): Promise<BookmarkRow[]> {
  return (await window.electron.dbQuery(
    `SELECT * FROM bookmarks WHERE book_id = ? AND is_deleted = 0 ORDER BY created_at DESC`,
    [bookSyncId]
  )) as BookmarkRow[];
}

export async function saveBookmark(params: {
  bookId: string;
  location: string;
  label?: string;
}): Promise<string> {
  const id = crypto.randomUUID();
  const now = Date.now();
  await window.electron.dbRun(
    `INSERT INTO bookmarks (id, book_id, location, label, created_at, updated_at, sync_version, is_dirty, is_deleted)
     VALUES (?, ?, ?, ?, ?, ?, 0, 1, 0)`,
    [id, params.bookId, params.location, params.label ?? null, now, now]
  );
  return id;
}

export async function deleteBookmark(bookmarkId: string): Promise<void> {
  await window.electron.dbRun(
    `UPDATE bookmarks SET is_deleted = 1, is_dirty = 1, updated_at = ? WHERE id = ?`,
    [Date.now(), bookmarkId]
  );
}

export async function toggleBookmark(params: {
  bookSyncId: string;
  location: string;
  label?: string;
}): Promise<{ action: 'created' | 'deleted' }> {
  const allBookmarks = await getBookmarksForBook(params.bookSyncId);
  const matching = allBookmarks.filter(b => locationsMatch(b.location, params.location));

  if (matching.length > 0) {
    for (const bookmark of matching) {
      await deleteBookmark(bookmark.id);
    }
    return { action: 'deleted' };
  }

  await saveBookmark({ bookId: params.bookSyncId, location: params.location, label: params.label });
  return { action: 'created' };
}
