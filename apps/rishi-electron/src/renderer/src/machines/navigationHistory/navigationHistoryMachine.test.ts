import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createActor } from 'xstate'
import { navigationHistoryMachine } from './navigationHistoryMachine'
import type { PositionDescriptor } from './types'
import { STACK_MAX_DEPTH } from './types'

const initialPdfPosition: PositionDescriptor = { kind: 'pdf', page: 1, offset: 0 }

function startActor() {
  const actor = createActor(navigationHistoryMachine)
  actor.start()
  return actor
}

describe('navigationHistoryMachine — lifecycle', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('starts in inactive', () => {
    const actor = startActor()
    expect(actor.getSnapshot().value).toBe('inactive')
    expect(actor.getSnapshot().context.bookId).toBeNull()
  })

  it('BOOK_OPENED transitions to active and stores bookId + currentPage', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'book-42', initialPosition: initialPdfPosition })
    const snap = actor.getSnapshot()
    expect(typeof snap.value).toBe('object') // parallel state
    expect(snap.context.bookId).toBe('book-42')
    expect(snap.context.currentPage).toEqual(initialPdfPosition)
  })

  it('BOOK_CLOSED clears stack, resumeMap, currentPage and returns to inactive', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'book-42', initialPosition: initialPdfPosition })
    actor.send({ type: 'BOOK_CLOSED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('inactive')
    expect(snap.context.bookId).toBeNull()
    expect(snap.context.stack).toEqual([])
    expect(snap.context.resumeMap.size).toBe(0)
    expect(snap.context.currentPage).toBeNull()
  })
})

describe('navigationHistoryMachine — stack', () => {
  const pos = (page: number): PositionDescriptor => ({ kind: 'pdf', page, offset: 0 })

  it('JUMP_REQUESTED pushes the from-anchor and enters stack.navigating', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(10) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(10),
      fromTts: null,
      to: pos(50),
      source: 'link',
      fromLabel: 'p. 10'
    })
    const snap = actor.getSnapshot()
    expect(snap.context.stack).toHaveLength(1)
    expect(snap.context.stack[0].position).toEqual(pos(10))
    expect(snap.context.stack[0].label).toBe('p. 10')
    expect(snap.context.stack[0].source).toBe('link')
    expect((snap.value as { active: { stack: string } }).active.stack).toBe('navigating')
  })

  it('stack.navigating returns to idle on PAGE_VISITED', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(10) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(10), fromTts: null, to: pos(50), source: 'link', fromLabel: 'p. 10'
    })
    actor.send({ type: 'PAGE_VISITED', position: pos(50), ttsContext: null })
    expect((actor.getSnapshot().value as { active: { stack: string } }).active.stack).toBe('idle')
  })

  it('POP_BACK removes top anchor and enters stack.navigating', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(10) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(10), fromTts: null, to: pos(50), source: 'link', fromLabel: 'p. 10'
    })
    actor.send({ type: 'PAGE_VISITED', position: pos(50), ttsContext: null })
    actor.send({ type: 'POP_BACK' })
    const snap = actor.getSnapshot()
    expect(snap.context.stack).toHaveLength(0)
    expect((snap.value as { active: { stack: string } }).active.stack).toBe('navigating')
  })

  it('POP_BACK on empty stack is a no-op', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(10) })
    actor.send({ type: 'POP_BACK' })
    expect(actor.getSnapshot().context.stack).toEqual([])
    expect((actor.getSnapshot().value as { active: { stack: string } }).active.stack).toBe('idle')
  })

  it('stack caps at STACK_MAX_DEPTH, dropping oldest', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(0) })
    for (let i = 0; i < STACK_MAX_DEPTH + 5; i++) {
      actor.send({
        type: 'JUMP_REQUESTED',
        from: pos(i),
        fromTts: null,
        to: pos(i + 100),
        source: 'link',
        fromLabel: `p. ${i}`
      })
      actor.send({ type: 'PAGE_VISITED', position: pos(i + 100), ttsContext: null })
    }
    const snap = actor.getSnapshot()
    expect(snap.context.stack).toHaveLength(STACK_MAX_DEPTH)
    // oldest entries dropped; first remaining should be from i=5
    expect(snap.context.stack[0].label).toBe('p. 5')
    expect(snap.context.stack[STACK_MAX_DEPTH - 1].label).toBe(`p. ${STACK_MAX_DEPTH + 4}`)
  })
})
