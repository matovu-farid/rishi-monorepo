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

type Snapshot = { page: number; paragraphs: ParagraphWithIndex[] }

class FakePdfControls {
  page = 0
  paragraphs: ParagraphWithIndex[] = []
  private subscribers: Array<(s: Snapshot) => void> = []
  next = vi.fn()
  prev = vi.fn()
  goTo = vi.fn((_: number) => {})

  subscribe = (cb: (s: Snapshot) => void): (() => void) => {
    this.subscribers.push(cb)
    return () => {
      this.subscribers = this.subscribers.filter((s) => s !== cb)
    }
  }
  getSnapshot = (): Snapshot => ({ page: this.page, paragraphs: this.paragraphs })
  /** Test helper: emit a state change. */
  emit(page: number, paragraphs: ParagraphWithIndex[]): void {
    this.page = page
    this.paragraphs = paragraphs
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

  describe('NAVIGATE_NEXT — the snap-back regression (THE bug class)', () => {
    let harness: Harness
    beforeEach(() => {
      harness = makeHarness(1, [P('pdf-1-0')])
      harness.captured.length = 0
    })

    it('emits NAV_NO_PROGRESS when the page subscription fires with the SAME page number (virtualizer no-op)', () => {
      const { controls, captured, actorRef } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      controls.emit(1, [P('pdf-1-0')])
      expect(captured).toEqual([
        { type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }
      ])
    })

    it('emits NAV_NO_PROGRESS when the new page has no paragraphs (image-only page)', () => {
      const { controls, captured, actorRef } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      controls.emit(2, [])
      expect(captured).toEqual([
        { type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }
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
})
