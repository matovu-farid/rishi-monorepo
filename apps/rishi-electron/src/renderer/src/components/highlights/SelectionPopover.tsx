import { useEffect, useRef } from 'react'
import { HIGHLIGHT_COLORS, type HighlightColor } from '@/types/highlight'

interface SelectionPopoverProps {
  cfiRange: string
  selectedText: string
  position: { x: number; y: number }
  onHighlight: (color: HighlightColor) => void
  onClose: () => void
  onReadAloudFrom?: () => void
}

export function SelectionPopover({ position, onHighlight, onClose }: SelectionPopoverProps) {
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
    <div
      ref={containerRef}
      className="fixed z-50 bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg shadow-md p-2"
      style={{ left: position.x, top: position.y }}
    >
      <div className="flex items-center gap-2">
        {HIGHLIGHT_COLORS.map((c) => (
          <button
            key={c.name}
            className="rounded-full border border-gray-300/50 transition-transform hover:scale-110 focus:outline-none focus:ring-2 focus:ring-blue-500"
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
        ))}
      </div>
    </div>
  )
}
