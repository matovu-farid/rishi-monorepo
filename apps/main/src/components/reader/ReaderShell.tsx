// apps/main/src/components/reader/ReaderShell.tsx
import { useCallback, useEffect, useRef, useState } from 'react';
import { Player } from '@/models/PlayerClass';
import TTSControls from '@/components/TTSControls';
import { useAtomValue } from 'jotai';
import type { Book } from '@/generated';
import type {
  Location, SelectionInfo, Paragraph, RendererHandle, AppliedHighlight, Viewport, BookContent,
} from '@/types/reader';
import type { SerializedSelection } from '@/types/reader';
import { useDrag } from '@use-gesture/react';
import { useBookAdapter } from './adapters/useBookAdapter';
import { ReflowableRenderer } from './renderers/ReflowableRenderer';
import { PagedRenderer } from './renderers/PagedRenderer';
import { TopBar, type PanelId } from './TopBar';
import { BottomBar } from './BottomBar';
import { SidePanel } from './SidePanel';
import { TOCPanel } from './TOCPanel';
import { themeAtom } from '@/stores/epub_atoms';
import { themes } from '@/themes/themes';
import { fontSettingsAtom, invertedDarkModeAtom } from '@/atoms/reader';
import { decodeLocation, encodeLocation } from '@/utils/location-codec';
import { updateBookLocation } from '@/generated';
import { triggerSyncOnWrite } from '@/modules/sync-triggers';
import type { BookKind } from '@/types/reader';
import { getHighlightsForBook, saveHighlight } from '@/modules/highlight-storage';
import { SelectionPopover } from '@/components/highlights/SelectionPopover';
import type { HighlightColor } from '@/types/highlight';
import { db } from '@/modules/kysley';
import { ReaderSettings } from './ReaderSettings';
import { HighlightsPanel } from '@/components/highlights/HighlightsPanel';
import { ChatPanel } from '@/components/chat/ChatPanel';

export function ReaderShell({ book }: { book: Book }) {
  const adapter = useBookAdapter(book);
  const themeKey = useAtomValue(themeAtom);
  const fontSettings = useAtomValue(fontSettingsAtom);
  const invertedDarkMode = useAtomValue(invertedDarkModeAtom);
  const [location, setLocation] = useState<Location>(() => decodeLocation(book.location, book.kind as BookKind));
  const [selection, setSelection] = useState<SelectionInfo | null>(null);
  const bookSyncIdRef = useRef<string | null>(null);

  // Look up the book's sync_id for highlight storage
  useEffect(() => {
    void db.selectFrom('books')
      .select(['sync_id'])
      .where('id', '=', book.id)
      .executeTakeFirst()
      .then((row) => { bookSyncIdRef.current = row?.sync_id ?? null; });
  }, [book.id]);
  const [visibleParagraphs, setVisibleParagraphs] = useState<Paragraph[]>([]);
  const [openPanel, setOpenPanel] = useState<PanelId | null>(null);
  const [viewport] = useState<Viewport>({ scale: 1 });
  const rendererRef = useRef<RendererHandle>(null);
  const [highlightsState, setHighlightsState] = useState<AppliedHighlight[]>([]);

  const refreshHighlights = useCallback(async () => {
    const rows = await getHighlightsForBook(String(book.id));
    setHighlightsState(rows
      .filter((row) => isHighlightForCurrentLocation(row, location))
      .map((row) => ({ id: String(row.id), serialized: deserializeHighlight(row), color: row.color })));
  }, [book.id, location]);

  useEffect(() => {
    void refreshHighlights();
  }, [refreshHighlights]);

  useEffect(() => {
    rendererRef.current?.applyHighlights(highlightsState);
  }, [highlightsState]);

  const audioRef = useRef<HTMLAudioElement | null>(null);
  const playerRef = useRef<Player | null>(null);
  // Force re-render when player is initialized so TTSControls can mount
  const [, forceRerender] = useState(0);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (openPanel) {
        if (e.key === 'Escape') { setOpenPanel(null); e.preventDefault(); }
        return;
      }
      switch (e.key) {
        case 'ArrowRight':
        case 'PageDown':
        case ' ':
          rendererRef.current?.next();
          e.preventDefault();
          break;
        case 'ArrowLeft':
        case 'PageUp':
          rendererRef.current?.prev();
          e.preventDefault();
          break;
      }
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [openPanel]);

  useEffect(() => {
    if (!audioRef.current) return;
    const player = new Player(audioRef.current);
    playerRef.current = player;
    void player.initialize(String(book.id));
    player.onRequestNextPage = () => rendererRef.current?.next();
    player.onRequestPrevPage = () => rendererRef.current?.prev();
    forceRerender((n) => n + 1);
    return () => { player.cleanup(); playerRef.current = null; };
  }, [book.id]);

  useEffect(() => {
    // Map our Paragraph -> ParagraphWithIndex shape (text + index)
    const mapped = visibleParagraphs.map((p) => ({ text: p.text, index: p.id }));
    playerRef.current?.setVisibleParagraphs(mapped);
  }, [visibleParagraphs]);

  useEffect(() => {
    const handle = setTimeout(() => {
      void updateBookLocation({ bookId: book.id, newLocation: encodeLocation(location) })
        .then(() => triggerSyncOnWrite())
        .catch((err) => console.error('Failed to save location:', err));
    }, 1000);
    return () => clearTimeout(handle);
  }, [book.id, location]);

  const swipeBind = useDrag(({ swipe: [swipeX] }) => {
    if (swipeX === -1) rendererRef.current?.next();
    if (swipeX === 1) rendererRef.current?.prev();
  });

  const themeColors = themes[themeKey] ?? themes[Object.keys(themes)[0] as keyof typeof themes];
  const theme = { bg: themeColors.background, fg: themeColors.color, accent: '#06f' };

  return (
    <div className="reader-shell" style={{
      display: 'grid', gridTemplateRows: 'auto 1fr auto',
      height: '100vh', background: theme.bg, color: theme.fg,
    }}>
      <TopBar book={book} progressLabel={progressLabel(adapter, location)} onOpenPanel={setOpenPanel} />
      <div style={{ position: 'relative', overflow: 'hidden' }} {...swipeBind()}>
        {adapter.status === 'loading' && <div style={{ padding: 16 }}>Loading…</div>}
        {adapter.status === 'error' && <div style={{ padding: 16, color: 'crimson' }}>Failed to open: {adapter.error?.message}</div>}
        {adapter.content?.kind === 'reflowable' && location.kind === 'reflowable' && (
          <ReflowableRenderer
            ref={rendererRef}
            content={adapter.content}
            location={location}
            theme={theme}
            fontSettings={fontSettings}
            highlights={highlightsState}
            onLocationChange={setLocation}
            onVisibleParagraphsChange={setVisibleParagraphs}
            onSelection={setSelection}
          />
        )}
        {adapter.content?.kind === 'paged' && location.kind === 'paged' && (
          <PagedRenderer
            ref={rendererRef}
            content={adapter.content}
            location={location}
            theme={theme}
            viewport={viewport}
            invertedDarkMode={invertedDarkMode}
            highlights={highlightsState}
            onLocationChange={setLocation}
            onVisibleParagraphsChange={setVisibleParagraphs}
            onSelection={setSelection}
          />
        )}
        {selection && (() => {
          const rect = selection.rects[0];
          const position = rect
            ? { x: rect.left + rect.width / 2, y: rect.top - 48 }
            : { x: 0, y: 0 };
          return (
            <SelectionPopover
              cfiRange={selection.serialized.kind === 'reflowable' ? selection.serialized.cfiRange : ''}
              selectedText={selection.text}
              position={position}
              onHighlight={(color: HighlightColor) => {
                const syncId = bookSyncIdRef.current;
                if (!syncId) { setSelection(null); return; }
                if (selection.serialized.kind === 'paged') {
                  // TODO: paged highlights not yet supported in the cfi_range schema
                  console.warn('Highlights for paged formats not yet supported');
                  setSelection(null);
                  return;
                }
                void saveHighlight({
                  bookSyncId: syncId,
                  cfiRange: selection.serialized.cfiRange,
                  text: selection.text,
                  color,
                }).then(() => refreshHighlights()).then(() => setSelection(null));
              }}
              onClose={() => setSelection(null)}
            />
          );
        })()}
      </div>
      <BottomBar>
        <audio ref={audioRef} hidden />
        {playerRef.current ? <TTSControls player={playerRef.current} /> : null}
      </BottomBar>
      <SidePanel
        open={openPanel === 'toc'}
        title="Table of contents"
        onClose={() => setOpenPanel(null)}
      >
        <TOCPanel
          toc={adapter.content?.metadata.tableOfContents ?? []}
          onJump={(loc) => { setLocation(loc); setOpenPanel(null); }}
        />
      </SidePanel>
      <SidePanel open={openPanel === 'settings'} title="Settings" onClose={() => setOpenPanel(null)}>
        <ReaderSettings contentKind={adapter.content?.kind ?? 'reflowable'} />
      </SidePanel>
      {/* HighlightsPanel and ChatPanel manage their own Sheet; pass open/onOpenChange directly */}
      <HighlightsPanel
        bookSyncId={bookSyncIdRef.current ?? ''}
        rendition={null}
        open={openPanel === 'highlights'}
        onOpenChange={(open) => { if (!open) setOpenPanel(null); }}
      />
      <ChatPanel
        bookId={book.id}
        bookSyncId={bookSyncIdRef.current ?? ''}
        bookTitle={book.title}
        rendition={null}
        open={openPanel === 'chat'}
        onOpenChange={(open) => { if (!open) setOpenPanel(null); }}
      />
    </div>
  );
}

function progressLabel(adapter: { content: BookContent | null }, loc: Location): string {
  if (!adapter.content) return '';
  if (adapter.content.kind === 'paged' && loc.kind === 'paged') {
    return `Page ${loc.pageIndex + 1} of ${adapter.content.pageCount}`;
  }
  if (adapter.content.kind === 'reflowable' && loc.kind === 'reflowable') {
    const total = adapter.content.chapters.length;
    const idx = adapter.content.chapters.findIndex((c) => c.id === loc.chapterId);
    return idx >= 0 ? `Chapter ${idx + 1} of ${total}` : '';
  }
  return '';
}

/**
 * Determines whether a stored highlight row belongs to the current reader location.
 *
 * SCHEMA DEVIATION: The actual highlights table does not have a JSON `location` field.
 * Instead it uses `cfi_range` (a string of the form `${chapterId}::${pathSpec}`).
 * For reflowable content we match by chapterId prefix.
 * Paged highlights are not stored in this schema, so they never match.
 */
function isHighlightForCurrentLocation(row: { cfi_range: string }, loc: Location): boolean {
  if (loc.kind === 'reflowable') {
    return row.cfi_range.startsWith(loc.chapterId + '::');
  }
  // Paged highlights are not stored in the current schema — nothing to apply.
  return false;
}

/**
 * Converts a highlight row into a SerializedSelection for the renderer.
 *
 * SCHEMA DEVIATION: `cfi_range` is the serialized range string produced by
 * `serializeRange()` in ReflowableRenderer (`${chapterId}::${pathSpec}`).
 * We extract the chapterId from the prefix and wrap it in the typed union.
 */
function deserializeHighlight(row: { cfi_range: string }): SerializedSelection {
  const sepIdx = row.cfi_range.indexOf('::');
  const chapterId = sepIdx >= 0 ? row.cfi_range.slice(0, sepIdx) : row.cfi_range;
  return { kind: 'reflowable', chapterId, cfiRange: row.cfi_range };
}
