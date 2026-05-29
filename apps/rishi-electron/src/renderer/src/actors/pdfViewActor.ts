// apps/electron/src/renderer/src/actors/pdfViewActor.ts
//
// Per-format implementation of the view-actor protocol for PDF.
//
// Why a thin injected interface (next/prev/goTo/subscribe/getSnapshot)
// instead of touching pdfStore + pageControls + virtualizer directly:
// every one of those is a heavy React hook tree. Inlining them in the
// actor would make tests need a real virtualizer (slow) and prevent
// reuse for other PDF backends. The wiring layer in PdfView binds the
// production implementations at mount time.
//
// Same validation rule as epubViewActor:
//   - VIEW_CHANGED: new page differs from previous AND has paragraphs
//   - NAV_NO_PROGRESS: same page OR empty paragraphs (during in-flight nav)
//
// Solves the existing `e2e/pdf-next-paragraph-snap-back.spec.ts`
// regression class structurally rather than via a regression gate.
import { fromCallback } from 'xstate'
import type { ParagraphWithIndex } from '@/stores/playerStore'
import { debugLog } from '@/utils/debugLog'
import type { ViewActorCommand, ViewActorEmit } from './viewActor'

export type PdfViewSnapshot = {
  page: number
  paragraphs: ParagraphWithIndex[]
  /**
   * True iff the host has finished extracting text for `page`. False during
   * the brief window between `pageNumber` updating and pdf.js's worker
   * delivering the page's text content. The actor must NOT treat
   * `paragraphs: []` with `dataReady: false` as an image-only page — that
   * case is the transient "still loading" state and a subsequent snapshot
   * will carry the real paragraphs (or stay empty if truly image-only, at
   * which point `dataReady` will be true).
   *
   * Optional for backwards compatibility with callers / tests that haven't
   * been updated yet; missing is treated as `true` (legacy behaviour where
   * empty-paragraphs always meant image-only).
   */
  dataReady?: boolean
}

export type PdfViewInput = {
  /**
   * Advance one page. Returns `true` if the navigation was initiated (page
   * change is in flight; wait for snapshot), `false` if at the document
   * boundary so no navigation can occur. The actor maps `false` to
   * NAV_NO_PROGRESS('end-of-document') immediately, so the player drops to
   * `stopped` without waiting for the 10 s nav timeout.
   */
  next: () => boolean
  /** Go back one page; same semantics as `next`. */
  prev: () => boolean
  /** Jump to a specific page; same semantics as `next` (out-of-bounds → false). */
  goTo: (page: number) => boolean
  /** Subscribe to page+paragraphs snapshots; returns unsubscribe. */
  subscribe: (cb: (s: PdfViewSnapshot) => void) => () => void
  /** Read the current snapshot (used for seed-on-mount). */
  getSnapshot: () => PdfViewSnapshot
}

const NAV_TIMEOUT_MS = 10_000

type NavNoProgressReason = Extract<ViewActorEmit, { type: 'NAV_NO_PROGRESS' }>['reason']

export const pdfViewActor = fromCallback<ViewActorCommand, PdfViewInput | undefined>(
  ({ sendBack, receive, input }) => {
    // See epubViewActor: usePlayerActor creates the player actor before the
    // PDF page-controls + virtualizer mount has produced a viewInput. Bail
    // to a no-op so the parent player actor doesn't enter a final state.
    if (!input) {
      debugLog('pdfView:noop-start', { reason: 'input-undefined' })
      return () => {}
    }
    const { next, prev, goTo, subscribe, getSnapshot } = input
    debugLog('pdfView:start', {
      seedPage: getSnapshot().page,
      seedParagraphCount: getSnapshot().paragraphs.length
    })

    let previousPage: number | null = null
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
      debugLog('pdfView:emit-nav-no-progress', { reason })
      sendBack({ type: 'NAV_NO_PROGRESS', reason })
    }

    const handleSnapshot = ({ page, paragraphs, dataReady = true }: PdfViewSnapshot): void => {
      const samePage = previousPage !== null && page === previousPage
      debugLog('pdfView:snapshot', {
        page,
        previousPage,
        paragraphCount: paragraphs.length,
        firstParagraphIndex: paragraphs[0]?.index ?? null,
        dataReady,
        samePage,
        navInProgress
      })

      if (samePage) {
        // Same-page snapshots happen for several reasons during normal
        // operation: footer-mask arrival, paragraph refit, scroll-driven
        // store mutations, and — critically — `nextPage()` itself, which
        // sets `isLookingForNextParagraph=true` on the pdfStore BEFORE
        // asking the virtualizer to scroll. Treating these as a failed
        // navigation produced the user-visible "audio stops on the last
        // paragraph" bug: AUDIO_ENDED → waitingForParagraphs →
        // sendTo('view', NAVIGATE_NEXT) → nextPage() → same-page snapshot
        // → NAV_NO_PROGRESS → stopped, all before the scroll began.
        //
        // The correct outcome signals are:
        //   - page actually changes (success / image-only path below), or
        //   - next()/prev() returned false at call time (end-of-document,
        //     handled in startNav), or
        //   - the 10 s navTimeout fires (worker crash / truly-stuck case).
        // Outside an in-flight nav, the same-page case is also silently
        // ignored — the existing republish flow (REPUBLISH command) is
        // what callers use when they want a re-emit of the current view.
        return
      }

      if (!dataReady) {
        // Page changed but pdf.js's worker hasn't returned text yet. This
        // is the transient window between `pageNumber` updating and
        // `setPageData` firing. Defer the decision: the subscriber will
        // fire again when the worker delivers data. The 10s NAV_TIMEOUT_MS
        // is the upper bound for the truly-stuck case (worker crash or
        // malformed PDF). Without this, TTS-auto-advance fires
        // NAVIGATE_NEXT, the page scrolls, the worker is still running,
        // the actor sees `paragraphs: []` and prematurely emits
        // NAV_NO_PROGRESS — the player drops to stopped and the real
        // paragraphs arrive too late to resume.
        return
      }

      if (paragraphs.length === 0) {
        // Page changed, data loaded, but there's no text — truly image-
        // only. Same NAV_NO_PROGRESS path as a same-page no-op.
        failNav('no-relocation')
        return
      }

      previousPage = page
      navInProgress = false
      clearNavTimeout()
      debugLog('pdfView:emit-view-changed', {
        page,
        paragraphCount: paragraphs.length,
        firstParagraphIndex: paragraphs[0]?.index ?? null
      })
      sendBack({
        type: 'VIEW_CHANGED',
        locator: String(page),
        paragraphs
      })
    }

    // Seed-on-mount — if the initial page has rendered text, emit it as the
    // first VIEW_CHANGED. Replaces the bespoke "seed from pdfStore" branch
    // in usePlayerMachine. If paragraphs aren't ready yet, the subsequent
    // subscribe callback will emit when they arrive.
    handleSnapshot(getSnapshot())

    const unsubscribe = subscribe(handleSnapshot)

    const startNav = (kind: 'next' | 'prev' | 'goTo', page?: number): void => {
      previousPage = getSnapshot().page
      navInProgress = true
      clearNavTimeout()
      navTimeout = setTimeout(() => failNav('timeout'), NAV_TIMEOUT_MS)
      let willNavigate: boolean
      if (kind === 'next') willNavigate = next()
      else if (kind === 'prev') willNavigate = prev()
      else willNavigate = goTo(page!)
      debugLog('pdfView:startNav', {
        kind,
        target: page ?? null,
        previousPage,
        willNavigate
      })
      // The format reader reported a boundary (first/last page) or invalid
      // target. Bail out immediately so the player can transition to
      // `stopped` without waiting for the 10 s nav timeout.
      if (!willNavigate) failNav('end-of-document')
    }

    receive((event) => {
      const cmd = event
      debugLog('pdfView:command', {
        cmd: cmd.type,
        locator: cmd.type === 'NAVIGATE_TO' ? cmd.locator : null,
        previousPage,
        navInProgress,
        currentPage: getSnapshot().page
      })
      if (cmd.type === 'NAVIGATE_NEXT') startNav('next')
      else if (cmd.type === 'NAVIGATE_PREV') startNav('prev')
      else if (cmd.type === 'NAVIGATE_TO') {
        const page = Number.parseInt(cmd.locator, 10)
        if (Number.isFinite(page)) startNav('goTo', page)
      } else {
        // REPUBLISH (only remaining variant in ViewActorCommand).
        const snap = getSnapshot()
        if (snap.paragraphs.length === 0) {
          debugLog('pdfView:republish-empty', { page: snap.page })
          sendBack({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
          return
        }
        // Emit even if page equals previousPage — REPUBLISH is the
        // "I lost track, tell me again" signal, not a navigation result.
        previousPage = snap.page
        debugLog('pdfView:republish-emit', {
          page: snap.page,
          paragraphCount: snap.paragraphs.length
        })
        sendBack({
          type: 'VIEW_CHANGED',
          locator: String(snap.page),
          paragraphs: snap.paragraphs
        })
      }
    })

    return () => {
      unsubscribe()
      clearNavTimeout()
    }
  }
)
