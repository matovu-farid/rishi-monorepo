import { describe, it, expect, vi, beforeEach } from 'vitest'

const highlightRangeMock = vi.fn().mockResolvedValue(undefined)
const removeHighlightMock = vi.fn().mockResolvedValue(true)

vi.mock('@/modules/epubwrapper', () => ({
  highlightRange: (...args: unknown[]) => highlightRangeMock(...args),
  removeHighlight: (...args: unknown[]) => removeHighlightMock(...args)
}))

import { createEpubTtsReconciler } from './reconcileTtsHighlight'

interface FakeRendition {
  annotations: { _annotations: Record<string, unknown> }
}

function makeRendition(userOwnedCfis: string[] = []): FakeRendition {
  const _annotations: Record<string, unknown> = {}
  for (const cfi of userOwnedCfis) {
    _annotations[encodeURI(cfi + 'highlight')] = { type: 'highlight', cfi }
  }
  return { annotations: { _annotations } }
}

beforeEach(() => {
  highlightRangeMock.mockClear()
  removeHighlightMock.mockClear()
})

describe('createEpubTtsReconciler', () => {
  it('with desiredIndex=null on an empty registry, calls nothing', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile(null)
    expect(highlightRangeMock).not.toHaveBeenCalled()
    expect(removeHighlightMock).not.toHaveBeenCalled()
  })

  it('with a fresh desiredIndex, calls highlightRange exactly once', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    expect(highlightRangeMock).toHaveBeenCalledTimes(1)
    expect(highlightRangeMock).toHaveBeenCalledWith(r, 'cfi-p5')
  })

  it('moves the highlight when desiredIndex changes', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    highlightRangeMock.mockClear()
    reconcile('cfi-p7')
    expect(removeHighlightMock).toHaveBeenCalledTimes(1)
    expect(removeHighlightMock).toHaveBeenCalledWith(r, 'cfi-p5')
    expect(highlightRangeMock).toHaveBeenCalledTimes(1)
    expect(highlightRangeMock).toHaveBeenCalledWith(r, 'cfi-p7')
  })

  it('clears the highlight when desiredIndex becomes null', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    removeHighlightMock.mockClear()
    reconcile(null)
    expect(removeHighlightMock).toHaveBeenCalledTimes(1)
    expect(removeHighlightMock).toHaveBeenCalledWith(r, 'cfi-p5')
  })

  it('does not blink: re-calling with the same desiredIndex emits no calls', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    highlightRangeMock.mockClear()
    removeHighlightMock.mockClear()
    reconcile('cfi-p5')
    expect(highlightRangeMock).not.toHaveBeenCalled()
    expect(removeHighlightMock).not.toHaveBeenCalled()
  })

  it('ownership registry: does NOT remove a CFI owned by a user highlight', () => {
    const r = makeRendition(['cfi-p5'])
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    expect(highlightRangeMock).toHaveBeenCalledWith(r, 'cfi-p5')
    removeHighlightMock.mockClear()
    reconcile('cfi-p7')
    expect(removeHighlightMock).not.toHaveBeenCalledWith(r, 'cfi-p5')
    expect(highlightRangeMock).toHaveBeenCalledWith(r, 'cfi-p7')
  })

  it('ownership registry: removes a CFI we did add when transitioning away', () => {
    const r = makeRendition()
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-p5')
    r.annotations._annotations[encodeURI('cfi-p5' + 'highlight')] = {}
    reconcile('cfi-p7')
    expect(removeHighlightMock).toHaveBeenCalledWith(r, 'cfi-p5')
  })

  it('ownership registry: handles a full cycle without touching user highlights', () => {
    const r = makeRendition(['cfi-user-A', 'cfi-user-B'])
    const reconcile = createEpubTtsReconciler(r as never)
    reconcile('cfi-tts-1')
    reconcile('cfi-tts-2')
    reconcile(null)
    const removedCfis = removeHighlightMock.mock.calls.map((c) => c[1])
    expect(removedCfis).not.toContain('cfi-user-A')
    expect(removedCfis).not.toContain('cfi-user-B')
  })

  it('does not throw when rendition.annotations._annotations is undefined', () => {
    // Simulate early-init Rendition where _annotations has not been populated yet.
    const r = { annotations: {} } as never
    const reconcile = createEpubTtsReconciler(r)
    expect(() => reconcile('cfi-p5')).not.toThrow()
    // Since we cannot detect prior ownership, we DO add to our owned set.
    // Transitioning away must then call removeHighlight for that CFI.
    removeHighlightMock.mockClear()
    reconcile('cfi-p7')
    expect(removeHighlightMock).toHaveBeenCalledWith(r, 'cfi-p5')
  })
})
