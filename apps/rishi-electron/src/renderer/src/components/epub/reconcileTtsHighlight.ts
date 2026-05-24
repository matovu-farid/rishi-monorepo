import type { Rendition } from 'epubjs'
import { highlightRange, removeHighlight } from '@/modules/epubwrapper'

/**
 * Build an idempotent TTS-highlight reconciler bound to a single epub.js
 * Rendition. The reconciler maintains a local ownership registry of CFIs
 * it has applied; it removes only what it owns and never enumerates
 * `rendition.annotations._annotations` to decide what to delete.
 *
 * This is how user-highlight isolation is enforced for EPUB: epub.js
 * shares the "highlight" annotation type between TTS and user
 * highlights, so we cannot separate them at the type/namespace layer.
 * Instead, we know what we added.
 */
export function createEpubTtsReconciler(rendition: Rendition) {
  const owned = new Set<string>()
  let currentTtsCfi: string | null = null

  return function reconcile(desiredIndex: string | null): void {
    // Step 1: clear the previous TTS highlight, but only if WE added it.
    if (currentTtsCfi && currentTtsCfi !== desiredIndex) {
      if (owned.has(currentTtsCfi)) {
        void removeHighlight(rendition, currentTtsCfi)
        owned.delete(currentTtsCfi)
      }
      currentTtsCfi = null
    }
    // Step 2: apply the new one. If a user highlight already exists at
    // this CFI, epub.js dedupes (the user's color wins visually); we do
    // not mark ourselves as owner so we never remove it later.
    if (desiredIndex && currentTtsCfi !== desiredIndex) {
      const hash = encodeURI(desiredIndex + 'highlight')
      const internal = (rendition.annotations as { _annotations?: Record<string, unknown> })
        ._annotations
      const userOwnsIt = internal ? hash in internal : false
      void highlightRange(rendition, desiredIndex)
      if (!userOwnsIt) owned.add(desiredIndex)
      currentTtsCfi = desiredIndex
    }
  }
}

export type EpubTtsReconciler = ReturnType<typeof createEpubTtsReconciler>
