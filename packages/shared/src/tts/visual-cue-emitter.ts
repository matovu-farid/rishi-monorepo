/**
 * Visual-cue emitter. Ported from
 * `apps/rishi-electron/src/renderer/src/services/tts/visual-cue-emitter.ts`.
 *
 * DOM-dependent (uses the visual heuristic to scan around a paragraph
 * element). Electron callers use this directly. Mobile uses a separate
 * RN-native cue path — the EPUB WebView can dispatch paragraphId +
 * element-info from its own context if needed.
 */
import { detectVisualsNear, type VisualHit } from './visual-heuristic'

export interface VisualNearbyEvent {
  paragraphId: string
  hits: VisualHit[]
}

type Listener = (e: VisualNearbyEvent) => void

export interface VisualCueEmitter {
  on(event: 'visual-nearby', listener: Listener): () => void
  notifyParagraph(input: { paragraphId: string; element: Element }): void
  /** Test-only: synchronously fire to all listeners. */
  __emitForTest?: (event: VisualNearbyEvent) => void
}

export function createVisualCueEmitter(): VisualCueEmitter {
  const listeners = new Set<Listener>()
  let lastParagraphId: string | null = null

  return {
    on(_event, listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    notifyParagraph({ paragraphId, element }) {
      if (paragraphId === lastParagraphId) return
      lastParagraphId = paragraphId
      const hits = detectVisualsNear(element, { siblingRadius: 1 })
      for (const l of listeners) l({ paragraphId, hits })
    },
    __emitForTest(event) {
      for (const l of listeners) l(event)
    }
  }
}
