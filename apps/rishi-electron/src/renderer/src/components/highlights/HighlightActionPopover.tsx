import { useEffect, useRef } from 'react'
import { MessageSquarePlus, MessageSquareText, Trash2 } from 'lucide-react'
import {
  HIGHLIGHT_COLORS,
  NOTE_COLOR_NONE,
  type HighlightColor
} from '@/types/highlight'

export interface HighlightActionPopoverProps {
  position: { x: number; y: number }
  currentColor: HighlightColor
  onSelectColor: (color: HighlightColor) => void
  onEditNote: () => void
  onDelete: () => void
  onClose: () => void
  /** Renders the note button as "View note" (filled icon) instead of "Add note" — a visual indicator that a note already exists. */
  hasNote?: boolean
}

export function HighlightActionPopover({
  position,
  currentColor,
  onSelectColor,
  onEditNote,
  onDelete,
  onClose,
  hasNote
}: HighlightActionPopoverProps) {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [onClose])

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        onClose()
      }
    }
    // Same 100 ms delay as SelectionPopover so the click that opened the
    // popover doesn't immediately close it.
    const timer = setTimeout(() => {
      document.addEventListener('mousedown', handleClickOutside)
    }, 100)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('mousedown', handleClickOutside)
    }
  }, [onClose])

  return (
    // TODO(Wave F): clamp x/y to viewport so the popover doesn't get clipped against the right/bottom edges. Same gap exists in SelectionPopover.
    <div
      ref={containerRef}
      className="fixed z-50 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg shadow-md p-2"
      style={{ left: position.x, top: position.y }}
    >
      <div className="flex items-center gap-2">
        {currentColor !== NOTE_COLOR_NONE && HIGHLIGHT_COLORS.map((c) => {
          const isCurrent = c.name === currentColor
          return (
            <button
              key={c.name}
              type="button"
              aria-pressed={isCurrent}
              aria-label={`Change to ${c.name}`}
              title={`Change to ${c.name}`}
              className={
                'rounded-full border border-gray-300/50 transition-transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-blue-500 ' +
                (isCurrent ? 'ring-2 ring-inset ring-blue-500' : '')
              }
              style={{
                width: 28,
                height: 28,
                backgroundColor: c.hex
              }}
              onClick={() => {
                onSelectColor(c.name)
                onClose()
              }}
            />
          )
        })}

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
            onEditNote()
            onClose()
          }}
        >
          {hasNote ? <MessageSquareText size={16} /> : <MessageSquarePlus size={16} className="text-gray-700 dark:text-gray-200" />}
        </button>

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
      </div>
    </div>
  )
}
