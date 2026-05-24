import { useEffect, useRef } from 'react'
import { MessageSquarePlus, MessageSquareText, Play, Trash2 } from 'lucide-react'
import { HIGHLIGHT_COLORS, type HighlightColor } from '@/types/highlight'

interface SelectionPopoverProps {
  cfiRange: string
  selectedText: string
  position: { x: number; y: number }
  onHighlight: (color: HighlightColor) => void
  onClose: () => void
  onReadAloudFrom?: () => void
  /** When set, the matching swatch is marked active (existing-highlight mode). */
  currentColor?: HighlightColor
  /** When set, renders the note button (existing-highlight mode). */
  onEditNote?: () => void
  /** Renders the note button as "View note" (filled icon) instead of "Add note" — a visual indicator that a note already exists. */
  hasNote?: boolean
  /** When set, renders a Delete button (existing-highlight mode). */
  onDelete?: () => void
  /** When set (and `onEditNote` is NOT set), renders the "Add note" button for a fresh selection — clicking creates a note-only highlight. `onEditNote` wins if both are provided. */
  onAddNote?: () => void
}

export function SelectionPopover({
  position,
  onHighlight,
  onClose,
  onReadAloudFrom,
  currentColor,
  onEditNote,
  hasNote,
  onDelete,
  onAddNote
}: SelectionPopoverProps) {
  // Edit on an existing highlight wins over Add for a fresh selection so
  // selecting text on top of an existing note doesn't accidentally create
  // a second note-only row.
  const noteHandler = onEditNote ?? onAddNote
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        onClose()
      }
    }
    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [onClose])

  // Close if clicking outside the popover
  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        onClose()
      }
    }
    // Delay to avoid catching the selection click itself
    const timer = setTimeout(() => {
      document.addEventListener('mousedown', handleClickOutside)
    }, 100)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('mousedown', handleClickOutside)
    }
  }, [onClose])

  return (
    // TODO(Wave F): clamp x/y to viewport so the popover doesn't get clipped against the right/bottom edges.
    <div
      ref={containerRef}
      data-testid="selection-popover"
      className="fixed z-50 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg shadow-md p-2"
      style={{ left: position.x, top: position.y }}
    >
      <div className="flex items-center gap-2">
        {onReadAloudFrom ? (
          <button
            type="button"
            className="rounded-full border border-gray-300/50 flex items-center justify-center transition-transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-blue-500 bg-gray-100 dark:bg-gray-700"
            style={{ width: 28, height: 28 }}
            aria-label="Read aloud from here"
            title="Read aloud from here"
            onClick={() => {
              onReadAloudFrom()
              onClose()
            }}
          >
            <Play size={14} className="text-gray-700 dark:text-gray-200" />
          </button>
        ) : null}
        {HIGHLIGHT_COLORS.map((c) => {
          const isCurrent = currentColor === c.name
          return (
            <button
              key={c.name}
              type="button"
              aria-pressed={currentColor ? isCurrent : undefined}
              className={
                'rounded-full border border-gray-300/50 transition-transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-blue-500 ' +
                (isCurrent ? 'ring-2 ring-inset ring-blue-500' : '')
              }
              style={{
                width: 28,
                height: 28,
                backgroundColor: c.hex
              }}
              aria-label={`Highlight ${c.name}`}
              title={`Highlight ${c.name}`}
              onClick={() => {
                onHighlight(c.name)
                onClose()
              }}
            />
          )
        })}
        {noteHandler ? (
          <button
            type="button"
            aria-label={hasNote ? 'View note' : 'Add note'}
            title={hasNote ? 'View note' : 'Add note'}
            className={
              'p-1 rounded focus:outline-none focus:ring-2 focus:ring-blue-500 ' +
              (hasNote
                ? 'text-blue-600 dark:text-blue-400 hover:bg-blue-100 dark:hover:bg-blue-900/30'
                : 'hover:bg-gray-100 dark:hover:bg-gray-700')
            }
            onClick={() => {
              noteHandler()
              onClose()
            }}
          >
            {hasNote ? (
              <MessageSquareText size={16} />
            ) : (
              <MessageSquarePlus size={16} className="text-gray-700 dark:text-gray-200" />
            )}
          </button>
        ) : null}
        {onDelete ? (
          <button
            type="button"
            aria-label="Delete highlight"
            title="Delete highlight"
            className="p-1 rounded hover:bg-red-100 dark:hover:bg-red-900/30 text-red-500 focus:outline-none focus:ring-2 focus:ring-red-500"
            onClick={() => {
              onDelete()
              onClose()
            }}
          >
            <Trash2 size={16} />
          </button>
        ) : null}
      </div>
    </div>
  )
}
