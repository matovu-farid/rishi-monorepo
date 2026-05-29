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
    ({
      top: 0,
      left: 0,
      right: 0,
      bottom: 800,
      width: 0,
      height: 800,
      x: 0,
      y: 0,
      toJSON: () => ({})
    }) as DOMRect

  const mark = document.createElement('mark')
  mark.textContent = 'first paragraph of newly-landed page N+1'
  // Mark is at viewport top — same geometry as just after
  // `virtualizer.scrollToIndex(N, { align: 'start' })`.
  mark.getBoundingClientRect = (): DOMRect =>
    ({
      top: 0,
      left: 0,
      right: 0,
      bottom: 24,
      width: 0,
      height: 24,
      x: 0,
      y: 0,
      toJSON: () => ({})
    }) as DOMRect
  // happy-dom's `innerText` falls back to `textContent`, which is what
  // useScrolling's `.find((m) => m.innerText)` actually reads.
  container.appendChild(mark)
  document.body.appendChild(container)
  createdContainers.push(container)
  return { container, mark }
}

/**
 * Build a stand-in for the PDF page wrapper (`[data-page-number="N"]`)
 * around a mark, with a stubbed `getBoundingClientRect()` so the centering
 * clamp in useScrolling can compute `pageTopInDoc` deterministically. The
 * wrapper is inserted as the mark's immediate parent inside `container`.
 */
function wrapMarkInPage(
  container: HTMLDivElement,
  mark: HTMLElement,
  pageNumber: number,
  pageTopInViewport: number
): HTMLDivElement {
  const pageEl = document.createElement('div')
  pageEl.setAttribute('data-page-number', String(pageNumber))
  pageEl.getBoundingClientRect = (): DOMRect =>
    ({
      top: pageTopInViewport,
      left: 0,
      right: 0,
      bottom: pageTopInViewport + 1000,
      width: 0,
      height: 1000,
      x: 0,
      y: pageTopInViewport,
      toJSON: () => ({})
    }) as DOMRect
  // Re-parent the mark under the new wrapper so `mark.closest(...)` resolves.
  container.removeChild(mark)
  pageEl.appendChild(mark)
  container.appendChild(pageEl)
  return pageEl
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
    expect(
      publishedParagraphs.length,
      'publishParagraphsForPage produced at least one paragraph'
    ).toBeGreaterThan(0)

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
    const { container, mark } = setupContainerWithMark()
    // Wrap the mark in a [data-page-number] ancestor positioned so its
    // top sits 100 px ABOVE the container's top — i.e. pageTopInDoc =
    // scrollTop(1000) - 100 = 900. This mimics in-page reading geometry
    // (the user has scrolled partway down the page), where the centering
    // clamp must NOT engage. Without the wrapper the clamp's defensive
    // `if (pageEl)` branch silently skips and we wouldn't exercise the
    // real production geometry.
    wrapMarkInPage(container, mark, 12, -100)
    // Move paragraph 1's mark into the lower half of the viewport so
    // the centered target (1000 + 500 - 400 + 12 = 1112) moves FORWARD
    // past `currentScrollTop` and stays well above `pageTopInDoc` (900).
    // Original fixture had the mark at top:0 — that geometry is now
    // owned by the new clamp test below.
    mark.getBoundingClientRect = (): DOMRect =>
      ({
        top: 500,
        left: 0,
        right: 0,
        bottom: 524,
        width: 0,
        height: 24,
        x: 0,
        y: 500,
        toJSON: () => ({})
      }) as DOMRect

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

  it('does NOT animate when centering would scroll backward past the new page top (clamp guard for paragraph 1+ on freshly-snapped page)', () => {
    // Reproduce the second symptom of the auto-advance race: after
    // pageControls.nextPage() lands page N+1 flush with the viewport top
    // via `virtualizer.scrollToIndex(N+1, { align: 'start' })`, the
    // `isLookingForNextParagraph` flag suppresses centering for
    // paragraph 0 — but paragraph 1's centering math (mark.top in the
    // top half of the viewport) produces a `targetScrollTop` BELOW the
    // page's top in document coordinates. Without the clamp, the 0.8 s
    // tween scrolls backward past the new page's top and visually drags
    // the previous page's bottom back into view. We isolate the clamp
    // here by leaving `isLookingForNextParagraph` false — so the only
    // thing that can suppress the animate is the new clamp+no-op guard.
    const { container, mark } = setupContainerWithMark()
    // Paragraph 1 sits 150 px below the page top — top half of the 800
    // px viewport, so the centered target would be 1000 + 150 - 400 + 12
    // = 762, which is 238 px ABOVE the page top (1000) → backward scroll
    // past the page top → clamp engages → no-op early-return.
    mark.getBoundingClientRect = (): DOMRect =>
      ({
        top: 150,
        left: 0,
        right: 0,
        bottom: 174,
        width: 0,
        height: 24,
        x: 0,
        y: 150,
        toJSON: () => ({})
      }) as DOMRect
    // Page top aligns flush with viewport top → pageTopInDoc =
    // 0 - 0 + currentScrollTop(1000) = 1000.
    wrapMarkInPage(container, mark, 2, 0)

    const p = makeParagraph('020001', 'paragraph 1 of freshly-snapped page 2')
    usePdfStore.setState({
      // Crucial: the existing isLookingForNextParagraph flag is FALSE.
      // The previous test covers that suppression path; this test isolates
      // the new clamp+no-op guard.
      isLookingForNextParagraph: false,
      currentViewParagraphs: [p],
      isTextGot: true,
      highlightedParagraphIndex: ''
    })

    renderUseScrolling(container)

    act(() => {
      usePdfStore.setState({ highlightedParagraphIndex: '020001' })
    })
    act(() => {
      vi.advanceTimersByTime(150)
    })

    expect(
      animateMock,
      'useScrolling must NOT center a paragraph whose centered target would scroll the page backward past its own top — that produces the jarring downward shift right after a page snap (paragraph 1+ regression on freshly-landed pages). The clamp pins targetScrollTop to pageTopInDoc, and the equality check skips the no-op tween so isAutoCentering does not stay held for the trailing-clear window.'
    ).not.toHaveBeenCalled()
  })

  it('still animates when the paragraph sits in the lower half of a freshly-snapped page (clamp must be conditional, not blanket)', () => {
    // Conditional-guard regression: the clamp must NOT fire for marks
    // whose centered target is forward of pageTopInDoc. Here paragraph
    // sits 500 px below the page top; centered target = 1000 + 500 - 400
    // + 12 = 1112, which is 112 px BELOW pageTopInDoc(1000) → no clamp,
    // forward scroll, animate fires once.
    const { container, mark } = setupContainerWithMark()
    mark.getBoundingClientRect = (): DOMRect =>
      ({
        top: 500,
        left: 0,
        right: 0,
        bottom: 524,
        width: 0,
        height: 24,
        x: 0,
        y: 500,
        toJSON: () => ({})
      }) as DOMRect
    wrapMarkInPage(container, mark, 2, 0)

    const p = makeParagraph('020005', 'paragraph 5 of freshly-snapped page 2 (lower half)')
    usePdfStore.setState({
      isLookingForNextParagraph: false,
      currentViewParagraphs: [p],
      isTextGot: true,
      highlightedParagraphIndex: ''
    })

    renderUseScrolling(container)

    act(() => {
      usePdfStore.setState({ highlightedParagraphIndex: '020005' })
    })
    act(() => {
      vi.advanceTimersByTime(150)
    })

    expect(
      animateMock,
      'lower-half paragraphs whose centered target is below pageTopInDoc must still auto-center — the clamp is a directional guard, not a blanket suppression'
    ).toHaveBeenCalledTimes(1)
  })
})
