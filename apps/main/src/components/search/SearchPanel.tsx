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
          className="text-sm line-clamp-3 [&_mark]:bg-yellow-500/30 [&_mark]:text-yellow-200 [&_mark]:rounded-sm"
          // sanitizeSnippet strips all HTML tags except <mark>/<mark> before rendering.
          // highlightedSnippet only ever contains <mark>-wrapped text from FTS5 or
          // the highlightText() utility (which regex-escapes user input).
          dangerouslySetInnerHTML={{ __html: sanitizeSnippet(result.highlightedSnippet) }}
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
