import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { useRef } from 'react'
import { renderHook, act } from '@testing-library/react'
import type { TextContent } from 'react-pdf'
import { usePdfStore, type Paragraph } from '@/stores/pdfStore'
import { publishParagraphsForPage } from '@/hooks/usePdfReader'
import { useScrolling } from './useScrolling'

// Capture every animate() call so we can assert whether useScrolling
// triggered a programmatic centering scroll (which is what "snaps back"
// to the previous page in the issue #30 refined symptom).
const animateMock = vi.fn()

vi.mock('framer-motion', () => ({
  animate: (...args: unknown[]) => animateMock(...args)
}))

/**
 * Build a Paragraph that lives inside `pdfStore.currentViewParagraphs`.
 * The dimensions field is irrelevant to useScrolling — only the `index`
 * (used to resolve the highlighted mark via `.find`) matters.
 */
function makeParagraph(index: string, text: string): Paragraph {
  return {
    index,
    text,
    dimensions: { top: 0, bottom: 0 }
  }
}

let createdContainers: HTMLDivElement[] = []

/**
 * Construct a fake scrollable container that already holds a `<mark>` for
 * a single highlighted paragraph. We anchor the mark at the top of the
 * container (mark.top === container.top) — the exact geometry produced
 * by `pageControls.nextPage()` followed by `virtualizer.scrollToIndex(N,
 * { align: 'start' })`, where the freshly-landed page's paragraph 0 sits
 * flush with the top of the viewport. With that geometry, `useScrolling`'s
 * centering math would scroll *up* by ~half the viewport height — pulling
 * the previous page (page N-1) back into view. That snap-back is what the
 * user reports in issue #30 after PR #31.
 */
function setupContainerWithMark(): {
  container: HTMLDivElement
  mark: HTMLElement
} {
  const container = document.createElement('div')
  // happy-dom doesn't lay out elements, so we stub getBoundingClientRect
  // and the size/scroll properties so useScrolling's centering math
  // produces a real, non-zero `targetScrollTop`.
  Object.defineProperty(container, 'clientHeight', { value: 800, configurable: true })
  let scrollTop = 1000
  Object.defineProperty(container, 'scrollTop', {
    get: () => scrollTop,
    set: (value: number) => {
      scrollTop = value
    },
    configurable: true
  })
  container.getBoundingClientRect = (): DOMRect =>
    ({ top: 0, left: 0, right: 0, bottom: 800, width: 0, height: 800, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect

  const mark = document.createElement('mark')
  mark.textContent = 'first paragraph of newly-landed page N+1'
  // Mark is at viewport top — same geometry as just after
  // `virtualizer.scrollToIndex(N, { align: 'start' })`.
  mark.getBoundingClientRect = (): DOMRect =>
    ({ top: 0, left: 0, right: 0, bottom: 24, width: 0, height: 24, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect
  // happy-dom's `innerText` falls back to `textContent`, which is what
  // useScrolling's `.find((m) => m.innerText)` actually reads.
  container.appendChild(mark)
  document.body.appendChild(container)
  createdContainers.push(container)
  return { container, mark }
}

/** Renders useScrolling with a stable ref pointing at `container`. */
function renderUseScrolling(container: HTMLDivElement): void {
  renderHook(() => {
    const ref = useRef<HTMLDivElement | null>(container)
    useScrolling(ref)
  })
}

describe('useScrolling — page-advance snap-back race (issue #30 refined symptom)', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    animateMock.mockReset()
    usePdfStore.setState(usePdfStore.getInitialState(), true)
  })

  afterEach(() => {
    vi.useRealTimers()
    for (const c of createdContainers) c.remove()
    createdContainers = []
  })

  it('does NOT auto-center the first paragraph of a freshly-landed page (would snap back to previous page)', () => {
    // Replay the exact race the user observed after PR #31:
    //   1. The player asked for the next page (pageControls.nextPage),
    //      which set `isLookingForNextParagraph = true` and asked the
    //      virtualizer to scroll to page N+1 with align:'start'.
    //   2. The new page's text was rendered and paragraphs were
    //      published via `publishParagraphsForPage`. In the BROKEN
    //      version this also cleared the suppression flag — even
    //      though the new highlight hadn't been assigned yet.
    //   3. The player then loaded paragraph 0's audio. `pdf.tsx` set
    //      `highlightedParagraphIndex` to that paragraph's id.
    //   4. `useScrolling` fired its 100 ms debounced auto-scroll. In
    //      the broken version the suppression flag was already false
    //      (cleared at step 2), so the centering math ran against the
    //      new mark — which sits at the top of the viewport — and
    //      scrolled *up* by ~half the viewport height, pulling page N
    //      back into view. This is the "goes back to the previous page"
    //      snap-back.
    //
    // The fix moves the flag-clear from `publishParagraphsForPage` into
    // `useScrolling`'s timeout body: clear AND skip centering for this
    // one tick. Subsequent paragraphs on the new page will see the flag
    // false and center normally.
    const { container } = setupContainerWithMark()

    // 1. pageControls.nextPage() has just run; flag is set.
    usePdfStore.setState({
      isLookingForNextParagraph: true,
      isTextGot: false,
      highlightedParagraphIndex: ''
    })

    // 2. publishParagraphsForPage runs for the new page. We exercise the
    //    REAL implementation so this test catches any regression that
    //    re-introduces the early flag-clear. Page 12's data contains one
    //    paragraph long enough to survive the MIN_PARAGRAPH_LENGTH filter
    //    in `pageDataToParagraphs`.
    const longText =
      'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.'
    const pageDataMap: Record<number, TextContent> = {
      12: {
        items: [
          // hasEOL on the last item; transform[5] arbitrary y-coordinate.
          {
            str: longText,
            transform: [1, 0, 0, 1, 0, 700],
            width: 0,
            height: 12,
            dir: 'ltr',
            fontName: 'g_d0_f1',
            hasEOL: true
          }
        ],
        styles: {},
        lang: null
      }
    }

    act(() => {
      publishParagraphsForPage(12, pageDataMap)
    })

    // After publishing, currentViewParagraphs is populated and isTextGot
    // is true. The flag MUST still be `true` after the fix (the producer
    // no longer clears it). With the original buggy code the flag is
    // already `false` at this point.
    const publishedParagraphs = usePdfStore.getState().currentViewParagraphs
    expect(publishedParagraphs.length, 'publishParagraphsForPage produced at least one paragraph').toBeGreaterThan(0)

    renderUseScrolling(container)

    // 3. The player loads audio for the first paragraph of the new page
    //    and pdf.tsx's subscriber assigns the highlight.
    const firstParagraphIndex = publishedParagraphs[0].index
    act(() => {
      usePdfStore.setState({ highlightedParagraphIndex: firstParagraphIndex })
    })

    // 4. The 100 ms debounce fires. With the broken code this calls
    //    animate(...) with a target above the current scrollTop —
    //    snap-back to the previous page. The fix makes this a no-op AND
    //    self-clears the flag so the next paragraph centers normally.
    act(() => {
      vi.advanceTimersByTime(150)
    })

    expect(
      animateMock,
      'useScrolling must NOT center the first highlight on a newly-landed page — that produces the snap-back to the previous page reported in issue #30 after PR #31.'
    ).not.toHaveBeenCalled()

    // The suppression has been spent — flag is now false so subsequent
    // in-page paragraph advances can center as usual.
    expect(
      usePdfStore.getState().isLookingForNextParagraph,
      'useScrolling must consume (clear) the suppression flag once it has been spent'
    ).toBe(false)
  })

  it('still centers in-page paragraph advances (suppression must self-clear after the first new-page highlight)', () => {
    // Regression guard for the fix: once the page-advance suppression
    // has been spent on the first new-page highlight, subsequent
    // paragraph advances WITHIN the same page must center normally.
    // A naive fix that just left the flag stuck `true` would silently
    // break the in-page auto-scroll-along.
    const { container } = setupContainerWithMark()

    const p0 = makeParagraph('120001', 'first paragraph of new page')
    const p1 = makeParagraph('120002', 'second paragraph of new page')
    usePdfStore.setState({
      isLookingForNextParagraph: true,
      currentViewParagraphs: [p0, p1],
      isTextGot: true,
      highlightedParagraphIndex: ''
    })

    renderUseScrolling(container)

    // First highlight: paragraph 0 of new page — must NOT center.
    act(() => {
      usePdfStore.setState({ highlightedParagraphIndex: '120001' })
    })
    act(() => {
      vi.advanceTimersByTime(150)
    })
    expect(animateMock).not.toHaveBeenCalled()

    // Second highlight: paragraph 1 of new page — must center as usual.
    act(() => {
      usePdfStore.setState({ highlightedParagraphIndex: '120002' })
    })
    act(() => {
      vi.advanceTimersByTime(150)
    })
    expect(
      animateMock,
      'after consuming the page-advance suppression, in-page highlight advances must continue to auto-center'
    ).toHaveBeenCalledTimes(1)
  })
})
