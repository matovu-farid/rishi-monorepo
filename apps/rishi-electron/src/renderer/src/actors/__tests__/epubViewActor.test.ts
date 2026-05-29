// apps/electron/src/renderer/src/actors/__tests__/epubViewActor.test.ts
//
// Unit tests for the epubViewActor — the per-format implementation of the
// view-actor protocol for EPUB. Tests inject a fake Rendition + paragraph
// extractor via input so they don't depend on epubjs.
//
// The critical invariant under test: VIEW_CHANGED is emitted ONLY when the
// new CFI differs from the previous AND the new view has paragraphs.
// Same-CFI relocated OR empty paragraphs → NAV_NO_PROGRESS instead. This is
// the validation that publishCurrentEpubParagraphs omitted today, which
// allowed the loop-back regression.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createActor, createMachine, type ActorRefFrom } from 'xstate'
import { epubViewActor, type EpubViewInput } from '../epubViewActor'
import type { ViewActorEmit } from '../viewActor'
import type { ParagraphWithIndex } from '@/stores/playerStore'

type RelocatedListener = (location: { start: { cfi: string } }) => void

class FakeRendition {
  location: { start: { cfi: string } } | null = null
  private listeners: Record<string, RelocatedListener[]> = {}
  next = vi.fn(async (): Promise<void> => {})
  prev = vi.fn(async (): Promise<void> => {})
  display = vi.fn(async (_: string): Promise<void> => {})

  on(event: string, listener: RelocatedListener): void {
    if (!this.listeners[event]) this.listeners[event] = []
    this.listeners[event].push(listener)
  }
  off(event: string, listener: RelocatedListener): void {
    this.listeners[event] = (this.listeners[event] ?? []).filter((l) => l !== listener)
  }
  emit(event: string, payload: { start: { cfi: string } }): void {
    ;(this.listeners[event] ?? []).forEach((l) => l(payload))
  }
}

type Harness = {
  rendition: FakeRendition
  captured: ViewActorEmit[]
  actorRef: ActorRefFrom<typeof epubViewActor>
  setParagraphs: (paragraphs: ParagraphWithIndex[]) => void
  stop: () => void
}

function makeHarness(initialCfi: string | null = null): Harness {
  const rendition = new FakeRendition()
  if (initialCfi) rendition.location = { start: { cfi: initialCfi } }
  let currentParagraphs: ParagraphWithIndex[] = []
  const getParagraphs = (): ParagraphWithIndex[] => currentParagraphs

  const captured: ViewActorEmit[] = []

  const parentMachine = createMachine({
    types: {} as { events: ViewActorEmit },
    invoke: {
      id: 'view',
      src: epubViewActor,
      input: {
        rendition: rendition as unknown as EpubViewInput['rendition'],
        getParagraphs
      } satisfies EpubViewInput
    },
    on: {
      VIEW_CHANGED: {
        actions: ({ event }) => {
          captured.push(event as ViewActorEmit)
        }
      },
      NAV_NO_PROGRESS: {
        actions: ({ event }) => {
          captured.push(event as ViewActorEmit)
        }
      }
    }
  })

  const parent = createActor(parentMachine)
  parent.start()
  const actorRef = parent.getSnapshot().children.view as ActorRefFrom<typeof epubViewActor>
  return {
    rendition,
    captured,
    actorRef,
    setParagraphs: (paragraphs) => {
      currentParagraphs = paragraphs
    },
    stop: () => parent.stop()
  }
}

async function flushMicrotasks(): Promise<void> {
  await new Promise<void>((r) => setTimeout(r, 0))
}

const P = (cfi: string, text = 'lorem'): ParagraphWithIndex => ({ index: cfi, text })

describe('epubViewActor', () => {
  let harness: Harness

  describe('NAVIGATE_NEXT — happy path', () => {
    beforeEach(() => {
      harness = makeHarness('cfi:before')
    })

    it('calls rendition.next() and emits VIEW_CHANGED when relocated fires with a new CFI and non-empty paragraphs', async () => {
      const { rendition, captured, actorRef, setParagraphs } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      await flushMicrotasks()
      expect(rendition.next).toHaveBeenCalledTimes(1)

      setParagraphs([P('cfi:after-1'), P('cfi:after-2')])
      rendition.emit('relocated', { start: { cfi: 'cfi:after-1' } })
      expect(captured).toEqual([
        {
          type: 'VIEW_CHANGED',
          locator: 'cfi:after-1',
          paragraphs: [P('cfi:after-1'), P('cfi:after-2')]
        }
      ])
    })
  })

  describe('NAVIGATE_NEXT — loop-back race (THE bug class)', () => {
    beforeEach(() => {
      harness = makeHarness('cfi:stuck')
    })

    it('emits NAV_NO_PROGRESS when the rendition fires relocated with the SAME CFI', async () => {
      const { rendition, captured, actorRef } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      await flushMicrotasks()
      // Rendition couldn't advance (end of book / drift restore) → fires
      // relocated with the previous CFI. Before this actor, the safety net
      // republished paragraphs of the OLD view and the player snapped to
      // paragraph 0 of the old view.
      rendition.emit('relocated', { start: { cfi: 'cfi:stuck' } })
      expect(captured).toEqual([
        { type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }
      ])
    })

    it('emits NAV_NO_PROGRESS when the new view has no paragraphs (image-only page)', async () => {
      const { rendition, captured, actorRef, setParagraphs } = harness
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      await flushMicrotasks()
      setParagraphs([]) // new view is image-only
      rendition.emit('relocated', { start: { cfi: 'cfi:image-only' } })
      expect(captured).toEqual([
        { type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }
      ])
    })

    it('emits NAV_NO_PROGRESS when rendition.next() rejects (end of book)', async () => {
      const rendition = new FakeRendition()
      rendition.location = { start: { cfi: 'cfi:last' } }
      rendition.next = vi.fn(async () => {
        throw new Error('No Section Found')
      })
      const captured: ViewActorEmit[] = []
      const parent = createActor(
        createMachine({
          invoke: {
            id: 'view',
            src: epubViewActor,
            input: {
              rendition: rendition as unknown as EpubViewInput['rendition'],
              getParagraphs: () => []
            } satisfies EpubViewInput
          },
          on: {
            NAV_NO_PROGRESS: { actions: ({ event }) => captured.push(event as ViewActorEmit) },
            VIEW_CHANGED: { actions: ({ event }) => captured.push(event as ViewActorEmit) }
          }
        })
      )
      parent.start()
      const ref = parent.getSnapshot().children.view as ActorRefFrom<typeof epubViewActor>
      ref.send({ type: 'NAVIGATE_NEXT' })
      await flushMicrotasks()
      expect(captured).toEqual([
        { type: 'NAV_NO_PROGRESS', reason: 'end-of-document' }
      ])
      parent.stop()
    })
  })

  describe('NAVIGATE_PREV', () => {
    it('calls rendition.prev() and emits VIEW_CHANGED on relocated', async () => {
      harness = makeHarness('cfi:current')
      const { rendition, captured, actorRef, setParagraphs } = harness
      actorRef.send({ type: 'NAVIGATE_PREV' })
      await flushMicrotasks()
      expect(rendition.prev).toHaveBeenCalledTimes(1)
      setParagraphs([P('cfi:prev-1')])
      rendition.emit('relocated', { start: { cfi: 'cfi:prev-1' } })
      expect(captured).toEqual([
        { type: 'VIEW_CHANGED', locator: 'cfi:prev-1', paragraphs: [P('cfi:prev-1')] }
      ])
    })
  })

  describe('NAVIGATE_TO', () => {
    it('calls rendition.display(locator) and emits VIEW_CHANGED on relocated', async () => {
      harness = makeHarness('cfi:before')
      const { rendition, captured, actorRef, setParagraphs } = harness
      actorRef.send({ type: 'NAVIGATE_TO', locator: 'cfi:bookmark' })
      await flushMicrotasks()
      expect(rendition.display).toHaveBeenCalledWith('cfi:bookmark')
      setParagraphs([P('cfi:bookmark')])
      rendition.emit('relocated', { start: { cfi: 'cfi:bookmark' } })
      expect(captured).toEqual([
        { type: 'VIEW_CHANGED', locator: 'cfi:bookmark', paragraphs: [P('cfi:bookmark')] }
      ])
    })
  })

  describe('relocated without an in-flight navigation (user-driven page curl)', () => {
    it('emits VIEW_CHANGED if the CFI changed and paragraphs are non-empty — the player should react to external page turns too', () => {
      harness = makeHarness('cfi:start')
      const { rendition, captured, setParagraphs } = harness
      setParagraphs([P('cfi:user-flipped')])
      rendition.emit('relocated', { start: { cfi: 'cfi:user-flipped' } })
      expect(captured).toEqual([
        {
          type: 'VIEW_CHANGED',
          locator: 'cfi:user-flipped',
          paragraphs: [P('cfi:user-flipped')]
        }
      ])
    })

    it('silently ignores same-CFI relocated when no navigation is in flight (drift restore)', () => {
      harness = makeHarness('cfi:steady')
      const { rendition, captured } = harness
      rendition.emit('relocated', { start: { cfi: 'cfi:steady' } })
      expect(captured).toEqual([])
    })
  })

  describe('multi-relocated bounce-back race during page-curl (THE TTS auto-advance loop-back bug)', () => {
    it('emits VIEW_CHANGED only ONCE per nav even when a stale bounce-back relocated fires within the settle window', async () => {
      // Repro: TTS auto-advance triggers NAVIGATE_NEXT. epubjs fires
      // `relocated` more than once within ~100 ms during the page-curl
      // animation (documented in EpubView.tsx:1048-1050). With no settle
      // guard, the SECOND relocated — carrying a stale CFI pointing back at
      // the OLD page — passes the same-CFI check (its CFI differs from the
      // CFI emitted by the FIRST relocated), so the actor re-emits
      // VIEW_CHANGED with the OLD view's paragraphs. The playerMachine then
      // writes those into ctx.currentParagraphs and resetIndexByDirection
      // snaps paragraphIndex to 0 — the "loop back to paragraph 0 of the
      // previous page" symptom users observe right after the last paragraph
      // finishes playing.
      harness = makeHarness('cfi:A')
      const { rendition, captured, actorRef, setParagraphs } = harness

      actorRef.send({ type: 'NAVIGATE_NEXT' })
      await flushMicrotasks()

      // Relocated #1: animation lands on NEW page B. paragraphs are B's.
      setParagraphs([P('cfi:B-p1'), P('cfi:B-p2')])
      rendition.location = { start: { cfi: 'cfi:B-p1' } }
      rendition.emit('relocated', { start: { cfi: 'cfi:B-p1' } })

      // Relocated #2: epubjs bounces back with a stale CFI on the OLD page
      // A during the same animation window. paragraphs read back as A's.
      // Without the settle guard, this would emit VIEW_CHANGED again and
      // snap the player to A_p0.
      setParagraphs([P('cfi:A-p1'), P('cfi:A-p2')])
      rendition.location = { start: { cfi: 'cfi:A-p1' } }
      rendition.emit('relocated', { start: { cfi: 'cfi:A-p1' } })

      expect(captured).toEqual([
        {
          type: 'VIEW_CHANGED',
          locator: 'cfi:B-p1',
          paragraphs: [P('cfi:B-p1'), P('cfi:B-p2')]
        }
      ])
    })

    it('keeps the bounce guard alive when bounces keep arriving past the original settle window', async () => {
      // Regression: the original 200 ms guard could be evaded by a
      // delayed bounce — if epubjs emitted a stale relocated at +250 ms
      // (e.g. after a React-state re-render layout shift caused a second
      // viewport oscillation), the view actor would treat it as a fresh
      // view-changed because settleSuppress had expired. This caused the
      // player to snap back to the OLD page's paragraph 0 after the
      // auto-advance, exactly the bug we're fixing. The fix: re-arm the
      // guard on every suppressed relocated so the window slides forward
      // as long as bounces keep arriving.
      vi.useFakeTimers()
      try {
        harness = makeHarness('cfi:A')
        const { rendition, captured, actorRef, setParagraphs } = harness

        actorRef.send({ type: 'NAVIGATE_NEXT' })
        await vi.advanceTimersByTimeAsync(0)

        // T = 0: relocated #1 = destination B.
        setParagraphs([P('cfi:B-p1')])
        rendition.location = { start: { cfi: 'cfi:B-p1' } }
        rendition.emit('relocated', { start: { cfi: 'cfi:B-p1' } })

        // T = 150 ms: first bounce — suppressed, re-arm window.
        await vi.advanceTimersByTimeAsync(150)
        setParagraphs([P('cfi:A-p1')])
        rendition.location = { start: { cfi: 'cfi:A-p1' } }
        rendition.emit('relocated', { start: { cfi: 'cfi:A-p1' } })

        // T = 300 ms: WITHOUT the re-arm this would land after the
        // original 200 ms guard timer fired and emit a stale view-changed.
        // With the re-arm, the guard is still active (last re-armed at 150
        // ms, expires at 350 ms).
        await vi.advanceTimersByTimeAsync(150)
        setParagraphs([P('cfi:A-p1')])
        rendition.location = { start: { cfi: 'cfi:A-p1' } }
        rendition.emit('relocated', { start: { cfi: 'cfi:A-p1' } })

        expect(captured).toEqual([
          { type: 'VIEW_CHANGED', locator: 'cfi:B-p1', paragraphs: [P('cfi:B-p1')] }
        ])
      } finally {
        vi.useRealTimers()
      }
    })

    it('emits VIEW_CHANGED for a SECOND legitimate navigation that arrives after the settle window expires', async () => {
      // Guard: the bounce-back lock must not block legitimate back-to-back
      // navigations (e.g. user clicks NEXT twice). When a new NAVIGATE_NEXT
      // arrives, the actor must accept the result even if the settle timer
      // from the previous nav is still pending.
      vi.useFakeTimers()
      try {
        harness = makeHarness('cfi:A')
        const { rendition, captured, actorRef, setParagraphs } = harness

        actorRef.send({ type: 'NAVIGATE_NEXT' })
        await vi.advanceTimersByTimeAsync(0)
        setParagraphs([P('cfi:B-p1')])
        rendition.location = { start: { cfi: 'cfi:B-p1' } }
        rendition.emit('relocated', { start: { cfi: 'cfi:B-p1' } })

        // Second nav arrives within the bounce-back window — must reset the
        // lock so its relocated emits VIEW_CHANGED.
        actorRef.send({ type: 'NAVIGATE_NEXT' })
        await vi.advanceTimersByTimeAsync(0)
        setParagraphs([P('cfi:C-p1')])
        rendition.location = { start: { cfi: 'cfi:C-p1' } }
        rendition.emit('relocated', { start: { cfi: 'cfi:C-p1' } })

        expect(captured).toEqual([
          { type: 'VIEW_CHANGED', locator: 'cfi:B-p1', paragraphs: [P('cfi:B-p1')] },
          { type: 'VIEW_CHANGED', locator: 'cfi:C-p1', paragraphs: [P('cfi:C-p1')] }
        ])
      } finally {
        vi.useRealTimers()
      }
    })
  })

  describe('undefined input (rendition not mounted yet)', () => {
    it('does NOT throw during start and acknowledges nav commands with NAV_NO_PROGRESS so the parent machine does not deadlock', () => {
      // Before this guard, destructuring `input` at the top of the actor
      // threw synchronously inside Actor.start(), pushing the parent player
      // machine into its final state. Every subsequent INITIALIZE / CLEANUP
      // / AUDIO_ENDED then fell on a stopped actor — observable in the dev
      // console as "Event X was sent to stopped actor x:N" cascades.
      const captured: ViewActorEmit[] = []
      const parent = createActor(
        createMachine({
          invoke: {
            id: 'view',
            src: epubViewActor,
            input: undefined
          },
          on: {
            VIEW_CHANGED: { actions: ({ event }) => captured.push(event as ViewActorEmit) },
            NAV_NO_PROGRESS: { actions: ({ event }) => captured.push(event as ViewActorEmit) }
          }
        })
      )
      expect(() => parent.start()).not.toThrow()
      const ref = parent.getSnapshot().children.view as ActorRefFrom<typeof epubViewActor>
      ref.send({ type: 'NAVIGATE_NEXT' })
      ref.send({ type: 'REPUBLISH' })
      expect(captured).toEqual([
        { type: 'NAV_NO_PROGRESS', reason: 'no-relocation' },
        { type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }
      ])
      parent.stop()
    })
  })

  describe('cleanup', () => {
    it('removes the relocated listener on actor stop so post-cleanup events no longer reach the parent', () => {
      harness = makeHarness('cfi:before')
      const { rendition, captured, setParagraphs, stop } = harness
      stop()
      setParagraphs([P('cfi:after-stop')])
      rendition.emit('relocated', { start: { cfi: 'cfi:after-stop' } })
      expect(captured).toEqual([])
    })
  })

  describe('REPUBLISH', () => {
    it('emits VIEW_CHANGED with current locator + paragraphs when paragraphs are non-empty', () => {
      harness = makeHarness('cfi:current')
      const { captured, actorRef, setParagraphs } = harness
      setParagraphs([P('cfi:current'), P('cfi:current-2')])
      actorRef.send({ type: 'REPUBLISH' })
      expect(captured).toEqual([
        {
          type: 'VIEW_CHANGED',
          locator: 'cfi:current',
          paragraphs: [P('cfi:current'), P('cfi:current-2')]
        }
      ])
    })

    it('emits VIEW_CHANGED even when CFI equals previousLocator (no-nav-in-flight republish must still produce the event so the machine can recover from cleared-paragraphs state)', () => {
      // Drive the actor through a navigation so previousLocator is set.
      harness = makeHarness('cfi:start')
      const { rendition, captured, actorRef, setParagraphs } = harness
      setParagraphs([P('cfi:after')])
      actorRef.send({ type: 'NAVIGATE_NEXT' })
      // In production rendition.location is mutated by epubjs before the
      // relocated callback fires; mirror that here so REPUBLISH reads the
      // post-nav CFI.
      rendition.location = { start: { cfi: 'cfi:after' } }
      rendition.emit('relocated', { start: { cfi: 'cfi:after' } })
      expect(captured).toEqual([
        { type: 'VIEW_CHANGED', locator: 'cfi:after', paragraphs: [P('cfi:after')] }
      ])
      captured.length = 0

      // Now REPUBLISH against the same CFI — must still emit VIEW_CHANGED.
      // Production case: playerMachine entered republishingParagraphs after
      // clearCurrentParagraphs left context.currentParagraphs = []; the
      // rendition hasn't moved but the machine has nothing to play.
      actorRef.send({ type: 'REPUBLISH' })
      expect(captured).toEqual([
        { type: 'VIEW_CHANGED', locator: 'cfi:after', paragraphs: [P('cfi:after')] }
      ])
    })

    it('emits NAV_NO_PROGRESS when current locator is null', () => {
      // No initial CFI — fresh rendition that hasn't rendered yet.
      harness = makeHarness(null)
      const { captured, actorRef, setParagraphs } = harness
      setParagraphs([P('cfi:something')])
      actorRef.send({ type: 'REPUBLISH' })
      expect(captured).toEqual([{ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }])
    })

    it('emits NAV_NO_PROGRESS when paragraphs are empty', () => {
      harness = makeHarness('cfi:image-only')
      const { captured, actorRef } = harness
      // setParagraphs defaults to []
      actorRef.send({ type: 'REPUBLISH' })
      expect(captured).toEqual([{ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' }])
    })
  })
})
