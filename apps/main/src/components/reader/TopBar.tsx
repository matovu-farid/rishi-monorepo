// apps/main/src/components/reader/TopBar.tsx
import { ListTree, Palette, Highlighter, MessageSquare } from 'lucide-react';
import { IconButton } from '@components/ui/IconButton';
import { BackButton } from '@components/BackButton';
import type { Book } from '@/generated';

export type PanelId = 'toc' | 'settings' | 'highlights' | 'chat';

export interface TopBarProps {
  book: Book;
  progressLabel: string;
  onOpenPanel: (panel: PanelId) => void;
}

export function TopBar({ book, progressLabel, onOpenPanel }: TopBarProps) {
  return (
    <div className="reader-top-bar" style={{
      display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px',
      borderBottom: '1px solid var(--reader-border, #e5e5e5)',
    }}>
      <BackButton />
      <div style={{ flex: 1, overflow: 'hidden', whiteSpace: 'nowrap', textOverflow: 'ellipsis' }}>
        {book.title || 'Untitled'}
      </div>
      <div style={{ opacity: 0.7, fontSize: 13 }}>{progressLabel}</div>
      <IconButton aria-label="Table of contents" onClick={() => onOpenPanel('toc')}><ListTree size={18} /></IconButton>
      <IconButton aria-label="Settings"           onClick={() => onOpenPanel('settings')}><Palette size={18} /></IconButton>
      <IconButton aria-label="Highlights"         onClick={() => onOpenPanel('highlights')}><Highlighter size={18} /></IconButton>
      <IconButton aria-label="Chat"               onClick={() => onOpenPanel('chat')}><MessageSquare size={18} /></IconButton>
    </div>
  );
}
