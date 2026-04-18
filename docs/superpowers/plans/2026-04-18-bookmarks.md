# Bookmarks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Apple Books-style bookmarks across all book formats (epub, pdf, mobi, djvu) with cross-device sync.

**Architecture:** New `bookmarks` SQLite table following the highlights sync pattern. A `bookmark-storage.ts` module provides CRUD via Kysely. Two shared React components — `BookmarkButton` (toggle in toolbar) and `BookmarksList` (tab in TOC sidebar) — are integrated into each reader view.

**Tech Stack:** SQLite (Diesel migrations), Kysely (TypeScript queries), React + React Query, Zustand stores, lucide-react icons.

---

## File Structure

**New files:**
- `src-tauri/migrations/2026-04-18-000000_add_bookmarks/up.sql` — create bookmarks table
- `src-tauri/migrations/2026-04-18-000000_add_bookmarks/down.sql` — drop bookmarks table
- `src/modules/bookmark-storage.ts` — Kysely CRUD functions
- `src/modules/bookmark-storage.test.ts` — unit tests for storage layer
- `src/components/bookmarks/BookmarkButton.tsx` — toggle bookmark icon
- `src/components/bookmarks/BookmarksList.tsx` — list panel for TOC sidebar

**Modified files:**
- `src/modules/kysley.ts` — add `bookmarks` table to DB interface
- `src/components/pdf/components/pdf.tsx` — add BookmarkButton + tabbed TOC sidebar
- `src/components/epub.tsx` — add BookmarkButton + tabbed TOC sidebar
- `src/components/mobi/MobiView.tsx` — add BookmarkButton + tabbed TOC sidebar
- `src/components/djvu/DjvuView.tsx` — add BookmarkButton + tabbed TOC sidebar

All paths are relative to `apps/main/`.

---

### Task 1: Database Migration

**Files:**
- Create: `src-tauri/migrations/2026-04-18-000000_add_bookmarks/up.sql`
- Create: `src-tauri/migrations/2026-04-18-000000_add_bookmarks/down.sql`

- [ ] **Step 1: Create the up migration**

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

- [ ] **Step 2: Create the down migration**

```sql
DROP TABLE bookmarks;
```

- [ ] **Step 3: Run the migration**

Run: `cd src-tauri && diesel migration run`

Expected: Migration succeeds, `schema.rs` is updated with `bookmarks` table.

- [ ] **Step 4: Verify schema.rs was updated**

Check that `src-tauri/src/schema.rs` now contains a `bookmarks` table definition.

- [ ] **Step 5: Commit**

```bash
git add src-tauri/migrations/2026-04-18-000000_add_bookmarks/
git add src-tauri/src/schema.rs
git commit -m "feat: add bookmarks database migration"
```

---

### Task 2: Kysely Schema + Storage Layer

**Files:**
- Modify: `src/modules/kysley.ts`
- Create: `src/modules/bookmark-storage.ts`
- Create: `src/modules/bookmark-storage.test.ts`

- [ ] **Step 1: Add bookmarks table to Kysely DB interface**

In `src/modules/kysley.ts`, add inside the `DB` interface (after the `highlights` block):

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

Also add at the bottom of the file:

```typescript
export type BookmarkRow = DB["bookmarks"];
```

- [ ] **Step 2: Write the failing tests**

Create `src/modules/bookmark-storage.test.ts`:

```typescript
import { describe, expect, it, vi, beforeEach } from "vitest";

// Mock kysley db before importing storage
const mockExecute = vi.fn().mockResolvedValue([]);
const mockExecuteTakeFirst = vi.fn().mockResolvedValue(undefined);

const mockDb = {
  insertInto: vi.fn().mockReturnThis(),
  selectFrom: vi.fn().mockReturnThis(),
  updateTable: vi.fn().mockReturnThis(),
  values: vi.fn().mockReturnThis(),
  set: vi.fn().mockReturnThis(),
  select: vi.fn().mockReturnThis(),
  selectAll: vi.fn().mockReturnThis(),
  where: vi.fn().mockReturnThis(),
  orderBy: vi.fn().mockReturnThis(),
  execute: mockExecute,
  executeTakeFirst: mockExecuteTakeFirst,
};

vi.mock("./kysley", () => ({ db: mockDb }));

import {
  saveBookmark,
  getBookmarksForBook,
  deleteBookmark,
  getBookmarkAtLocation,
  toggleBookmark,
} from "./bookmark-storage";

describe("bookmark-storage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Re-chain after clear
    mockDb.insertInto.mockReturnThis();
    mockDb.selectFrom.mockReturnThis();
    mockDb.updateTable.mockReturnThis();
    mockDb.values.mockReturnThis();
    mockDb.set.mockReturnThis();
    mockDb.select.mockReturnThis();
    mockDb.selectAll.mockReturnThis();
    mockDb.where.mockReturnThis();
    mockDb.orderBy.mockReturnThis();
    mockExecute.mockResolvedValue([]);
    mockExecuteTakeFirst.mockResolvedValue(undefined);
  });

  it("saveBookmark inserts a new bookmark", async () => {
    const id = await saveBookmark({
      bookSyncId: "sync-123",
      location: "42",
      label: "Page 42",
    });

    expect(id).toBeDefined();
    expect(typeof id).toBe("string");
    expect(mockDb.insertInto).toHaveBeenCalledWith("bookmarks");
    expect(mockDb.values).toHaveBeenCalledWith(
      expect.objectContaining({
        book_id: "sync-123",
        location: "42",
        label: "Page 42",
        is_deleted: 0,
        is_dirty: 1,
      })
    );
  });

  it("getBookmarksForBook queries non-deleted bookmarks", async () => {
    mockExecute.mockResolvedValue([
      { id: "b1", location: "10", label: "Page 10" },
    ]);

    const result = await getBookmarksForBook("sync-123");

    expect(mockDb.selectFrom).toHaveBeenCalledWith("bookmarks");
    expect(mockDb.where).toHaveBeenCalledWith("book_id", "=", "sync-123");
    expect(mockDb.where).toHaveBeenCalledWith("is_deleted", "=", 0);
    expect(mockDb.orderBy).toHaveBeenCalledWith("created_at", "desc");
    expect(result).toEqual([{ id: "b1", location: "10", label: "Page 10" }]);
  });

  it("deleteBookmark soft-deletes", async () => {
    await deleteBookmark("bookmark-id-1");

    expect(mockDb.updateTable).toHaveBeenCalledWith("bookmarks");
    expect(mockDb.set).toHaveBeenCalledWith(
      expect.objectContaining({ is_deleted: 1, is_dirty: 1 })
    );
    expect(mockDb.where).toHaveBeenCalledWith("id", "=", "bookmark-id-1");
  });

  it("getBookmarkAtLocation returns bookmark if exists", async () => {
    mockExecuteTakeFirst.mockResolvedValue({ id: "b1", location: "42" });

    const result = await getBookmarkAtLocation("sync-123", "42");

    expect(result).toEqual({ id: "b1", location: "42" });
    expect(mockDb.where).toHaveBeenCalledWith("location", "=", "42");
  });

  it("getBookmarkAtLocation returns undefined if not bookmarked", async () => {
    mockExecuteTakeFirst.mockResolvedValue(undefined);

    const result = await getBookmarkAtLocation("sync-123", "99");

    expect(result).toBeUndefined();
  });

  it("toggleBookmark creates when not existing", async () => {
    // getBookmarkAtLocation returns undefined
    mockExecuteTakeFirst.mockResolvedValue(undefined);

    const result = await toggleBookmark({
      bookSyncId: "sync-123",
      location: "42",
      label: "Page 42",
    });

    expect(result.action).toBe("created");
    expect(result.id).toBeDefined();
    expect(mockDb.insertInto).toHaveBeenCalledWith("bookmarks");
  });

  it("toggleBookmark deletes when existing", async () => {
    mockExecuteTakeFirst.mockResolvedValue({ id: "existing-id", location: "42" });

    const result = await toggleBookmark({
      bookSyncId: "sync-123",
      location: "42",
    });

    expect(result.action).toBe("deleted");
    expect(result.id).toBe("existing-id");
    expect(mockDb.updateTable).toHaveBeenCalledWith("bookmarks");
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd apps/main && npx vitest run src/modules/bookmark-storage.test.ts`

Expected: FAIL — `bookmark-storage` module does not exist.

- [ ] **Step 4: Implement bookmark-storage.ts**

Create `src/modules/bookmark-storage.ts`:

```typescript
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd apps/main && npx vitest run src/modules/bookmark-storage.test.ts`

Expected: All 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add src/modules/kysley.ts src/modules/bookmark-storage.ts src/modules/bookmark-storage.test.ts
git commit -m "feat: add bookmark storage layer with Kysely queries"
```

---

### Task 3: BookmarkButton Component

**Files:**
- Create: `src/components/bookmarks/BookmarkButton.tsx`

- [ ] **Step 1: Create the BookmarkButton component**

```tsx
import { Bookmark } from "lucide-react";
import { IconButton } from "@components/ui/IconButton";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { getBookmarkAtLocation, toggleBookmark } from "@/modules/bookmark-storage";

interface BookmarkButtonProps {
  bookSyncId: string;
  location: string;
  label?: string;
  className?: string;
}

export function BookmarkButton({ bookSyncId, location, label, className }: BookmarkButtonProps) {
  const queryClient = useQueryClient();

  const { data: existingBookmark } = useQuery({
    queryKey: ["bookmark", bookSyncId, location],
    queryFn: () => getBookmarkAtLocation(bookSyncId, location),
    enabled: !!bookSyncId && !!location,
  });

  const isBookmarked = !!existingBookmark;

  const handleToggle = async () => {
    if (!bookSyncId || !location) return;
    await toggleBookmark({ bookSyncId, location, label });
    void queryClient.invalidateQueries({ queryKey: ["bookmark", bookSyncId, location] });
    void queryClient.invalidateQueries({ queryKey: ["bookmarks", bookSyncId] });
  };

  return (
    <IconButton
      onClick={handleToggle}
      className={className}
      aria-label={isBookmarked ? "Remove bookmark" : "Add bookmark"}
    >
      <Bookmark
        size={20}
        fill={isBookmarked ? "#ef4444" : "none"}
        stroke={isBookmarked ? "#ef4444" : "currentColor"}
      />
    </IconButton>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add src/components/bookmarks/BookmarkButton.tsx
git commit -m "feat: add BookmarkButton toggle component"
```

---

### Task 4: BookmarksList Component

**Files:**
- Create: `src/components/bookmarks/BookmarksList.tsx`

- [ ] **Step 1: Create the BookmarksList component**

```tsx
import { Bookmark, Trash2 } from "lucide-react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { getBookmarksForBook, deleteBookmark } from "@/modules/bookmark-storage";

interface BookmarksListProps {
  bookSyncId: string;
  onNavigate: (location: string) => void;
}

export function BookmarksList({ bookSyncId, onNavigate }: BookmarksListProps) {
  const queryClient = useQueryClient();

  const { data: bookmarks = [] } = useQuery({
    queryKey: ["bookmarks", bookSyncId],
    queryFn: () => getBookmarksForBook(bookSyncId),
    enabled: !!bookSyncId,
  });

  const handleDelete = async (id: string) => {
    await deleteBookmark(id);
    void queryClient.invalidateQueries({ queryKey: ["bookmarks", bookSyncId] });
  };

  if (bookmarks.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-gray-400">
        <Bookmark size={32} className="mb-2 opacity-50" />
        <p className="text-sm">No bookmarks yet</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-1 p-2">
      {bookmarks.map((bm) => (
        <div
          key={bm.id}
          className="flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-800 cursor-pointer group"
          onClick={() => onNavigate(bm.location)}
        >
          <Bookmark size={16} fill="#ef4444" stroke="#ef4444" className="shrink-0" />
          <div className="flex-1 min-w-0">
            <div className="text-sm font-medium truncate">
              {bm.label || bm.location}
            </div>
            <div className="text-xs text-gray-400">
              {new Date(bm.created_at).toLocaleDateString()}
            </div>
          </div>
          <button
            onClick={(e) => {
              e.stopPropagation();
              void handleDelete(bm.id);
            }}
            className="opacity-0 group-hover:opacity-100 p-1 hover:text-red-500 transition-opacity"
            aria-label="Delete bookmark"
          >
            <Trash2 size={14} />
          </button>
        </div>
      ))}
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add src/components/bookmarks/BookmarksList.tsx
git commit -m "feat: add BookmarksList panel component"
```

---

### Task 5: Integrate into PDF Reader

**Files:**
- Modify: `src/components/pdf/components/pdf.tsx`

- [ ] **Step 1: Add imports**

Add at the top of `pdf.tsx`:

```typescript
import { BookmarkButton } from "@/components/bookmarks/BookmarkButton";
import { BookmarksList } from "@/components/bookmarks/BookmarksList";
import { Bookmark } from "lucide-react";
```

- [ ] **Step 2: Add state for sync_id lookup and sidebar tab**

Inside the `PdfView` component, add after the existing state declarations:

```typescript
const [bookSyncId, setBookSyncId] = useState<string>("");
const [tocTab, setTocTab] = useState<"contents" | "bookmarks">("contents");
const currentPageNumber = usePdfStore((s) => s.pageNumber);

// Look up book's sync_id for bookmarks
useEffect(() => {
  void import("@/modules/kysley").then(({ db }) => {
    void db.selectFrom("books")
      .select(["sync_id"])
      .where("id", "=", book.id)
      .executeTakeFirst()
      .then((row) => {
        if (row?.sync_id) setBookSyncId(row.sync_id);
      });
  });
}, [book.id]);
```

- [ ] **Step 3: Add BookmarkButton to the top bar**

In the top bar `div` (the `fixed top-0` section), add the `BookmarkButton` between the grid icon and the Back button:

```tsx
<BookmarkButton
  bookSyncId={bookSyncId}
  location={String(currentPageNumber)}
  label={`Page ${currentPageNumber}`}
  className={cn(
    "hover:bg-black/10 dark:hover:bg-white/10 border-none",
    getTextColor()
  )}
/>
```

- [ ] **Step 4: Add tabs to the TOC sidebar sheet**

Replace the TOC sidebar `SheetContent` children with a tabbed layout. After the `SheetHeader`, add:

```tsx
<div className="flex border-b border-gray-200 dark:border-gray-700">
  <button
    onClick={() => setTocTab("contents")}
    className={cn(
      "flex-1 px-4 py-2 text-sm font-medium transition-colors",
      tocTab === "contents"
        ? "border-b-2 border-blue-500 text-blue-600"
        : "text-gray-500 hover:text-gray-700"
    )}
  >
    Contents
  </button>
  <button
    onClick={() => setTocTab("bookmarks")}
    className={cn(
      "flex-1 px-4 py-2 text-sm font-medium transition-colors",
      tocTab === "bookmarks"
        ? "border-b-2 border-red-500 text-red-600"
        : "text-gray-500 hover:text-gray-700"
    )}
  >
    Bookmarks
  </button>
</div>
```

Then wrap the existing `<Document>` + `<Outline>` in a conditional, and add the bookmarks list:

```tsx
{tocTab === "contents" ? (
  <div className={cn(/* existing TOC styling */)}>
    <Document file={filepath.toString()} options={pdfOptions}>
      <Outline onItemClick={onItemClick} />
    </Document>
  </div>
) : (
  <BookmarksList
    bookSyncId={bookSyncId}
    onNavigate={(location) => {
      const pageNum = parseInt(location, 10);
      if (pageNum > 0) {
        virtualizer.scrollToIndex(pageNum - 1, { align: "start", behavior: "smooth" });
        setPageNumber(pageNum);
        setTocOpen(false);
      }
    }}
  />
)}
```

- [ ] **Step 5: Manually test**

Run: `cd apps/main && pnpm tauri dev`

Test:
1. Open a PDF book
2. Tap the bookmark icon in the top bar — it should turn red
3. Tap again — it should turn gray (removed)
4. Add a bookmark, open TOC sidebar, switch to Bookmarks tab — bookmark appears
5. Tap bookmark in list — navigates to that page
6. Delete bookmark via hover button

- [ ] **Step 6: Commit**

```bash
git add src/components/pdf/components/pdf.tsx
git commit -m "feat: integrate bookmarks into PDF reader"
```

---

### Task 6: Integrate into EPUB Reader

**Files:**
- Modify: `src/components/epub.tsx`

- [ ] **Step 1: Add imports**

Add at the top of `epub.tsx`:

```typescript
import { BookmarkButton } from "@/components/bookmarks/BookmarkButton";
import { BookmarksList } from "@/components/bookmarks/BookmarksList";
```

- [ ] **Step 2: Add state for sync_id and current location tracking**

The epub reader already has `currentLocation` state and a `book.syncId` or similar. Add:

```typescript
const [bookSyncId, setBookSyncId] = useState<string>("");

useEffect(() => {
  void db.selectFrom("books")
    .select(["sync_id"])
    .where("id", "=", book.id)
    .executeTakeFirst()
    .then((row) => {
      if (row?.sync_id) setBookSyncId(row.sync_id);
    });
}, [book.id]);
```

- [ ] **Step 3: Add BookmarkButton to the toolbar**

Find the toolbar area near the `BackButton` and add:

```tsx
<BookmarkButton
  bookSyncId={bookSyncId}
  location={currentLocation}
  label={undefined}
  className="hover:bg-transparent border-none"
/>
```

The label is left undefined for epub — the storage layer will store it as null and the list will fall back to showing the location.

- [ ] **Step 4: Add bookmarks tab to any TOC/menu panel**

If the epub reader has a table-of-contents panel or menu, add a Bookmarks tab following the same pattern as PDF (Task 5 Step 4). The `onNavigate` callback for epub:

```tsx
onNavigate={(location) => {
  const rendition = useEpubStore.getState().rendition;
  if (rendition) {
    void rendition.display(location);
  }
}}
```

If no TOC sidebar exists yet, create one with a `Sheet` following the same structure as `pdf.tsx`.

- [ ] **Step 5: Commit**

```bash
git add src/components/epub.tsx
git commit -m "feat: integrate bookmarks into EPUB reader"
```

---

### Task 7: Integrate into MOBI Reader

**Files:**
- Modify: `src/components/mobi/MobiView.tsx`

- [ ] **Step 1: Add imports**

```typescript
import { BookmarkButton } from "@/components/bookmarks/BookmarkButton";
import { BookmarksList } from "@/components/bookmarks/BookmarksList";
```

- [ ] **Step 2: Add BookmarkButton to the toolbar**

The mobi reader has a toolbar near `BackButton`. Add:

```tsx
<BookmarkButton
  bookSyncId={bookSyncIdRef.current ?? ""}
  location={String(chapterIndex)}
  label={`Chapter ${chapterIndex + 1}`}
  className="hover:bg-transparent border-none"
/>
```

`bookSyncIdRef` already exists in MobiView — it's set up in an existing `useEffect`.

- [ ] **Step 3: Add bookmarks sidebar**

Add a `Sheet` with tabs (Contents + Bookmarks) following the PDF pattern. The `onNavigate` callback for mobi:

```tsx
onNavigate={(location) => {
  const idx = parseInt(location, 10);
  if (Number.isFinite(idx) && idx >= 0) {
    setChapterIndex(idx);
  }
}}
```

- [ ] **Step 4: Commit**

```bash
git add src/components/mobi/MobiView.tsx
git commit -m "feat: integrate bookmarks into MOBI reader"
```

---

### Task 8: Integrate into DJVU Reader

**Files:**
- Modify: `src/components/djvu/DjvuView.tsx`

- [ ] **Step 1: Add imports**

```typescript
import { BookmarkButton } from "@/components/bookmarks/BookmarkButton";
import { BookmarksList } from "@/components/bookmarks/BookmarksList";
```

- [ ] **Step 2: Add BookmarkButton to the toolbar**

The djvu reader has a toolbar area. Add:

```tsx
<BookmarkButton
  bookSyncId={bookSyncIdRef.current ?? ""}
  location={String(currentPage)}
  label={`Page ${currentPage}`}
  className="hover:bg-transparent border-none"
/>
```

`bookSyncIdRef` already exists in DjvuView.

- [ ] **Step 3: Add bookmarks sidebar**

Add a `Sheet` with tabs (Contents + Bookmarks) following the PDF pattern. The `onNavigate` callback for djvu:

```tsx
onNavigate={(location) => {
  const page = parseInt(location, 10);
  if (page > 0) {
    setCurrentPage(page);
  }
}}
```

- [ ] **Step 4: Commit**

```bash
git add src/components/djvu/DjvuView.tsx
git commit -m "feat: integrate bookmarks into DJVU reader"
```

---

### Task 9: TypeScript Check + Final Test

**Files:** None (verification only)

- [ ] **Step 1: Run TypeScript check**

Run: `cd apps/main && npx tsc --noEmit 2>&1 | grep -v "node_modules" | head -30`

Expected: No new errors from bookmark files.

- [ ] **Step 2: Run all bookmark tests**

Run: `cd apps/main && npx vitest run src/modules/bookmark-storage.test.ts`

Expected: All tests PASS.

- [ ] **Step 3: Run the app and verify all formats**

Run: `cd apps/main && pnpm tauri dev`

Test each format:
1. **PDF**: Open PDF → bookmark icon in top bar → toggle works → TOC sidebar has Bookmarks tab → navigate from list
2. **EPUB**: Open EPUB → bookmark icon → toggle works → bookmarks tab → navigate
3. **MOBI**: Open MOBI → bookmark icon → toggle works → bookmarks tab → navigate
4. **DJVU**: Open DJVU → bookmark icon → toggle works → bookmarks tab → navigate

- [ ] **Step 4: Final commit**

```bash
git commit --allow-empty -m "feat: bookmarks feature complete across all book formats"
```
