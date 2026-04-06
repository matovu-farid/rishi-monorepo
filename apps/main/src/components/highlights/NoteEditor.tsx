import React, { useEffect, useState } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@components/components/ui/dialog';
import { Textarea } from '@components/components/ui/textarea';
import { Button } from '@components/components/ui/button';
import { updateHighlightNote } from '@/modules/highlight-storage';
import { triggerSyncOnWrite } from '@/modules/sync-triggers';
import type { Selectable } from 'kysely';
import type { DB } from '@/modules/kysley';

type HighlightRow = Selectable<DB['highlights']>;

interface NoteEditorProps {
  highlight: HighlightRow | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}

export function NoteEditor({
  highlight,
  open,
  onOpenChange,
  onSaved,
}: NoteEditorProps) {
  const [noteValue, setNoteValue] = useState('');

  useEffect(() => {
    if (highlight) {
      setNoteValue(highlight.note ?? '');
    }
  }, [highlight]);

  const handleSave = async () => {
    if (!highlight) return;
    await updateHighlightNote(highlight.id, noteValue);
    triggerSyncOnWrite();
    onSaved();
    onOpenChange(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault();
      handleSave();
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle className="text-lg font-semibold">
            Edit Note
          </DialogTitle>
        </DialogHeader>

        <Textarea
          rows={4}
          placeholder="Add a note..."
          value={noteValue}
          onChange={(e) => setNoteValue(e.target.value)}
          onKeyDown={handleKeyDown}
        />

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Discard changes
          </Button>
          <Button onClick={handleSave}>Save note</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
