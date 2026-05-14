import type React from 'react'
import { useState, useRef, useEffect, useCallback } from 'react'
import { createPortal } from 'react-dom'

interface MenuProps {
  children: React.ReactNode
  trigger: React.ReactNode
  open?: boolean
  onClose?: () => void
  onOpen?: () => void
  anchorOrigin?: {
    vertical: 'top' | 'bottom'
    horizontal: 'left' | 'center' | 'right'
  }
  theme?: {
    background: string
    color: string
  }
}

export const Menu: React.FC<MenuProps> = ({
  children,
  trigger,
  open: controlledOpen,
  onClose,
  onOpen,
  anchorOrigin = { vertical: 'bottom', horizontal: 'left' },
  theme
}) => {
  const [internalOpen, setInternalOpen] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLDivElement>(null)

  const isOpen = controlledOpen ?? internalOpen

  // Wrapped in `useCallback` so the click-outside effect can list it as a
  // dep without re-attaching the listener on every render — and so the
  // `react-hooks/exhaustive-deps` rule stays satisfied.
  const handleClose = useCallback(() => {
    if (controlledOpen === undefined) {
      setInternalOpen(false)
    }
    onClose?.()
  }, [controlledOpen, onClose])

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        menuRef.current &&
        !menuRef.current.contains(event.target as Node) &&
        triggerRef.current &&
        !triggerRef.current.contains(event.target as Node)
      ) {
        handleClose()
      }
    }

    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside)
      return () => document.removeEventListener('mousedown', handleClickOutside)
    }
    return undefined
  }, [isOpen, handleClose])

  const handleTriggerClick = () => {
    if (controlledOpen === undefined) {
      setInternalOpen(!internalOpen)
    } else {
      // For controlled mode, toggle the menu
      if (controlledOpen) {
        onClose?.()
      } else {
        onOpen?.()
      }
    }
  }

  // `useCallback` keyed on the reactive `anchorOrigin` fields keeps the
  // identity stable across renders (so `setMenuRef` doesn't churn) while
  // satisfying `react-hooks/exhaustive-deps`. `triggerRef` is a ref, so
  // it's not a reactive dep.
  const computeMenuPosition = useCallback((): React.CSSProperties => {
    if (!triggerRef.current) return {}

    const rect = triggerRef.current.getBoundingClientRect()
    const position: React.CSSProperties = {}
    const menuHeight = 200 // Estimated menu height
    const viewportHeight = window.innerHeight
    const viewportWidth = window.innerWidth

    // Determine vertical position
    if (anchorOrigin.vertical === 'bottom') {
      const spaceBelow = viewportHeight - rect.bottom
      const spaceAbove = rect.top

      if (spaceBelow >= menuHeight || spaceBelow > spaceAbove) {
        // Position below
        position.top = rect.bottom + 4
      } else {
        // Position above
        position.bottom = viewportHeight - rect.top + 4
      }
    } else {
      const spaceAbove = rect.top
      const spaceBelow = viewportHeight - rect.top

      if (spaceAbove >= menuHeight || spaceAbove > spaceBelow) {
        // Position above
        position.bottom = viewportHeight - rect.top + 4
      } else {
        // Position below
        position.top = rect.bottom + 4
      }
    }

    // Determine horizontal position
    if (anchorOrigin.horizontal === 'left') {
      position.left = Math.max(4, rect.left)
    } else if (anchorOrigin.horizontal === 'right') {
      position.right = Math.max(4, viewportWidth - rect.right)
    } else {
      // Center horizontally
      const centerX = rect.left + rect.width / 2
      const menuWidth = 160 // min-w-[160px]
      const leftPos = Math.max(4, centerX - menuWidth / 2)
      const rightPos = Math.max(4, viewportWidth - (centerX + menuWidth / 2))

      if (leftPos < rightPos) {
        position.left = leftPos
      } else {
        position.right = rightPos
      }
    }

    return position
  }, [anchorOrigin.vertical, anchorOrigin.horizontal])

  // Re-runs when `computeMenuPosition` changes (i.e. when `anchorOrigin`
  // changes), which re-applies inline styles to the mounted menu node —
  // the desired behavior.
  const setMenuRef = useCallback(
    (node: HTMLDivElement | null) => {
      menuRef.current = node
      if (!node) return
      Object.assign(node.style, computeMenuPosition())
    },
    [computeMenuPosition]
  )

  return (
    <>
      <div ref={triggerRef} onClick={handleTriggerClick}>
        {trigger}
      </div>
      {isOpen
        ? createPortal(
            <div
              ref={setMenuRef}
              className="fixed z-[9999] border border-gray-200 rounded-md shadow-lg py-1 min-w-[160px] max-h-[300px] overflow-y-auto"
              style={{
                backgroundColor: theme?.background ?? '#ffffff',
                color: theme?.color ?? '#000000',
                borderColor: theme?.color ? `${theme.color}20` : '#e5e7eb'
              }}
            >
              {children}
            </div>,
            document.body
          )
        : null}
    </>
  )
}
