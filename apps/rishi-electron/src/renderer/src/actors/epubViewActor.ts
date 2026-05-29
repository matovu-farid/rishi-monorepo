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
import { debugLog } from '@/utils/debugLog'
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
// During a page-curl, epubjs emits `relocated` more than once within
// ~100 ms (documented in EpubView.tsx:1048-1050). The first event lands
// on the new view; subsequent events can bounce back with a STALE CFI
// describing the old view. Without this guard, the bounce-back re-emits
// VIEW_CHANGED with the old view's paragraphs and playerMachine snaps
// playback to paragraph 0 of the old view — the TTS auto-advance loop-
// back. 200 ms covers the documented window with margin and is far below
// any plausible user "tap NEXT twice" cadence (~250 ms+).
const SETTLE_GUARD_MS = 200

// Local shape used by handleRelocated. Marked all-optional because epubjs's
// `relocated` payload can lose its CFI on certain re-emits (the bounce-back
// race we already filter elsewhere). Lets us guard with `?.` without
// triggering @typescript-eslint/no-unnecessary-condition.
type Location = { start?: { cfi?: string } } | undefined
// epubjs's Rendition.location is typed as non-null but in practice is
// undefined until the first `displayed` event fires. Helper centralises the
// defensive read so we can suppress the lint rule once.
const readRenditionCfi = (rendition: Rendition): string | null => {
  const loc = rendition.location as Location
  return loc?.start?.cfi ?? null
}
type NavNoProgressReason = Extract<ViewActorEmit, { type: 'NAV_NO_PROGRESS' }>['reason']

export const epubViewActor = fromCallback<ViewActorCommand, EpubViewInput | undefined>(
  ({ sendBack, receive, input }) => {
    // Defensive: usePlayerActor creates the player actor at mount time using
    // whatever viewInput is currently available. EpubView's viewInput memo
    // resolves to `undefined` until the epubjs Rendition has been created in
    // the `getRendition` callback. If we destructured eagerly here, the
    // throw would propagate up Actor.start() and put the whole player
    // machine into a final state — every subsequent INITIALIZE, CLEANUP,
    // and AUDIO_ENDED then hits a stopped actor (visible in the dev
    // console as "Event X was sent to stopped actor x:N"). Worse, the
    // audioActor sibling keeps the singleton audioElement's `ended`
    // listener attached, so when EpubView finally creates a working
    // replacement actor we end up with zombie listeners firing AUDIO_ENDED
    // at the dead actor. Returning a no-op cleanup here keeps the parent
    // alive; React swaps the actor cleanly once viewInput stabilises.
    if (!input) {
      // Still emit the dev dump so the instrumentation captures the swap.
      debugLog('view:noop-start', { reason: 'input-undefined' })
      // Acknowledge nav commands with NAV_NO_PROGRESS so the machine doesn't
      // sit in waitingForParagraphs/republishingParagraphs for the full 10 s
      // timeout if the user triggers a navigation before the rendition has
      // mounted. The actor instance is swapped as soon as EpubView produces
      // a real viewInput.
      receive(() => {
        // Any command (NAVIGATE_NEXT / PREV / TO or REPUBLISH) gets the
        // same no-progress reply while the rendition isn't ready. The
        // command-type switch lives in the real (input-bound) path below.
        sendBack({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
      })
      return () => {}
    }
    const { rendition, getParagraphs } = input
    let previousLocator: string | null = readRenditionCfi(rendition)
    let navInProgress = false
    let navTimeout: ReturnType<typeof setTimeout> | null = null
    // True for SETTLE_GUARD_MS after the most recent VIEW_CHANGED emit.
    // Filters bounce-back relocated events during a single page-curl.
    // Reset by startNav so legitimate back-to-back navigations are not
    // dropped, and by clearSettleGuard() when the timer fires.
    let settleSuppress = false
    let settleTimer: ReturnType<typeof setTimeout> | null = null

    const clearNavTimeout = (): void => {
      if (navTimeout) {
        clearTimeout(navTimeout)
        navTimeout = null
      }
    }

    const clearSettleGuard = (): void => {
      settleSuppress = false
      if (settleTimer) {
        clearTimeout(settleTimer)
        settleTimer = null
      }
    }

    const armSettleGuard = (): void => {
      settleSuppress = true
      if (settleTimer) clearTimeout(settleTimer)
      settleTimer = setTimeout(() => {
        settleSuppress = false
        settleTimer = null
      }, SETTLE_GUARD_MS)
    }

    const failNav = (reason: NavNoProgressReason): void => {
      if (!navInProgress) return
      navInProgress = false
      clearNavTimeout()
      sendBack({ type: 'NAV_NO_PROGRESS', reason })
    }

    const handleRelocated = (location: Location): void => {
      const newLocator = location?.start?.cfi ?? null
      const newParagraphs = newLocator ? getParagraphs() : []
      const decision = (() => {
        if (settleSuppress) return 'suppressed-bounce'
        if (!newLocator) return 'no-cfi'
        const sameView = previousLocator !== null && newLocator === previousLocator
        if (sameView) return 'nav-no-progress-same-view'
        if (newParagraphs.length === 0) return 'nav-no-progress-empty'
        return 'view-changed'
      })()
      debugLog('view:relocated', {
        newLocator,
        previousLocator,
        paragraphCount: newParagraphs.length,
        firstParagraphCfi: newParagraphs[0]?.index ?? null,
        navInProgress,
        settleSuppress,
        decision,
        renditionLocationCfi: readRenditionCfi(rendition)
      })

      // Bounce-back guard: ignore relocated events that fire within the
      // settle window after a successful VIEW_CHANGED. epubjs's page-curl
      // emits multiple relocateds in rapid succession; the second one can
      // carry a stale CFI that, if accepted, would snap the player back
      // to the old view's paragraph 0. While bounces keep arriving, KEEP
      // the guard alive — extends the window beyond SETTLE_GUARD_MS so a
      // delayed bounce past the original timer still hits a closed gate.
      if (settleSuppress) {
        armSettleGuard()
        return
      }

      if (!newLocator) return

      const sameView = previousLocator !== null && newLocator === previousLocator
      const empty = newParagraphs.length === 0

      if (sameView || empty) {
        // If a navigation was in flight and produced no progress, tell the
        // parent. Otherwise (drift restore with no in-flight nav) silently
        // ignore — emitting NAV_NO_PROGRESS would confuse a parent that
        // didn't ask to navigate.
        failNav('no-relocation')
        // Re-arm so a same-CFI re-emit (typically from EpubView's
        // display() re-anchor) keeps the guard alive against a later
        // bounce to a different stale CFI.
        armSettleGuard()
        return
      }

      previousLocator = newLocator
      navInProgress = false
      clearNavTimeout()
      armSettleGuard()
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
      previousLocator = readRenditionCfi(rendition) ?? previousLocator
      navInProgress = true
      clearNavTimeout()
      // Reset the settle guard from any prior nav. Without this, a NEW
      // navigation that arrives within SETTLE_GUARD_MS of the previous emit
      // would have its relocated suppressed and the parent would never
      // receive VIEW_CHANGED (machine would time out in waitingForParagraphs).
      clearSettleGuard()
      navTimeout = setTimeout(() => failNav('timeout'), NAV_TIMEOUT_MS)

      debugLog('view:startNav', { kind, locator: locator ?? null, previousLocator })

      let promise: Promise<unknown>
      if (kind === 'next') promise = rendition.next()
      else if (kind === 'prev') promise = rendition.prev()
      else promise = rendition.display(locator)

      promise.then(
        () => debugLog('view:navPromise:resolved', { kind }),
        (err: unknown) => {
          debugLog('view:navPromise:rejected', {
            kind,
            err: err instanceof Error ? err.message : String(err)
          })
          failNav('end-of-document')
        }
      )
    }

    receive((event) => {
      const cmd = event
      debugLog('view:command', {
        cmd: cmd.type,
        locator: cmd.type === 'NAVIGATE_TO' ? cmd.locator : null,
        previousLocator,
        navInProgress,
        settleSuppress,
        renditionLocationCfi: readRenditionCfi(rendition)
      })
      if (cmd.type === 'NAVIGATE_NEXT') startNav('next')
      else if (cmd.type === 'NAVIGATE_PREV') startNav('prev')
      else if (cmd.type === 'NAVIGATE_TO') startNav('display', cmd.locator)
      else {
        // REPUBLISH (only remaining variant in ViewActorCommand).
        const newLocator = readRenditionCfi(rendition)
        const newParagraphs = getParagraphs()
        if (!newLocator || newParagraphs.length === 0) {
          sendBack({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
          return
        }
        // Emit even if locator equals previousLocator — REPUBLISH is the
        // "I lost track, tell me again" signal, not a navigation result.
        previousLocator = newLocator
        // Arm the settle guard so any bounce-back relocated that fires
        // immediately after this re-emit doesn't re-introduce the snap-back.
        armSettleGuard()
        sendBack({ type: 'VIEW_CHANGED', locator: newLocator, paragraphs: newParagraphs })
      }
    })

    return () => {
      rendition.off('relocated', handleRelocated)
      clearNavTimeout()
      clearSettleGuard()
    }
  }
)
