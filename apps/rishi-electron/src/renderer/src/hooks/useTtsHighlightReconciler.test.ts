import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePlayerStore } from '@/stores/playerStore'
import { useTtsHighlightReconciler } from './useTtsHighlightReconciler'

function setActive(index: string | null): void {
  usePlayerStore.setState({
    activeParagraph: index ? ({ index, key: index, text: '' } as never) : null,
  })
}

beforeEach(() => {
  usePlayerStore.setState({ activeParagraph: null })
})

afterEach(() => {
  // Restore JSDOM's visibilityState to a known good value so tests that
  // mutate it via Object.defineProperty cannot leak state across runs.
  Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true })
})

describe('useTtsHighlightReconciler', () => {
  it('calls the reconciler on mount with the current activeParagraph', () => {
    setActive('p5')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    expect(reconcile).toHaveBeenCalledWith('p5')
  })

  it('calls the reconciler with null when activeParagraph is null', () => {
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    expect(reconcile).toHaveBeenCalledWith(null)
  })

  it('re-invokes the reconciler when activeParagraph changes', () => {
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    act(() => setActive('p7'))
    expect(reconcile).toHaveBeenCalledWith('p7')
  })

  it('re-invokes the reconciler on document.visibilitychange to visible', () => {
    setActive('p5')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))
    expect(reconcile).toHaveBeenCalledWith('p5')
  })

  it('does not re-invoke on visibilitychange to hidden', () => {
    setActive('p5')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))
    expect(reconcile).not.toHaveBeenCalled()
  })

  it('re-invokes the reconciler on window.focus', () => {
    setActive('p5')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    window.dispatchEvent(new Event('focus'))
    expect(reconcile).toHaveBeenCalledWith('p5')
  })

  it('re-invokes the reconciler on iframe.load when iframe is provided', () => {
    setActive('p5')
    const iframe = document.createElement('iframe')
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, iframe))
    reconcile.mockClear()
    iframe.dispatchEvent(new Event('load'))
    expect(reconcile).toHaveBeenCalledWith('p5')
  })

  it('tears down listeners on unmount', () => {
    setActive('p5')
    const reconcile = vi.fn()
    const { unmount } = renderHook(() => useTtsHighlightReconciler(reconcile, null))
    unmount()
    reconcile.mockClear()
    window.dispatchEvent(new Event('focus'))
    document.dispatchEvent(new Event('visibilitychange'))
    act(() => setActive('p9'))
    expect(reconcile).not.toHaveBeenCalled()
  })
})

describe('useTtsHighlightReconciler — integration (the bug class)', () => {
  it('sweeps stale state on focus return even when activeParagraph did not change', () => {
    setActive('p5')
    let lastSeen: string | null | undefined
    const reconcile = vi.fn((d: string | null) => { lastSeen = d })
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    window.dispatchEvent(new Event('blur'))
    reconcile.mockClear()
    window.dispatchEvent(new Event('focus'))
    expect(reconcile).toHaveBeenCalledWith('p5')
    expect(lastSeen).toBe('p5')
  })

  it('full cycle: activeParagraph p5 → blur → focus → advance to p7', () => {
    const calls: Array<string | null> = []
    const reconcile = vi.fn((d: string | null) => { calls.push(d) })
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    act(() => setActive('p5'))
    window.dispatchEvent(new Event('focus'))
    act(() => setActive('p7'))
    expect(calls).toContain('p5')
    expect(calls).toContain('p7')
    expect(calls[calls.length - 1]).toBe('p7')
  })
})

describe('useTtsHighlightReconciler — lastPlayedParagraphIndex fallback', () => {
  beforeEach(() => {
    usePlayerStore.setState({
      activeParagraph: null,
      lastPlayedParagraphIndex: null
    })
  })

  it('uses lastPlayedParagraphIndex when activeParagraph is null', () => {
    usePlayerStore.setState({ lastPlayedParagraphIndex: 'p-resume' })
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    expect(reconcile).toHaveBeenLastCalledWith('p-resume')
  })

  it('prefers activeParagraph over lastPlayedParagraphIndex', () => {
    usePlayerStore.setState({
      activeParagraph: { index: 'p-active', text: 't' },
      lastPlayedParagraphIndex: 'p-resume'
    })
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    expect(reconcile).toHaveBeenLastCalledWith('p-active')
  })

  it('fires reconcile when lastPlayedParagraphIndex changes', () => {
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    reconcile.mockClear()
    usePlayerStore.setState({ lastPlayedParagraphIndex: 'p-late' })
    expect(reconcile).toHaveBeenCalledWith('p-late')
  })

  it('reconcile sees null when both are null', () => {
    const reconcile = vi.fn()
    renderHook(() => useTtsHighlightReconciler(reconcile, null))
    expect(reconcile).toHaveBeenLastCalledWith(null)
  })
})
