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
  const bookIdRef = useRef(bookId);

  // Keep refs in sync
  useEffect(() => {
    queryRef.current = query;
  }, [query]);

  bookIdRef.current = bookId;

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
        if (queryRef.current !== searchQuery || bookIdRef.current !== bookId) return; // stale
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
        if (queryRef.current !== searchQuery || bookIdRef.current !== bookId) return; // stale
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
      if (queryRef.current !== searchQuery || bookIdRef.current !== bookId) return; // stale

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
