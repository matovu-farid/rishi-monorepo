import { useCallback, useEffect, useState } from 'react'
import { Pencil, Trash2 } from 'lucide-react'
import { getHighlightsForBook, deleteHighlightById } from '@/modules/highlight-storage'
import { getSyncService } from '@/services'
import { getHighlightHex, type HighlightColor } from '@/types/highlight'
import { NoteEditor } from './NoteEditor'
import type { HighlightRow } from '@/modules/highlight-storage'
import type { Rendition } from 'epubjs/types'

interface HighlightsPanelProps {
  bookSyncId: string
  rendition: Rendition | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function HighlightsPanel({
  bookSyncId,
  rendition,
  open,
  onOpenChange
}: HighlightsPanelProps) {
  const [highlights, setHighlights] = useState<HighlightRow[]>([])
  const [editingHighlight, setEditingHighlight] = useState<HighlightRow | null>(null)
  const [hoveredId, setHoveredId] = useState<string | null>(null)

  const refreshHighlights = useCallback(async () => {
    if (!bookSyncId) return
    const rows = await getHighlightsForBook(bookSyncId)
    setHighlights(rows)
  }, [bookSyncId])

  useEffect(() => {
    if (open && bookSyncId) {
      // Why: state depends on async DB load — legitimate effect setState pattern
      // eslint-disable-next-line react-hooks/set-state-in-effect
      void refreshHighlights()
    }
  }, [open, bookSyncId, refreshHighlights])

  const handleDelete = async (highlightId: string) => {
    try {
      await deleteHighlightById(highlightId)
      getSyncService().triggerWrite()
      await refreshHighlights()
    } catch (err) {
      console.error('[highlights] delete failed:', err)
    }
  }

  const handleNavigate = (cfiRange: string) => {
    void rendition?.display(cfiRange)
  }

  if (!open) return null

  return (
    <>
      {/* Sheet panel */}
      <div className="fixed inset-y-0 right-0 z-50 w-[400px] bg-white dark:bg-gray-900 border-l border-gray-200 dark:border-gray-700 shadow-xl flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-gray-200 dark:border-gray-700">
          <h2 className="text-lg font-semibold">Highlights</h2>
          <button
            onClick={() => onOpenChange(false)}
            className="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-800"
            aria-label="Close"
          >
            &times;
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto px-4 py-2">
          {highlights.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-16 text-center">
              <h3 className="text-base font-semibold mb-1">No highlights yet</h3>
              <p className="text-sm text-gray-500">
                Select text while reading to create a highlight.
              </p>
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              {highlights.map((hl) => (
                <div
                  key={hl.id}
                  className="relative cursor-pointer rounded-md p-3 hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
                  style={{
                    borderLeft: `3px solid ${getHighlightHex(hl.color as HighlightColor)}`
                  }}
                  onClick={() => handleNavigate(hl.cfiRange)}
                  onMouseEnter={() => setHoveredId(hl.id)}
                  onMouseLeave={() => setHoveredId(null)}
                >
                  <p className="text-sm line-clamp-2">{hl.text}</p>
                  {hl.chapter ? <p className="text-xs text-gray-500 mt-1">{hl.chapter}</p> : null}
                  {hl.note ? (
                    <p className="text-xs italic text-gray-500 mt-1 line-clamp-1">{hl.note}</p>
                  ) : null}

                  {hoveredId === hl.id && (
                    <div className="absolute right-2 top-2 flex items-center gap-1">
                      <button
                        className="p-1 rounded hover:bg-gray-200 dark:hover:bg-gray-700"
                        aria-label="Edit note"
                        title="Edit note"
                        onClick={(e) => {
                          e.stopPropagation()
                          setEditingHighlight(hl)
                        }}
                      >
                        <Pencil size={16} />
                      </button>
                      <button
                        className="p-1 rounded hover:bg-red-100 dark:hover:bg-red-900/30 text-red-500"
                        aria-label="Delete highlight"
                        title="Delete highlight"
                        onClick={(e) => {
                          e.stopPropagation()
                          void handleDelete(hl.id)
                        }}
                      >
                        <Trash2 size={16} />
                      </button>
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-4 py-2 border-t border-gray-200 dark:border-gray-700">
          <p className="text-xs text-gray-500">
            {highlights.length} highlight{highlights.length !== 1 ? 's' : ''}
          </p>
        </div>
      </div>

      <NoteEditor
        highlight={editingHighlight}
        open={editingHighlight !== null}
        onOpenChange={(isOpen) => {
          if (!isOpen) setEditingHighlight(null)
        }}
        onSaved={refreshHighlights}
      />
    </>
  )
}
