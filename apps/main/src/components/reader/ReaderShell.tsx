// apps/main/src/components/reader/ReaderShell.tsx
import { useEffect, useRef, useState } from 'react';
import { useAtomValue } from 'jotai';
import type { Book } from '@/generated';
import type {
  Location, SelectionInfo, Paragraph, RendererHandle, AppliedHighlight, Viewport, BookContent,
} from '@/types/reader';
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

export function ReaderShell({ book }: { book: Book }) {
  const adapter = useBookAdapter(book);
  const themeKey = useAtomValue(themeAtom);
  const fontSettings = useAtomValue(fontSettingsAtom);
  const invertedDarkMode = useAtomValue(invertedDarkModeAtom);
  const [location, setLocation] = useState<Location>(() => decodeLocation(book.location, book.kind as BookKind));
  const [_selection, setSelection] = useState<SelectionInfo | null>(null);
  const [_visibleParagraphs, setVisibleParagraphs] = useState<Paragraph[]>([]);
  const [openPanel, setOpenPanel] = useState<PanelId | null>(null);
  const [viewport] = useState<Viewport>({ scale: 1 });
  const rendererRef = useRef<RendererHandle>(null);
  const highlights: AppliedHighlight[] = []; // wired in Task 26

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
            highlights={highlights}
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
            highlights={highlights}
            onLocationChange={setLocation}
            onVisibleParagraphsChange={setVisibleParagraphs}
            onSelection={setSelection}
          />
        )}
      </div>
      <BottomBar>{null /* TTSControls wired in Task 25 */}</BottomBar>
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
      {/* Other panels wired in feature tasks */}
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
