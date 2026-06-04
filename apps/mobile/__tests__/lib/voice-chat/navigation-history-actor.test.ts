/**
 * T-P2.6 — NAVHIST-001: mobile navigation-history actor (consumer wiring).
 *
 * Source: `.parity-v2/SPEC.md` §3.11 (NAVHIST-001), `.parity-v2/PLAN.md`
 * T-P1.6 (shared machine) + T-P2.6 (mobile half).
 *
 * The shared `@rishi/shared/machines/navigationHistory` exports a parametric
 * XState machine. Mobile re-exports it via `@/lib/machines/navigationHistory`
 * with mobile-specific Anchor binding. This test exercises the wiring contract:
 *
 *   1. Importing the mobile entry point yields a running actor and a `send`
 *      function.
 *   2. BOOK_OPENED initializes per-book scope (empty stack, pill hidden).
 *   3. JUMP_REQUESTED pushes an anchor and signals pill should become visible.
 *   4. POP_BACK emits RESUME_REQUESTED with the topmost anchor.
 *   5. BOOK_CLOSED clears scope (per SPEC §3.11 acceptance #5: per-book scope).
 *   6. Opening a DIFFERENT book resets the stack (cross-book scope test).
 *
 * Until `apps/mobile/lib/machines/navigationHistory/index.ts` exports the
 * actor + the shared machine binding, this file fails at import time (RED).
 */
import { createActor } from 'xstate'
import {
  navigationHistoryMachine,
  type NavigationHistoryEvent,
  type AnchorPoint,
} from '@/lib/machines/navigationHistory'

function makePosition(page: number) {
  return { kind: 'pdf' as const, page, offset: 0 }
}

describe('mobile navigationHistoryMachine (NAVHIST-001 wiring)', () => {
  it('starts in inactive state until BOOK_OPENED', () => {
    const actor = createActor(navigationHistoryMachine).start()
    const snap = actor.getSnapshot()
    expect(String(snap.value)).toContain('inactive')
    actor.stop()
  })

  it('BOOK_OPENED initializes scope with empty stack and hidden pill', () => {
    const actor = createActor(navigationHistoryMachine).start()
    actor.send({
      type: 'BOOK_OPENED',
      bookId: 'book-1',
      initialPosition: makePosition(1),
    })
    const snap = actor.getSnapshot()
    expect(snap.context.bookId).toBe('book-1')
    expect(snap.context.stack).toEqual([])
    expect(snap.context.pillVisible).toBe(false)
    actor.stop()
  })

  it('JUMP_REQUESTED pushes an anchor and shows the pill', () => {
    const actor = createActor(navigationHistoryMachine).start()
    actor.send({
      type: 'BOOK_OPENED',
      bookId: 'book-1',
      initialPosition: makePosition(1),
    })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: makePosition(1),
      fromTts: null,
      to: makePosition(42),
      source: 'toc',
      fromLabel: 'p. 1',
    } as NavigationHistoryEvent)

    const snap = actor.getSnapshot()
    expect(snap.context.stack.length).toBe(1)
    expect(snap.context.pillVisible).toBe(true)
    actor.stop()
  })

  it('POP_BACK emits RESUME_REQUESTED with the topmost anchor', () => {
    const actor = createActor(navigationHistoryMachine).start()
    actor.send({
      type: 'BOOK_OPENED',
      bookId: 'book-1',
      initialPosition: makePosition(1),
    })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: makePosition(1),
      fromTts: null,
      to: makePosition(42),
      source: 'toc',
      fromLabel: 'p. 1',
    } as NavigationHistoryEvent)

    const emitted: Array<{ type: string; anchor: AnchorPoint }> = []
    actor.on('RESUME_REQUESTED', (e) => {
      emitted.push(e as { type: string; anchor: AnchorPoint })
    })

    actor.send({ type: 'POP_BACK' } as NavigationHistoryEvent)
    expect(emitted.length).toBe(1)
    expect(emitted[0].anchor.bookId).toBe('book-1')
    actor.stop()
  })

  it('per-book scope: opening a different book resets the stack', () => {
    const actor = createActor(navigationHistoryMachine).start()
    actor.send({
      type: 'BOOK_OPENED',
      bookId: 'book-1',
      initialPosition: makePosition(1),
    })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: makePosition(1),
      fromTts: null,
      to: makePosition(42),
      source: 'toc',
      fromLabel: 'p. 1',
    } as NavigationHistoryEvent)
    expect(actor.getSnapshot().context.stack.length).toBe(1)

    actor.send({ type: 'BOOK_CLOSED' } as NavigationHistoryEvent)
    actor.send({
      type: 'BOOK_OPENED',
      bookId: 'book-2',
      initialPosition: makePosition(1),
    })

    const snap = actor.getSnapshot()
    expect(snap.context.bookId).toBe('book-2')
    expect(snap.context.stack).toEqual([])
    actor.stop()
  })

  it('depth cap: stack never grows beyond STACK_MAX_DEPTH', async () => {
    const { STACK_MAX_DEPTH } = await import('@/lib/machines/navigationHistory')
    const actor = createActor(navigationHistoryMachine).start()
    actor.send({
      type: 'BOOK_OPENED',
      bookId: 'book-1',
      initialPosition: makePosition(1),
    })

    for (let i = 0; i < STACK_MAX_DEPTH + 5; i++) {
      actor.send({
        type: 'JUMP_REQUESTED',
        from: makePosition(i),
        fromTts: null,
        to: makePosition(i + 1),
        source: 'link',
        fromLabel: `p. ${i}`,
      } as NavigationHistoryEvent)
    }
    expect(actor.getSnapshot().context.stack.length).toBe(STACK_MAX_DEPTH)
    actor.stop()
  })
})
