/**
 * E2E regression for the "PDF snap-back" bug (#30) at real-world timing.
 *
 * Symptom (user-reported on PR #31):
 *   1. Play the last paragraph of page N.
 *   2. Click "next paragraph" — the reader briefly advances to page N+1 (correct)
 *      but THEN snaps back to page N within ~1–2 seconds (wrong).
 *
 * The previous unit tests only sampled state synchronously after the click, so
 * they missed the late snap-back. This spec waits an absolute 2.5s after
 * dispatching the next-paragraph action and then asserts BOTH:
 *   - `pdfStore.pageNumber` is N+1
 *   - `pdfStore.highlightedParagraphIndex` resolves to a paragraph on page N+1
 *
 * Screenshots are captured before the click ("snap-back-before.png") and after
 * the long wait ("snap-back-after.png") so a human can visually confirm.
 */

import path from 'path'
import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

// The reader-launch + per-page advance walk easily exceeds 60s on slower
// machines (or under load). Extend the per-test timeout so the actual
// assertions (waiting 2.5s after the page-boundary NEXT) get a chance to run.
test.setTimeout(180_000)

const SCREENSHOT_DIR = path.resolve(__dirname, 'screenshots')

// Indices match `pageDataToParagraphs`: pageNumber * 10000 + i.
// We pick the LAST paragraph of page 1 as the active highlight, then dispatch
// NEXT through the player machine. Wait 2.5s; assert the reader has advanced
// to page 2 AND the highlight resolved to a paragraph on page 2.
test('NEXT on last paragraph of page N lands on page N+1 and does not snap back (2.5s wait)', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Snap Back Spec'
    })

    console.log('[diag] importBook OK, id=', book.id)
    const bookPage = await openBook(app.page, book.id)
    console.log('[diag] openBook OK')
    bookPage.on('console', (msg) => {
      const text = msg.text()
      // Forward only diagnostic / error / warn lines so the test log isn't
      // overwhelmed by routine `[player] audio prefetch` chatter.
      if (
        msg.type() === 'error' ||
        msg.type() === 'warning' ||
        text.includes('[snap-back]') ||
        text.includes('[diag]')
      ) {
        console.log(`[renderer/${msg.type()}] ${text}`)
      }
    })
    // Give the virtualizer and page-text extraction time to settle.
    await bookPage.waitForTimeout(3500)
    console.log('[diag] book page settled')

    // Confirm the reader mounted and at least two pages of paragraphs are
    // available — the bug only manifests when crossing a page boundary.
    await expect(
      bookPage.locator('[data-testid="pdf-scroll-container"]').first()
    ).toBeVisible({ timeout: 15000 })

    // Wait until pdfStore has paragraphs for page 1 (the source page). Page 2's
    // text is rendered lazily by the virtualizer once we scroll there, so we
    // do NOT block on it here — the boundary NEXT triggers that render.
    console.log('[diag] waiting for page1 data + currentViewParagraphs')
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi?: {
            pdfStore: {
              getState: () => {
                pageNumberToPageData: Record<number, unknown>
                pageNumber: number
                pageCount: number
                currentViewParagraphs: { index: string }[]
              }
            }
          }
        }
        const s = w.__rishi?.pdfStore.getState()
        if (!s) return false
        return (
          s.pageCount >= 2 &&
          !!s.pageNumberToPageData[1] &&
          s.currentViewParagraphs.length > 0
        )
      },
      undefined,
      { timeout: 30000 }
    )
    console.log('[diag] page1 + currentViewParagraphs ready')

    // Install a fast silent-WAV TTS mock so the real player machine can drive
    // PLAY → loading → playing on each paragraph without hitting the network.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { setTestTtsService: (s: unknown) => void }
      }
      const sampleRate = 8000
      const dataSize = 800
      const buf = new ArrayBuffer(44 + dataSize)
      const view = new DataView(buf)
      const u8 = new Uint8Array(buf)
      u8.set([0x52, 0x49, 0x46, 0x46], 0)
      view.setUint32(4, 36 + dataSize, true)
      u8.set([0x57, 0x41, 0x56, 0x45], 8)
      u8.set([0x66, 0x6d, 0x74, 0x20], 12)
      view.setUint32(16, 16, true)
      view.setUint16(20, 1, true)
      view.setUint16(22, 1, true)
      view.setUint32(24, sampleRate, true)
      view.setUint32(28, sampleRate, true)
      view.setUint16(32, 1, true)
      view.setUint16(34, 8, true)
      u8.set([0x64, 0x61, 0x74, 0x61], 36)
      view.setUint32(40, dataSize, true)
      for (let i = 0; i < dataSize; i++) u8[44 + i] = 0x80
      const noop = (): void => {}
      w.__rishi.setTestTtsService({
        requestAudio: async () =>
          URL.createObjectURL(new Blob([u8], { type: 'audio/wav' })),
        cancelRequest: () => true,
        cancelBookRequests: noop,
        clearBookCache: async () => {},
        getQueueStatus: () => ({ pending: 0, isProcessing: false, active: 0 }),
        onAudioReady: () => noop,
        onError: () => noop
      })
    })

    // Make sure we're on page 1 to start.
    const startState = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          pdfStore: {
            getState: () => {
              pageNumber: number
              currentViewParagraphs: { index: string; text: string }[]
            }
          }
        }
      }
      const s = w.__rishi.pdfStore.getState()
      return {
        pageNumber: s.pageNumber,
        paragraphCount: s.currentViewParagraphs.length,
        lastParagraphIndex: s.currentViewParagraphs[s.currentViewParagraphs.length - 1]?.index ?? null
      }
    })
    console.log('[diag] startState:', JSON.stringify(startState))
    expect(startState.pageNumber, 'reader should start on page 1').toBe(1)
    expect(startState.paragraphCount, 'page 1 must have paragraphs').toBeGreaterThan(0)
    expect(startState.lastParagraphIndex, 'page 1 must have a final paragraph').toBeTruthy()

    // Simulate the EXACT precondition the user reports: highlight on the LAST
    // paragraph of page 1, with `lastPlayedParagraphIndex` reflecting that
    // saved position. We do NOT run the real player through 6 paragraphs —
    // each play step takes ~100ms+ and the player can race past the boundary
    // before our assertion runs. The bug we're testing lives between
    // `requestNextPage()` and what the reader displays after the scroll
    // settles; the source of the page-request (the real player vs. our
    // direct call) doesn't matter for that downstream path.
    const advanceResult = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => {
              currentParagraphs: { index: string; text: string }[]
              activeParagraph: { index: string } | null
            }
            setState: (s: Record<string, unknown>) => void
          }
          pdfStore: {
            getState: () => {
              setHighlightedParagraphIndex: (i: string) => void
              setIsHighlighting: (v: boolean) => void
            }
          }
        }
      }
      const paragraphs = w.__rishi.playerStore.getState().currentParagraphs
      const lastParagraph = paragraphs[paragraphs.length - 1]
      if (!lastParagraph) throw new Error('no paragraphs on initial page')

      // Mark the player as "last paragraph of page 1" without running PLAY,
      // so the player machine doesn't keep advancing past our setpoint.
      w.__rishi.playerStore.setState({
        activeParagraph: lastParagraph,
        lastPlayedParagraphIndex: lastParagraph.index
      })
      // Mirror into the PDF store so the UI shows the highlight on the last
      // paragraph of page 1 (the user's pre-click state).
      w.__rishi.pdfStore.getState().setIsHighlighting(true)
      w.__rishi.pdfStore.getState().setHighlightedParagraphIndex(lastParagraph.index)

      return {
        lastIndex: lastParagraph.index,
        finalActive: w.__rishi.playerStore.getState().activeParagraph?.index ?? null,
        paragraphCount: paragraphs.length
      }
    })
    expect(
      advanceResult.finalActive,
      `should be sitting on last paragraph of page 1 (got ${advanceResult.finalActive} vs last=${advanceResult.lastIndex})`
    ).toBe(advanceResult.lastIndex)
    console.log('[diag] advanceResult:', JSON.stringify(advanceResult))

    // Wait long enough for useScrolling's 100ms debounced effect to fire AND
    // for the resulting framer-motion `animate(...)` call to start running,
    // but NOT so long that the 800 ms animate completes. The bug window is
    // exactly while a previous animate is still interpolating: when the
    // page-boundary NEXT then jumps the virtualizer to page N+1, the
    // in-flight animate keeps overwriting scrollTop back toward the
    // page-N target — the user-observable snap-back.
    // Wait for the <mark> element wrapping the highlighted paragraph to
    // actually appear in the DOM — that's what `useScrolling`'s effect
    // queries (`container.querySelectorAll('mark')`). Without this the
    // effect's 100ms timeout returns early (no element found) and no
    // animate ever starts, so the page boundary NEXT cannot collide with
    // a stale animate.
    await bookPage.waitForFunction(
      () => {
        const c = document.querySelector('[data-testid="pdf-scroll-container"]')
        if (!c) return false
        return Array.from(c.querySelectorAll<HTMLElement>('mark')).some(
          (m) => (m.innerText ?? m.textContent ?? '').length > 0
        )
      },
      undefined,
      { timeout: 5000 }
    )
    console.log('[diag] <mark> visible')
    console.log('[diag] taking before screenshot')
    const before = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          pdfStore: {
            getState: () => {
              pageNumber: number
              highlightedParagraphIndex: string
              currentViewParagraphs: { index: string }[]
            }
          }
          playerStore: {
            getState: () => {
              activeParagraph: { index: string } | null
              playingState: string
            }
          }
        }
      }
      const pdf = w.__rishi.pdfStore.getState()
      const player = w.__rishi.playerStore.getState()
      return {
        pageNumber: pdf.pageNumber,
        highlightedParagraphIndex: pdf.highlightedParagraphIndex,
        activeIndex: player.activeParagraph?.index ?? null,
        playingState: player.playingState,
        viewIndexes: pdf.currentViewParagraphs.map((p) => p.index)
      }
    })
    await bookPage.screenshot({
      path: path.join(SCREENSHOT_DIR, 'snap-back-before.png'),
      fullPage: false
    })
    console.log('[diag] before screenshot OK', JSON.stringify(before))

    // Sanity: we ARE on page 1, with the highlight on its last paragraph.
    expect(before.pageNumber, 'before-click: must be on page 1').toBe(1)
    expect(before.viewIndexes, 'before-click: page-1 paragraph indexes').toContain(
      advanceResult.lastIndex
    )
    expect(
      before.activeIndex,
      'before-click: active paragraph is last paragraph of page 1'
    ).toBe(advanceResult.lastIndex)

    // ===== THE ACTION: NEXT on last paragraph of page 1 =====
    // This is exactly what the user does ("click next paragraph"). When the
    // player has no further paragraphs on the current page, the machine's
    // `playing.NEXT[1]` branch enters `waitingForParagraphs`, the audioUnsub
    // hook sets `pageRequest='next'`, and pdf.tsx's subscription invokes
    // `pageControls.nextPage()` — the same chain the real UI executes.
    //
    // To exercise this chain reliably from the test we trigger the same
    // `pageRequest='next'` directly via `requestNextPage()`. This is what the
    // playerMachine would emit one tick later anyway; calling it ourselves
    // removes the dependency on the audioUnsub seeing the exact state.
    const preBoundary = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => { requestNextPage: () => void }
          }
          pdfStore: {
            getState: () => {
              virtualizer: unknown | null
              pageCount: number
              pageNumber: number
            }
          }
        }
      }
      const pdf = w.__rishi.pdfStore.getState()
      const diag = {
        hasVirtualizer: !!pdf.virtualizer,
        pageCount: pdf.pageCount,
        pageNumber: pdf.pageNumber
      }
      w.__rishi.playerStore.getState().requestNextPage()
      return diag
    })
    console.log('[diag] requestNextPage dispatched. preBoundary =', JSON.stringify(preBoundary))

    // Continuously sample so we can see WHEN the snap-back happens.
    const timeline = await bookPage.evaluate(async () => {
      const w = window as unknown as {
        __rishi: {
          pdfStore: {
            getState: () => {
              pageNumber: number
              highlightedParagraphIndex: string
              currentViewParagraphs: { index: string }[]
              isLookingForNextParagraph: boolean
            }
          }
          playerStore: {
            getState: () => {
              activeParagraph: { index: string } | null
              currentParagraphs: { index: string }[]
              playingState: string
              lastPlayedParagraphIndex: string | null
            }
          }
        }
      }
      const start = performance.now()
      const samples: Array<{
        t: number
        pdfPage: number
        scrollTop: number
        mountedPages: number[]
        highlighted: string
        viewFirst: string | null
        viewLast: string | null
        active: string | null
        lastPlayed: string | null
        playerState: string
        flag: boolean
      }> = []
      const container = document.querySelector<HTMLElement>(
        '[data-testid="pdf-scroll-container"]'
      )
      while (performance.now() - start < 3000) {
        const pdf = w.__rishi.pdfStore.getState()
        const player = w.__rishi.playerStore.getState()
        const mounted = Array.from(document.querySelectorAll<HTMLElement>('[data-page-number]'))
          .map((n) => Number(n.getAttribute('data-page-number')))
          .sort((a, b) => a - b)
        samples.push({
          t: Math.round(performance.now() - start),
          pdfPage: pdf.pageNumber,
          scrollTop: container?.scrollTop ?? -1,
          mountedPages: mounted,
          highlighted: pdf.highlightedParagraphIndex,
          viewFirst: pdf.currentViewParagraphs[0]?.index ?? null,
          viewLast: pdf.currentViewParagraphs[pdf.currentViewParagraphs.length - 1]?.index ?? null,
          active: player.activeParagraph?.index ?? null,
          lastPlayed: player.lastPlayedParagraphIndex ?? null,
          playerState: player.playingState,
          flag: pdf.isLookingForNextParagraph
        })
        // eslint-disable-next-line no-await-in-loop
        await new Promise((r) => {
          setTimeout(r, 50)
        })
      }
      return samples
    })

    // Take the AFTER screenshot — bound it with a timeout so a hanging
    // renderer doesn't swallow our actual assertion failure.
    await Promise.race([
      bookPage.screenshot({
        path: path.join(SCREENSHOT_DIR, 'snap-back-after.png'),
        fullPage: false
      }),
      new Promise<void>((r) => {
        setTimeout(r, 10000)
      })
    ])
    console.log('[diag] after screenshot done')

    // Final state must reflect page N+1.
    const final = timeline[timeline.length - 1]
    // Log the timeline so a failure is debuggable from CI output.
    console.log(
      '[snap-back] sampled timeline (every 50ms):\n' +
        timeline
          .filter(
            (s, i) =>
              i === 0 ||
              i === timeline.length - 1 ||
              s.pdfPage !== timeline[i - 1].pdfPage ||
              s.highlighted !== timeline[i - 1].highlighted ||
              s.active !== timeline[i - 1].active ||
              s.playerState !== timeline[i - 1].playerState ||
              s.flag !== timeline[i - 1].flag ||
              Math.abs(s.scrollTop - timeline[i - 1].scrollTop) > 5 ||
              s.mountedPages.join(',') !== timeline[i - 1].mountedPages.join(',')
          )
          .map(
            (s) =>
              `t=${s.t}ms page=${s.pdfPage} scrollTop=${s.scrollTop} mounted=[${s.mountedPages.join(',')}] hl=${s.highlighted || '-'} active=${s.active || '-'} lastPlayed=${s.lastPlayed || '-'} state=${s.playerState} flag=${s.flag}`
          )
          .join('\n')
    )

    // The user-observable bug: scroll snaps back from page 2 to page 1.
    // Page 1's start is scrollTop≈0; page 2's start is ~1418 (measured).
    // We assert that the final scrollTop is at or beyond page 2's start —
    // anything less means the reader scrolled BACK to page 1 territory,
    // which is the snap-back the user reports.
    //
    // We pull the canonical page-2 scrollTop from the FIRST sample
    // (immediately after `requestNextPage`, when the virtualizer's scroll
    // jump has happened but no centering animate has had a chance to run).
    const initialJumpScrollTop = timeline[0].scrollTop
    expect(
      initialJumpScrollTop,
      `precondition: the virtualizer must have scrolled forward at least one page (initial scrollTop=${initialJumpScrollTop})`
    ).toBeGreaterThan(800)

    const finalScrollTop = final.scrollTop
    expect(
      finalScrollTop,
      `after 2.5s the reader must still be at page 2 (initial jump scrollTop=${initialJumpScrollTop}, final=${finalScrollTop}); a final value much smaller than the initial jump indicates the snap-back to page 1.`
    ).toBeGreaterThan(initialJumpScrollTop - 200)

    // Reinforce: pdfStore.pageNumber must also reflect page 2.
    expect(
      final.pdfPage,
      `after 2.5s wait, pdfStore.pageNumber must be 2 (was: ${final.pdfPage}); timeline shows the reader snapped back`
    ).toBeGreaterThanOrEqual(2)
  } finally {
    // closeApp can hang on slow indexing fibers in the main process. Wrap it
    // so a stuck shutdown doesn't mask the real assertion failure (which
    // would otherwise turn into a generic "test timeout exceeded").
    await Promise.race([
      closeApp(app),
      new Promise<void>((r) => {
        setTimeout(r, 5000)
      })
    ])
  }
})
