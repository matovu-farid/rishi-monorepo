import { useEffect, useRef } from 'react'
import { AnimatePresence, motion } from 'framer-motion'

/** Minimal TOC item shape matching epub.js NavItem */
export interface TocItem {
  label: string
  href: string
  subitems?: TocItem[]
}

interface TocEntryProps {
  data: TocItem
  onNavigate: (href: string) => void
  depth: number
}

/** Recursive TOC entry with indentation */
function TocEntry({ data, onNavigate, depth }: TocEntryProps) {
  return (
    <div>
      <button
        onClick={() => onNavigate(data.href)}
        className="block w-full text-left py-3 px-4 text-sm text-gray-700 hover:bg-gray-100 border-b border-gray-100 cursor-pointer transition-all duration-200"
        style={{ paddingLeft: 16 + depth * 16 }}
      >
        {data.label}
      </button>
      {data.subitems &&
        data.subitems.length > 0 &&
        data.subitems.map((item, i) => (
          <TocEntry key={i} data={item} onNavigate={onNavigate} depth={depth + 1} />
        ))}
    </div>
  )
}

export interface TableOfContentsProps {
  toc: TocItem[]
  onNavigate: (href: string) => void
  isOpen: boolean
  onClose: () => void
}

/**
 * TableOfContents Component
 * Slide-in sidebar with a dark overlay backdrop.
 * Renders a hierarchical list of chapters/sections.
 * Uses Framer Motion for smooth slide animation.
 */
export function TableOfContents({ toc, onNavigate, isOpen, onClose }: TableOfContentsProps) {
  const panelRef = useRef<HTMLDivElement>(null)

  // Auto-focus the panel when opened
  useEffect(() => {
    if (isOpen) {
      requestAnimationFrame(() => {
        panelRef.current?.focus()
      })
    }
  }, [isOpen])

  return (
    <AnimatePresence>
      {isOpen && (
        <>
          {/* Dark backdrop overlay */}
          <motion.div
            key="toc-backdrop"
            data-testid="toc-backdrop"
            className="fixed inset-0 z-40 bg-black/40"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2 }}
            onClick={onClose}
          />

          {/* TOC sidebar panel */}
          <motion.div
            ref={panelRef}
            key="toc-panel"
            role="dialog"
            aria-label="Table of Contents"
            aria-modal="true"
            tabIndex={-1}
            onKeyDown={(e) => {
              if (e.key === 'Escape') onClose()
            }}
            className="fixed top-0 left-0 bottom-0 z-50 w-64 bg-white shadow-lg overflow-y-auto"
            initial={{ x: -256 }}
            animate={{ x: 0 }}
            exit={{ x: -256 }}
            transition={{ type: 'spring', stiffness: 400, damping: 35 }}
          >
            <div className="p-4 border-b border-gray-200 font-semibold text-gray-800">
              Table of Contents
            </div>
            <div>
              {toc.map((item, i) => (
                <TocEntry
                  key={i}
                  data={item}
                  onNavigate={(href) => {
                    onNavigate(href)
                    onClose()
                  }}
                  depth={0}
                />
              ))}
            </div>
          </motion.div>
        </>
      )}
    </AnimatePresence>
  )
}
