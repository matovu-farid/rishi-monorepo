import {
  Play,
  Pause,
  Square,
  SkipBack,
  SkipForward,
  AlertTriangle,
  Loader2,
  RotateCcw
} from 'lucide-react'
import { AnimatePresence, motion } from 'framer-motion'
import { toast } from 'sonner'
import { useEffect, useRef, useState, useCallback, useSyncExternalStore } from 'react'
import { useRequireAuth } from '@/hooks/useRequireAuth'
import { usePlayerMachine } from '@/hooks/usePlayerMachine'
import { usePlayerStore, type PlayerStoreState } from '@/stores/playerStore'
import { ContextualHint } from '@/components/tutorial/ContextualHint'

interface TTSControlsProps {
  bookId: string
  disabled?: boolean
}

/** Duration before the expanded pill auto-collapses (ms). */
const AUTO_DISMISS_MS = 4_000

/**
 * `prefers-reduced-motion` user-preference subscription (#201 / VIS-008).
 *
 * The morph transition between orb and pill ships `transitionDuration` as an
 * inline style, so the global `@media (prefers-reduced-motion: reduce)` rule
 * in globals.css cannot override it (inline wins). This hook reads the live
 * media-query value via `matchMedia` + `useSyncExternalStore` so the inline
 * style can collapse to `0ms` when the user opts out of animation.
 *
 * Runs in Electron's bundled Chromium — modern matchMedia + EventTarget
 * MediaQueryList semantics are guaranteed, so no Safari < 14 fallback is
 * needed. The third `getServerSnapshot` argument is the useSyncExternalStore
 * contract for the (unused) SSR path.
 */
function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(
    (notify) => {
      const mql = window.matchMedia('(prefers-reduced-motion: reduce)')
      const handler = (): void => notify()
      mql.addEventListener('change', handler)
      return () => mql.removeEventListener('change', handler)
    },
    () => window.matchMedia('(prefers-reduced-motion: reduce)').matches,
    () => false // SSR / non-browser fallback (unreachable in Electron renderer)
  )
}

/** Player states that represent an active playback session — the pill must
 *  not auto-collapse while in any of these. Idle / stopped / paused / error
 *  still auto-collapse (intentional). */
const ACTIVE_PLAYBACK_STATES: ReadonlySet<PlayerStoreState> = new Set([
  'loading',
  'playing',
  'waitingForParagraphs',
  'pageNavigating',
  'republishingParagraphs'
])

export default function TTSControls({ bookId, disabled = false }: TTSControlsProps) {
  const prefersReducedMotion = usePrefersReducedMotion()
  const [showError, setShowError] = useState(false)
  const error = usePlayerStore((s) => s.errors).join('\n')
  const errors = usePlayerStore((s) => s.errors)
  const { requireAuth, AuthDialog } = useRequireAuth()

  const playingState = usePlayerStore((s) => s.playingState)
  const { send } = usePlayerMachine(bookId)

  // --- Pill expand / collapse state ---
  const [expanded, setExpanded] = useState(false)
  const dismissTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const isHoveringRef = useRef(false)

  // --- Dismiss-timer helpers ---
  const clearDismissTimer = useCallback(() => {
    if (dismissTimerRef.current !== null) {
      clearTimeout(dismissTimerRef.current)
      dismissTimerRef.current = null
    }
  }, [])

  const startDismissTimer = useCallback(() => {
    clearDismissTimer()
    dismissTimerRef.current = setTimeout(() => {
      setExpanded(false)
    }, AUTO_DISMISS_MS)
  }, [clearDismissTimer])

  // When playingState changes, manage auto-dismiss timer.
  // While in any active-playback state we suspend the timer; otherwise we
  // start it (unless the user is hovering).
  useEffect(() => {
    if (!expanded) return
    if (ACTIVE_PLAYBACK_STATES.has(playingState)) {
      clearDismissTimer()
    } else if (!isHoveringRef.current) {
      startDismissTimer()
    }
  }, [playingState, expanded, clearDismissTimer, startDismissTimer])

  // Cleanup dismiss timer on unmount
  useEffect(() => {
    return () => clearDismissTimer()
  }, [clearDismissTimer])

  // Keyboard shortcuts: ArrowDown → next paragraph, ArrowUp → prev paragraph.
  // Mounted globally so the shortcut works whether or not the pill is expanded.
  useEffect(() => {
    if (disabled) return
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
      if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return
      const target = e.target as HTMLElement | null
      if (
        target &&
        (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)
      ) {
        return
      }
      e.preventDefault()
      send({ type: e.key === 'ArrowDown' ? 'NEXT' : 'PREV' })
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [send, disabled])

  // --- Mouse handlers for expanded pill ---
  const handleMouseEnter = () => {
    isHoveringRef.current = true
    clearDismissTimer()
  }

  const handleMouseLeave = () => {
    isHoveringRef.current = false
    if (expanded && !ACTIVE_PLAYBACK_STATES.has(playingState)) {
      startDismissTimer()
    }
  }

  // --- Orb click → expand ---
  const handleOrbClick = () => {
    clearDismissTimer()
    setExpanded(true)
  }

  // Show error snackbar when error occurs
  const handleErrorClose = () => {
    setShowError(false)
  }

  const handlePlay = () => {
    // Allow pause/resume without auth since playback was already started
    if (playingState === 'playing') {
      send({ type: 'PAUSE' })
      return
    }
    if (playingState.startsWith('paused')) {
      send({ type: 'RESUME' })
      return
    }
    requireAuth('tts', () => {
      send({ type: 'PLAY' })
    })
  }

  const handleStop = () => {
    send({ type: 'STOP' })
  }

  const handlePrev = () => {
    send({ type: 'PREV' })
  }

  const handleNext = () => {
    send({ type: 'NEXT' })
  }

  const handleRepeat = () => {
    send({ type: 'REPEAT' })
  }

  const handleShowErrorDetails = () => {
    toast.info(`Errors: ${errors.join(', ')}`, {
      position: 'top-center',
      duration: 5000
    })
  }

  const getPlayIcon = () => {
    if (playingState === 'loading') {
      return <Loader2 size={24} className="animate-spin text-black/60" />
    }
    if (playingState === 'playing') {
      return <Pause size={24} className="text-black/60" />
    }
    return <Play size={24} className="text-black/60" />
  }

  const isPlaying = playingState === 'playing'

  // Show the Repeat button across a continuous playback session. While
  // `playingState` briefly drops to `loading` between paragraphs, we keep the
  // button mounted so the pill doesn't reflow every paragraph boundary.
  // Initial load (`stopped → loading → playing`) starts hidden because
  // `showRepeat` is only true while the last non-`loading` state was `playing`.
  //
  // Implementation: track the most recent non-loading state and derive
  // `showRepeat` from it during render. This is the React docs "adjust state
  // when props change" pattern (https://react.dev/learn/you-might-not-need-an-effect#adjusting-some-state-when-a-prop-changes)
  // — setting state during render with a guard is React's bail-out path and
  // doesn't trigger the cascading-renders warning that the equivalent
  // `useEffect` shape did.
  const [lastNonLoadingState, setLastNonLoadingState] = useState<PlayerStoreState>(playingState)
  if (playingState !== 'loading' && playingState !== lastNonLoadingState) {
    setLastNonLoadingState(playingState)
  }
  const showRepeat = lastNonLoadingState === 'playing'

  // --- Waveform bars ---
  // Stable IDs let React reconcile bars across re-renders without
  // falling back to array-index keys (which `react/no-array-index-key`
  // flags as a stale-state hazard).
  const bars = [
    { id: 'bar-0', height: 8 },
    { id: 'bar-1', height: 14 },
    { id: 'bar-2', height: 20 },
    { id: 'bar-3', height: 12 }
  ] as const

  // Shared liquid glass styles
  const glassContainer: React.CSSProperties = {
    background:
      'linear-gradient(135deg, rgba(255,255,255,0.30) 0%, rgba(255,255,255,0.12) 40%, rgba(200,210,230,0.16) 100%)',
    backdropFilter: 'blur(40px) saturate(180%)',
    WebkitBackdropFilter: 'blur(40px) saturate(180%)',
    border: '1px solid rgba(255,255,255,0.45)',
    boxShadow:
      '0 4px 24px rgba(0,0,0,0.18), 0 1px 6px rgba(0,0,0,0.12), inset 0 0 0 0.5px rgba(255,255,255,0.3), inset 0 1px 0 rgba(255,255,255,0.5)'
  }

  const glassButton: React.CSSProperties = {
    background: 'linear-gradient(135deg, rgba(255,255,255,0.35) 0%, rgba(255,255,255,0.15) 100%)',
    backdropFilter: 'blur(20px)',
    WebkitBackdropFilter: 'blur(20px)',
    border: '0.5px solid rgba(255,255,255,0.35)',
    boxShadow: '0 1px 4px rgba(0,0,0,0.06), inset 0 0.5px 0 rgba(255,255,255,0.4)'
  }

  return (
    <ContextualHint
      id="tts-controls"
      title="Listen to Your Book"
      description="Tap to have your book read aloud with AI-powered text-to-speech."
      dotPosition="top-left"
    >
      {AuthDialog}

      {/* Inject keyframes for waveform animation */}
      <style>{`
        @keyframes tts-waveform {
          0%, 100% { transform: scaleY(0.4); }
          50% { transform: scaleY(1); }
        }
        @media (prefers-reduced-motion: reduce) {
          @keyframes tts-waveform {
            0%, 50%, 100% { transform: scaleY(0.7); }
          }
        }
      `}</style>

      {/* Single morphing container: orb ↔ pill */}
      <div
        onClick={!expanded ? handleOrbClick : undefined}
        onKeyDown={
          !expanded
            ? (e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault()
                  handleOrbClick()
                }
              }
            : undefined
        }
        role={!expanded ? 'button' : undefined}
        tabIndex={!expanded ? 0 : undefined}
        aria-label={!expanded ? 'Expand TTS controls' : 'TTS controls'}
        onMouseEnter={expanded ? handleMouseEnter : undefined}
        onMouseLeave={expanded ? handleMouseLeave : undefined}
        className="fixed z-50 flex items-center justify-center motion-reduce:transition-none"
        style={{
          ...glassContainer,
          // Position: bottom-right orb vs bottom-center pill
          bottom: 32,
          right: expanded ? 'auto' : 32,
          left: expanded ? '50%' : 'auto',
          transform: expanded ? 'translateX(-50%)' : 'none',
          // Size: explicit values so CSS can interpolate the transition
          width: expanded ? (showRepeat ? 280 : 240) : 52,
          height: expanded ? 66 : 52,
          borderRadius: expanded ? 40 : '50%',
          padding: expanded ? '8px 14px' : 0,
          gap: expanded ? 6 : 0,
          cursor: expanded ? 'default' : 'pointer',
          // Morph animation — honors `prefers-reduced-motion: reduce` by
          // collapsing the duration to 0 so the orb ↔ pill swap is instant
          // for users who opt out of animation (#201 / VIS-008).
          transitionProperty:
            'width, height, border-radius, padding, gap, bottom, right, left, transform',
          transitionDuration: prefersReducedMotion ? '0ms' : expanded ? '250ms' : '200ms',
          transitionTimingFunction: expanded ? 'cubic-bezier(0.34, 1.56, 0.64, 1)' : 'ease-in-out'
        }}
      >
        {/* Collapsed: Waveform bars */}
        {!expanded && (
          <div className="flex items-center gap-[3px]">
            {bars.map((bar, i) => (
              <div
                key={bar.id}
                style={{
                  width: 3,
                  height: bar.height,
                  borderRadius: 1.5,
                  backgroundColor: 'rgba(0,0,0,0.50)',
                  transformOrigin: 'center',
                  animation:
                    isPlaying && !prefersReducedMotion
                      ? `tts-waveform 0.8s ease-in-out ${i * 0.15}s infinite`
                      : 'none'
                }}
              />
            ))}
          </div>
        )}

        {/* Expanded: Control buttons */}
        {expanded ? (
          <>
            {/* Previous */}
            <button
              onClick={handlePrev}
              disabled={disabled || playingState === 'loading'}
              aria-label="Previous"
              className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed transition-transform duration-150 hover:scale-105 active:scale-95"
              style={{ ...glassButton, width: 42, height: 42 }}
            >
              <SkipBack size={20} className="text-black/60" />
            </button>

            {/* Play / Pause */}
            <button
              onClick={handlePlay}
              disabled={disabled}
              aria-label={isPlaying ? 'Pause' : 'Play'}
              className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed transition-transform duration-150 hover:scale-105 active:scale-95"
              style={{ ...glassButton, width: 50, height: 50 }}
            >
              {getPlayIcon()}
            </button>

            {/* Repeat current paragraph — visible across the playback session,
                including the brief `loading` between paragraphs. */}
            <AnimatePresence initial={false}>
              {showRepeat ? (
                <motion.button
                  key="repeat"
                  initial={{ opacity: 0, width: 0, marginInlineStart: 0, marginInlineEnd: 0 }}
                  animate={{ opacity: 1, width: 42, marginInlineStart: 0, marginInlineEnd: 0 }}
                  exit={{ opacity: 0, width: 0, marginInlineStart: 0, marginInlineEnd: 0 }}
                  transition={{ duration: 0.18, ease: 'easeOut' }}
                  onClick={handleRepeat}
                  disabled={disabled}
                  aria-label="Repeat current paragraph"
                  className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed hover:scale-105 active:scale-95"
                  style={{ ...glassButton, height: 42 }}
                >
                  <RotateCcw size={18} className="text-black/60" />
                </motion.button>
              ) : null}
            </AnimatePresence>

            {/* Next */}
            <button
              onClick={handleNext}
              disabled={disabled || playingState === 'loading'}
              aria-label="Next"
              className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed transition-transform duration-150 hover:scale-105 active:scale-95"
              style={{ ...glassButton, width: 42, height: 42 }}
            >
              <SkipForward size={20} className="text-black/60" />
            </button>

            {/* Stop */}
            <button
              onClick={handleStop}
              disabled={disabled || playingState !== 'playing'}
              aria-label="Stop"
              className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed transition-transform duration-150 hover:scale-105 active:scale-95"
              style={{ ...glassButton, width: 42, height: 42 }}
            >
              <Square size={20} className="text-black/55" />
            </button>

            {/* Error indicator (dev only) */}
            {import.meta.env.DEV && errors.length > 0 ? (
              <button
                onClick={handleShowErrorDetails}
                aria-label="Show error details"
                className="flex items-center justify-center rounded-full cursor-pointer transition-transform duration-150 hover:scale-105 active:scale-95"
                style={{ ...glassButton, width: 36, height: 36 }}
              >
                <AlertTriangle size={16} className="text-red-500" />
              </button>
            ) : null}
          </>
        ) : null}
      </div>

      {/* Error Toast */}
      {showError && !!error ? (
        <div className="fixed top-4 left-1/2 transform -translate-x-1/2 z-50">
          {toast.error(error, {
            position: 'top-center',
            duration: 6000,
            onDismiss: handleErrorClose,
            onAutoClose: handleErrorClose
          }) && null}
        </div>
      ) : null}
    </ContextualHint>
  )
}
