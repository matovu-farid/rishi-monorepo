import { describe, it, expect, beforeEach, vi } from 'vitest'
import { usePlayerStore } from './playerStore'

describe('playerStore', () => {
  beforeEach(() => {
    usePlayerStore.setState({
      playingState: 'idle',
      activeParagraph: null,
      endedParagraph: null,
      lastMove: null,
      errors: [],
      currentParagraphs: [],
      nextPageParagraphs: [],
      prevPageParagraphs: [],
      pageRequest: null,
      send: null
    })
  })

  it('should start in idle state', () => {
    expect(usePlayerStore.getState().playingState).toBe('idle')
  })

  it('should set current paragraphs', () => {
    const paragraphs = [
      { index: '1', text: 'Hello' },
      { index: '2', text: 'World' }
    ]
    usePlayerStore.getState().setCurrentParagraphs(paragraphs)
    expect(usePlayerStore.getState().currentParagraphs).toEqual(paragraphs)
  })

  it('should set next page paragraphs', () => {
    const paragraphs = [{ index: '3', text: 'Next' }]
    usePlayerStore.getState().setNextPageParagraphs(paragraphs)
    expect(usePlayerStore.getState().nextPageParagraphs).toEqual(paragraphs)
  })

  it('should set prev page paragraphs', () => {
    const paragraphs = [{ index: '0', text: 'Prev' }]
    usePlayerStore.getState().setPrevPageParagraphs(paragraphs)
    expect(usePlayerStore.getState().prevPageParagraphs).toEqual(paragraphs)
  })

  it('should request next page', () => {
    usePlayerStore.getState().requestNextPage()
    expect(usePlayerStore.getState().pageRequest).toBe('next')
  })

  it('should request prev page', () => {
    usePlayerStore.getState().requestPrevPage()
    expect(usePlayerStore.getState().pageRequest).toBe('prev')
  })

  it('should clear page request', () => {
    usePlayerStore.getState().requestNextPage()
    usePlayerStore.getState().clearPageRequest()
    expect(usePlayerStore.getState().pageRequest).toBeNull()
  })

  it('should set send function', () => {
    const send = vi.fn()
    usePlayerStore.getState().setSend(send)
    expect(usePlayerStore.getState().send).toBe(send)
  })
})
