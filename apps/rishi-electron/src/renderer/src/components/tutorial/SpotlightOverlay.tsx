import { useEffect, useState, useCallback } from 'react'
import { motion, AnimatePresence } from 'framer-motion'

interface TargetRect {
  x: number
  y: number
  width: number
  height: number
}

interface SpotlightOverlayProps {
  targetSelector: string
  padding?: number
  borderRadius?: number
}

export function SpotlightOverlay({
  targetSelector,
  padding = 8,
  borderRadius = 8
}: SpotlightOverlayProps) {
  const [rect, setRect] = useState<TargetRect | null>(null)

  const measure = useCallback(() => {
    const el = document.querySelector(`[data-tour="${targetSelector}"]`)
    if (!el) {
      setRect(null)
      return
    }
    const r = el.getBoundingClientRect()
    setRect({
      x: r.x - padding,
      y: r.y - padding,
      width: r.width + padding * 2,
      height: r.height + padding * 2
    })
  }, [targetSelector, padding])

  useEffect(() => {
    // Why: measuring DOM rect into state — must run post-render to read layout
    // eslint-disable-next-line react-hooks/set-state-in-effect
    measure()

    let resizeTimer: ReturnType<typeof setTimeout>
    const handleResize = () => {
      clearTimeout(resizeTimer)
      resizeTimer = setTimeout(measure, 100)
    }
    window.addEventListener('resize', handleResize)

    const el = document.querySelector(`[data-tour="${targetSelector}"]`)
    let observer: ResizeObserver | null = null
    if (el) {
      observer = new ResizeObserver(() => measure())
      observer.observe(el)
    }

    return () => {
      window.removeEventListener('resize', handleResize)
      clearTimeout(resizeTimer)
      observer?.disconnect()
    }
  }, [targetSelector, measure])

  return (
    <AnimatePresence>
      {rect ? (
        <motion.svg
          key="spotlight"
          className="fixed inset-0 z-[55] pointer-events-auto"
          style={{ width: '100vw', height: '100vh' }}
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.3 }}
          onClick={(e) => e.stopPropagation()}
        >
          <defs>
            <mask id="spotlight-mask">
              <rect x="0" y="0" width="100%" height="100%" fill="white" />
              <motion.rect
                fill="black"
                rx={borderRadius}
                ry={borderRadius}
                initial={false}
                animate={{
                  x: rect.x,
                  y: rect.y,
                  width: rect.width,
                  height: rect.height
                }}
                transition={{ type: 'spring', stiffness: 300, damping: 30 }}
              />
            </mask>
          </defs>
          <rect
            x="0"
            y="0"
            width="100%"
            height="100%"
            fill="rgba(0, 0, 0, 0.5)"
            mask="url(#spotlight-mask)"
          />
        </motion.svg>
      ) : null}
    </AnimatePresence>
  )
}
