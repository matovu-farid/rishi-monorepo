import { useEffect, useState } from 'react'
import { getVisualCueEmitter, type VisualNearbyEvent } from '@/services/tts'
import { usePrefsStore } from '@/stores/prefsStore'

/**
 * Floating affordance that appears next to the reader when the TTS cursor
 * advances to a paragraph adjacent to a figure or equation. Tapping the cue
 * scrolls the nearby visual into view.
 *
 * The component subscribes to the visual-cue emitter for its lifetime; it
 * relies on the emitter sending an event with empty `hits` to clear itself
 * when the next paragraph has no nearby visuals.
 */
export function TTSVisualCue(): React.JSX.Element | null {
  const enabled = usePrefsStore((s) => s.ttsVisualCueEnabled)
  const [event, setEvent] = useState<VisualNearbyEvent | null>(null)

  useEffect(() => {
    const off = getVisualCueEmitter().on('visual-nearby', (e) => {
      setEvent(e.hits.length === 0 ? null : e)
    })
    return off
  }, [])

  if (!enabled || !event) return null

  const firstHit = event.hits[0]
  const kind = firstHit.kind
  const target = firstHit.element

  const label =
    kind === 'equation'
      ? 'Equation on page'
      : kind === 'figure'
        ? 'Figure on page'
        : 'Image on page'

  return (
    <button
      type="button"
      data-testid="tts-visual-cue"
      className="fixed bottom-24 right-6 z-50 rounded-full bg-amber-500/90 px-3 py-2 text-sm text-white shadow-lg hover:bg-amber-500"
      onClick={() => {
        target?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      }}
    >
      {label}
    </button>
  )
}
