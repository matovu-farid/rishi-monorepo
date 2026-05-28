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

export type PdfViewSnapshot = { page: number; paragraphs: ParagraphWithIndex[] }

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

export const pdfViewActor = fromCallback<ViewActorCommand, PdfViewInput>(
  ({ sendBack, receive, input }) => {
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

    const handleSnapshot = ({ page, paragraphs }: PdfViewSnapshot): void => {
      const samePage = previousPage !== null && page === previousPage
      const empty = paragraphs.length === 0
      if (samePage || empty) {
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
      const cmd = event as ViewActorCommand
      if (cmd.type === 'NAVIGATE_NEXT') startNav('next')
      else if (cmd.type === 'NAVIGATE_PREV') startNav('prev')
      else if (cmd.type === 'NAVIGATE_TO') {
        const page = Number.parseInt(cmd.locator, 10)
        if (Number.isFinite(page)) startNav('goTo', page)
      } else if (cmd.type === 'REPUBLISH') {
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
