/**
 * Mobile visual-cue store. The shared `createVisualCueEmitter` requires
 * a DOM to scan around the active paragraph — that machinery only runs
 * inside the EPUB / MOBI / AZW3 / DJVU WebView contexts on mobile.
 *
 * Wiring on mobile is "WebView postMessage → setVisualCue({kind, label})".
 * The reader's WebView injects a tiny script that calls the shared
 * `detectVisualsNear` and posts the result to the React Native side;
 * the bridge calls `setVisualCue(...)` here.
 *
 * For PDFs (no WebView), the chunker already knows page layout — the
 * reader can call `setVisualCue` directly when the active chunk's
 * chapter / page contains a figure.
 *
 * This store is mobile-only — electron uses its own DOM-attached
 * emitter, which still lives at `@rishi/shared/tts.createVisualCueEmitter`.
 */
import { create } from 'zustand'
import type { VisualKind } from '@rishi/shared/tts'

export interface VisualCueState {
  /** Kind of visual nearby, or null when none. */
  kind: VisualKind | null
  /** Human-readable label for the cue, e.g. "Equation on page". */
  label: string | null
  /** Optional opaque "target" tag the reader can use to scroll to the
   *  hit when the user taps the cue. */
  target: string | null
}

interface VisualCueStore extends VisualCueState {
  setVisualCue: (cue: Partial<VisualCueState> | null) => void
  clearVisualCue: () => void
}

export const useVisualCueStore = create<VisualCueStore>()((set) => ({
  kind: null,
  label: null,
  target: null,
  setVisualCue: (cue) => {
    if (cue === null) {
      set({ kind: null, label: null, target: null })
      return
    }
    set({
      kind: cue.kind ?? null,
      label: cue.label ?? null,
      target: cue.target ?? null,
    })
  },
  clearVisualCue: () => set({ kind: null, label: null, target: null }),
}))

/** Helper for components that just want the label. */
export function selectVisualCueLabel(s: VisualCueState): string | null {
  return s.label
}
