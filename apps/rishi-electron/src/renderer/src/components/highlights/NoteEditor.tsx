import React, { useEffect, useState } from 'react'
import { updateHighlightNote } from '@/modules/highlight-storage'
import { triggerSyncOnWrite } from '@/modules/sync-triggers'
import type { HighlightRow } from '@/modules/highlight-storage'

interface NoteEditorProps {
  highlight: HighlightRow | null
  open: boolean
  onOpenChange: (open: boolean) => void
  onSaved: () => void
}

export function NoteEditor({ highlight, open, onOpenChange, onSaved }: NoteEditorProps) {
  const [noteValue, setNoteValue] = useState('')

  useEffect(() => {
    if (highlight) {
      setNoteValue(highlight.note ?? '')
    }
  }, [highlight])

  const handleSave = async () => {
    if (!highlight) return
    await updateHighlightNote(highlight.id, noteValue)
    triggerSyncOnWrite()
    onSaved()
    onOpenChange(false)
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault()
      void handleSave()
    }
  }

  if (!open) return null

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center">
      {/* Overlay */}
      <div className="absolute inset-0 bg-black/40" onClick={() => onOpenChange(false)} />
      {/* Dialog */}
      <div className="relative bg-white dark:bg-gray-900 rounded-xl shadow-2xl p-6 w-full max-w-md z-10">
        <h3 className="text-lg font-semibold mb-4">Edit Note</h3>

        <textarea
          rows={4}
          className="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-transparent px-3 py-2 text-sm placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 resize-none"
          placeholder="Add a note..."
          value={noteValue}
          onChange={(e) => setNoteValue(e.target.value)}
          onKeyDown={handleKeyDown}
        />

        <div className="flex justify-end gap-2 mt-4">
          <button
            className="px-4 py-2 text-sm rounded-md hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
            onClick={() => onOpenChange(false)}
          >
            Discard changes
          </button>
          <button
            className="px-4 py-2 text-sm rounded-md bg-blue-600 text-white hover:bg-blue-700 transition-colors"
            onClick={handleSave}
          >
            Save note
          </button>
        </div>
      </div>
    </div>
  )
}
