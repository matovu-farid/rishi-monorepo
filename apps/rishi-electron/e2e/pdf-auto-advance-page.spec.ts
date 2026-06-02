/**
 * Regression: PDF auto-advance past the last paragraph of a page must keep
 * playing on the next page.
 *
 * User-reported bug (2026-05-31):
 *   "At the end of the last paragraph of a page, the reader correctly scrolls
 *    to the new page but the reading just halts."
 *
 * This is the PDF-equivalent of the EPUB regression test at
 * e2e/tts-page-navigation.spec.ts:1421. The EPUB path is structurally
 * identical (playing → AUDIO_ENDED → waitingForParagraphs → view actor
 * NAVIGATE_NEXT → VIEW_CHANGED → PARAGRAPHS_UPDATED → loading → playing) but
 * PDF goes through `pdfViewActor`, the `pdfStore`, the virtualizer scroll
 * path, and `usePdfReader`'s inner reader machine — none of which the EPUB
 * test exercises.
 *
 * The failure mode this test prevents: `pageControls.nextPage()` scrolls the
 * virtualizer to the next page with `align: 'start'`, landing scrollTop
 * exactly at the previous page's bottom (== the new page's top). The 120 px
 * boundary hysteresis in `visiblePositionFromVirtualizer` then keeps
 * reporting the OLD page, so PAGE_CHANGED never fires, `pdfStore.pageNumber`
 * stays put, `pdfViewActor` never sees a page change, and the player times
 * out in `waitingForParagraphs` → `stopped`.
 */

import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'
import {
  installSilentMockTts,
  sendPlayerEvent,
  waitForPlayerSendReady,
  waitForPlayerState
} from './helpers/player-helpers'

test.setTimeout(120_000)

test('PDF: AUDIO_ENDED on last paragraph of a page keeps playing on next page', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'PDF Auto-Advance Boundary'
    })

    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[data-testid="pdf-scroll-container"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForPlayerSendReady(bookPage)

    // Wait for page-1's paragraphs to be extracted and published. We poll
    // pdfStore directly because the EPUB-flavoured waitForParagraphs helper
    // reads epubStore.currentEpubLocation, which is empty for PDFs.
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
        return s.pageCount >= 2 && !!s.pageNumberToPageData[1] && s.currentViewParagraphs.length > 0
      },
      undefined,
      { timeout: 30000 }
    )

    // Silent 100 ms WAV: audio element reaches `ended` quickly per paragraph
    // so we exercise the real AUDIO_ENDED → waitingForParagraphs path.
    await installSilentMockTts(bookPage)

    // Identify the last paragraph of page 1 so we can PLAY_FROM there. This
    // keeps the test under ~5 s even if page 1 has many paragraphs.
    const start = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => { currentParagraphs: { text: string; index: string }[] }
          }
          pdfStore: { getState: () => { pageNumber: number } }
        }
      }
      const paragraphs = w.__rishi.playerStore.getState().currentParagraphs
      if (paragraphs.length === 0) throw new Error('no paragraphs published for page 1')
      return {
        startPageNumber: w.__rishi.pdfStore.getState().pageNumber,
        lastIndex: paragraphs.length - 1,
        lastParagraphId: paragraphs[paragraphs.length - 1].index,
        lastParagraphText: paragraphs[paragraphs.length - 1].text
      }
    })
    expect(start.startPageNumber, 'reader should open on page 1').toBe(1)

    // PLAY_FROM the last paragraph of page 1. Pass the FULL paragraph text
    // as the partial-first override so the TTS fetch returns a real WAV
    // (instead of the skip path triggered by empty text). The player will
    // play that 100 ms WAV, fire AUDIO_ENDED, and route to waitingForParagraphs.
    await bookPage.evaluate(
      ({ paragraphIndex, partialFirstKey, partialFirstText }) => {
        const w = window as unknown as {
          __rishi: {
            playerStore: {
              getState: () => {
                send:
                  | ((e: {
                      type: 'PLAY_FROM'
                      paragraphIndex: number
                      partialFirstText: string
                      partialFirstKey: string
                    }) => void)
                  | null
              }
            }
          }
        }
        const send = w.__rishi.playerStore.getState().send
        if (!send) throw new Error('playerStore.send is null')
        send({
          type: 'PLAY_FROM',
          paragraphIndex,
          partialFirstText,
          partialFirstKey
        })
      },
      {
        paragraphIndex: start.lastIndex,
        partialFirstKey: start.lastParagraphId,
        partialFirstText: start.lastParagraphText
      }
    )

    // Player should reach `playing` on the last paragraph of page 1.
    await waitForPlayerState(bookPage, 'playing', 10000)

    // Wait for pdfStore.pageNumber to actually change. AUDIO_ENDED fires when
    // the 100 ms WAV finishes; the player routes to waitingForParagraphs and
    // sends NAVIGATE_NEXT to pdfViewActor, which calls pageControls.nextPage()
    // and waits for the new page's paragraphs.
    await bookPage.waitForFunction(
      (startPage) => {
        const w = window as unknown as {
          __rishi: { pdfStore: { getState: () => { pageNumber: number } } }
        }
        return w.__rishi.pdfStore.getState().pageNumber > startPage
      },
      start.startPageNumber,
      { timeout: 25000 }
    )

    // ===== THE ASSERTION the bug violates =====
    //
    // After the page changed, the player MUST continue playing. If it landed
    // in `stopped` the user sees the scroll happen and audio die — the exact
    // regression they reported.
    const stateAfterNav = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { playerStore: { getState: () => { playingState: string } } }
      }
      return w.__rishi.playerStore.getState().playingState
    })
    expect(
      stateAfterNav,
      `After AUDIO_ENDED on last paragraph of page 1 and page change to page 2+, ` +
        `the player must continue playing — got '${stateAfterNav}'. If 'stopped', ` +
        `the wantsAutoResume → PARAGRAPHS_UPDATED → loading chain broke somewhere ` +
        `in the PDF view-actor / pdf paragraph republish path.`
    ).not.toBe('stopped')

    // Stronger gate: the player must actually reach `playing` again on the
    // new page within a reasonable window — proves auto-resume completed,
    // not just that the machine briefly transitioned to `loading` before
    // halting.
    await waitForPlayerState(bookPage, 'playing', 15000)

    // Strongest gate: the active paragraph must belong to page >= 2 (i.e.
    // index encoding `pageNumber * 10000 + idx` resolves to page >= 2).
    const activeIndex = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => { activeParagraph: { index: string } | null }
          }
        }
      }
      return w.__rishi.playerStore.getState().activeParagraph?.index ?? null
    })
    expect(activeIndex, 'activeParagraph must be set after auto-advance').not.toBeNull()
    const activePage = activeIndex ? Math.floor(Number(activeIndex) / 10000) : null
    expect(
      activePage,
      `after auto-advance the active paragraph must live on the new page (page >= 2); ` +
        `got activeIndex='${activeIndex}' resolving to page ${activePage}. If page 1, ` +
        `the player is re-reading the old view instead of continuing forward.`
    ).toBeGreaterThanOrEqual(2)

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
  } finally {
    await Promise.race([
      closeApp(app),
      new Promise<void>((r) => {
        setTimeout(r, 5000)
      })
    ])
  }
})
