import { useCallback, useEffect, useState } from 'react';
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetFooter,
} from '@components/components/ui/sheet';
import { ScrollArea } from '@components/components/ui/scroll-area';
import {
  Tooltip,
  TooltipTrigger,
  TooltipContent,
} from '@components/components/ui/tooltip';
import { Pencil, Trash2 } from 'lucide-react';
import { getHighlightsForBook, deleteHighlightById } from '@/modules/highlight-storage';
import { triggerSyncOnWrite } from '@/modules/sync-triggers';
import { getHighlightHex, type HighlightColor } from '@/types/highlight';
import { NoteEditor } from './NoteEditor';
import type { Rendition } from 'epubjs/types';
import type { Selectable } from 'kysely';
import type { DB } from '@/modules/kysley';

type HighlightRow = Selectable<DB['highlights']>;

interface HighlightsPanelProps {
  bookSyncId: string;
  rendition: Rendition | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function HighlightsPanel({
  bookSyncId,
  rendition,
  open,
  onOpenChange,
}: HighlightsPanelProps) {
  const [highlights, setHighlights] = useState<HighlightRow[]>([]);
  const [editingHighlight, setEditingHighlight] = useState<HighlightRow | null>(
    null
  );
  const [hoveredId, setHoveredId] = useState<string | null>(null);

  const refreshHighlights = useCallback(async () => {
    if (!bookSyncId) return;
    const rows = await getHighlightsForBook(bookSyncId);
    setHighlights(rows as HighlightRow[]);
  }, [bookSyncId]);

  useEffect(() => {
    if (open && bookSyncId) {
      void refreshHighlights();
    }
  }, [open, bookSyncId, refreshHighlights]);

  const handleDelete = async (highlightId: string) => {
    await deleteHighlightById(highlightId);
    triggerSyncOnWrite();
    await refreshHighlights();
  };

  const handleNavigate = (cfiRange: string) => {
    void rendition?.display(cfiRange);
  };

  return (
    <>
      <Sheet open={open} onOpenChange={onOpenChange}>
        <SheetContent side="right" className="w-[400px] flex flex-col">
          <SheetHeader>
            <SheetTitle className="text-lg font-semibold">
              Highlights
            </SheetTitle>
          </SheetHeader>

          <ScrollArea className="flex-1 px-4">
            {highlights.length === 0 ? (
              <div className="flex flex-col items-center justify-center py-16 text-center">
                <h3 className="text-base font-semibold mb-1">
                  No highlights yet
                </h3>
                <p className="text-sm text-muted-foreground">
                  Select text while reading to create a highlight.
                </p>
              </div>
            ) : (
              <div className="flex flex-col gap-2">
                {highlights.map((hl) => (
                  <div
                    key={hl.id}
                    className="relative cursor-pointer rounded-md p-3 hover:bg-accent/50 transition-colors"
                    style={{
                      borderLeft: `3px solid ${getHighlightHex(hl.color as HighlightColor)}`,
                    }}
                    onClick={() => handleNavigate(hl.cfi_range)}
                    onMouseEnter={() => setHoveredId(hl.id)}
                    onMouseLeave={() => setHoveredId(null)}
                  >
                    <p className="text-sm line-clamp-2">{hl.text}</p>
                    {hl.chapter && (
                      <p className="text-xs text-muted-foreground mt-1">
                        {hl.chapter}
                      </p>
                    )}
                    {hl.note && (
                      <p className="text-xs italic text-muted-foreground mt-1 line-clamp-1">
                        {hl.note}
                      </p>
                    )}

                    {hoveredId === hl.id && (
                      <div className="absolute right-2 top-2 flex items-center gap-1">
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <button
                              className="p-1 rounded hover:bg-accent"
                              aria-label="Edit note"
                              onClick={(e) => {
                                e.stopPropagation();
                                setEditingHighlight(hl);
                              }}
                            >
                              <Pencil size={16} />
                            </button>
                          </TooltipTrigger>
                          <TooltipContent>Edit note</TooltipContent>
                        </Tooltip>
                        <Tooltip>
                          <TooltipTrigger asChild>
                            <button
                              className="p-1 rounded hover:bg-destructive/20 text-destructive"
                              aria-label="Delete highlight"
                              onClick={(e) => {
                                e.stopPropagation();
                                void handleDelete(hl.id);
                              }}
                            >
                              <Trash2 size={16} />
                            </button>
                          </TooltipTrigger>
                          <TooltipContent>Delete highlight</TooltipContent>
                        </Tooltip>
                      </div>
                    )}
                  </div>
                ))}
              </div>
            )}
          </ScrollArea>

          <SheetFooter>
            <p className="text-xs text-muted-foreground">
              {highlights.length} highlight{highlights.length !== 1 ? 's' : ''}
            </p>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      <NoteEditor
        highlight={editingHighlight}
        open={editingHighlight !== null}
        onOpenChange={(isOpen) => {
          if (!isOpen) setEditingHighlight(null);
        }}
        onSaved={refreshHighlights}
      />
    </>
  );
}
