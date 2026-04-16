// apps/main/src/components/reader/BottomBar.tsx
import type { ReactNode } from 'react';

export function BottomBar({ children }: { children: ReactNode }) {
  return (
    <div className="reader-bottom-bar" style={{
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      padding: '8px 12px', borderTop: '1px solid var(--reader-border, #e5e5e5)',
    }}>
      {children}
    </div>
  );
}
