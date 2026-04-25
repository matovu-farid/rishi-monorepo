import { useEffect, useRef } from 'react';
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

/**
 * Sanitizes a snippet string, allowing only <mark> tags and stripping all
 * other HTML. This is safe because highlightedSnippet comes from either
 * FTS5's snippet() function (which only wraps matched terms in <mark> tags)
 * or from highlightText() in the hook (which regex-escapes the query before
 * wrapping in <mark>). No user-controlled HTML is injected.
 */
function sanitizeSnippet(html: string): string {
  return html
    .replace(/<(?!\/?mark\b)[^>]+>/gi, '') // strip all tags except <mark> and </mark>
    .replace(/<mark\s[^>]*>/gi, '<mark>') // strip attributes from mark tags
    .replace(/&(?!amp;|lt;|gt;|quot;|#\d+;|#x[\da-f]+;)/gi, '&amp;'); // encode stray ampersands
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

  if (!open) return null;

  return (
    <div className="fixed inset-y-0 right-0 z-50 w-[400px] bg-white dark:bg-gray-900 border-l border-gray-200 dark:border-gray-700 shadow-xl flex flex-col">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold">Search</h2>
        <button
          onClick={() => onOpenChange(false)}
          className="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-800"
          aria-label="Close"
        >
          &times;
        </button>
      </div>

      {/* Search input */}
      <div className="px-4 pb-2 pt-3">
        <div className="flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-800/50 px-3 py-2">
          <Search size={14} className="text-gray-400 shrink-0" />
          <input
            ref={inputRef}
            type="text"
            className="flex-1 bg-transparent text-sm outline-none placeholder:text-gray-400"
            placeholder='Search or "exact phrase"'
            value={query}
            onChange={(e) => handleQueryChange(e.target.value)}
            onKeyDown={handleKeyDown}
          />
          {isSearching && <Loader2 size={14} className="animate-spin text-gray-400" />}
        </div>

        {/* Result count */}
        {query.trim() && (
          <p className="text-xs text-gray-500 mt-2">
            {results.length} result{results.length !== 1 ? 's' : ''}
          </p>
        )}
      </div>

      {/* Results list */}
      <div className="flex-1 overflow-y-auto px-4">
        {!query.trim() ? (
          <div className="flex flex-col items-center justify-center py-16 text-center">
            <h3 className="text-base font-semibold mb-1">Search this book</h3>
            <p className="text-sm text-gray-500">
              Type to find text, or press Enter for smart search.
            </p>
          </div>
        ) : results.length === 0 && !isSearching ? (
          <div className="flex flex-col items-center justify-center py-16 text-center">
            <h3 className="text-base font-semibold mb-1">No results found</h3>
            <p className="text-sm text-gray-500">
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
      </div>

      {/* Footer */}
      <div className="px-4 py-2 border-t border-gray-200 dark:border-gray-700">
        <p className="text-xs text-gray-500">
          {activeMode === 'semantic' && results.length > 0
            ? 'Showing semantically related passages'
            : 'Press Enter for smart search'}
        </p>
      </div>
    </div>
  );
}

function SearchResultItem({
  result,
  onNavigate,
}: {
  result: BookSearchResult;
  onNavigate: (result: BookSearchResult) => void;
}) {
  // sanitizeSnippet strips all HTML except <mark> tags which come from
  // FTS5 snippet() or highlightText() (both regex-escape user input).
  const sanitizedHtml = result.highlightedSnippet
    ? sanitizeSnippet(result.highlightedSnippet)
    : null;

  return (
    <button
      className="cursor-pointer rounded-md p-3 hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors text-left w-full"
      style={{ borderLeft: '3px solid rgba(156, 163, 175, 0.4)' }}
      onClick={() => onNavigate(result)}
    >
      {sanitizedHtml ? (
        <p
          className="text-sm line-clamp-3 [&_mark]:bg-yellow-500/30 [&_mark]:text-yellow-200 [&_mark]:rounded-sm"
          dangerouslySetInnerHTML={{ __html: sanitizedHtml }}
        />
      ) : (
        <p className="text-sm line-clamp-3">{result.snippet}</p>
      )}
      {(result.pageNumber || result.chapter) && (
        <p className="text-xs text-gray-500 mt-1">
          {[result.chapter, result.pageNumber ? `Page ${result.pageNumber}` : null]
            .filter(Boolean)
            .join(' · ')}
        </p>
      )}
    </button>
  );
}
