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

  it('should transition to republishingParagraphs on PLAY when no paragraphs are loaded', () => {
    // PLAY in stopped+empty routes to republishingParagraphs (NOT
    // waitingForParagraphs). The hook calls publishCurrentEpubParagraphs()
    // rather than setting pageRequest, avoiding an unwanted page advance.
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PLAY' })
    expect(actor.getSnapshot().value).toBe('republishingParagraphs')
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

  describe('PAGE_NAVIGATING (external page nav)', () => {
    it('clears currentParagraphs and transitions to pageNavigating from playing', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })
      expect(actor.getSnapshot().value).toBe('playing')

      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('pageNavigating')
      expect(snap.context.currentParagraphs).toEqual([])
      expect(snap.context.paragraphIndex).toBe(0)
      expect(snap.context.wantsAutoResume).toBe(true)
    })

    it('STOP+PLAY from pageNavigating must NOT see the old paragraphs', () => {
      // This is the exact user-reported scenario: nav happened, user
      // clicked Stop+Play before the new paragraphs landed. PLAY in
      // stopped state must not see the old page's paragraphs.
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })

      actor.send({ type: 'STOP' })
      expect(actor.getSnapshot().value).toBe('stopped')
      expect(actor.getSnapshot().context.currentParagraphs).toEqual([])

      actor.send({ type: 'PLAY' })
      // No paragraphs in context, so PLAY routes to republishingParagraphs
      // (the hook will call publishCurrentEpubParagraphs() — no pageRequest).
      expect(actor.getSnapshot().value).toBe('republishingParagraphs')
    })

    it('auto-resumes loading on PARAGRAPHS_UPDATED if was playing before', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })

      actor.send({
        type: 'PARAGRAPHS_UPDATED',
        paragraphs: [
          { index: 'p-new-0', text: 'new' },
          { index: 'p-new-1', text: 'next' }
        ]
      })
      expect(actor.getSnapshot().value).toBe('loading')
      expect(actor.getSnapshot().context.currentParagraphs[0].index).toBe('p-new-0')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(false)
    })

    it('does NOT auto-resume if user was paused before nav', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })
      actor.send({ type: 'PAUSE' })
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      expect(actor.getSnapshot().value).toBe('pageNavigating')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(false)

      actor.send({
        type: 'PARAGRAPHS_UPDATED',
        paragraphs: [{ index: 'p-new-0', text: 'new' }]
      })
      expect(actor.getSnapshot().value).toBe('stopped')
    })

    it('stopped + PAGE_NAVIGATING transitions to pageNavigating, paragraphs preserved', () => {
      // After the fix: stopped:PAGE_NAVIGATING now transitions to
      // pageNavigating (not stays in stopped) and does NOT clear paragraphs.
      // This prevents a fast PLAY-after-nav from going to waitingForParagraphs
      // and triggering a spurious pageRequest='next'.
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('pageNavigating')
      expect(snap.context.currentParagraphs.length).toBe(3)
      expect(snap.context.wantsAutoResume).toBe(false)
      expect(snap.context.direction).toBe('forward')
    })

    // 5.1: stopped → pageNavigating on PAGE_NAVIGATING, paragraphs preserved.
    it('stopped → pageNavigating preserves currentParagraphs and sets direction', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      const paragraphs = makeParagraphs(3)
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs })
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'backward' })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('pageNavigating')
      expect(snap.context.currentParagraphs).toEqual(paragraphs)
      expect(snap.context.direction).toBe('backward')
      expect(snap.context.wantsAutoResume).toBe(false)
    })

    // 5.2: stopped → pageNavigating → PLAY → wantsAutoResume → loading on
    // PARAGRAPHS_UPDATED. Proves user clicking PLAY during initial book-open
    // curl still starts audio (no missed PLAY event).
    it('PLAY during pageNavigating from stopped → loading on PARAGRAPHS_UPDATED', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      expect(actor.getSnapshot().value).toBe('pageNavigating')

      actor.send({ type: 'PLAY' })
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(true)
      // Still in pageNavigating waiting for paragraphs to land.
      expect(actor.getSnapshot().value).toBe('pageNavigating')

      actor.send({
        type: 'PARAGRAPHS_UPDATED',
        paragraphs: [
          { index: 'p-new-0', text: 'new page first paragraph' },
          { index: 'p-new-1', text: 'new page second paragraph' }
        ]
      })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('loading')
      expect(snap.context.paragraphIndex).toBe(0)
      expect(snap.context.wantsAutoResume).toBe(false)
    })

    // 5.3: stopped → pageNavigating → PARAGRAPHS_UPDATED without PLAY → stopped.
    // Proves nav with no user intent does not auto-play.
    it('pageNavigating without PLAY returns to stopped on PARAGRAPHS_UPDATED', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      expect(actor.getSnapshot().value).toBe('pageNavigating')

      actor.send({
        type: 'PARAGRAPHS_UPDATED',
        paragraphs: [{ index: 'p-new-0', text: 'new' }]
      })
      const snap = actor.getSnapshot()
      expect(snap.value).toBe('stopped')
      expect(snap.context.wantsAutoResume).toBe(false)
      expect(snap.context.currentParagraphs[0].index).toBe('p-new-0')
    })

    // 5.4: Integration — stopped:PAGE_NAVIGATING followed by PLAY exercises
    // pageNavigating:PLAY which sets wantsAutoResume. Confirms the combined
    // sequence works end-to-end.
    it('stopped:PAGE_NAVIGATING then PLAY routes through pageNavigating:PLAY', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })

      // Initial state.
      expect(actor.getSnapshot().value).toBe('stopped')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(false)

      // External nav starts.
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      expect(actor.getSnapshot().value).toBe('pageNavigating')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(false)

      // User clicks PLAY during the curl.
      actor.send({ type: 'PLAY' })
      expect(actor.getSnapshot().value).toBe('pageNavigating')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(true)
    })

    // Regression: when the player auto-advances past the last paragraph on a
    // page (AUDIO_ENDED), it should continue playing on the next page once
    // PARAGRAPHS_UPDATED arrives. Previously playing → waitingForParagraphs
    // did not set wantsAutoResume, so the subsequent PAGE_NAVIGATING (fired
    // by the hook when nav state leaves idle) preserved wantsAutoResume=false
    // and the player stopped on the new page.
    it('playing → AUDIO_ENDED at last → page nav → PARAGRAPHS_UPDATED keeps loading', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(1) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })
      expect(actor.getSnapshot().value).toBe('playing')

      // Audio finishes the last paragraph — player asks for the next page.
      actor.send({ type: 'AUDIO_ENDED' })
      expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(true)

      // External nav fires (rendition started turning the page).
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      expect(actor.getSnapshot().value).toBe('pageNavigating')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(true)

      // New page paragraphs arrive — must auto-resume to loading, not stopped.
      actor.send({
        type: 'PARAGRAPHS_UPDATED',
        paragraphs: [
          { index: 'p-new-0', text: 'next page first paragraph' },
          { index: 'p-new-1', text: 'next page second paragraph' }
        ]
      })
      expect(actor.getSnapshot().value).toBe('loading')
      expect(actor.getSnapshot().context.paragraphIndex).toBe(0)
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(false)
    })

    it('playing → NEXT at last paragraph → page nav → PARAGRAPHS_UPDATED keeps loading', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(1) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })

      actor.send({ type: 'NEXT' })
      expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(true)

      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      actor.send({
        type: 'PARAGRAPHS_UPDATED',
        paragraphs: [{ index: 'p-new-0', text: 'new' }]
      })
      expect(actor.getSnapshot().value).toBe('loading')
    })

    it('playing → PREV at first paragraph → page nav → PARAGRAPHS_UPDATED keeps loading', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })

      actor.send({ type: 'PREV' })
      expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(true)

      actor.send({ type: 'PAGE_NAVIGATING', direction: 'backward' })
      actor.send({
        type: 'PARAGRAPHS_UPDATED',
        paragraphs: [{ index: 'p-prev-0', text: 'prev' }]
      })
      expect(actor.getSnapshot().value).toBe('loading')
    })

    // Regression: when the user clicks the player's PREV button at the first
    // paragraph of a page, the machine must remember it wanted to go BACKWARD
    // even if the subsequent PAGE_NAVIGATING event reports a different
    // direction (the hook used to hardcode 'forward'). On the previous page
    // the player must land on the LAST paragraph, not paragraph 0.
    it('PREV at first paragraph preserves backward direction through pageNavigating', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })

      // Player at first paragraph clicks PREV.
      actor.send({ type: 'PREV' })
      expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
      expect(actor.getSnapshot().context.direction).toBe('backward')

      // The hook used to hardcode direction='forward' in PAGE_NAVIGATING
      // regardless of player intent. The state machine must preserve the
      // direction it already set (backward) — this PAGE_NAVIGATING event's
      // direction is best-effort, the player's existing intent wins.
      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      expect(actor.getSnapshot().context.direction).toBe('backward')

      // Previous page's paragraphs arrive (5 paragraphs).
      const prevPageParagraphs = Array.from({ length: 5 }, (_, i) => ({
        index: `prev-${i}`,
        text: `Previous page paragraph ${i}`
      }))
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: prevPageParagraphs })

      expect(actor.getSnapshot().value).toBe('loading')
      // The user must land on the LAST paragraph of the previous page
      // (index 4), not the first (index 0).
      expect(actor.getSnapshot().context.paragraphIndex).toBe(4)
    })

    it('stopped → NEXT at last paragraph → page nav does NOT auto-resume', () => {
      // Counter-test: user is stopped, clicks NEXT at boundary — they
      // explicitly want to navigate but not auto-play.
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(1) })
      actor.send({ type: 'NEXT' })
      expect(actor.getSnapshot().value).toBe('waitingForParagraphs')
      expect(actor.getSnapshot().context.wantsAutoResume).toBe(false)

      actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      actor.send({
        type: 'PARAGRAPHS_UPDATED',
        paragraphs: [{ index: 'p-new-0', text: 'new' }]
      })
      expect(actor.getSnapshot().value).toBe('stopped')
    })
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
    // No paragraphs -> republishingParagraphs (hook will republish from the
    // rendition without firing pageRequest).
    expect(actor.getSnapshot().value).toBe('republishingParagraphs')
  })

  describe('REPEAT', () => {
    it('transitions playing → loading and keeps paragraphIndex unchanged', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })
      // Advance to paragraph index 1 so we can prove REPEAT does NOT reset to 0.
      actor.send({ type: 'NEXT' })
      actor.send({ type: 'AUDIO_LOADED' })
      expect(actor.getSnapshot().value).toBe('playing')
      expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

      actor.send({ type: 'REPEAT' })

      const snap = actor.getSnapshot()
      expect(snap.value).toBe('loading')
      expect(snap.context.paragraphIndex).toBe(1)
    })

    it('clears partialFirstText and partialFirstKey from context', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      // Enter playing via PLAY_FROM with a partial-first override.
      actor.send({
        type: 'PLAY_FROM',
        paragraphIndex: 1,
        partialFirstText: 'half of the paragraph',
        partialFirstKey: 'p-1:0,1:21'
      })
      actor.send({ type: 'AUDIO_LOADED' })
      expect(actor.getSnapshot().context.partialFirstText).toBe('half of the paragraph')
      expect(actor.getSnapshot().context.partialFirstKey).toBe('p-1:0,1:21')

      actor.send({ type: 'REPEAT' })

      const snap = actor.getSnapshot()
      expect(snap.value).toBe('loading')
      expect(snap.context.partialFirstText).toBeNull()
      expect(snap.context.partialFirstKey).toBeNull()
      expect(snap.context.partialFirstParagraphIndex).toBeNull()
    })

    it('is a no-op from every non-playing state', () => {
      const cases: Array<{ name: string; enter: (a: typeof actor) => void }> = [
        { name: 'idle', enter: () => {} },
        {
          name: 'stopped',
          enter: (a) => {
            a.send({ type: 'INITIALIZE', bookId: 'book1' })
          }
        },
        {
          name: 'loading',
          enter: (a) => {
            a.send({ type: 'INITIALIZE', bookId: 'book1' })
            a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
            a.send({ type: 'PLAY' })
          }
        },
        {
          name: 'paused.clean',
          enter: (a) => {
            a.send({ type: 'INITIALIZE', bookId: 'book1' })
            a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
            a.send({ type: 'PLAY' })
            a.send({ type: 'AUDIO_LOADED' })
            a.send({ type: 'PAUSE' })
          }
        },
        {
          name: 'paused.stale',
          enter: (a) => {
            a.send({ type: 'INITIALIZE', bookId: 'book1' })
            a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
            a.send({ type: 'PLAY' })
            a.send({ type: 'AUDIO_LOADED' })
            a.send({ type: 'PAUSE' })
            a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(2) })
          }
        },
        {
          name: 'waitingForParagraphs',
          enter: (a) => {
            a.send({ type: 'INITIALIZE', bookId: 'book1' })
            a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(1) })
            a.send({ type: 'PLAY' })
            a.send({ type: 'AUDIO_LOADED' })
            a.send({ type: 'NEXT' })
          }
        },
        {
          name: 'pageNavigating',
          enter: (a) => {
            a.send({ type: 'INITIALIZE', bookId: 'book1' })
            a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
            a.send({ type: 'PLAY' })
            a.send({ type: 'AUDIO_LOADED' })
            a.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
          }
        },
        {
          name: 'republishingParagraphs',
          enter: (a) => {
            a.send({ type: 'INITIALIZE', bookId: 'book1' })
            a.send({ type: 'PLAY' })
          }
        },
        {
          name: 'error',
          enter: (a) => {
            a.send({ type: 'INITIALIZE', bookId: 'book1' })
            a.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
            a.send({ type: 'PLAY' })
            a.send({ type: 'AUDIO_LOADED' })
            a.send({ type: 'AUDIO_ERROR', error: 'boom' })
          }
        }
      ]

      for (const c of cases) {
        const fresh = createActor(playerMachine)
        fresh.start()
        c.enter(fresh)
        const beforeValue = fresh.getSnapshot().value
        const beforeIndex = fresh.getSnapshot().context.paragraphIndex
        fresh.send({ type: 'REPEAT' })
        const afterValue = fresh.getSnapshot().value
        const afterIndex = fresh.getSnapshot().context.paragraphIndex
        expect(afterValue, `state should not change from ${c.name}`).toEqual(beforeValue)
        expect(afterIndex, `paragraphIndex should not change from ${c.name}`).toBe(beforeIndex)
      }
    })

    it('after REPEAT, AUDIO_ENDED advances paragraphIndex by 1 as normal', () => {
      actor.send({ type: 'INITIALIZE', bookId: 'book1' })
      actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeParagraphs(3) })
      actor.send({ type: 'PLAY' })
      actor.send({ type: 'AUDIO_LOADED' })
      actor.send({ type: 'NEXT' })
      actor.send({ type: 'AUDIO_LOADED' })
      expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

      actor.send({ type: 'REPEAT' })
      expect(actor.getSnapshot().value).toBe('loading')

      actor.send({ type: 'AUDIO_LOADED' })
      expect(actor.getSnapshot().value).toBe('playing')

      actor.send({ type: 'AUDIO_ENDED' })
      expect(actor.getSnapshot().value).toBe('loading')
      expect(actor.getSnapshot().context.paragraphIndex).toBe(2)
    })
  })
})

describe('playerMachine - PLAY_FROM', () => {
  const paragraphs = [
    { index: 'p0', text: 'First.' },
    { index: 'p1', text: 'Second.' },
    { index: 'p2', text: 'Third.' }
  ]

  function setupPlayingState() {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book-1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs })
    return actor
  }

  it('PLAY_FROM from stopped transitions to loading with the target paragraph index', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 2,
      partialFirstText: 'override text',
      partialFirstKey: 'p2#s=0'
    })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(2)
    expect(actor.getSnapshot().context.partialFirstText).toBe('override text')
    expect(actor.getSnapshot().context.partialFirstKey).toBe('p2#s=0')
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBe(2)
  })

  it('PLAY_FROM from playing transitions to loading with new index', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 0,
      partialFirstText: 'p0 full',
      partialFirstKey: 'p0#s=0'
    })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')

    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 2,
      partialFirstText: 'p2 override',
      partialFirstKey: 'p2#s=5'
    })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(2)
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBe(2)
  })

  it('PLAY_FROM is ignored from idle', () => {
    const actor = createActor(playerMachine).start()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'x',
      partialFirstKey: 'p1#s=0'
    })
    expect(actor.getSnapshot().value).toBe('idle')
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
  })

  it('PLAY_FROM is ignored from pageNavigating', () => {
    const actor = setupPlayingState()
    actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
    expect(actor.getSnapshot().value).toBe('pageNavigating')
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'x',
      partialFirstKey: 'p1#s=0'
    })
    expect(actor.getSnapshot().value).toBe('pageNavigating')
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
  })

  it('override clears on STOP', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'override',
      partialFirstKey: 'p1#s=0'
    })
    actor.send({ type: 'STOP' })
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBeNull()
  })

  it('override clears on PAGE_NAVIGATING', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'override',
      partialFirstKey: 'p1#s=0'
    })
    actor.send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
  })

  it('override survives RESUME from paused.clean', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'override',
      partialFirstKey: 'p1#s=0'
    })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    actor.send({ type: 'RESUME' })
    expect(actor.getSnapshot().value).toBe('playing')
    expect(actor.getSnapshot().context.partialFirstText).toBe('override')
  })

  it('override clears after AUDIO_ENDED for the override paragraph', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 0,
      partialFirstText: 'override',
      partialFirstKey: 'p0#s=0'
    })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'AUDIO_ENDED' })
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBeNull()
  })

  it('override clears on CHAT_STARTED', () => {
    const actor = setupPlayingState()
    actor.send({
      type: 'PLAY_FROM',
      paragraphIndex: 1,
      partialFirstText: 'override',
      partialFirstKey: 'p1#s=0'
    })
    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().context.partialFirstText).toBeNull()
    expect(actor.getSnapshot().context.partialFirstParagraphIndex).toBeNull()
  })
})

describe('playerMachine - CHAT_STARTED per-state', () => {
  function makeP(count: number): ParagraphWithIndex[] {
    return Array.from({ length: count }, (_, i) => ({
      index: `p-${i}`,
      text: `Paragraph ${i}`
    }))
  }

  it('CHAT_STARTED from playing transitions to paused.clean and preserves paragraphIndex', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

    actor.send({ type: 'CHAT_STARTED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ paused: 'clean' })
    expect(snap.context.paragraphIndex).toBe(1)
  })

  it('CHAT_STARTED from playing sets wantsAutoResumeAfterChat', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')

    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(true)
  })

  it('CHAT_STARTED from loading transitions to paused.clean and sets the flag', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    expect(actor.getSnapshot().value).toBe('loading')

    actor.send({ type: 'CHAT_STARTED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ paused: 'clean' })
    expect(snap.context.wantsAutoResumeAfterChat).toBe(true)
  })

  it('CHAT_STARTED from waitingForParagraphs transitions to paused.clean and sets the flag', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(1) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'NEXT' })
    expect(actor.getSnapshot().value).toBe('waitingForParagraphs')

    actor.send({ type: 'CHAT_STARTED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ paused: 'clean' })
    expect(snap.context.wantsAutoResumeAfterChat).toBe(true)
  })

  it('CHAT_STARTED from stopped does not change state and does not set the flag', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    expect(actor.getSnapshot().value).toBe('stopped')

    actor.send({ type: 'CHAT_STARTED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('stopped')
    expect(snap.context.wantsAutoResumeAfterChat).toBe(false)
  })

  it('CHAT_STARTED from paused.clean stays in paused.clean and does not set the flag', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })

    actor.send({ type: 'CHAT_STARTED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toEqual({ paused: 'clean' })
    expect(snap.context.wantsAutoResumeAfterChat).toBe(false)
  })

  it('CHAT_STARTED from idle is a no-op for the flag', () => {
    const actor = createActor(playerMachine).start()
    expect(actor.getSnapshot().value).toBe('idle')

    actor.send({ type: 'CHAT_STARTED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('idle')
    expect(snap.context.wantsAutoResumeAfterChat).toBe(false)
  })

  it('CHAT_STARTED from republishingParagraphs clears the flag without setting it', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(true)
    actor.send({ type: 'STOP' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: [] })
    actor.send({ type: 'PLAY' })
    expect(actor.getSnapshot().value).toBe('republishingParagraphs')

    actor.send({ type: 'CHAT_STARTED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('republishingParagraphs')
    expect(snap.context.wantsAutoResumeAfterChat).toBe(false)
  })

  it('exiting paused.clean via RESUME clears wantsAutoResumeAfterChat', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(true)

    actor.send({ type: 'RESUME' })
    expect(actor.getSnapshot().value).toBe('playing')
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(false)

    actor.send({ type: 'CHAT_ENDED' })
    expect(actor.getSnapshot().value).toBe('playing')
  })
})

describe('playerMachine - CHAT_ENDED', () => {
  function makeP(count: number): ParagraphWithIndex[] {
    return Array.from({ length: count }, (_, i) => ({
      index: `p-${i}`,
      text: `Paragraph ${i}`
    }))
  }

  it('CHAT_ENDED from paused.clean with flag=true transitions to loading at the same paragraphIndex', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(true)
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

    actor.send({ type: 'CHAT_ENDED' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('loading')
    expect(snap.context.paragraphIndex).toBe(1)
  })

  it('CHAT_ENDED from paused.clean with flag=false stays paused', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(false)

    actor.send({ type: 'CHAT_ENDED' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
  })

  it('CHAT_ENDED from stopped is a no-op', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    expect(actor.getSnapshot().value).toBe('stopped')

    actor.send({ type: 'CHAT_ENDED' })
    expect(actor.getSnapshot().value).toBe('stopped')
  })

  it('CHAT_ENDED always clears wantsAutoResumeAfterChat', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    actor.send({ type: 'PARAGRAPHS_UPDATED', paragraphs: makeP(3) })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(true)

    actor.send({ type: 'CHAT_ENDED' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(false)
  })
})

describe('resumeParagraphIndex (INITIALIZE option)', () => {
  let actor: ReturnType<typeof createActor<typeof playerMachine>>

  beforeEach(() => {
    actor = createActor(playerMachine)
    actor.start()
  })

  it('starts with a null resumeParagraphIndex by default', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    expect(actor.getSnapshot().context.resumeParagraphIndex).toBeNull()
  })

  it('stores resumeParagraphIndex from INITIALIZE payload', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1', resumeParagraphIndex: 'p-2' })
    expect(actor.getSnapshot().context.resumeParagraphIndex).toBe('p-2')
  })

  it('treats an absent resumeParagraphIndex as null (not undefined)', () => {
    actor.send({ type: 'INITIALIZE', bookId: 'book1' })
    expect(actor.getSnapshot().context.resumeParagraphIndex).toBeNull()
  })
})
