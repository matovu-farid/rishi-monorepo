// apps/electron/src/renderer/src/actors/__tests__/pdfViewActor.test.ts
//
// Unit tests for the pdfViewActor — the per-format implementation of the
// view-actor protocol for PDF. Uses an injected `subscribe` so tests can
// drive page changes synchronously without touching pdfStore or the
// virtualizer.
//
// The same invariant as epubViewActor under test: VIEW_CHANGED is emitted
// ONLY when the new page number differs from the previous AND the new
// page has paragraphs. Same-page subscription fires → NAV_NO_PROGRESS if
// a nav was in flight, otherwise silently ignored.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createActor, createMachine, type ActorRefFrom } from 'xstate'
import { pdfViewActor, type PdfViewInput } from '../pdfViewActor'
import type { ViewActorEmit } from '../viewActor'
import type { ParagraphWithIndex } from '@/stores/playerStore'

type Snapshot = { page: number; paragraphs: ParagraphWithIndex[]; dataReady: boolean }

class FakePdfControls {
  page = 0
  paragraphs: ParagraphWithIndex[] = []
  // Default to `true` so all existing tests behave as before — they were
  // written assuming the host always has text data by the time the
  // subscriber fires. Only the new deferred-emit tests flip this to false.
  dataReady = true
  // Return value for the next next()/prev() call. `true` = nav initiated,
  // wait for page-change snapshot. `false` = at document boundary, actor
  // should emit NAV_NO_PROGRESS('end-of-document') immediately.
  nextWillNavigate = true
  prevWillNavigate = true
  goToWillNavigate = true
  private subscribers: Array<(s: Snapshot) => void> = []
  next = vi.fn((): boolean => this.nextWillNavigate)
  prev = vi.fn((): boolean => this.prevWillNavigate)
  goTo = vi.fn((_: number): boolean => this.goToWillNavigate)

  subscribe = (cb: (s: Snapshot) => void): (() => void) => {
    this.subscribers.push(cb)
    return () => {
      this.subscribers = this.subscribers.filter((s) => s !== cb)
    }
  }
  getSnapshot = (): Snapshot => ({
    page: this.page,
    paragraphs: this.paragraphs,
    dataReady: this.dataReady
  })
  /** Test helper: emit a state change. */
  emit(page: number, paragraphs: ParagraphWithIndex[], dataReady = true): void {
    this.page = page
    this.paragraphs = paragraphs
    this.dataReady = dataReady
    this.subscribers.forEach((s) => s(this.getSnapshot()))
  }
}

type Harness = {
  controls: FakePdfControls
  captured: ViewActorEmit[]
  actorRef: ActorRefFrom<typeof pdfViewActor>
  stop: () => void
}

function makeHarness(initialPage = 0, initialParagraphs: ParagraphWithIndex[] = []): Harness {
  const controls = new FakePdfControls()
  controls.page = initialPage
  controls.paragraphs = initialParagraphs
  const captured: ViewActorEmit[] = []
  const parentMachine = createMachine({
    types: {} as { events: ViewActorEmit },
    invoke: {
      id: 'view',
      src: pdfViewActor,
      input: {
        next: controls.next,
        prev: controls.prev,
        goTo: controls.goTo,
        subscribe: controls.subscribe,
        getSnapshot: controls.getSnapshot
      } satisfies PdfViewInput
    },
    on: {
      VIEW_CHANGED: { actions: ({ event }) => captured.push(event as ViewActorEmit) },
      NAV_NO_PROGRESS: { actions: ({ event }) => captured.push(event as ViewActorEmit) }
    }
  })
  const parent = createActor(parentMachine)
  parent.start()
  return {
    controls,
    captured,
    actorRef: parent.getSnapshot().children.view as ActorRefFrom<typeof pdfViewActor>,
    stop: () => parent.stop()
  }
}

const P = (id: string, text = 'lorem'): ParagraphWithIndex => ({ index: id, text })

describe('pdfViewActor', () => {
  describe('seed-on-mount (PDF-specific win from §3.2.1)', () => {
    it('emits VIEW_CHANGED with the initial page snapshot when the page is rendered before the actor starts', () => {
      const { captured } = makeHarness(1, [P('pdf-1-0'), P('pdf-1-1')])
      expect(captured).toEqual([
        {
          type: 'VIEW_CHANGED',
          locator: '1',
          paragraphs: [P('pdf-1-0'), P('pdf-1-1')]
        }
      ])
    })

    it('does NOT emit a seed if the initial page has not rendered yet (paragraphs empty)', () => {
      const { captured } = makeHarness(0, [])
      expect(captured).toEqual([])
    })
  })

  describe('NAVIGATE_NEXT — happy path', () => {
    let harness: Harness
    beforeEach(() => {
      harness = makeHarness(1, [P('pdf-1-0')])
      harness.captured.length = 0 // drop the seed emission
    })

    it('calls next() and emits VIEW_CHANGED when the page subscription fires with a new page + non-empty paragraphs', () => {
      const { controls, captured, actorRef } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      expect(controls.next).toHaveBeenCalledTimes(1)
      controls.emit(2, [P('pdf-2-0'), P('pdf-2-1')])
      expect(captured).toEqual([
        {
          type: 'VIEW_CHANGED',
          locator: '2',
          paragraphs: [P('pdf-2-0'), P('pdf-2-1')]
        }
      ])
    })
  })

  describe('NAVIGATE_NEXT — boundary + transient-snapshot handling', () => {
    let harness: Harness
    beforeEach(() => {
      harness = makeHarness(1, [P('pdf-1-0')])
      harness.captured.length = 0
    })

    it('emits NAV_NO_PROGRESS(end-of-document) immediately when next() returns false (at last page)', () => {
      const { controls, captured, actorRef } = harness
      controls.nextWillNavigate = false
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      expect(captured).toEqual([{ type: 'NAV_NO_PROGRESS', reason: 'end-of-document' }])
    })

    // Regression: in production, nextPage()/previousPage() mutate the pdfStore
    // (set isLookingForNextParagraph=true) BEFORE asking the virtualizer to
    // scroll. The subscriber fires synchronously on that mutation, producing
    // a same-page snapshot. The actor used to interpret this as a failed
    // navigation and fire NAV_NO_PROGRESS — the machine then dropped to
    // stopped while the scroll was still in flight. User-visible symptom:
    // last-paragraph AUDIO_ENDED → audio stops, no auto-advance to next page.
    //
    // The fix: same-page snapshots during navInProgress are silently
    // deferred. The page-change snapshot (or the 10s nav timeout) is what
    // decides outcome.
    it('does NOT emit NAV_NO_PROGRESS on a same-page snapshot fired during navigation (production race)', () => {
      const { controls, captured, actorRef } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      // Same-page snapshot — mimics nextPage() mutating pdfStore before scroll.
      controls.emit(1, [P('pdf-1-0')])
      expect(captured).toEqual([])

      // Page actually changes — the legitimate commit.
      controls.emit(2, [P('pdf-2-0')])
      expect(captured).toEqual([{ type: 'VIEW_CHANGED', locator: '2', paragraphs: [P('pdf-2-0')] }])
    })

    it('emits NAV_NO_PROGRESS when the new page has no paragraphs AND text extraction is complete (image-only page)', () => {
      const { controls, captured, actorRef } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      // dataReady=true → the host finished extraction and there's genuinely
      // no text on this page. The actor must treat this as a failed nav.
      controls.emit(2, [], true)
      expect(captured).toEqual([{ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }])
    })

    // Regression: TTS-auto-advance scrolls to the next page, but pdf.js's
    // worker hasn't returned the page's text yet. The pdfStore subscriber
    // fires immediately on the pageNumber change (data still undefined),
    // and the actor used to treat that transient empty as a failed nav —
    // sending NAV_NO_PROGRESS, dropping the player to stopped, and silently
    // landing the real paragraphs into a context the user can't resume from.
    //
    // The actor must DEFER the decision: do nothing on the empty-pending
    // snapshot, then emit VIEW_CHANGED on the next snapshot once the worker
    // delivers the text. The 10s nav timeout is the upper bound for the
    // truly-stuck case (worker crash, malformed PDF).
    it('defers — does NOT emit NAV_NO_PROGRESS — when the new page has no paragraphs YET (data not extracted)', () => {
      const { controls, captured, actorRef } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })

      // First subscriber fire: pageNumber flipped to 2 but pdf.js worker
      // hasn't delivered text yet. dataReady=false → defer.
      controls.emit(2, [], false)
      expect(captured).toEqual([])

      // Worker finishes, setPageData populates the store, subscriber fires
      // again with the real paragraphs. NOW the actor commits.
      controls.emit(2, [P('pdf-2-0'), P('pdf-2-1')], true)
      expect(captured).toEqual([
        {
          type: 'VIEW_CHANGED',
          locator: '2',
          paragraphs: [P('pdf-2-0'), P('pdf-2-1')]
        }
      ])
    })
  })

  describe('NAVIGATE_PREV / NAVIGATE_TO', () => {
    it('NAVIGATE_PREV calls prev() and emits VIEW_CHANGED on page change', () => {
      const harness = makeHarness(3, [P('pdf-3-0')])
      harness.captured.length = 0
      harness.actorRef.send({ type: 'NAVIGATE_PREV' })
      expect(harness.controls.prev).toHaveBeenCalledTimes(1)
      harness.controls.emit(2, [P('pdf-2-0')])
      expect(harness.captured).toEqual([
        { type: 'VIEW_CHANGED', locator: '2', paragraphs: [P('pdf-2-0')] }
      ])
    })

    it('NAVIGATE_TO calls goTo(parsed page) and emits VIEW_CHANGED on the matching page change', () => {
      const harness = makeHarness(1, [P('pdf-1-0')])
      harness.captured.length = 0
      harness.actorRef.send({ type: 'NAVIGATE_TO', locator: '5' })
      expect(harness.controls.goTo).toHaveBeenCalledWith(5)
      harness.controls.emit(5, [P('pdf-5-0')])
      expect(harness.captured).toEqual([
        { type: 'VIEW_CHANGED', locator: '5', paragraphs: [P('pdf-5-0')] }
      ])
    })
  })

  describe('subscribe event without an in-flight navigation', () => {
    it('emits VIEW_CHANGED on user-driven page change (scroll) — same protocol as epub user-curl', () => {
      const harness = makeHarness(1, [P('pdf-1-0')])
      harness.captured.length = 0
      harness.controls.emit(2, [P('pdf-2-0')])
      expect(harness.captured).toEqual([
        { type: 'VIEW_CHANGED', locator: '2', paragraphs: [P('pdf-2-0')] }
      ])
    })

    it('silently ignores same-page subscription fires when no navigation is in flight (paragraph republish on footer-mask arrival)', () => {
      const harness = makeHarness(1, [P('pdf-1-0')])
      harness.captured.length = 0
      harness.controls.emit(1, [P('pdf-1-0'), P('pdf-1-1')])
      expect(harness.captured).toEqual([])
    })
  })

  describe('cleanup', () => {
    it('unsubscribes on actor stop so post-cleanup page changes do not reach the parent', () => {
      const harness = makeHarness(1, [P('pdf-1-0')])
      harness.captured.length = 0
      harness.stop()
      harness.controls.emit(2, [P('pdf-2-0')])
      expect(harness.captured).toEqual([])
    })
  })

  describe('REPUBLISH', () => {
    it('emits VIEW_CHANGED with current page + paragraphs when paragraphs are non-empty', () => {
      const harness = makeHarness(3, [P('pdf-3-0'), P('pdf-3-1')])
      harness.captured.length = 0 // drop the seed emission
      harness.actorRef.send({ type: 'REPUBLISH' })
      expect(harness.captured).toEqual([
        {
          type: 'VIEW_CHANGED',
          locator: '3',
          paragraphs: [P('pdf-3-0'), P('pdf-3-1')]
        }
      ])
    })

    it('emits VIEW_CHANGED even when page equals previousPage (no-nav-in-flight republish must still produce the event so the machine can recover from cleared-paragraphs state)', () => {
      const harness = makeHarness(1, [P('pdf-1-0')])
      // Drive through a navigation so previousPage is set.
      harness.captured.length = 0
      harness.actorRef.send({ type: 'NAVIGATE_NEXT' })
      harness.controls.emit(2, [P('pdf-2-0')])
      expect(harness.captured).toEqual([
        { type: 'VIEW_CHANGED', locator: '2', paragraphs: [P('pdf-2-0')] }
      ])
      harness.captured.length = 0

      harness.actorRef.send({ type: 'REPUBLISH' })
      expect(harness.captured).toEqual([
        { type: 'VIEW_CHANGED', locator: '2', paragraphs: [P('pdf-2-0')] }
      ])
    })

    it('emits NAV_NO_PROGRESS when paragraphs are empty', () => {
      const harness = makeHarness(2, [])
      harness.captured.length = 0
      harness.actorRef.send({ type: 'REPUBLISH' })
      expect(harness.captured).toEqual([{ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }])
    })
  })
})
