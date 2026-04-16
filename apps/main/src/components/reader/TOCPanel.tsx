// apps/main/src/components/reader/TOCPanel.tsx
import type { TOCEntry, Location } from '@/types/reader';

export interface TOCPanelProps {
  toc: TOCEntry[];
  onJump: (loc: Location) => void;
}

export function TOCPanel({ toc, onJump }: TOCPanelProps) {
  if (toc.length === 0) return <div style={{ opacity: 0.7 }}>No table of contents available.</div>;
  return <ul style={{ listStyle: 'none', paddingLeft: 0 }}>{toc.map((e, i) => <Entry key={i} entry={e} onJump={onJump} depth={0} />)}</ul>;
}

function Entry({ entry, onJump, depth }: { entry: TOCEntry; onJump: (loc: Location) => void; depth: number }) {
  return (
    <li>
      <button
        onClick={() => onJump(entry.location)}
        style={{ paddingLeft: depth * 16, padding: '6px 0', display: 'block', width: '100%', textAlign: 'left', background: 'none', border: 0, cursor: 'pointer' }}
      >
        {entry.title}
      </button>
      {entry.children.length > 0 && (
        <ul style={{ listStyle: 'none', paddingLeft: 0 }}>
          {entry.children.map((c, i) => <Entry key={i} entry={c} onJump={onJump} depth={depth + 1} />)}
        </ul>
      )}
    </li>
  );
}
