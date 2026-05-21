import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createActor } from 'xstate'
import { navigationHistoryMachine } from './navigationHistoryMachine'
import type { PositionDescriptor } from './types'
import type { AnchorPoint } from './types'
import { STACK_MAX_DEPTH, DWELL_MS } from './types'

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

describe('navigationHistoryMachine — engagement', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  const pos = (page: number): PositionDescriptor => ({ kind: 'pdf', page, offset: 0 })

  function getEngagement(actor: ReturnType<typeof startActor>): string {
    return (actor.getSnapshot().value as { active: { engagement: string } }).active.engagement
  }

  it('starts in engagement.idle after BOOK_OPENED', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    expect(getEngagement(actor)).toBe('idle')
  })

  it('PAGE_VISITED moves engagement to dwelling', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'PAGE_VISITED', position: pos(2), ttsContext: null })
    expect(getEngagement(actor)).toBe('dwelling')
  })

  it('ENGAGEMENT_TAP from idle goes straight to engaged', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    expect(getEngagement(actor)).toBe('engaged')
  })

  it('ENGAGEMENT_TTS_PLAYING also reaches engaged', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'ENGAGEMENT_TTS_PLAYING' })
    expect(getEngagement(actor)).toBe('engaged')
  })

  it('after DWELL_MS the dwell timer fires and reaches engaged', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'PAGE_VISITED', position: pos(2), ttsContext: null })
    vi.advanceTimersByTime(DWELL_MS)
    expect(getEngagement(actor)).toBe('engaged')
  })

  it('VISIBILITY_HIDDEN pauses dwell (enters paused); VISIBILITY_VISIBLE resumes (restarts timer)', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'PAGE_VISITED', position: pos(2), ttsContext: null })
    vi.advanceTimersByTime(DWELL_MS - 1000)
    actor.send({ type: 'VISIBILITY_HIDDEN' })
    expect(getEngagement(actor)).toBe('paused')
    vi.advanceTimersByTime(60_000) // hidden window, should NOT trigger engaged
    expect(getEngagement(actor)).toBe('paused')
    actor.send({ type: 'VISIBILITY_VISIBLE' })
    expect(getEngagement(actor)).toBe('dwelling')
    vi.advanceTimersByTime(DWELL_MS) // timer restarted on re-entry; need full DWELL_MS
    expect(getEngagement(actor)).toBe('engaged')
  })

  it('PAGE_VISITED to a different page resets engaged back to dwelling on new page', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    expect(getEngagement(actor)).toBe('engaged')
    actor.send({ type: 'PAGE_VISITED', position: pos(2), ttsContext: null })
    expect(getEngagement(actor)).toBe('dwelling')
  })
})

describe('navigationHistoryMachine — resume map + pill', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  const pos = (page: number, offset = 0): PositionDescriptor => ({ kind: 'pdf', page, offset })

  it('entering engaged writes currentPage anchor into resumeMap[pageKey]', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(7, 250) })
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 250), ttsContext: { paragraphIndex: 3 } })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    const snap = actor.getSnapshot()
    const anchor = snap.context.resumeMap.get('pdf:7')
    expect(anchor).toBeDefined()
    expect(anchor!.position).toEqual(pos(7, 250))
    expect(anchor!.tts).toEqual({ paragraphIndex: 3 })
    expect(anchor!.source).toBe('engagement')
  })

  it('JUMP_REQUESTED shows pill; engagement.engaged hides pill', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    expect(actor.getSnapshot().context.pillVisible).toBe(false)
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(1), fromTts: null, to: pos(5), source: 'link', fromLabel: 'p. 1'
    })
    expect(actor.getSnapshot().context.pillVisible).toBe(true)
    actor.send({ type: 'PAGE_VISITED', position: pos(5), ttsContext: null })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    expect(actor.getSnapshot().context.pillVisible).toBe(false)
    // stack entry retained
    expect(actor.getSnapshot().context.stack).toHaveLength(1)
  })

  it('DISMISS_PILL hides without popping', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(1), fromTts: null, to: pos(5), source: 'link', fromLabel: 'p. 1'
    })
    actor.send({ type: 'DISMISS_PILL' })
    expect(actor.getSnapshot().context.pillVisible).toBe(false)
    expect(actor.getSnapshot().context.stack).toHaveLength(1)
  })

  it('POP_BACK to empty stack hides the pill', () => {
    const actor = startActor()
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(1), fromTts: null, to: pos(5), source: 'link', fromLabel: 'p. 1'
    })
    actor.send({ type: 'PAGE_VISITED', position: pos(5), ttsContext: null })
    expect(actor.getSnapshot().context.pillVisible).toBe(true)
    actor.send({ type: 'POP_BACK' })
    expect(actor.getSnapshot().context.stack).toHaveLength(0)
    expect(actor.getSnapshot().context.pillVisible).toBe(false)
  })
})

describe('navigationHistoryMachine — smart resume emission', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  const pos = (page: number, offset = 0): PositionDescriptor => ({ kind: 'pdf', page, offset })

  function captureEmitted(actor: ReturnType<typeof startActor>): AnchorPoint[] {
    const out: AnchorPoint[] = []
    actor.on('RESUME_REQUESTED', (e: { type: 'RESUME_REQUESTED'; anchor: AnchorPoint }) => {
      out.push(e.anchor)
    })
    return out
  }

  it('PAGE_VISITED to a page with stored anchor (while stack.idle) emits RESUME_REQUESTED', () => {
    const actor = startActor()
    const emitted = captureEmitted(actor)
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(7, 250) })
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 250), ttsContext: { paragraphIndex: 3 } })
    actor.send({ type: 'ENGAGEMENT_TAP' }) // captures anchor at page 7
    // navigate away
    actor.send({ type: 'PAGE_VISITED', position: pos(9), ttsContext: null })
    const beforeReturn = emitted.length
    // return to page 7 via plain page-flip (no JUMP_REQUESTED — pure PAGE_VISITED)
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 0), ttsContext: null })
    expect(emitted.length).toBe(beforeReturn + 1)
    expect(emitted[emitted.length - 1].position).toEqual(pos(7, 250))
    expect(emitted[emitted.length - 1].tts).toEqual({ paragraphIndex: 3 })
  })

  it('PAGE_VISITED arriving during stack.navigating does NOT emit (deliberate jump wins)', () => {
    const actor = startActor()
    const emitted = captureEmitted(actor)
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(7, 250) })
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 250), ttsContext: { paragraphIndex: 3 } })
    actor.send({ type: 'ENGAGEMENT_TAP' })
    actor.send({ type: 'PAGE_VISITED', position: pos(9), ttsContext: null })
    const beforeJump = emitted.length
    // deliberate jump back to page 7
    actor.send({
      type: 'JUMP_REQUESTED',
      from: pos(9), fromTts: null, to: pos(7, 100), source: 'link', fromLabel: 'p. 9'
    })
    actor.send({ type: 'PAGE_VISITED', position: pos(7, 100), ttsContext: null })
    expect(emitted.length).toBe(beforeJump) // no new emission — deliberate wins
  })

  it('PAGE_VISITED to a page with no stored anchor does not emit', () => {
    const actor = startActor()
    const emitted = captureEmitted(actor)
    actor.send({ type: 'BOOK_OPENED', bookId: 'b', initialPosition: pos(1) })
    actor.send({ type: 'PAGE_VISITED', position: pos(50), ttsContext: null })
    expect(emitted).toEqual([])
  })
})
