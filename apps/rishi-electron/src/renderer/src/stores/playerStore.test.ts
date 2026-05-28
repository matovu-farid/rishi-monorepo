import { describe, it, expect, beforeEach, vi } from 'vitest'
import { usePlayerStore } from './playerStore'

describe('playerStore', () => {
  beforeEach(() => {
    usePlayerStore.setState({
      playingState: 'idle',
      activeParagraph: null,
      errors: [],
      currentParagraphs: [],
      nextPageParagraphs: [],
      prevPageParagraphs: [],
      send: null,
      lastPlayedParagraphIndex: null
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

  it('should set send function', () => {
    const send = vi.fn()
    usePlayerStore.getState().setSend(send)
    expect(usePlayerStore.getState().send).toBe(send)
  })
})

describe('lastPlayedParagraphIndex', () => {
  beforeEach(() => {
    usePlayerStore.setState({ lastPlayedParagraphIndex: null })
  })

  it('starts as null', () => {
    expect(usePlayerStore.getState().lastPlayedParagraphIndex).toBeNull()
  })

  it('setLastPlayedParagraphIndex updates the field', () => {
    usePlayerStore.getState().setLastPlayedParagraphIndex('p-7')
    expect(usePlayerStore.getState().lastPlayedParagraphIndex).toBe('p-7')

    usePlayerStore.getState().setLastPlayedParagraphIndex(null)
    expect(usePlayerStore.getState().lastPlayedParagraphIndex).toBeNull()
  })
})
