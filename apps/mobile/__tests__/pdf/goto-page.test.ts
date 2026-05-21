/**
 * Verifies the go-to-page input handling rules: clamping, parsing,
 * and seek-lockout against the pdfStore.
 */

import { usePdfStore, BookNavigationState } from '@/lib/stores/pdfStore'

const initialState = usePdfStore.getState()
function reset(): void {
  usePdfStore.setState(initialState, true)
}

/**
 * Pure helper used by the reader screen's "Go to page" prompt — the
 * same rule lives in electron's reader so test it independently of UI.
 */
export function parsePageInput(input: string, totalPages: number): number | null {
  const n = Number.parseInt(input, 10)
  if (!Number.isFinite(n)) return null
  if (n < 1) return null
  if (n > totalPages) return null
  return n
}

describe('parsePageInput', () => {
  it('returns the number when in range', () => {
    expect(parsePageInput('5', 100)).toBe(5)
    expect(parsePageInput('  42  ', 100)).toBe(42) // parseInt is tolerant
  })

  it('rejects non-numeric input', () => {
    expect(parsePageInput('abc', 100)).toBeNull()
    expect(parsePageInput('', 100)).toBeNull()
    expect(parsePageInput('1.5', 100)).toBe(1) // parseInt floors
  })

  it('rejects out-of-range numbers', () => {
    expect(parsePageInput('0', 100)).toBeNull()
    expect(parsePageInput('-5', 100)).toBeNull()
    expect(parsePageInput('101', 100)).toBeNull()
  })

  it('accepts the last page', () => {
    expect(parsePageInput('100', 100)).toBe(100)
  })
})

describe('pdfStore go-to-page interaction', () => {
  beforeEach(reset)

  it('setPageNumber locks out further setPageNumber until Idle', () => {
    usePdfStore.getState().setPageCount(100)
    usePdfStore.getState().setPageNumber(20)
    expect(usePdfStore.getState().bookNavigationState).toBe(BookNavigationState.Navigating)
    usePdfStore.getState().setPageNumber(50) // ignored (still Navigating)
    expect(usePdfStore.getState().pageNumber).toBe(20)

    // Simulate the WebView reporting that the seek landed.
    usePdfStore.setState({ bookNavigationState: BookNavigationState.Idle })
    usePdfStore.getState().setPageNumber(50)
    expect(usePdfStore.getState().pageNumber).toBe(50)
  })

  it('scroll reports during a seek do not stomp the target page', () => {
    usePdfStore.getState().setPageCount(100)
    usePdfStore.getState().setPageNumber(80)
    // The WebView's scroll watcher might still be reporting "1" while
    // the JS scrollTo is in flight. The store must ignore those.
    usePdfStore.getState().setScrollPageNumber(1)
    expect(usePdfStore.getState().pageNumber).toBe(80)
    expect(usePdfStore.getState().scrollPageNumber).toBe(1)
  })
})
