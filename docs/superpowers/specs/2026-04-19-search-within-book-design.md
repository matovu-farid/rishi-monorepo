# Search Within Book — Design Spec

## Overview

Add in-book search to Rishi with two modes: **exact text search** (as-you-type with debounce) and **semantic search** (on Enter). The UI follows the Apple Books search UX pattern, implemented using the same Sheet-based slide-out panel design as the existing `HighlightsPanel` and `ChatPanel`.

Quoting the query (e.g., `"exact phrase"`) forces exact matching; unquoted queries trigger exact search as-you-type and semantic search on Enter.

## Search Modes

### Exact Text Search
- **Trigger:** As-you-type with 300ms debounce
- **EPUB:** Uses the existing `ReactReader.searchInBook()` method which walks epub.js spine items, extracts text nodes, and returns `{ cfi, excerpt }` results
- **PDF/MOBI/DjVu:** Uses a new `search_book_text` Tauri command backed by SQLite FTS5 on the `chunk_data` table
- **Result display:** Snippet with matched terms highlighted in gold

### Semantic Search
- **Trigger:** On Enter key press
- **All formats:** Uses the existing `getContextForQuery()` Tauri command which embeds the query via `all-MiniLM-L6-v2`, searches the HNSW vector index, and returns matching chunk texts
- **Result display:** Snippet without term highlighting (matches by meaning, not literal text)

## Backend Changes

### New Migration — FTS5 Virtual Table

A content-sync FTS5 virtual table mirroring `chunk_data.data`, with triggers to keep it in sync on insert/update/delete:

```sql
CREATE VIRTUAL TABLE chunk_data_fts USING fts5(
  data,
  content='chunk_data',
  content_rowid='id'
);

CREATE TRIGGER chunk_data_ai AFTER INSERT ON chunk_data BEGIN
  INSERT INTO chunk_data_fts(rowid, data) VALUES (new.id, new.data);
END;

CREATE TRIGGER chunk_data_ad AFTER DELETE ON chunk_data BEGIN
  INSERT INTO chunk_data_fts(chunk_data_fts, rowid, data) VALUES('delete', old.id, old.data);
END;

CREATE TRIGGER chunk_data_au AFTER UPDATE ON chunk_data BEGIN
  INSERT INTO chunk_data_fts(chunk_data_fts, rowid, data) VALUES('delete', old.id, old.data);
  INSERT INTO chunk_data_fts(rowid, data) VALUES (new.id, new.data);
END;
```

Note: Existing books that were indexed before this migration will need their FTS index rebuilt. The migration `up.sql` should include a one-time population:

```sql
INSERT INTO chunk_data_fts(rowid, data) SELECT id, data FROM chunk_data;
```

### New Tauri Command — `search_book_text`

```rust
#[tauri::command]
pub fn search_book_text(query: String, book_id: i32) -> Result<Vec<TextSearchResult>, String>
```

- Runs a raw SQL query: `SELECT chunk_data.id, chunk_data.pageNumber, chunk_data.bookId, snippet(chunk_data_fts, 0, '<mark>', '</mark>', '...', 40) as snippet, chunk_data.data FROM chunk_data_fts JOIN chunk_data ON chunk_data.id = chunk_data_fts.rowid WHERE chunk_data.bookId = ? AND chunk_data_fts MATCH ?`
- Returns `Vec<TextSearchResult>` with fields: `id: i64`, `page_number: i32`, `book_id: i32`, `data: String`, `snippet: String`
- The `snippet()` function provides FTS5-generated excerpts with `<mark>` tags around matches

### Existing Command Reused — `get_context_for_query`

Already does end-to-end semantic search. The frontend calls it with `(queryText, bookId, k=10)` and gets back `Vec<String>` of matching chunk texts. Page numbers are resolved via a Kysely query on `chunk_data` (same pattern as `useChat.ts:131`).

## Frontend Changes

### New Component — `SearchPanel.tsx`

Location: `apps/main/src/components/search/SearchPanel.tsx`

Sheet-based slide-out panel matching `HighlightsPanel` pattern:
- `Sheet` + `SheetContent side="right" className="w-[400px] flex flex-col"`
- `SheetHeader` with title "Search"
- Search input below header with placeholder `Search or "exact phrase"`
- Result count below input (e.g., "5 results")
- `ScrollArea` with result items
- `SheetFooter` with contextual hint: "Press Enter for smart search" (during exact) or "Showing semantically related passages" (after semantic)

**Props:**
```typescript
interface SearchPanelProps {
  bookId: number;
  bookFormat: 'epub' | 'pdf' | 'mobi' | 'djvu';
  rendition: Rendition | null;  // for EPUB navigation
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onNavigate: (target: { cfi?: string; pageNumber?: number }) => void;
}
```

### New Hook — `useBookSearch`

Location: `apps/main/src/hooks/useBookSearch.ts`

Manages search state and orchestrates both pipelines.

**State:**
- `query: string` — current search input
- `results: SearchResult[]` — combined results list
- `isSearching: boolean` — loading state
- `searchMode: 'exact' | 'semantic'` — auto-detected from query format and trigger

**Behavior:**
- On keystroke (debounced 300ms): detect if query is quoted → exact search
  - EPUB: call `searchInBook()` via ReactReader ref
  - PDF/MOBI/DjVu: call `searchBookText()` Tauri command
- On Enter: run semantic search via `getContextForQuery()`, replace results
- Results are normalized into a common shape:

```typescript
interface SearchResult {
  id: string;
  snippet: string;           // text excerpt
  highlightedSnippet?: string; // snippet with <mark> tags (exact only)
  pageNumber?: number;
  chapter?: string;
  cfi?: string;              // EPUB only
  mode: 'exact' | 'semantic';
}
```

### Search Result Item

Each result displays:
- Snippet text — with matched terms highlighted via `<mark>` for exact search, plain text for semantic
- Chapter name and/or page number in `text-xs text-muted-foreground`
- `border-left: 3px solid` accent (same pattern as highlights)
- Click navigates: EPUB calls `rendition.display(cfi)`, PDF/MOBI/DjVu updates page store
- `hover:bg-accent/50 transition-colors` on hover (same as highlight items)

### Toolbar Integration

- Add a `Search` icon (lucide-react) to the reader toolbar alongside existing icons
- Clicking toggles `SearchPanel` open/closed
- `Cmd+F` / `Ctrl+F` keyboard shortcut toggles the panel
- Auto-focus the search input when the panel opens

### Empty States

- **No query:** "Search for text in this book"
- **No results (exact):** "No matches found"
- **No results (semantic):** "No related passages found"
- **Book not indexed:** "This book hasn't been indexed yet. Open it to start indexing."

## Navigation on Result Click

| Format | Exact Search Navigation | Semantic Search Navigation |
|--------|------------------------|---------------------------|
| EPUB   | `rendition.display(cfi)` — jumps to exact match location | `rendition.display(pageNumber)` — jumps to page containing the chunk |
| PDF    | Update PDF page store to `pageNumber` | Same |
| MOBI   | Navigate to `pageNumber` | Same |
| DjVu   | Navigate to `pageNumber` | Same |

## Files to Create

1. `apps/main/src-tauri/migrations/<timestamp>_create_fts_index/up.sql` — FTS5 migration
2. `apps/main/src-tauri/migrations/<timestamp>_create_fts_index/down.sql` — Drop FTS table and triggers
3. `apps/main/src/components/search/SearchPanel.tsx` — Search panel UI
4. `apps/main/src/hooks/useBookSearch.ts` — Search logic hook

## Files to Modify

1. `apps/main/src-tauri/src/sql.rs` — Add `search_book_text` command and `TextSearchResult` struct
2. `apps/main/src-tauri/src/lib.rs` — Register `search_book_text` in `invoke_handler!`
3. `apps/main/src/generated/commands.ts` — Add generated binding (auto via `cargo tauri dev`)
4. `apps/main/src/generated/types.ts` — Add `TextSearchResult` type (auto-generated)
5. Reader components (epub.tsx, pdf.tsx, mobi, djvu) — Add search icon to toolbar, wire `SearchPanel`

## Out of Scope

- Search across multiple books (library-wide search)
- Search history / recent searches
- Advanced search syntax beyond quoted exact match
- Highlighting matches in the reader view itself (only in the search panel)
