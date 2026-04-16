// apps/main/src/components/reader/SidePanel.tsx
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/components/ui/sheet';
import type { ReactNode } from 'react';

export interface SidePanelProps {
  open: boolean;
  title: string;
  onClose: () => void;
  children: ReactNode;
}

export function SidePanel({ open, title, onClose, children }: SidePanelProps) {
  return (
    <Sheet open={open} onOpenChange={(o) => { if (!o) onClose(); }}>
      <SheetContent side="right">
        <SheetHeader>
          <SheetTitle>{title}</SheetTitle>
        </SheetHeader>
        <div style={{ paddingTop: 12 }}>{children}</div>
      </SheetContent>
    </Sheet>
  );
}
