import { describe, it, expect, beforeEach } from 'vitest'
import { createActor } from 'xstate'
import { playerMachine } from './playerMachine'
import type { ParagraphWithIndex } from '@/stores/playerStore'

function makeParagraphs(count: number): ParagraphWithIndex[] {
  return Array.from({ length: count }, (_, i) => ({
    index: `p-${i}`,
    text: `Paragraph ${i}`
  }))
}

describe('playerMachine', () => {
  let actor: ReturnType<typeof createActor<typeof playerMachine>>

  beforeEach(() => {
    actor = createActor(playerMachine)
    actor.start()
  })

  it('should start in the idle state', () => {
    expect(actor.getSnapshot().value).toBe('idle')
  })

  it('should transition to stopped on INITIALIZE', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    expect(actor.getSnapshot().value).toBe('stopped')
    expect(actor.getSnapshot().context.bookId).toBe('book1')
  })

  it('should transition to waitingForParagraphs on PLAY when no paragraphs are loaded', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PLAY' })
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
  })

  it('should transition to loading on PLAY when paragraphs are loaded', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    expect(actor.getSnapshot().value).toBe('loading')
  })

  it('should transition to playing on AUDIO_LOADED from loading', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')
  })

  it('should transition to paused on PAUSE from playing', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
  })

  it('should return to playing on RESUME from paused.clean', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    actor.send({ type: 'RESUME' })
    expect(actor.getSnapshot().value).toBe('playing')
  })

  it('should transition to paused.stale when paragraphs change while paused', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    expect(actor.getSnapshot().value).toEqual({ paused: 'stale' })
  })

  it('should transition to loading on RESUME from paused.stale', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'RESUME' })
    expect(actor.getSnapshot().value).toBe('loading')
  })

  it('should transition to stopped on STOP from playing', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'STOP' })
    expect(actor.getSnapshot().value).toBe('stopped')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0)
  })

  it('should advance paragraph index on NEXT from playing', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
  })

  it('should retreat paragraph index on PREV from playing', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    // Advance first, then go back
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PREV' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0)
  })

  it('should transition to waitingForParagraphs on NEXT at last paragraph', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(1) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
    expect(actor.getSnapshot().context.direction).toBe('forward')
  })

  it('should transition to waitingForParagraphs on PREV at first paragraph', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PREV' })
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
    expect(actor.getSnapshot().context.direction).toBe('backward')
  })

  it('should transition to loading when paragraphs arrive during waitingForParagraphs', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PLAY' }) // No paragraphs -> waiting
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    expect(actor.getSnapshot().value).toBe('loading')
  })

  it('should retry on AUDIO_ERROR when retries remain', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_ERROR', error: 'network error' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.retryCount).toBe(1)
  })

  it('should transition to error after max retries', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    // Exhaust retries (MAX_RETRIES is 3)
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 1' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 2' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 3' })
    expect(actor.getSnapshot().value).toBe('error')
    expect(actor.getSnapshot().context.errors.length).toBeGreaterThanOrEqual(3)
  })

  it('should advance on AUDIO_ENDED when more paragraphs exist', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'AUDIO_ENDED' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
  })

  it('should store next page paragraphs', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    const nextParagraphs = makeParagraphs(2)
    actor.send({ type: 'NEXT_PARAGRAPHS_UPDATED', paragraphs: nextParagraphs })
    expect(actor.getSnapshot().context.nextPageParagraphs).toEqual(nextParagraphs)
  })

  it('should store prev page paragraphs', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    const prevParagraphs = makeParagraphs(2)
    actor.send({ type: 'PREV_PARAGRAPHS_UPDATED', paragraphs: prevParagraphs })
    expect(actor.getSnapshot().context.prevPageParagraphs).toEqual(prevParagraphs)
  })

  it('should reset to idle on CLEANUP', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'CLEANUP' })
    expect(actor.getSnapshot().value).toBe('idle')
    expect(actor.getSnapshot().context.bookId).toBe('')
  })

  it('should stop on CHAT_STARTED from any state', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().value).toBe('stopped')
  })

  it('should recover from error state on PLAY', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 1' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 2' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 3' })
    expect(actor.getSnapshot().value).toBe('error')
    actor.send({ type: 'PLAY' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.errors).toEqual([])
  })

  it('should recover from error state on NEXT', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 1' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 2' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail 3' })
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
  })

  // --- Additional regression tests ported from Tauri ---

  it('error -> PREV -> loading', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail1' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail2' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail3' })
    expect(actor.getSnapshot().value).toBe('error')
    // Advance to index 1 first
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail4' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail5' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail6' })
    expect(actor.getSnapshot().value).toBe('error')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
    // Now PREV should go back to index 0
    actor.send({ type: 'PREV' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0)
    expect(actor.getSnapshot().context.errors).toEqual([])
  })

  it('loading -> PAUSE -> paused.clean', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    expect(actor.getSnapshot().value).toBe('loading')
    actor.send({ type: 'PAUSE' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
  })

  it('loading -> PARAGRAPHS_UPDATED -> loading (restarts with new paragraphs)', () => {
    const newParagraphs = makeParagraphs(2)
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    expect(actor.getSnapshot().value).toBe('loading')
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: newParagraphs })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.currentParagraphs).toEqual(newParagraphs)
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0)
  })

  it('playing -> AUDIO_ERROR -> error (not silently dropped)', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')
    actor.send({ type: 'AUDIO_ERROR', error: 'decode failure mid-play' })
    expect(actor.getSnapshot().value).toBe('error')
    expect(actor.getSnapshot().context.errors).toContain('decode failure mid-play')
  })

  it("STOP clears timedOut so paragraphs don't auto-resume", () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'STOP' })
    expect(actor.getSnapshot().context.timedOut).toBe(false)
  })

  it('playing -> PARAGRAPHS_UPDATED -> loading (page changed while playing)', () => {
    const newParagraphs = makeParagraphs(2)
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: newParagraphs })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(0)
  })

  it('paused.clean -> NEXT -> loading', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
  })

  it('stopped -> NEXT -> loading', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
  })

  it('stopped -> PREV at first paragraph -> waitingForParagraphs', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PREV' })
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
    expect(actor.getSnapshot().context.direction).toBe('backward')
  })

  // --- Additional comprehensive tests ---

  it('should clamp paragraph index at the end when advancing past last', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(2) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    // At index 0, advance to 1
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'AUDIO_LOADED' })
    // At last index (1), NEXT should go to waitingForParagraphs
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
  })

  it('should clamp paragraph index at 0 when retreating past first', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    // At index 0, PREV should go to waitingForParagraphs
    actor.send({ type: 'PREV' })
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
    expect(actor.getSnapshot().context.direction).toBe('backward')
  })

  it('INITIALIZE from idle transitions to stopped with the given bookId', () => {
    // INITIALIZE is only handled in idle state
    expect(actor.getSnapshot().value).toBe('idle')
    actor.send({ type: 'INITIALIZE', bookId: 'book-new' })
    expect(actor.getSnapshot().value).toBe('stopped')
    expect(actor.getSnapshot().context.bookId).toBe('book-new')
  })

  it('paused.stale -> STOP -> stopped', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    expect(actor.getSnapshot().value).toEqual({ paused: 'stale' })
    actor.send({ type: 'STOP' })
    expect(actor.getSnapshot().value).toBe('stopped')
  })

  it('paused.stale -> NEXT -> loading', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(5) })
    expect(actor.getSnapshot().value).toEqual({ paused: 'stale' })
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('loading')
  })

  it('should preserve next/prev page paragraphs across state transitions', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    const nextP = makeParagraphs(2)
    const prevP = makeParagraphs(3)
    actor.send({ type: 'NEXT_PARAGRAPHS_UPDATED', paragraphs: nextP })
    actor.send({ type: 'PREV_PARAGRAPHS_UPDATED', paragraphs: prevP })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(4) })
    actor.send({ type: 'PLAY' })
    // Even after transitioning to loading, next/prev should persist
    expect(actor.getSnapshot().context.nextPageParagraphs).toEqual(nextP)
    expect(actor.getSnapshot().context.prevPageParagraphs).toEqual(prevP)
  })

  it('AUDIO_ENDED at last paragraph -> waitingForParagraphs with forward direction', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(1) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'AUDIO_ENDED' })
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
    expect(actor.getSnapshot().context.direction).toBe('forward')
  })

  it('CLEANUP from playing -> idle with reset context', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')
    actor.send({ type: 'CLEANUP' })
    expect(actor.getSnapshot().value).toBe('idle')
    expect(actor.getSnapshot().context.currentParagraphs).toEqual([])
    expect(actor.getSnapshot().context.nextPageParagraphs).toEqual([])
    expect(actor.getSnapshot().context.prevPageParagraphs).toEqual([])
  })

  it('error -> STOP -> stopped with cleared errors', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail1' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail2' })
    actor.send({ type: 'AUDIO_ERROR', error: 'fail3' })
    expect(actor.getSnapshot().value).toBe('error')
    actor.send({ type: 'STOP' })
    expect(actor.getSnapshot().value).toBe('stopped')
    expect(actor.getSnapshot().context.errors).toEqual([])
  })

  it('should handle empty paragraphs array gracefully', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: [] })
    actor.send({ type: 'PLAY' })
    // No paragraphs -> waitingForParagraphs
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
  })
})
