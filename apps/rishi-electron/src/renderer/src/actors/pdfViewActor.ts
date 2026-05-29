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
  /** Advance one page (NOOP at end of document). */
  next: () => void
  /** Go back one page (NOOP at start). */
  prev: () => void
  /** Jump to a specific page number (1-based). */
  goTo: (page: number) => void
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
    if (!input) return () => {}
    const { next, prev, goTo, subscribe, getSnapshot } = input

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
      sendBack({ type: 'NAV_NO_PROGRESS', reason })
    }

    const handleSnapshot = ({ page, paragraphs, dataReady = true }: PdfViewSnapshot): void => {
      const samePage = previousPage !== null && page === previousPage

      if (samePage) {
        // Stayed on the same page — no progress regardless of paragraphs
        // or extraction state. Same-page subscriber fires happen when the
        // host republishes paragraphs for the current page (e.g. footer-
        // mask arrival, refit). If a nav was in flight, signal failure;
        // otherwise stay silent (handled by failNav's navInProgress guard).
        failNav('no-relocation')
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
      if (kind === 'next') next()
      else if (kind === 'prev') prev()
      else goTo(page!)
    }

    receive((event) => {
      const cmd = event
      if (cmd.type === 'NAVIGATE_NEXT') startNav('next')
      else if (cmd.type === 'NAVIGATE_PREV') startNav('prev')
      else if (cmd.type === 'NAVIGATE_TO') {
        const page = Number.parseInt(cmd.locator, 10)
        if (Number.isFinite(page)) startNav('goTo', page)
      } else {
        // REPUBLISH (only remaining variant in ViewActorCommand).
        const snap = getSnapshot()
        if (snap.paragraphs.length === 0) {
          sendBack({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
          return
        }
        // Emit even if page equals previousPage — REPUBLISH is the
        // "I lost track, tell me again" signal, not a navigation result.
        previousPage = snap.page
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
