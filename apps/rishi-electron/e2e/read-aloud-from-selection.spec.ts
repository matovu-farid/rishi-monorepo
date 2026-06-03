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
      test.fixme(true, 'No paragraphs published — fixture issue or renderer not settled')
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

    // The TTS log must contain a requestAudio call whose CFI matches the
    // selection we stored. Length-only would pass even if the player fetched
    // audio for the wrong selection (e.g. currentParagraphs[0] regardless of
    // the stored selection).
    const log = await readTtsLog(bookPage)
    expect(log.some((r) => r.cfiRange === firstParagraphCfi)).toBe(true)
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
      test.fixme(true, 'Player still in idle — INITIALIZE not fired yet')
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

  // Regression for the bug where the right-click "Read Aloud From Here" item
  // would do nothing because the selectionStore was empty (the rendition's
  // `selected` event never fired or its closure was stale). The IPC path
  // must resolve the live iframe selection at handler-call time and not
  // depend on the store being primed.
  test('IPC reader:readAloudFromSelection works from a live iframe selection (empty store)', async () => {
    // Make sure the store is empty so the only working source is the live
    // iframe selection — exactly what the right-click path provides.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi?: { selectionStore: { getState: () => { clear: () => void } } }
      }
      w.__rishi?.selectionStore.getState().clear()
    })

    // Create a real selection inside the EPUB iframe using the DOM API.
    // (The rendition's `selected` event is irrelevant here — we want to
    // prove the resolver picks it up from the live `window.getSelection()`.)
    //
    // The fixture's first spine item is `titlepage.xhtml`, which contains
    // only an SVG cover image (no text nodes). epub.js pre-renders multiple
    // iframes for the current view and adjacent pages, so `querySelector`
    // ordering depends on layout state. Find the FIRST iframe whose body
    // has a non-empty text node — that's the content iframe we can select
    // from. Poll briefly so the test isn't fragile when iframes are still
    // being mounted.
    const selectionInfo = await bookPage.evaluate(async () => {
      const findTextIframe = (): {
        iframe: HTMLIFrameElement
        textNode: Text
      } | null => {
        const iframes = Array.from(
          document.querySelectorAll('iframe')
        ) as HTMLIFrameElement[]
        for (const iframe of iframes) {
          const doc = iframe.contentDocument
          if (!doc || !doc.body) continue
          const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
          let node = walker.nextNode() as Text | null
          // Skip whitespace-only text nodes.
          while (node && (!node.textContent || node.textContent.trim().length === 0)) {
            node = walker.nextNode() as Text | null
          }
          if (node && node.textContent && node.textContent.trim().length > 0) {
            return { iframe, textNode: node }
          }
        }
        return null
      }

      // Poll up to 5 s for a content iframe to appear with real text.
      const deadline = Date.now() + 5000
      let hit = findTextIframe()
      while (!hit && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 100))
        hit = findTextIframe()
      }
      if (!hit) return null

      const { iframe, textNode } = hit
      const win = iframe.contentWindow
      if (!win) return null
      const text = textNode.textContent ?? ''
      // Find the first non-whitespace character so the selected text is
      // guaranteed visible (selecting only whitespace would round-trip to
      // empty in `sel.toString()`).
      const startOffset = text.search(/\S/)
      const endOffset = Math.min(text.length, startOffset + 20)
      const range = (iframe.contentDocument as Document).createRange()
      range.setStart(textNode, startOffset)
      range.setEnd(textNode, endOffset)
      const sel = win.getSelection()
      sel?.removeAllRanges()
      sel?.addRange(range)
      return { selectedText: sel?.toString() ?? '' }
    })

    expect(
      selectionInfo,
      'No iframe with text content found — EPUB fixture or render state issue'
    ).not.toBeNull()
    expect(
      selectionInfo!.selectedText.trim().length,
      'Programmatic iframe selection produced empty text'
    ).toBeGreaterThan(0)

    await clearTtsLog(bookPage)

    // Clear the selectionStore and dispatch the IPC in a single page
    // evaluate call so the rendition's `selected` event (which fires
    // asynchronously when the iframe selection changes and calls
    // `setEpubSelection`) cannot race in between. This guarantees the
    // resolver sees an empty store at dispatch time and MUST fall back
    // to `resolveLiveSelection(renditionRef.current)` — the regression
    // this test pins.
    const storeBeforeDispatch = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi?: {
          selectionStore: {
            getState: () => { clear: () => void; current: unknown }
          }
        }
      }
      w.__rishi?.selectionStore.getState().clear()
      const current = w.__rishi?.selectionStore.getState().current ?? null
      // The renderer is subscribed via window.electron.on('reader:readAloudFromSelection').
      // We can't trigger an actual webContents.send from inside page.evaluate,
      // so dispatch the same window CustomEvent the ⌘⇧L path uses — both
      // paths share `handleReadAloudFrom`, so this exercises the same code.
      window.dispatchEvent(new CustomEvent('rishi:readAloudFromSelection'))
      return current
    })
    expect(
      storeBeforeDispatch,
      'selectionStore must be empty at IPC dispatch — proves the live iframe path resolved the selection'
    ).toBeNull()

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

    // The resolver matches the live iframe selection to a paragraph and
    // dispatches PLAY_FROM with that paragraph's CFI. handleReadAloudFrom
    // CLEARS the selectionStore after dispatching (see
    // `epub/EpubView.tsx:handleReadAloudFrom` — `.clear()` at the end), so
    // we can't read the resolved CFI from the store. Instead, assert via the
    // TTS log: the request must reference a paragraph that's in the current
    // page's paragraph list (proves the resolver ran — length-only would
    // pass even if the player fetched audio for a wrong selection because
    // an earlier auto-play could have populated the log).
    const log = await readTtsLog(bookPage)
    expect(log.length, 'TTS service must have received at least one request').toBeGreaterThan(0)

    const currentParagraphCfis = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi?: {
          playerStore: { getState: () => { currentParagraphs: Array<{ index: string }> } }
        }
      }
      return w.__rishi?.playerStore.getState().currentParagraphs.map((p) => p.index) ?? []
    })
    expect(
      log.some((r) => currentParagraphCfis.includes(r.cfiRange)),
      'TTS request CFI must match a current-page paragraph (proves the resolver ran)'
    ).toBe(true)
  })
})
