import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, act, cleanup } from '@testing-library/react'
import { TTSVisualCue } from '../TTSVisualCue'
import { getVisualCueEmitter } from '@/services/tts'

describe('TTSVisualCue', () => {
  beforeEach(() => {
    cleanup()
  })

  it('renders nothing by default', () => {
    render(<TTSVisualCue />)
    expect(screen.queryByTestId('tts-visual-cue')).toBeNull()
  })

  it('renders an equation cue when emitter fires equation hit', () => {
    render(<TTSVisualCue />)
    act(() => {
      getVisualCueEmitter().__emitForTest?.({
        paragraphId: 'p1',
        hits: [{ kind: 'equation', element: null, label: 'equation' }]
      })
    })
    const cue = screen.getByTestId('tts-visual-cue')
    expect(cue).toHaveTextContent(/equation/i)
  })

  it('scrolls the hit element into view when the cue is clicked', () => {
    const el = document.createElement('figure')
    document.body.appendChild(el)
    el.scrollIntoView = vi.fn()
    render(<TTSVisualCue />)
    act(() => {
      getVisualCueEmitter().__emitForTest?.({
        paragraphId: 'p1',
        hits: [{ kind: 'figure', element: el, label: 'figure' }]
      })
    })
    screen.getByTestId('tts-visual-cue').click()
    expect(el.scrollIntoView).toHaveBeenCalled()
  })

  it('clears the cue when a new paragraph has empty hits', () => {
    render(<TTSVisualCue />)
    act(() => {
      getVisualCueEmitter().__emitForTest?.({
        paragraphId: 'p1',
        hits: [{ kind: 'equation', element: null, label: 'equation' }]
      })
    })
    expect(screen.queryByTestId('tts-visual-cue')).not.toBeNull()
    act(() => {
      getVisualCueEmitter().__emitForTest?.({ paragraphId: 'p2', hits: [] })
    })
    expect(screen.queryByTestId('tts-visual-cue')).toBeNull()
  })
})
