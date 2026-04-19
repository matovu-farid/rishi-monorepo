# Search Within Book — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-book search with two modes — exact text search (as-you-type with debounce) and semantic search (on Enter) — via a slide-out panel in the reader toolbar.

**Architecture:** FTS5 virtual table for exact text search on `chunk_data`, existing HNSW vector search for semantic. New `SearchPanel` component using the same `Sheet` pattern as `HighlightsPanel`/`ChatPanel`. New `useBookSearch` hook orchestrates both pipelines. EPUB exact search uses the existing `ReactReader.searchInBook()` method; PDF/MOBI/DjVu use the FTS5 Tauri command.

**Tech Stack:** Rust/Diesel (SQLite FTS5), Tauri commands, React, Zustand/Jotai, Radix Sheet, lucide-react icons

---

## File Structure

**Create:**
- `apps/main/src-tauri/migrations/2026-04-19-000000_create_fts_index/up.sql` — FTS5 virtual table + sync triggers + backfill
- `apps/main/src-tauri/migrations/2026-04-19-000000_create_fts_index/down.sql` — Drop FTS table and triggers
- `apps/main/src/components/search/SearchPanel.tsx` — Search slide-out panel UI
- `apps/main/src/hooks/useBookSearch.ts` — Search orchestration hook

**Modify:**
- `apps/main/src-tauri/src/sql.rs` — Add `TextSearchResult` struct and `search_book_text` command
- `apps/main/src-tauri/src/lib.rs` — Register `search_book_text` in `invoke_handler!`
- `apps/main/src/generated/commands.ts` — Add `searchBookText` binding
- `apps/main/src/generated/types.ts` — Add `TextSearchResult` and `SearchBookTextParams` types
- `apps/main/src/components/epub.tsx` — Add search icon to toolbar, wire `SearchPanel`
- `apps/main/src/components/pdf/components/pdf.tsx` — Add search icon to toolbar, wire `SearchPanel`
- `apps/main/src/components/mobi/MobiView.tsx` — Add search icon to toolbar, wire `SearchPanel`
- `apps/main/src/components/djvu/DjvuView.tsx` — Add search icon to toolbar, wire `SearchPanel`

---

### Task 1: FTS5 Migration

**Files:**
- Create: `apps/main/src-tauri/migrations/2026-04-19-000000_create_fts_index/up.sql`
- Create: `apps/main/src-tauri/migrations/2026-04-19-000000_create_fts_index/down.sql`

- [ ] **Step 1: Create the migration directory**

```bash
mkdir -p apps/main/src-tauri/migrations/2026-04-19-000000_create_fts_index
```

- [ ] **Step 2: Write the up migration**

Create `apps/main/src-tauri/migrations/2026-04-19-000000_create_fts_index/up.sql`:

```sql
-- FTS5 content-sync table mirroring chunk_data.data
CREATE VIRTUAL TABLE chunk_data_fts USING fts5(
  data,
  content='chunk_data',
  content_rowid='id'
);

-- Keep FTS index in sync with chunk_data
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

-- Backfill FTS index with existing chunk_data rows
INSERT INTO chunk_data_fts(rowid, data) SELECT id, data FROM chunk_data;
```

- [ ] **Step 3: Write the down migration**

Create `apps/main/src-tauri/migrations/2026-04-19-000000_create_fts_index/down.sql`:

```sql
DROP TRIGGER IF EXISTS chunk_data_ai;
DROP TRIGGER IF EXISTS chunk_data_ad;
DROP TRIGGER IF EXISTS chunk_data_au;
DROP TABLE IF EXISTS chunk_data_fts;
```

- [ ] **Step 4: Verify the migration runs**

```bash
cd apps/main/src-tauri && cargo build 2>&1 | tail -20
```

Expected: Build succeeds. Diesel's `embed_migrations!()` in `db.rs` picks up the new migration automatically.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/migrations/2026-04-19-000000_create_fts_index/
git commit -m "feat(search): add FTS5 migration for chunk_data full-text search"
```

---

### Task 2: Rust `search_book_text` Command

**Files:**
- Modify: `apps/main/src-tauri/src/sql.rs`
- Modify: `apps/main/src-tauri/src/lib.rs`

- [ ] **Step 1: Add `TextSearchResult` struct and `search_book_text` function to `sql.rs`**

Add this after the `PageData` struct (around line 60) in `apps/main/src-tauri/src/sql.rs`:

```rust
#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TextSearchResult {
    pub id: i64,
    pub page_number: i32,
    pub book_id: i32,
    pub data: String,
    pub snippet: String,
}
```

Add this function before the `#[cfg(test)]` block at the end of `sql.rs`:

```rust
#[tauri::command]
pub fn search_book_text(query: String, book_id: i32) -> Result<Vec<TextSearchResult>, String> {
    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    // FTS5 MATCH query with snippet generation, filtered by bookId
    #[derive(diesel::QueryableByName)]
    struct RawSearchResult {
        #[diesel(sql_type = diesel::sql_types::BigInt)]
        id: i64,
        #[diesel(sql_type = diesel::sql_types::Integer, column_name = "pageNumber")]
        page_number: i32,
        #[diesel(sql_type = diesel::sql_types::Integer, column_name = "bookId")]
        book_id: i32,
        #[diesel(sql_type = diesel::sql_types::Text)]
        data: String,
        #[diesel(sql_type = diesel::sql_types::Text)]
        snippet: String,
    }

    let results: Vec<RawSearchResult> = diesel::sql_query(
        "SELECT chunk_data.id, chunk_data.pageNumber, chunk_data.bookId, chunk_data.data, \
         snippet(chunk_data_fts, 0, '<mark>', '</mark>', '...', 40) as snippet \
         FROM chunk_data_fts \
         JOIN chunk_data ON chunk_data.id = chunk_data_fts.rowid \
         WHERE chunk_data.bookId = ?1 AND chunk_data_fts MATCH ?2 \
         ORDER BY rank \
         LIMIT 50"
    )
    .bind::<diesel::sql_types::Integer, _>(&book_id)
    .bind::<diesel::sql_types::Text, _>(&query)
    .load(&mut conn)
    .map_err(|e| format!("FTS search failed: {}", e))?;

    Ok(results
        .into_iter()
        .map(|r| TextSearchResult {
            id: r.id,
            page_number: r.page_number,
            book_id: r.book_id,
            data: r.data,
            snippet: r.snippet,
        })
        .collect())
}
```

- [ ] **Step 2: Register the command in `lib.rs`**

In `apps/main/src-tauri/src/lib.rs`, add `sql::search_book_text,` to the `invoke_handler!` macro, after the `sql::get_text_from_vector_id,` line:

```rust
            sql::get_text_from_vector_id,
            sql::search_book_text,
```

- [ ] **Step 3: Add a test for `search_book_text`**

Add this test inside the `mod tests` block in `sql.rs`, after the existing `test_save_page_data_many` test:

```rust
    #[test]
    fn test_search_book_text() -> Result<(), String> {
        let _setup = init_test_database_setup()?;
        let book_id = 1;

        let page_data = vec![
            ChunkDataInsertable {
                id: Some(100),
                page_number: 1,
                book_id,
                data: "The philosophy of consciousness has been debated for centuries.".to_string(),
            },
            ChunkDataInsertable {
                id: Some(101),
                page_number: 2,
                book_id,
                data: "Quantum mechanics describes the behavior of particles at atomic scales.".to_string(),
            },
            ChunkDataInsertable {
                id: Some(102),
                page_number: 3,
                book_id,
                data: "Neural networks in the brain give rise to consciousness and awareness.".to_string(),
            },
        ];
        save_page_data_many(page_data)?;

        // Search for "consciousness" — should find chunks on pages 1 and 3
        let results = search_book_text("consciousness".to_string(), book_id)?;
        expect!(results.len()).to(be_equal_to(2));
        // Results should be from pages 1 and 3 (order by FTS rank)
        let page_numbers: Vec<i32> = results.iter().map(|r| r.page_number).collect();
        expect!(page_numbers.contains(&1)).to(be_equal_to(true));
        expect!(page_numbers.contains(&3)).to(be_equal_to(true));
        // Snippets should contain <mark> tags
        for result in &results {
            expect!(result.snippet.contains("<mark>")).to(be_equal_to(true));
        }

        // Search for "quantum" — should find only page 2
        let results2 = search_book_text("quantum".to_string(), book_id)?;
        expect!(results2.len()).to(be_equal_to(1));
        expect!(results2[0].page_number).to(be_equal_to(2));

        // Search for a term that doesn't exist
        let results3 = search_book_text("nonexistentterm".to_string(), book_id)?;
        expect!(results3.is_empty()).to(be_equal_to(true));

        Ok(())
    }
```

Also add `search_book_text` to the test imports at the top of the `mod tests` block:

```rust
    use super::{
        delete_book, get_all_page_data_by_book_id, get_book, save_book, save_page_data_many,
        search_book_text, update_book_cover, BookInsertable, ChunkDataInsertable,
    };
```

- [ ] **Step 4: Run the test**

```bash
cd apps/main/src-tauri && cargo test test_search_book_text -- --nocapture
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/sql.rs apps/main/src-tauri/src/lib.rs
git commit -m "feat(search): add search_book_text Tauri command with FTS5"
```

---

### Task 3: TypeScript Bindings

**Files:**
- Modify: `apps/main/src/generated/types.ts`
- Modify: `apps/main/src/generated/commands.ts`

- [ ] **Step 1: Add `TextSearchResult` type and params to `types.ts`**

Add at the end of `apps/main/src/generated/types.ts` (before the closing blank line):

```typescript
export interface TextSearchResult {
  id: number;
  pageNumber: number;
  bookId: number;
  data: string;
  snippet: string;
}

export interface SearchBookTextParams {
  query: string;
  bookId: number;
  [key: string]: unknown;
}
```

- [ ] **Step 2: Add `searchBookText` command to `commands.ts`**

Add at the end of `apps/main/src/generated/commands.ts`:

```typescript
export async function searchBookText(params: types.SearchBookTextParams): Promise<types.TextSearchResult[]> {
  return invoke('search_book_text', params);
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/generated/types.ts apps/main/src/generated/commands.ts
git commit -m "feat(search): add TypeScript bindings for search_book_text"
```

---

### Task 4: `useBookSearch` Hook

**Files:**
- Create: `apps/main/src/hooks/useBookSearch.ts`

- [ ] **Step 1: Create the hook**

Create `apps/main/src/hooks/useBookSearch.ts`:

```typescript
import { useState, useCallback, useRef, useEffect } from 'react';
import { searchBookText } from '@/generated/commands';
import { getContextForQuery } from '@/generated/commands';
import { db } from '@/modules/kysley';

export type SearchMode = 'exact' | 'semantic';

export interface BookSearchResult {
  id: string;
  snippet: string;
  highlightedSnippet?: string;
  pageNumber?: number;
  chapter?: string;
  cfi?: string;
  mode: SearchMode;
}

interface UseBookSearchOptions {
  bookId: number;
  bookFormat: string;
  epubSearchFn?: (query: string) => Promise<{ cfi: string; excerpt: string }[]>;
}

export function useBookSearch({ bookId, bookFormat, epubSearchFn }: UseBookSearchOptions) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<BookSearchResult[]>([]);
  const [isSearching, setIsSearching] = useState(false);
  const [activeMode, setActiveMode] = useState<SearchMode>('exact');
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const queryRef = useRef('');

  // Keep ref in sync
  useEffect(() => {
    queryRef.current = query;
  }, [query]);

  // Detect if query is quoted
  const isQuotedQuery = useCallback((q: string) => {
    const trimmed = q.trim();
    return trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length > 2;
  }, []);

  // Strip quotes from query
  const stripQuotes = useCallback((q: string) => {
    const trimmed = q.trim();
    if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
      return trimmed.slice(1, -1);
    }
    return trimmed;
  }, []);

  // Exact search (FTS5 or epub.js spine search)
  const runExactSearch = useCallback(async (searchQuery: string) => {
    const cleanQuery = stripQuotes(searchQuery);
    if (!cleanQuery || cleanQuery.length < 2) {
      setResults([]);
      return;
    }

    setIsSearching(true);
    setActiveMode('exact');

    try {
      if (bookFormat === 'epub' && epubSearchFn) {
        // Use epub.js spine-based search for EPUBs
        const epubResults = await epubSearchFn(cleanQuery);
        if (queryRef.current !== searchQuery) return; // stale
        setResults(
          epubResults.map((r, i) => ({
            id: `epub-${i}`,
            snippet: r.excerpt,
            highlightedSnippet: highlightText(r.excerpt, cleanQuery),
            cfi: r.cfi,
            mode: 'exact' as SearchMode,
          }))
        );
      } else {
        // Use FTS5 for PDF/MOBI/DjVu (and EPUB without epubSearchFn)
        const ftsResults = await searchBookText({ query: cleanQuery, bookId });
        if (queryRef.current !== searchQuery) return; // stale
        setResults(
          ftsResults.map((r) => ({
            id: `fts-${r.id}`,
            snippet: r.data,
            highlightedSnippet: r.snippet, // FTS5 snippet with <mark> tags
            pageNumber: r.pageNumber,
            mode: 'exact' as SearchMode,
          }))
        );
      }
    } catch (err) {
      console.error('[useBookSearch] exact search failed:', err);
      setResults([]);
    } finally {
      setIsSearching(false);
    }
  }, [bookId, bookFormat, epubSearchFn, stripQuotes]);

  // Semantic search (vector)
  const runSemanticSearch = useCallback(async (searchQuery: string) => {
    const cleanQuery = stripQuotes(searchQuery);
    if (!cleanQuery || cleanQuery.length < 2) return;

    setIsSearching(true);
    setActiveMode('semantic');

    try {
      const contextTexts = await getContextForQuery({ queryText: cleanQuery, bookId, k: 10 });
      if (queryRef.current !== searchQuery) return; // stale

      // Resolve page numbers from chunk_data
      const resultsWithPages: BookSearchResult[] = await Promise.all(
        contextTexts.map(async (text, i) => {
          const chunk = await db
            .selectFrom('chunk_data')
            .select(['pageNumber'])
            .where('bookId', '=', bookId)
            .where('data', '=', text)
            .executeTakeFirst();

          return {
            id: `semantic-${i}`,
            snippet: text.length > 200 ? text.slice(0, 200) + '...' : text,
            pageNumber: chunk?.pageNumber,
            mode: 'semantic' as SearchMode,
          };
        })
      );

      setResults(resultsWithPages);
    } catch (err) {
      console.error('[useBookSearch] semantic search failed:', err);
    } finally {
      setIsSearching(false);
    }
  }, [bookId, stripQuotes]);

  // Handle query changes — debounced exact search
  const handleQueryChange = useCallback((newQuery: string) => {
    setQuery(newQuery);

    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
    }

    if (!newQuery.trim()) {
      setResults([]);
      return;
    }

    debounceRef.current = setTimeout(() => {
      void runExactSearch(newQuery);
    }, 300);
  }, [runExactSearch]);

  // Handle Enter — run semantic search
  const handleSubmit = useCallback(() => {
    if (!query.trim()) return;

    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
    }

    // If query is quoted, run exact search immediately
    if (isQuotedQuery(query)) {
      void runExactSearch(query);
    } else {
      void runSemanticSearch(query);
    }
  }, [query, isQuotedQuery, runExactSearch, runSemanticSearch]);

  // Cleanup debounce on unmount
  useEffect(() => {
    return () => {
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
      }
    };
  }, []);

  return {
    query,
    results,
    isSearching,
    activeMode,
    handleQueryChange,
    handleSubmit,
  };
}

/** Wrap matched terms in <mark> tags for display */
function highlightText(text: string, query: string): string {
  if (!query) return text;
  const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return text.replace(new RegExp(`(${escaped})`, 'gi'), '<mark>$1</mark>');
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/hooks/useBookSearch.ts
git commit -m "feat(search): add useBookSearch hook with exact and semantic modes"
```

---

### Task 5: `SearchPanel` Component

**Files:**
- Create: `apps/main/src/components/search/SearchPanel.tsx`

- [ ] **Step 1: Create the component**

Create `apps/main/src/components/search/SearchPanel.tsx`:

Note: The `highlightedSnippet` field contains HTML from the FTS5 `snippet()` function which only produces `<mark>` tags — it does not accept user input and is safe to render. The `highlightText` utility in `useBookSearch` also only wraps matched terms in `<mark>` tags using a regex escape of the query.

```tsx
import { useEffect, useRef } from 'react';
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetFooter,
} from '@components/components/ui/sheet';
import { ScrollArea } from '@components/components/ui/scroll-area';
import { Search, Loader2 } from 'lucide-react';
import { useBookSearch, type BookSearchResult } from '@/hooks/useBookSearch';

interface SearchPanelProps {
  bookId: number;
  bookFormat: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onNavigate: (result: BookSearchResult) => void;
  epubSearchFn?: (query: string) => Promise<{ cfi: string; excerpt: string }[]>;
}

export function SearchPanel({
  bookId,
  bookFormat,
  open,
  onOpenChange,
  onNavigate,
  epubSearchFn,
}: SearchPanelProps) {
  const {
    query,
    results,
    isSearching,
    activeMode,
    handleQueryChange,
    handleSubmit,
  } = useBookSearch({ bookId, bookFormat, epubSearchFn });

  const inputRef = useRef<HTMLInputElement>(null);

  // Auto-focus input when panel opens
  useEffect(() => {
    if (open) {
      setTimeout(() => inputRef.current?.focus(), 100);
    }
  }, [open]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleSubmit();
    }
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="w-[400px] flex flex-col">
        <SheetHeader>
          <SheetTitle className="text-lg font-semibold">Search</SheetTitle>
        </SheetHeader>

        {/* Search input */}
        <div className="px-4 pb-2">
          <div className="flex items-center gap-2 rounded-md border border-input bg-muted/50 px-3 py-2">
            <Search size={14} className="text-muted-foreground shrink-0" />
            <input
              ref={inputRef}
              type="text"
              className="flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
              placeholder='Search or "exact phrase"'
              value={query}
              onChange={(e) => handleQueryChange(e.target.value)}
              onKeyDown={handleKeyDown}
            />
            {isSearching && <Loader2 size={14} className="animate-spin text-muted-foreground" />}
          </div>

          {/* Result count */}
          {query.trim() && (
            <p className="text-xs text-muted-foreground mt-2">
              {results.length} result{results.length !== 1 ? 's' : ''}
            </p>
          )}
        </div>

        {/* Results list */}
        <ScrollArea className="flex-1 px-4">
          {!query.trim() ? (
            <div className="flex flex-col items-center justify-center py-16 text-center">
              <h3 className="text-base font-semibold mb-1">Search this book</h3>
              <p className="text-sm text-muted-foreground">
                Type to find text, or press Enter for smart search.
              </p>
            </div>
          ) : results.length === 0 && !isSearching ? (
            <div className="flex flex-col items-center justify-center py-16 text-center">
              <h3 className="text-base font-semibold mb-1">No results found</h3>
              <p className="text-sm text-muted-foreground">
                {activeMode === 'exact'
                  ? 'Try pressing Enter for a smart search.'
                  : 'No related passages found.'}
              </p>
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              {results.map((result) => (
                <SearchResultItem
                  key={result.id}
                  result={result}
                  onNavigate={onNavigate}
                />
              ))}
            </div>
          )}
        </ScrollArea>

        <SheetFooter>
          <p className="text-xs text-muted-foreground">
            {activeMode === 'semantic' && results.length > 0
              ? 'Showing semantically related passages'
              : 'Press Enter for smart search'}
          </p>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  );
}

function SearchResultItem({
  result,
  onNavigate,
}: {
  result: BookSearchResult;
  onNavigate: (result: BookSearchResult) => void;
}) {
  return (
    <button
      className="cursor-pointer rounded-md p-3 hover:bg-accent/50 transition-colors text-left"
      style={{ borderLeft: '3px solid hsl(var(--muted-foreground) / 0.4)' }}
      onClick={() => onNavigate(result)}
    >
      {result.highlightedSnippet ? (
        <p
          className="text-sm line-clamp-3 [&>mark]:bg-yellow-500/30 [&>mark]:text-yellow-200 [&>mark]:rounded-sm"
          // Safe: highlightedSnippet is generated by FTS5 snippet() which only produces
          // <mark> tags from indexed content, or by highlightText() which regex-escapes
          // the query before wrapping in <mark>. No user-controlled HTML is injected.
          dangerouslySetInnerHTML={{ __html: result.highlightedSnippet }}
        />
      ) : (
        <p className="text-sm line-clamp-3">{result.snippet}</p>
      )}
      {(result.pageNumber || result.chapter) && (
        <p className="text-xs text-muted-foreground mt-1">
          {[result.chapter, result.pageNumber ? `Page ${result.pageNumber}` : null]
            .filter(Boolean)
            .join(' · ')}
        </p>
      )}
    </button>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/components/search/SearchPanel.tsx
git commit -m "feat(search): add SearchPanel slide-out component"
```

---

### Task 6: Wire SearchPanel into EPUB Reader

**Files:**
- Modify: `apps/main/src/components/epub.tsx`

- [ ] **Step 1: Add imports and state**

At the top of `apps/main/src/components/epub.tsx`, add `Search` to the lucide-react import and import `SearchPanel`:

```typescript
import { Palette, Highlighter, MessageSquare, Search } from "lucide-react";
```

Add after the `ChatPanel` import:

```typescript
import { SearchPanel } from "@/components/search/SearchPanel";
import type { BookSearchResult } from "@/hooks/useBookSearch";
```

Inside `EpubView`, add state after `const [chatPanelOpen, setChatPanelOpen] = useState(false);`:

```typescript
  const [searchPanelOpen, setSearchPanelOpen] = useState(false);
```

- [ ] **Step 2: Add navigation handler and keyboard shortcut**

Add after the `searchPanelOpen` state declaration:

```typescript
  const handleSearchNavigate = useCallback((result: BookSearchResult) => {
    if (result.cfi && rendition) {
      void rendition.display(result.cfi);
    } else if (result.pageNumber && rendition) {
      void rendition.display(result.pageNumber);
    }
  }, [rendition]);

  // Cmd+F / Ctrl+F keyboard shortcut
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
        e.preventDefault();
        setSearchPanelOpen((prev) => !prev);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);
```

- [ ] **Step 3: Add search button to toolbar**

In the toolbar `div` (the `<div className="absolute right-2 top-2 z-10 flex items-center gap-2">`), add a search button before the highlights button:

```tsx
        <button
          onClick={() => setSearchPanelOpen(true)}
          className={cn("p-2 rounded-md", getTextColor())}
          aria-label="Search in book"
        >
          <Search size={20} />
        </button>
```

- [ ] **Step 4: Add SearchPanel component**

Add the `SearchPanel` component after the `ChatPanel` component (before the closing `</div>`):

```tsx
      {/* Search Panel */}
      <SearchPanel
        bookId={book.id}
        bookFormat="epub"
        open={searchPanelOpen}
        onOpenChange={setSearchPanelOpen}
        onNavigate={handleSearchNavigate}
      />
```

Note: We skip `epubSearchFn` for now — the FTS5 backend works for all formats including EPUB. The epub.js spine search can be wired in later as an enhancement for CFI-precise navigation.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/epub.tsx
git commit -m "feat(search): wire SearchPanel into EPUB reader with Cmd+F shortcut"
```

---

### Task 7: Wire SearchPanel into PDF Reader

**Files:**
- Modify: `apps/main/src/components/pdf/components/pdf.tsx`

- [ ] **Step 1: Add imports and state**

At the top of `apps/main/src/components/pdf/components/pdf.tsx`, add `Search` to the lucide-react import:

```typescript
import { Loader2, Menu as MenuIcon, LayoutGrid, Search } from "lucide-react";
```

Add the SearchPanel import:

```typescript
import { SearchPanel } from "@/components/search/SearchPanel";
import type { BookSearchResult } from "@/hooks/useBookSearch";
```

Inside `PdfView`, add state after the existing state declarations:

```typescript
  const [searchPanelOpen, setSearchPanelOpen] = useState(false);
```

- [ ] **Step 2: Add navigation handler and keyboard shortcut**

Add after the state:

```typescript
  const handleSearchNavigate = useCallback((result: BookSearchResult) => {
    if (result.pageNumber) {
      setBookNavState(BookNavigationState.Idle);
      virtualizer.scrollToIndex(result.pageNumber - 1, {
        align: "start",
        behavior: "smooth",
      });
      setPageNumber(result.pageNumber);
    }
  }, [virtualizer, setBookNavState, setPageNumber]);

  // Cmd+F / Ctrl+F keyboard shortcut
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
        e.preventDefault();
        setSearchPanelOpen((prev) => !prev);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);
```

- [ ] **Step 3: Add search button to the top bar**

In the fixed top bar's flex container (around line 213), add a search button after the `LayoutGrid` button:

```tsx
          <IconButton
            onClick={() => setSearchPanelOpen(true)}
            className={cn(
              "hover:bg-black/10 dark:hover:bg-white/10 border-none",
              getTextColor()
            )}
            aria-label="Search in book"
          >
            <Search size={20} />
          </IconButton>
```

- [ ] **Step 4: Add SearchPanel component**

Add the `SearchPanel` component before the closing `</div>` of the root element, after the `ThumbnailSidebar`:

```tsx
      {/* Search Panel */}
      <SearchPanel
        bookId={book.id}
        bookFormat="pdf"
        open={searchPanelOpen}
        onOpenChange={setSearchPanelOpen}
        onNavigate={handleSearchNavigate}
      />
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/pdf/components/pdf.tsx
git commit -m "feat(search): wire SearchPanel into PDF reader"
```

---

### Task 8: Wire SearchPanel into MOBI Reader

**Files:**
- Modify: `apps/main/src/components/mobi/MobiView.tsx`

- [ ] **Step 1: Add imports and state**

Add `Search` to the lucide-react import in `MobiView.tsx`:

```typescript
import { ChevronLeft, ChevronRight, MessageSquare, Palette, Search } from "lucide-react";
```

Add SearchPanel import:

```typescript
import { SearchPanel } from "@/components/search/SearchPanel";
import type { BookSearchResult } from "@/hooks/useBookSearch";
```

Add state inside `MobiView`:

```typescript
  const [searchPanelOpen, setSearchPanelOpen] = useState(false);
```

- [ ] **Step 2: Add navigation handler and keyboard shortcut**

```typescript
  const handleSearchNavigate = useCallback((result: BookSearchResult) => {
    if (result.pageNumber !== undefined) {
      // MOBI uses chapter index as page number
      setChapterIndex(result.pageNumber);
    }
  }, []);

  // Cmd+F / Ctrl+F keyboard shortcut
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
        e.preventDefault();
        setSearchPanelOpen((prev) => !prev);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);
```

- [ ] **Step 3: Add search button to toolbar**

Find the toolbar area (where the `BackButton`, highlights, chat buttons are) and add a search button. Look for the area with the `MessageSquare` button and add before it:

```tsx
        <button
          onClick={() => setSearchPanelOpen(true)}
          className={cn("p-2 rounded-md", getTextColor())}
          aria-label="Search in book"
        >
          <Search size={20} />
        </button>
```

- [ ] **Step 4: Add SearchPanel component**

Add before the closing `</div>` of the component, after `ChatPanel`:

```tsx
      {/* Search Panel */}
      <SearchPanel
        bookId={book.id}
        bookFormat="mobi"
        open={searchPanelOpen}
        onOpenChange={setSearchPanelOpen}
        onNavigate={handleSearchNavigate}
      />
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/mobi/MobiView.tsx
git commit -m "feat(search): wire SearchPanel into MOBI reader"
```

---

### Task 9: Wire SearchPanel into DjVu Reader

**Files:**
- Modify: `apps/main/src/components/djvu/DjvuView.tsx`

- [ ] **Step 1: Add imports and state**

Add `Search` to the lucide-react import in `DjvuView.tsx`:

```typescript
import { ChevronLeft, ChevronRight, MessageSquare, ZoomIn, ZoomOut, Search } from "lucide-react";
```

Add SearchPanel import:

```typescript
import { SearchPanel } from "@/components/search/SearchPanel";
import type { BookSearchResult } from "@/hooks/useBookSearch";
```

Add state inside `DjvuView`:

```typescript
  const [searchPanelOpen, setSearchPanelOpen] = useState(false);
```

- [ ] **Step 2: Add navigation handler and keyboard shortcut**

```typescript
  const handleSearchNavigate = useCallback((result: BookSearchResult) => {
    if (result.pageNumber !== undefined) {
      setCurrentPage(result.pageNumber);
    }
  }, []);

  // Cmd+F / Ctrl+F keyboard shortcut
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
        e.preventDefault();
        setSearchPanelOpen((prev) => !prev);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);
```

- [ ] **Step 3: Add search button to toolbar**

Find the toolbar area and add a search button. Look for the area with `MessageSquare` and add before it:

```tsx
        <IconButton
          onClick={() => setSearchPanelOpen(true)}
          className="hover:bg-black/10 dark:hover:bg-white/10 border-none"
          aria-label="Search in book"
        >
          <Search size={20} />
        </IconButton>
```

- [ ] **Step 4: Add SearchPanel component**

Add before the closing tag, after `ChatPanel`:

```tsx
      {/* Search Panel */}
      <SearchPanel
        bookId={book.id}
        bookFormat="djvu"
        open={searchPanelOpen}
        onOpenChange={setSearchPanelOpen}
        onNavigate={handleSearchNavigate}
      />
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/djvu/DjvuView.tsx
git commit -m "feat(search): wire SearchPanel into DjVu reader"
```

---

### Task 10: Build Verification

- [ ] **Step 1: Run Rust tests**

```bash
cd apps/main/src-tauri && cargo test 2>&1 | tail -30
```

Expected: All tests pass, including `test_search_book_text`.

- [ ] **Step 2: Run TypeScript build**

```bash
cd apps/main && npx tsc --noEmit 2>&1 | tail -30
```

Expected: No new errors from the search feature files.

- [ ] **Step 3: Commit any fixes if needed**

If there are build errors, fix them and commit:

```bash
git add -A
git commit -m "fix(search): resolve build errors"
```
