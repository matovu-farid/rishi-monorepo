import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createActor } from 'xstate'
import { navigationHistoryMachine } from './navigationHistoryMachine'
import type { PositionDescriptor } from './types'

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
