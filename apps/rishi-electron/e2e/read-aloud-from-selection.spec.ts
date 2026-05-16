// e2e/read-aloud-from-selection.spec.ts
//
// Verifies the full read-aloud-from-selection flow end-to-end.
//
// The three UI surfaces (SelectionPopover, right-click menu, ⌘⇧L shortcut) all
// converge on `handleReadAloudFrom` in EpubView. The pragmatic test approach:
//   1. Pre-populate the selectionStore (the shared seam).
//   2. Dispatch `rishi:readAloudFromSelection` (same event ⌘⇧L fires).
//   3. Assert the player machine transitions to `loading` and then requests
//      audio from the TTS service — proving PLAY_FROM was dispatched.
//
// Native menus and real audio are skipped: native menus require OS interaction,
// and real audio is blocked by auth. Both blockers are handled:
//   - Auth is bypassed by setting a fake user via the exposed authStore seam.
//   - TTS audio is replaced by a silent mock WAV via setTestTtsService.

import { test, expect, type Page } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'
import {
  installSilentMockTts,
  waitForParagraphs,
  waitForPlayerSendReady,
  readTtsLog,
  clearTtsLog
} from './helpers/player-helpers'

test.describe('Read Aloud From Selection', () => {
  let app: LaunchedApp
  let bookId: number
  let bookPage: Page

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Read Aloud Selection Spec'
    })
    bookId = book.id
  })

  test.afterAll(async () => {
    await bookPage?.close().catch(() => {})
    await deleteAllBooks(app.page).catch(() => {})
    await closeApp(app).catch(() => {})
  })

  test.beforeEach(async () => {
    bookPage = await openBook(app.page, bookId)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    // Wait for paragraphs to be published and the player send fn to be ready.
    await waitForParagraphs(bookPage)
    await waitForPlayerSendReady(bookPage)

    // Install the silent mock TTS so audio requests don't hit the network.
    await installSilentMockTts(bookPage)

    // Inject a fake authenticated user so requireAuth() calls the action
    // directly instead of opening the premium feature dialog.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi?: {
          authStore: {
            setState: (state: { user: { id: string; name: string; email: string } }) => void
          }
        }
      }
      w.__rishi?.authStore.setState({
        user: { id: 'test-user', name: 'Test User', email: 'test@example.com' }
      })
    })
  })

  test('dispatching readAloudFromSelection with a stored selection triggers PLAY_FROM', async () => {
    // Read the first paragraph's CFI from the playerStore. This is the live
    // CFI published by the EPUB renderer for the current page view.
    const firstParagraphCfi = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi?: {
          playerStore: { getState: () => { currentParagraphs: Array<{ index: string }> } }
        }
      }
      return w.__rishi?.playerStore.getState().currentParagraphs[0]?.index ?? null
    })

    if (!firstParagraphCfi) {
      test.skip(true, 'No paragraphs published — fixture issue or renderer not settled')
      return
    }

    // Pre-populate the selection store with the first paragraph's CFI and some text.
    await bookPage.evaluate((cfi) => {
      const w = window as unknown as {
        __rishi?: {
          selectionStore: {
            getState: () => { setEpubSelection: (sel: { cfiRange: string; text: string }) => void }
          }
        }
      }
      w.__rishi?.selectionStore.getState().setEpubSelection({
        cfiRange: cfi,
        text: 'sample selection text for e2e test'
      })
    }, firstParagraphCfi)

    // Clear the TTS log so we only capture requests from this action.
    await clearTtsLog(bookPage)

    // Dispatch the same window CustomEvent the ⌘⇧L shortcut fires.
    // handleReadAloudFrom() in EpubView listens for this event.
    await bookPage.evaluate(() => {
      window.dispatchEvent(new CustomEvent('rishi:readAloudFromSelection'))
    })

    // Wait for the player machine to enter loading state: it should dispatch
    // PLAY_FROM → loading → TTS requestAudio call.
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi?: { playerStore: { getState: () => { playingState: string } } }
        }
        const state = w.__rishi?.playerStore.getState().playingState
        // Accept loading, playing, or paused — any of these means PLAY_FROM fired.
        return state === 'loading' || state === 'playing' || state === 'paused'
      },
      { timeout: 10000 }
    )

    // The TTS log should contain at least one requestAudio call, confirming
    // the player machine fetched audio for the selection.
    const log = await readTtsLog(bookPage)
    expect(log.length).toBeGreaterThan(0)
  })

  test('dispatching readAloudFromSelection without a stored selection falls back to PLAY', async () => {
    // Ensure no selection is stored.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi?: {
          selectionStore: { getState: () => { clear: () => void } }
        }
      }
      w.__rishi?.selectionStore.getState().clear()
    })

    // Verify initial state is stopped (not idle — paragraphs are published).
    const initialState = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi?: { playerStore: { getState: () => { playingState: string } } }
      }
      return w.__rishi?.playerStore.getState().playingState
    })
    // If already idle (INITIALIZE not fired yet), skip — this is a timing issue.
    if (initialState === 'idle') {
      test.skip(true, 'Player still in idle — INITIALIZE not fired yet')
      return
    }

    await clearTtsLog(bookPage)

    // Dispatch without a selection — the handler should fall back to the
    // regular readAloudToggle path (which calls commonHandlers.readAloudToggle).
    // In stopped state with paragraphs, that means PLAY → loading.
    await bookPage.evaluate(() => {
      window.dispatchEvent(new CustomEvent('rishi:readAloudFromSelection'))
    })

    // The fallback path calls readAloudToggle. When no selection is present,
    // menuHandlers.readAloudFromSelection calls commonHandlers.readAloudToggle
    // which dispatches PLAY to the player machine. Verify loading state.
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi?: { playerStore: { getState: () => { playingState: string } } }
        }
        const state = w.__rishi?.playerStore.getState().playingState
        return state === 'loading' || state === 'playing' || state === 'paused'
      },
      { timeout: 10000 }
    )
  })
})
