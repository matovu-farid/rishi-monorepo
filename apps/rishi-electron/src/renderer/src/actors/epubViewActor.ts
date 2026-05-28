// apps/electron/src/renderer/src/actors/epubViewActor.ts
//
// Per-format implementation of the view-actor protocol for EPUB. Wraps a
// single epubjs Rendition and translates NAVIGATE_NEXT/PREV/TO commands
// into rendition.next()/prev()/display(), then emits VIEW_CHANGED or
// NAV_NO_PROGRESS based on the relocated event.
//
// The validation rule (same for every per-format actor):
//
//   if (newLocator === previousLocator || paragraphs.length === 0) {
//     NAV_NO_PROGRESS
//   } else {
//     VIEW_CHANGED { locator, paragraphs }
//   }
//
// This is what publishCurrentEpubParagraphs omits today — it republishes
// without checking either condition, which lets the loop-back regression
// land playback on paragraph 0 of the OLD view.
import { fromCallback } from 'xstate'
import type Rendition from 'epubjs/types/rendition'
import type { ParagraphWithIndex } from '@/stores/playerStore'
import type { ViewActorCommand, ViewActorEmit } from './viewActor'

export type EpubViewInput = {
  rendition: Rendition
  /**
   * Reads the paragraphs for whatever view the rendition currently shows.
   * Injected so the actor can be tested without epubjs. Production binds
   * this to `getCurrentViewParagraphs(rendition)` (mapped to
   * ParagraphWithIndex) at the call site.
   */
  getParagraphs: () => ParagraphWithIndex[]
}

const NAV_TIMEOUT_MS = 10_000

type Location = { start: { cfi: string } }
type NavNoProgressReason = Extract<ViewActorEmit, { type: 'NAV_NO_PROGRESS' }>['reason']

export const epubViewActor = fromCallback<ViewActorCommand, EpubViewInput>(
  ({ sendBack, receive, input }) => {
    const { rendition, getParagraphs } = input
    let previousLocator: string | null = rendition.location?.start?.cfi ?? null
    let navInProgress = false
    let navTimeout: ReturnType<typeof setTimeout> | null = null

    const clearNavTimeout = (): void => {
      if (navTimeout) {
        clearTimeout(navTimeout)
        navTimeout = null
      }
    }

    const failNav = (reason: NavNoProgressReason): void => {
      if (!navInProgress) return
      navInProgress = false
      clearNavTimeout()
      sendBack({ type: 'NAV_NO_PROGRESS', reason })
    }

    const handleRelocated = (location: Location): void => {
      const newLocator = location?.start?.cfi
      if (!newLocator) return
      const newParagraphs = getParagraphs()

      const sameView = previousLocator !== null && newLocator === previousLocator
      const empty = newParagraphs.length === 0

      if (sameView || empty) {
        // If a navigation was in flight and produced no progress, tell the
        // parent. Otherwise (drift restore with no in-flight nav) silently
        // ignore — emitting NAV_NO_PROGRESS would confuse a parent that
        // didn't ask to navigate.
        failNav('no-relocation')
        return
      }

      previousLocator = newLocator
      navInProgress = false
      clearNavTimeout()
      sendBack({
        type: 'VIEW_CHANGED',
        locator: newLocator,
        paragraphs: newParagraphs
      })
    }

    rendition.on('relocated', handleRelocated)

    const startNav = (kind: 'next' | 'prev' | 'display', locator?: string): void => {
      // Snapshot the current CFI so the relocated-with-same-cfi case can be
      // detected even if the rendition mutates its `location` synchronously.
      previousLocator = rendition.location?.start?.cfi ?? previousLocator
      navInProgress = true
      clearNavTimeout()
      navTimeout = setTimeout(() => failNav('timeout'), NAV_TIMEOUT_MS)

      let promise: Promise<unknown>
      if (kind === 'next') promise = rendition.next()
      else if (kind === 'prev') promise = rendition.prev()
      else promise = rendition.display(locator!)

      promise.catch(() => failNav('end-of-document'))
    }

    receive((event) => {
      const cmd = event as ViewActorCommand
      if (cmd.type === 'NAVIGATE_NEXT') startNav('next')
      else if (cmd.type === 'NAVIGATE_PREV') startNav('prev')
      else if (cmd.type === 'NAVIGATE_TO') startNav('display', cmd.locator)
      else if (cmd.type === 'REPUBLISH') {
        const newLocator = rendition.location?.start?.cfi
        const newParagraphs = getParagraphs()
        if (!newLocator || newParagraphs.length === 0) {
          sendBack({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
          return
        }
        // Emit even if locator equals previousLocator — REPUBLISH is the
        // "I lost track, tell me again" signal, not a navigation result.
        previousLocator = newLocator
        sendBack({ type: 'VIEW_CHANGED', locator: newLocator, paragraphs: newParagraphs })
      }
    })

    return () => {
      rendition.off('relocated', handleRelocated)
      clearNavTimeout()
    }
  }
)
