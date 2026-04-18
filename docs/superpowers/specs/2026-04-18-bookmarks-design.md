# Bookmarks Feature — Design Spec

Apple Books-style bookmarks across all book formats (epub, pdf, mobi, djvu) with cross-device sync.

## Database Schema

New `bookmarks` table following the same sync pattern as `highlights`:

```sql
CREATE TABLE bookmarks (
    id TEXT PRIMARY KEY NOT NULL,           -- UUID v4
    book_id TEXT NOT NULL,                  -- books.sync_id (not integer id)
    user_id TEXT,
    location TEXT NOT NULL,                 -- format-opaque: CFI, page number, or chapter index
    label TEXT,                             -- auto-generated display label
    created_at INTEGER NOT NULL DEFAULT 0,  -- milliseconds
    updated_at INTEGER NOT NULL DEFAULT 0,  -- milliseconds
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
);
```

The `location` field stores the same value as `book.location` at bookmark time — CFI for epub, page number string for pdf/djvu, chapter index string for mobi. The bookmark system treats this opaquely.

The `label` field is auto-generated at creation time for display in the bookmark list:
- **EPUB**: Chapter name from the current TOC entry
- **PDF**: "Page {n}"
- **MOBI**: "Chapter {n}"
- **DJVU**: "Page {n}"

## Kysely Schema Addition

Add to the `DB` interface in `modules/kysley.ts`:

```typescript
bookmarks: {
    id: string;
    book_id: string;
    user_id: string | null;
    location: string;
    label: string | null;
    created_at: number;
    updated_at: number;
    sync_version: number;
    is_dirty: number;
    is_deleted: number;
};
```

## Storage Layer

New file: `modules/bookmark-storage.ts` — mirrors `highlight-storage.ts`:

- `saveBookmark(params: { bookSyncId, location, label? })` — insert with UUID, returns id
- `getBookmarksForBook(bookSyncId)` — returns all non-deleted bookmarks, sorted by created_at desc
- `deleteBookmark(id)` — soft-delete (is_deleted=1, is_dirty=1)
- `getBookmarkAtLocation(bookSyncId, location)` — check if current page/location is bookmarked
- `toggleBookmark(params)` — if exists at location, delete it; otherwise create it. Returns the new state.

## UI Components

### 1. BookmarkButton

Shared component used by all reader views. Placed in the top bar next to existing icons.

```
Props:
  - bookSyncId: string
  - location: string        — current reading position
  - format: string           — 'epub' | 'pdf' | 'mobi' | 'djvu'
  - label?: string           — auto-generated display label
```

Behavior:
- Renders a `Bookmark` icon from lucide-react
- **Gray outline** when current location is not bookmarked
- **Filled red** when current location is bookmarked
- Tap toggles the bookmark on/off via `toggleBookmark()`
- Queries bookmark state via React Query (`useQuery` with key `["bookmark", bookSyncId, location]`)

### 2. BookmarksList

Panel shown as a tab inside the TOC sidebar sheet.

```
Props:
  - bookSyncId: string
  - onNavigate: (location: string) => void
```

Behavior:
- Fetches bookmarks via React Query (`useQuery` with key `["bookmarks", bookSyncId]`)
- Each item shows: red bookmark icon, label text, date
- Tap navigates to the bookmarked location
- Swipe-to-delete or delete button removes the bookmark
- Empty state: "No bookmarks yet"

### 3. TOC Sidebar Tabs

Modify the existing TOC sidebar sheet (hamburger menu) in all reader views to include tabs:
- **Contents** tab — existing TOC/Outline (default)
- **Bookmarks** tab — BookmarksList component

Use a simple tab bar at the top of the sheet content.

## Integration Points

### PDF Reader (`pdf.tsx`)
- Add `BookmarkButton` to the top bar (between grid icon and Back button)
- Pass `location = String(pageNumber)`, `label = "Page {pageNumber}"`
- Add tabs to the TOC sidebar sheet
- `onNavigate`: scroll virtualizer to the bookmarked page

### EPUB Reader (`epub.tsx`)
- Add `BookmarkButton` to the reader toolbar
- Pass `location = currentEpubLocation` (CFI), `label = current chapter name`
- Add tabs to any existing TOC/menu panel
- `onNavigate`: call `rendition.display(cfi)`

### MOBI Reader (`MobiView.tsx`)
- Add `BookmarkButton` to the toolbar
- Pass `location = String(chapterIndex)`, `label = "Chapter {chapterIndex + 1}"`
- `onNavigate`: set chapter index to bookmarked value

### DJVU Reader (`DjvuView.tsx`)
- Add `BookmarkButton` to the toolbar
- Pass `location = String(currentPage)`, `label = "Page {currentPage}"`
- `onNavigate`: set current page to bookmarked value

## Diesel Migration

New migration `YYYY-MM-DD-000000_add_bookmarks/up.sql`:

```sql
CREATE TABLE bookmarks (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    location TEXT NOT NULL,
    label TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
);
```

`down.sql`:
```sql
DROP TABLE bookmarks;
```

After creating the migration, run `diesel migration run` to update `schema.rs` and `models.rs`.

## Sync

Bookmarks follow the same sync protocol as highlights:
- `is_dirty = 1` on create/update/delete
- `sync_version` incremented by the sync server
- Soft deletes only (`is_deleted = 1`)
- Uses `book_id = books.sync_id` for cross-device consistency

No additional sync backend work is needed beyond registering the `bookmarks` table in the existing sync flow.

## Files to Create/Modify

**New files:**
- `src-tauri/migrations/YYYY-MM-DD-000000_add_bookmarks/up.sql`
- `src-tauri/migrations/YYYY-MM-DD-000000_add_bookmarks/down.sql`
- `src/modules/bookmark-storage.ts`
- `src/components/bookmarks/BookmarkButton.tsx`
- `src/components/bookmarks/BookmarksList.tsx`

**Modified files:**
- `src/modules/kysley.ts` — add bookmarks table to DB interface
- `src/components/pdf/components/pdf.tsx` — add BookmarkButton + tabs in TOC sidebar
- `src/components/epub.tsx` — add BookmarkButton + tabs
- `src/components/mobi/MobiView.tsx` — add BookmarkButton + tabs
- `src/components/djvu/DjvuView.tsx` — add BookmarkButton + tabs
- `src-tauri/src/schema.rs` — auto-generated by diesel migration
- `src-tauri/src/models.rs` — add Bookmarks struct
