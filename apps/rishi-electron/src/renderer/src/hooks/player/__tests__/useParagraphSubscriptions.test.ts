// Pins the load-bearing deep-equal guard in the current-paragraph
// subscription. The hook forwards playerStore.currentParagraphs into the
// machine via PARAGRAPHS_UPDATED — but only when the new array differs
// in content from the machine's ctx.currentParagraphs. The team has
// fought playing → loading flickers multiple times when this guard
// regressed (reference-different but content-identical arrays were
// forwarded, triggering a transient re-enter of `loading`).
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'

vi.mock('@/services', () => ({
  getTtsService: () => ({
    requestAudio: vi.fn(async () => undefined)
  })
}))

import { usePlayerStore } from '@/stores/playerStore'
import { useParagraphSubscriptions } from '../useParagraphSubscriptions'
import type { PlayerActor } from '@/hooks/player/usePlayerActor'

type Paragraph = { index: string; text: string }

function makeFakeActor(opts: {
  initialCurrent: Paragraph[]
  value?: string
}): { actor: PlayerActor; send: ReturnType<typeof vi.fn> } {
  const send = vi.fn()
  let currentParagraphs = opts.initialCurrent
  const actor = {
    send,
    getSnapshot: () => ({
      value: opts.value ?? 'idle',
      context: {
        currentParagraphs,
        partialFirstText: null,
        partialFirstParagraphIndex: null
      }
    })
  } as unknown as PlayerActor
  // Allow the test to step ctx after a forwarded send (simulating the
  // machine accepting the new paragraphs).
  ;(actor as unknown as { _setCtxCurrent: (p: Paragraph[]) => void })._setCtxCurrent = (p) => {
    currentParagraphs = p
  }
  return { actor, send }
}

beforeEach(() => {
  usePlayerStore.setState({
    currentParagraphs: [],
    nextPageParagraphs: [],
    prevPageParagraphs: []
  })
})

describe('useParagraphSubscriptions (current-paragraphs deep-equal guard)', () => {
  it('does NOT forward PARAGRAPHS_UPDATED when the new array is content-identical to ctx', () => {
    const ctxParagraphs: Paragraph[] = [
      { index: 'p1', text: 'hello' },
      { index: 'p2', text: 'world' }
    ]
    const { actor, send } = makeFakeActor({ initialCurrent: ctxParagraphs })

    renderHook(() => useParagraphSubscriptions(actor, 'book-1'))

    // Write a NEW array (different reference) but identical content.
    // Without the deep-equal guard, this would PARAGRAPHS_UPDATED the
    // machine and risk a transient playing → loading flicker.
    usePlayerStore.getState().setCurrentParagraphs([
      { index: 'p1', text: 'hello' },
      { index: 'p2', text: 'world' }
    ])

    expect(send).not.toHaveBeenCalled()
  })

  it('forwards PARAGRAPHS_UPDATED when content actually changes', () => {
    const { actor, send } = makeFakeActor({ initialCurrent: [] })

    renderHook(() => useParagraphSubscriptions(actor, 'book-1'))

    const next: Paragraph[] = [{ index: 'p1', text: 'hello' }]
    usePlayerStore.getState().setCurrentParagraphs(next)

    expect(send).toHaveBeenCalledWith({
      type: 'PARAGRAPHS_UPDATED',
      paragraphs: next
    })
  })
})
