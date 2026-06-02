import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  closeOverlays,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'
import {
  readPlayerSnapshot,
  waitForParagraphs,
  waitForLocationChange,
  installSilentMockTts as installMockTts,
  clearTtsLog,
  readTtsLog,
  sendPlayerEvent,
  waitForPlayerState
} from './helpers/player-helpers'

// Each test imports a fresh book and opens its own window so they don't
// share rendition state. (The fixture only has a few pages, and once a
// previous test has advanced past them the Next-page button stops moving.)
test.describe('TTS state follows EPUB page navigation', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test('clicking Next page refreshes player paragraphs to the new page', async () => {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Nav Spec A'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    const before = await readPlayerSnapshot(bookPage)
    expect(before.paragraphs.length).toBeGreaterThan(0)

    await bookPage.locator('[aria-label="Next page"]').first().click()
    const after = await waitForLocationChange(bookPage, before.location)

    expect(after.location).not.toBe(before.location)
    expect(after.paragraphs[0]?.index).not.toBe(before.paragraphs[0]?.index)
  })

  test('entering loading state pauses the audio element BEFORE the TTS fetch resolves', async () => {
    // This guards the audio-bleed fix: when the player machine enters
    // 'loading' (e.g., on a page flip during playback), it must call
    // audioElement.pause() immediately — not after the TTS fetch resolves —
    // otherwise the previous page's audio keeps playing in the gap.
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Nav Spec C'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    // Install a mock TTS service with a deliberate 800 ms delay. We can
    // detect whether audio pause happens immediately (the fix) or only
    // after 800 ms (no fix).
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          setTestTtsService: (s: unknown) => void
          audioElement: HTMLAudioElement
        }
        __rishiPauseLog?: number[]
      }
      w.__rishiPauseLog = []
      const originalPause = w.__rishi.audioElement.pause.bind(w.__rishi.audioElement)
      w.__rishi.audioElement.pause = function () {
        w.__rishiPauseLog!.push(performance.now())
        return originalPause()
      }
      const wav = new Uint8Array([
        0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74,
        0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x44, 0xac, 0x00, 0x00, 0x88, 0x58,
        0x01, 0x00, 0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61, 0x00, 0x00, 0x00, 0x00
      ])
      const noop = (): void => {}
      w.__rishi.setTestTtsService({
        requestAudio: async () =>
          new Promise<string>((resolve) => {
            setTimeout(
              () => resolve(URL.createObjectURL(new Blob([wav], { type: 'audio/wav' }))),
              800
            )
          }),
        cancelRequest: () => true,
        cancelBookRequests: noop,
        clearBookCache: async () => {},
        getQueueStatus: () => ({ pending: 0, isProcessing: false, active: 0 }),
        onAudioReady: () => noop,
        onError: () => noop
      })
    })

    const startMs = await bookPage.evaluate(() => performance.now())
    await sendPlayerEvent(bookPage, 'PLAY')

    // Wait briefly — long enough for the state-machine subscriber to
    // process state=loading, but well short of the 800 ms TTS delay.
    await bookPage.waitForTimeout(150)

    const pauseLog = await bookPage.evaluate(
      () => (window as unknown as { __rishiPauseLog: number[] }).__rishiPauseLog
    )
    expect(pauseLog.length).toBeGreaterThan(0)
    const firstPauseDelay = pauseLog[0] - startMs
    expect(
      firstPauseDelay,
      `audioElement.pause() must fire shortly after PLAY (not wait for TTS fetch). Got ${firstPauseDelay}ms.`
    ).toBeLessThan(300)

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  test('INVARIANT: highlight (activeParagraph) is always on the visible page during playback', async () => {
    // The user's diagnostic: while the reader is playing, the highlighted text
    // MUST be on the currently visible page. If activeParagraph is non-null
    // but its CFI is not in currentParagraphs (which is the visible spread),
    // the reader is reading the wrong page — that's the bug.
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Invariant Spec'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    // Install a mock TTS that returns a valid playable WAV (100 ms of silence)
    // so audio can actually reach `playing` state and activeParagraph gets set.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { setTestTtsService: (s: unknown) => void }
        __rishiInvariantLog?: Array<{
          ts: number
          activeIndex: string | null
          currentIndexes: string[]
          state: string
        }>
      }
      w.__rishiInvariantLog = []
      // Build a 100ms silent WAV (44-byte header + 800 bytes of 0x80 silence)
      const sampleRate = 8000
      const dataSize = 800
      const buf = new ArrayBuffer(44 + dataSize)
      const view = new DataView(buf)
      const u8 = new Uint8Array(buf)
      u8.set([0x52, 0x49, 0x46, 0x46], 0) // "RIFF"
      view.setUint32(4, 36 + dataSize, true)
      u8.set([0x57, 0x41, 0x56, 0x45], 8) // "WAVE"
      u8.set([0x66, 0x6d, 0x74, 0x20], 12) // "fmt "
      view.setUint32(16, 16, true)
      view.setUint16(20, 1, true)
      view.setUint16(22, 1, true)
      view.setUint32(24, sampleRate, true)
      view.setUint32(28, sampleRate, true)
      view.setUint16(32, 1, true)
      view.setUint16(34, 8, true)
      u8.set([0x64, 0x61, 0x74, 0x61], 36) // "data"
      view.setUint32(40, dataSize, true)
      for (let i = 0; i < dataSize; i++) u8[44 + i] = 0x80
      const wav = u8
      const noop = (): void => {}
      w.__rishi.setTestTtsService({
        requestAudio: async () => URL.createObjectURL(new Blob([wav], { type: 'audio/wav' })),
        cancelRequest: () => true,
        cancelBookRequests: noop,
        clearBookCache: async () => {},
        getQueueStatus: () => ({ pending: 0, isProcessing: false, active: 0 }),
        onAudioReady: () => noop,
        onError: () => noop
      })
    })

    // Continuously sample (activeParagraph, currentParagraphs, playingState)
    // and record every snapshot. This catches both transient and permanent
    // invariant violations.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => {
              activeParagraph: { index: string } | null
              currentParagraphs: { index: string }[]
              playingState: string
            }
            subscribe: (l: () => void) => () => void
          }
          __rishiInvariantStopFn?: () => void
        }
        __rishiInvariantLog: Array<{
          ts: number
          activeIndex: string | null
          currentIndexes: string[]
          state: string
        }>
      }
      const sample = (): void => {
        const s = w.__rishi.playerStore.getState()
        w.__rishiInvariantLog.push({
          ts: performance.now(),
          activeIndex: s.activeParagraph?.index ?? null,
          currentIndexes: s.currentParagraphs.map((p) => p.index),
          state: s.playingState
        })
      }
      // Sample on every store change AND on a 50ms tick to catch transients.
      const unsub = w.__rishi.playerStore.subscribe(sample)
      const tick = setInterval(sample, 50)
      w.__rishi.__rishiInvariantStopFn = () => {
        unsub()
        clearInterval(tick)
      }
      sample()
    })

    // PLAY and wait for state=playing (audio actually started).
    await sendPlayerEvent(bookPage, 'PLAY')
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: {
            playerStore: {
              getState: () => {
                playingState: string
                activeParagraph: { index: string } | null
              }
            }
          }
        }
        const s = w.__rishi.playerStore.getState()
        return s.playingState === 'playing' && s.activeParagraph !== null
      },
      undefined,
      { timeout: 8000 }
    )

    // Click Next page. The bug (if present) manifests during/after this.
    await bookPage.locator('[aria-label="Next page"]').first().click()

    // Wait for the EPUB location to change and audio to settle again.
    const startSnap = await readPlayerSnapshot(bookPage)
    await waitForLocationChange(bookPage, startSnap.location)
    // Give the player machine time to re-load and reach playing.
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: {
            playerStore: {
              getState: () => {
                playingState: string
                activeParagraph: { index: string } | null
              }
            }
          }
        }
        const s = w.__rishi.playerStore.getState()
        return s.playingState === 'playing' && s.activeParagraph !== null
      },
      undefined,
      { timeout: 8000 }
    )

    // Stop sampling and read the log.
    const log = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { __rishiInvariantStopFn?: () => void }
        __rishiInvariantLog: Array<{
          ts: number
          activeIndex: string | null
          currentIndexes: string[]
          state: string
        }>
      }
      w.__rishi.__rishiInvariantStopFn?.()
      return w.__rishiInvariantLog
    })

    // Find any sample where the highlight (activeIndex) is non-null but
    // points to a CFI NOT in the visible page's currentParagraphs. That's
    // a violation: the user would see/hear the wrong page.
    const violations = log.filter(
      (s) =>
        s.activeIndex !== null &&
        s.currentIndexes.length > 0 &&
        !s.currentIndexes.includes(s.activeIndex)
    )
    expect(
      violations,
      `Highlight pointed to a paragraph NOT on the visible page in ${violations.length} sample(s). First violation: state=${violations[0]?.state}, activeIndex=${violations[0]?.activeIndex}, currentIndexes=${JSON.stringify(violations[0]?.currentIndexes)}`
    ).toEqual([])

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  test('clicking Next during playback pauses the OLD page audio immediately', async () => {
    // This mirrors the user's exact manual flow:
    //   1. open page, click Play, wait for audio to be playing
    //   2. click Next page arrow
    //   3. the OLD page's audio must NOT keep playing
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Bleed Spec'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    // Install a mock TTS that returns a known-distinguishable blob URL per
    // request so we can detect whether audio.src is still the OLD blob
    // after Next is clicked. We track EVERY blob URL ever issued (not just
    // latest per CFI) so we can identify which paragraph an audio.src came
    // from even after the same CFI is re-requested.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { setTestTtsService: (s: unknown) => void }
        __rishiBlobToCfi?: Map<string, string>
      }
      w.__rishiBlobToCfi = new Map()
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
        requestAudio: async (req: { cfiRange: string }) => {
          const url = URL.createObjectURL(new Blob([u8], { type: 'audio/wav' }))
          w.__rishiBlobToCfi!.set(url, req.cfiRange)
          return url
        },
        cancelRequest: () => true,
        cancelBookRequests: noop,
        clearBookCache: async () => {},
        getQueueStatus: () => ({ pending: 0, isProcessing: false, active: 0 }),
        onAudioReady: () => noop,
        onError: () => noop
      })
    })

    const startSnap = await readPlayerSnapshot(bookPage)
    const oldFirstCfi = startSnap.paragraphs[0]?.index
    expect(oldFirstCfi).toBeTruthy()

    // PLAY -> wait for state=playing AND audio actually un-paused AND the
    // src points to the expected first-paragraph blob. Capture the snapshot
    // atomically from inside waitForFunction so the assertions below cannot
    // race a fast AUDIO_ENDED (100 ms WAV) that pauses the audio between
    // the wait settling and the next page.evaluate read.
    await sendPlayerEvent(bookPage, 'PLAY')
    const playingBeforeHandle = await bookPage.waitForFunction(
      (expectedCfi) => {
        const w = window as unknown as {
          __rishi: {
            playerStore: { getState: () => { playingState: string } }
            audioElement: HTMLAudioElement
          }
          __rishiBlobToCfi: Map<string, string>
        }
        const a = w.__rishi.audioElement
        const cfiOfSrc = w.__rishiBlobToCfi.get(a.src) ?? null
        if (
          w.__rishi.playerStore.getState().playingState === 'playing' &&
          a.paused === false &&
          cfiOfSrc === expectedCfi
        ) {
          return { src: a.src, paused: a.paused, cfiOfSrc }
        }
        return null
      },
      oldFirstCfi,
      { timeout: 8000 }
    )
    const playingBefore = (await playingBeforeHandle.jsonValue()) as {
      src: string
      paused: boolean
      cfiOfSrc: string | null
    }
    expect(playingBefore.paused).toBe(false)
    expect(
      playingBefore.cfiOfSrc,
      'Audio is playing a blob we did not issue from the mock TTS'
    ).toBeTruthy()
    expect(playingBefore.cfiOfSrc).toBe(oldFirstCfi)
    const oldBlob = playingBefore.src

    // Click the Next page arrow — exactly like the user does.
    await bookPage.locator('[aria-label="Next page"]').first().click()

    // The bug: after clicking Next, the audio keeps playing the OLD blob.
    // Invariant: within a short window, the audio element MUST either
    // be paused or have moved to a new src — it cannot still be unpaused
    // on the OLD blob.
    await bookPage.waitForFunction(
      (oldBlobUrl) => {
        const w = window as unknown as {
          __rishi: { audioElement: HTMLAudioElement }
        }
        const a = w.__rishi.audioElement
        return a.paused || a.src !== oldBlobUrl
      },
      oldBlob,
      { timeout: 1500 }
    )

    // And: when audio is playing again on the new page, its src must be a
    // blob we issued for a CFI on the CURRENT visible page.
    const afterSnap = await readPlayerSnapshot(bookPage)
    const afterAudio = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { audioElement: HTMLAudioElement }
        __rishiBlobToCfi: Map<string, string>
      }
      return {
        src: w.__rishi.audioElement.src,
        paused: w.__rishi.audioElement.paused,
        cfiOfSrc: w.__rishiBlobToCfi.get(w.__rishi.audioElement.src) ?? null
      }
    })
    if (!afterAudio.paused) {
      expect(
        afterSnap.paragraphs.some((p) => p.index === afterAudio.cfiOfSrc),
        `Audio is playing CFI ${afterAudio.cfiOfSrc}, which is NOT on the visible page (${afterSnap.paragraphs.map((p) => p.index).join(', ')})`
      ).toBe(true)
    }

    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  test('audio.play() is NOT called for stale blob when state moves on during loadAndPlayAudio', async () => {
    // Race scenario: a TTS fetch already resolved and loadAndPlayAudio is
    // mid-flight (awaiting canplaythrough on blob_OLD). The user clicks
    // Next. PARAGRAPHS_UPDATED reenters loading, stopAudio runs, but the
    // OLD loadAndPlayAudio's promise chain is still alive. When
    // canplaythrough fires for blob_OLD, audio.play() will be called on
    // the OLD blob — bleed. This test forces that race by delaying the
    // canplaythrough event.
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Race Spec'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    // Spy on audio.play and pause to detect what was played and when.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          audioElement: HTMLAudioElement
          setTestTtsService: (s: unknown) => void
        }
        __rishiPlayLog?: Array<{ ts: number; src: string }>
        __rishiBlobToCfi?: Map<string, string>
        __rishiCanPlayGate?: { hold: boolean; pending: Array<() => void> }
      }
      w.__rishiPlayLog = []
      w.__rishiBlobToCfi = new Map()
      w.__rishiCanPlayGate = { hold: false, pending: [] }
      const origPlay = w.__rishi.audioElement.play.bind(w.__rishi.audioElement)
      w.__rishi.audioElement.play = function () {
        w.__rishiPlayLog!.push({ ts: performance.now(), src: this.src })
        return origPlay()
      }
      // Wrap addEventListener so we can gate canplaythrough firing.
      const origAdd = w.__rishi.audioElement.addEventListener.bind(w.__rishi.audioElement)
      w.__rishi.audioElement.addEventListener = function (
        type: string,
        listener: EventListenerOrEventListenerObject,
        opts?: AddEventListenerOptions | boolean
      ) {
        if (type === 'canplaythrough' && w.__rishiCanPlayGate!.hold) {
          // Defer firing canplaythrough until the gate is opened.
          const fn = typeof listener === 'function' ? listener : listener.handleEvent.bind(listener)
          const realListener = (e: Event): void => fn(e)
          const wrapped = (e: Event): void => {
            w.__rishiCanPlayGate!.pending.push(() => realListener(e))
          }
          return origAdd(type, wrapped, opts)
        }
        return origAdd(type, listener, opts)
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
        requestAudio: async (req: { cfiRange: string }) => {
          // First request (page 1 CFI) returns instantly. Subsequent
          // requests delay for 1.5 s so we can interleave a Next click
          // during the OLD loadAndPlayAudio's await on canplaythrough.
          const isFirst = w.__rishiBlobToCfi!.size === 0
          const url = URL.createObjectURL(new Blob([u8], { type: 'audio/wav' }))
          w.__rishiBlobToCfi!.set(url, req.cfiRange)
          if (!isFirst) {
            await new Promise<void>((r) => {
              setTimeout(r, 1500)
            })
          }
          return url
        },
        cancelRequest: () => true,
        cancelBookRequests: noop,
        clearBookCache: async () => {},
        getQueueStatus: () => ({ pending: 0, isProcessing: false, active: 0 }),
        onAudioReady: () => noop,
        onError: () => noop
      })
    })

    const startSnap = await readPlayerSnapshot(bookPage)
    const oldFirstCfi = startSnap.paragraphs[0]?.index
    expect(oldFirstCfi).toBeTruthy()

    // Gate canplaythrough so we can interleave a Next click during the
    // loadAndPlayAudio await.
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishiCanPlayGate: { hold: boolean } }
      w.__rishiCanPlayGate.hold = true
    })

    await sendPlayerEvent(bookPage, 'PLAY')

    // Wait for audio.src to be set to the OLD blob (loadAndPlayAudio
    // reached the canplaythrough await).
    await bookPage.waitForFunction(
      (cfi) => {
        const w = window as unknown as {
          __rishi: { audioElement: HTMLAudioElement }
          __rishiBlobToCfi: Map<string, string>
        }
        const a = w.__rishi.audioElement
        const cfiOfSrc = w.__rishiBlobToCfi.get(a.src)
        return cfiOfSrc === cfi
      },
      oldFirstCfi,
      { timeout: 5000 }
    )

    // Now interrupt: click Next while loadAndPlayAudio is paused on the
    // canplaythrough await.
    await bookPage.locator('[aria-label="Next page"]').first().click()

    // Wait for PARAGRAPHS_UPDATED to land — currentParagraphs no longer
    // contains oldFirstCfi.
    await bookPage.waitForFunction(
      (cfi) => {
        const w = window as unknown as {
          __rishi: {
            playerStore: { getState: () => { currentParagraphs: { index: string }[] } }
          }
        }
        const ps = w.__rishi.playerStore.getState().currentParagraphs
        return ps.length > 0 && !ps.some((p) => p.index === cfi)
      },
      oldFirstCfi,
      { timeout: 5000 }
    )

    // Now release the gate — canplaythrough fires for the OLD blob.
    // Without the load-in-flight cancellation fix, this triggers
    // audio.play() on the OLD blob → bleed.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishiCanPlayGate: { hold: boolean; pending: Array<() => void> }
      }
      w.__rishiCanPlayGate.hold = false
      for (const fn of w.__rishiCanPlayGate.pending.splice(0)) fn()
    })

    // Watch the playLog over a short window for any off-page audio.play()
    // call. waitForFunction resolves *as soon as* a bleed appears (fail-fast
    // diagnostic); a 300ms timeout with no bleed means the system stayed
    // clean — which is the post-condition we want.
    const afterSnap = await readPlayerSnapshot(bookPage)
    const visibleCfis = afterSnap.paragraphs.map((p) => p.index)
    const bleedAppeared = await bookPage
      .waitForFunction(
        (visible) => {
          const w = window as unknown as {
            __rishiPlayLog: Array<{ ts: number; src: string }>
            __rishiBlobToCfi: Map<string, string>
          }
          const visibleSet = new Set(visible)
          return w.__rishiPlayLog.some((e) => {
            const cfi = w.__rishiBlobToCfi.get(e.src) ?? null
            return cfi !== null && !visibleSet.has(cfi)
          })
        },
        visibleCfis,
        { timeout: 300 }
      )
      .then(() => true)
      .catch(() => false)

    const playLog = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishiPlayLog: Array<{ ts: number; src: string }>
        __rishiBlobToCfi: Map<string, string>
      }
      return w.__rishiPlayLog.map((e) => ({
        ...e,
        cfi: w.__rishiBlobToCfi.get(e.src) ?? null
      }))
    })

    const visibleSet = new Set(visibleCfis)
    const bleeds = playLog.filter((e) => e.cfi !== null && !visibleSet.has(e.cfi))
    expect(
      bleeds,
      `audio.play() was called for off-page CFI(s): ${JSON.stringify(bleeds)}. Visible page: ${visibleCfis.slice(0, 3).join(', ')}... bleedAppeared=${bleedAppeared}`
    ).toEqual([])

    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  test('PLAY after STOP + page nav targets the NEW page, not the old', async () => {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Nav Spec B'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    await installMockTts(bookPage)

    const startSnap = await readPlayerSnapshot(bookPage)
    const startFirstCfi = startSnap.paragraphs[0]?.index
    expect(startFirstCfi).toBeTruthy()

    // PLAY -> wait for the priority-1 (active) TTS request for the current page.
    await sendPlayerEvent(bookPage, 'PLAY')
    await bookPage.waitForFunction(
      (cfi) => {
        const w = window as unknown as {
          __rishiTtsLog: Array<{ cfiRange: string; priority: number }>
        }
        return w.__rishiTtsLog.some((r) => r.cfiRange === cfi && r.priority === 1)
      },
      startFirstCfi,
      { timeout: 5000 }
    )

    // STOP and wait for the machine to land in 'stopped'.
    await sendPlayerEvent(bookPage, 'STOP')
    await waitForPlayerState(bookPage, 'stopped')

    // Reset the log so we only observe what PLAY-after-nav asks for.
    await clearTtsLog(bookPage)

    // Wait for navMachine to settle to idle before clicking Next.
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: { navStore: { getState: () => { navState: string } } }
        }
        return w.__rishi.navStore.getState().navState === 'idle'
      },
      undefined,
      { timeout: 5000 }
    )

    // Navigate to the next page and wait for the player store to reflect it.
    await bookPage.locator('[aria-label="Next page"]').first().click()
    const nextSnap = await waitForLocationChange(bookPage, startSnap.location)
    const nextFirstCfi = nextSnap.paragraphs[0]?.index
    expect(nextFirstCfi).toBeTruthy()
    expect(nextFirstCfi).not.toBe(startFirstCfi)

    // PLAY again. The very first priority-1 request after this PLAY MUST be
    // the new page's first paragraph. If it's an old-page CFI, that is the
    // user-reported bug ("Stop+Play restarts from the old page").
    await sendPlayerEvent(bookPage, 'PLAY')
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishiTtsLog: Array<{ priority: number }>
        }
        return w.__rishiTtsLog.some((r) => r.priority === 1)
      },
      undefined,
      { timeout: 5000 }
    )

    const log = await readTtsLog(bookPage)
    const firstActiveRequest = log.find((r) => r.priority === 1)
    expect(
      firstActiveRequest?.cfiRange,
      `Expected first active TTS request to be the new page CFI (${nextFirstCfi}); got ${firstActiveRequest?.cfiRange}`
    ).toBe(nextFirstCfi)

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  test('audio pauses synchronously with navMachine leaving idle (no bleed during curl)', async () => {
    // The user's manual flow: audio is playing, click Next page, expect the
    // OLD page audio to silence IMMEDIATELY — not after the 200 ms curl
    // animation + relocate + setCurrentParagraphs + PARAGRAPHS_UPDATED chain.
    // We instrument both the nav state change and the audio.pause() call
    // inside the renderer so we measure the actual JS-time gap between
    // "nav started" and "audio silenced", independent of Playwright click
    // overhead. This must be near-zero (<50 ms) — both are synchronous.
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Immediate Pause Spec'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    await installMockTts(bookPage)

    await sendPlayerEvent(bookPage, 'PLAY')
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: {
            playerStore: { getState: () => { playingState: string } }
            audioElement: HTMLAudioElement
          }
        }
        return (
          w.__rishi.playerStore.getState().playingState === 'playing' &&
          w.__rishi.audioElement.paused === false
        )
      },
      undefined,
      { timeout: 8000 }
    )

    // Instrument: snapshot audio.paused AT the moment navState leaves 'idle'.
    // Because subscribers fire synchronously, if the player's nav subscriber
    // ran first (it should — it was registered during app boot), the audio
    // is already paused by the time our test subscriber fires. That's the
    // ideal: pause completes *before* anyone else observes nav has started.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          audioElement: HTMLAudioElement
          navStore: {
            subscribe: (
              selector: (s: { navState: string }) => unknown,
              listener: (next: string, prev: string) => void
            ) => () => void
          }
        }
        __rishiNavBleed?: { observedPausedAtNavLeft: boolean | null }
        __rishiNavBleedTeardown?: () => void
      }
      w.__rishiNavBleed = { observedPausedAtNavLeft: null }
      const unsub = w.__rishi.navStore.subscribe(
        (s) => s.navState,
        (next, prev) => {
          if (
            prev === 'idle' &&
            next !== 'idle' &&
            w.__rishiNavBleed!.observedPausedAtNavLeft === null
          ) {
            w.__rishiNavBleed!.observedPausedAtNavLeft = w.__rishi.audioElement.paused
          }
        }
      )
      w.__rishiNavBleedTeardown = unsub
    })

    await bookPage.locator('[aria-label="Next page"]').first().click()

    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishiNavBleed?: { observedPausedAtNavLeft: boolean | null }
        }
        return w.__rishiNavBleed?.observedPausedAtNavLeft !== null
      },
      undefined,
      { timeout: 2000 }
    )

    const observedPaused = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishiNavBleed: { observedPausedAtNavLeft: boolean | null }
        __rishiNavBleedTeardown: () => void
      }
      const v = w.__rishiNavBleed.observedPausedAtNavLeft
      w.__rishiNavBleedTeardown()
      return v
    })

    expect(
      observedPaused,
      `audio.paused must be TRUE at the moment navState first leaves 'idle'. observedPausedAtNavLeft=${observedPaused}. If false, the player did not pause the OLD page's audio before any other subscriber learned about the nav — meaning a downstream consumer would observe still-playing audio of the previous page.`
    ).toBe(true)

    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  test('Stop+Play immediately after Next does NOT replay the old page', async () => {
    // The user's exact second complaint: "Even if I click stop and then play
    // on a completely different page, It still restarts from the old page
    // not the new one." This happens when Stop+Play fire BEFORE
    // PARAGRAPHS_UPDATED has landed — the machine's currentParagraphs are
    // still the old page, so PLAY fetches the old CFI.
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Fast StopPlay Spec'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    await installMockTts(bookPage)

    const startSnap = await readPlayerSnapshot(bookPage)
    const oldFirstCfi = startSnap.paragraphs[0]?.index
    expect(oldFirstCfi).toBeTruthy()

    // Get audio playing on page 1.
    await sendPlayerEvent(bookPage, 'PLAY')
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: { playerStore: { getState: () => { playingState: string } } }
        }
        return w.__rishi.playerStore.getState().playingState === 'playing'
      },
      undefined,
      { timeout: 8000 }
    )

    // Click Next, then IMMEDIATELY send STOP+PLAY — do NOT wait for the
    // paragraphs to update. This simulates the user clicking Stop+Play
    // during the curl animation.
    await clearTtsLog(bookPage)
    await bookPage.locator('[aria-label="Next page"]').first().click()
    // Send STOP+PLAY via the actor directly (synchronous in JS time, faster
    // than the click-then-paragraphs-settle chain).
    await sendPlayerEvent(bookPage, 'STOP')
    await sendPlayerEvent(bookPage, 'PLAY')

    // Let the curl + relocate + PARAGRAPHS_UPDATED chain settle.
    await waitForLocationChange(bookPage, startSnap.location)
    // And wait for the player to issue at least one priority-1 request.
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishiTtsLog: Array<{ priority: number }>
        }
        return w.__rishiTtsLog.some((r) => r.priority === 1)
      },
      undefined,
      { timeout: 5000 }
    )

    const afterSnap = await readPlayerSnapshot(bookPage)
    const newPageCfis = new Set(afterSnap.paragraphs.map((p) => p.index))
    const log = await readTtsLog(bookPage)
    const activeRequests = log.filter((r) => r.priority === 1)
    // Find any priority-1 request whose CFI is the OLD page — that is the bug.
    const replayedOld = activeRequests.filter((r) => r.cfiRange === oldFirstCfi)
    expect(
      replayedOld,
      `After Next + Stop + Play, the player issued ${replayedOld.length} priority-1 TTS request(s) for the OLD page CFI (${oldFirstCfi}). All active requests: ${JSON.stringify(activeRequests)}. New page CFIs: ${[...newPageCfis].slice(0, 3).join(', ')}...`
    ).toEqual([])

    // And: at least one priority-1 request must target the NEW page.
    const newPageActive = activeRequests.filter((r) => newPageCfis.has(r.cfiRange))
    expect(
      newPageActive.length,
      `Expected at least one priority-1 request for the new page; got ${JSON.stringify(activeRequests)}`
    ).toBeGreaterThan(0)

    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  // ---------------------------------------------------------------------
  // T1 — UI-driven Play→Next→Play recovery.
  //
  // Reproduces the user's exact complaint: clicking the Next page arrow
  // during playback, then clicking Play (the UI button — NOT
  // sendPlayerEvent), must return the player to `playing` within 5s.
  // This exercises the real `handlePlay` dispatch in TTSControls and
  // proves the UI mapping is consistent with whatever state the machine
  // ends up in after the page-curl.
  //
  // The reviewer's M-4 requires asserting the auth dialog is NOT visible
  // immediately after clicking Play — otherwise PLAY is never dispatched
  // and the test would just time out with no diagnostic.
  // ---------------------------------------------------------------------
  test('T1: Play -> Next via UI button -> Play button recovers (BUG)', async () => {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Stuck T1'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)
    await installMockTts(bookPage)

    // Use sendPlayerEvent to start playback — bypasses the orb-expansion
    // step. The TTSControls pill is collapsed by default; we'll click the
    // orb later only if we need to access the Play button.
    await sendPlayerEvent(bookPage, 'PLAY')
    await waitForPlayerState(bookPage, 'playing', 8000)

    // Confirm audio actually un-paused (state label alone is not enough).
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: { audioElement: HTMLAudioElement }
        }
        return w.__rishi.audioElement.paused === false
      },
      undefined,
      { timeout: 5000 }
    )

    // Click the EPUB next-page arrow.
    await bookPage.locator('[aria-label="Next page"]').first().click()

    // Wait for the player to settle into a non-transient state. If the
    // auto-resume path works, this lands on `playing`. Otherwise it lands on
    // a stable resting state (stopped/paused/waitingForParagraphs) and the
    // recovery branch below kicks in. Polling for stability (instead of a
    // fixed 6s sleep) makes us fail fast on a regression that hangs in
    // `loading`/`pageNavigating`, and skips wall-clock waste on a fast pass.
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: { playerStore: { getState: () => { playingState: string } } }
        }
        const s = w.__rishi.playerStore.getState().playingState
        return s !== 'loading' && s !== 'pageNavigating'
      },
      undefined,
      { timeout: 8000 }
    )

    const stateAfterNav = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { playerStore: { getState: () => { playingState: string } } }
      }
      return w.__rishi.playerStore.getState().playingState
    })

    // If the player is already back to playing, we're done — the auto-resume
    // path worked. Otherwise we must click the Play UI button.
    if (stateAfterNav !== 'playing') {
      // Re-expand the orb if collapsed (AUTO_DISMISS_MS = 4000ms).
      const orbVisible = await bookPage
        .locator('[aria-label="Expand TTS controls"]')
        .isVisible()
        .catch(() => false)
      if (orbVisible) {
        await bookPage.locator('[aria-label="Expand TTS controls"]').click()
      }

      await expect(bookPage.locator('button[aria-label="Play"]')).toBeVisible({
        timeout: 3000
      })
      await bookPage.locator('button[aria-label="Play"]').click()

      // Review M-4: assert auth dialog is NOT visible. If it is, PLAY was
      // never dispatched and the player would silently stall.
      await expect(
        bookPage.locator('[role="dialog"]'),
        'Auth dialog appeared after clicking Play - test user not authenticated for TTS feature.'
      ).not.toBeVisible({ timeout: 500 })

      // Wait for the player to return to `playing` within 5s.
      await waitForPlayerState(bookPage, 'playing', 5000).catch(() => {
        throw new Error(
          'After Next + Play UI click, player did not return to playing within 5s. ' +
            'This is the user-reported stuck-state bug.'
        )
      })
    }

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  // ---------------------------------------------------------------------
  // T2 — Stuck-loop reproducer (the reviewer's Hard-question C).
  //
  // We force the exact state the bug produces:
  //   1. PLAY -> playing
  //   2. Manually send PAGE_NAVIGATING via the wrapped send. This puts the
  //      machine in `pageNavigating` with wantsAutoResume=true and clears
  //      currentParagraphs (clearCurrentParagraphs from the playing→pageNav
  //      transition).
  //   3. We do NOT fire PARAGRAPHS_UPDATED. Instead we send STOP, which
  //      transitions pageNavigating → stopped with empty currentParagraphs
  //      (same shape as the 10s `after` timeout would produce, modulo
  //      `timedOut`). This avoids waiting 10s in real time.
  //   4. Record the EPUB location.
  //   5. Send PLAY (sendPlayerEvent). Pre-fix: this transitions stopped→
  //      waitingForParagraphs (no paragraphs), which invokes the view actor
  //      with NAVIGATE_NEXT → EPUB navigates forward.
  //   6. Assert the EPUB location did NOT change. If it did, that's the
  //      stuck-loop bug.
  // ---------------------------------------------------------------------
  test('T2: Stuck-loop reproducer - PLAY after pageNavigating timeout must not cause unwanted nav (BUG)', async () => {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Stuck T2'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)
    await installMockTts(bookPage)

    // Record an identifier for the "page" BEFORE we do anything that might
    // mutate it. The epubStore's `currentEpubLocation` is sometimes the
    // literal string "undefined" during a transient load — so we use the
    // first paragraph's CFI as our page identity (same approach used in
    // the existing passing tests). This is more reliable than the global
    // epub location.
    const pageBefore = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => { currentParagraphs: { index: string }[] }
          }
        }
      }
      return w.__rishi.playerStore.getState().currentParagraphs[0]?.index ?? null
    })
    expect(pageBefore, 'Pre-nav page CFI must be set').toBeTruthy()

    await sendPlayerEvent(bookPage, 'PLAY')
    await waitForPlayerState(bookPage, 'playing', 8000)

    // Forge an external PAGE_NAVIGATING via the wrapped send (the same one
    // sendPlayerEvent uses, but with a payload).
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => {
              send: ((e: { type: string; direction?: 'forward' | 'backward' }) => void) | null
            }
          }
        }
      }
      const send = w.__rishi.playerStore.getState().send
      if (!send) throw new Error('playerStore.send is null')
      send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
    })

    // Verify the machine is now in `pageNavigating`. Note: the playerStore's
    // `currentParagraphs` is NOT the same as the machine context's — the store
    // is fed by the EPUB rendition's `relocated`, which we did not actually
    // trigger. So we can only observe state, not the empty-paragraphs symptom
    // from outside the machine. We instead manually clear the store's
    // currentParagraphs so the machine sees an empty PARAGRAPHS_UPDATED if any
    // subscription re-fires.
    await waitForPlayerState(bookPage, 'pageNavigating', 2000)
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => {
              setCurrentParagraphs?: (p: unknown[]) => void
            }
          }
        }
      }
      // Directly clear via the store action if present, otherwise via setState.
      const setFn = w.__rishi.playerStore.getState().setCurrentParagraphs
      if (typeof setFn === 'function') {
        setFn([])
      }
    })

    // Simulate the 10s timeout outcome: send STOP from pageNavigating
    // (machine line 487-489) -> stopped. Combined with the cleared store
    // currentParagraphs above, the machine context's paragraphs are now empty
    // (mirroring the user-visible stuck state).
    await sendPlayerEvent(bookPage, 'STOP')
    await waitForPlayerState(bookPage, 'stopped', 2000)

    // Confirm activeParagraph is null (audio is silent, no highlight).
    const stuckShape = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => {
              playingState: string
              activeParagraph: unknown
              currentParagraphs: unknown[]
            }
          }
        }
      }
      const s = w.__rishi.playerStore.getState()
      return {
        playingState: s.playingState,
        activeParagraph: s.activeParagraph,
        currentParagraphsCount: s.currentParagraphs.length
      }
    })
    expect(stuckShape.playingState).toBe('stopped')
    expect(stuckShape.activeParagraph).toBeNull()

    // Send PLAY. PRE-FIX: this routes stopped (hasParagraphs=false) →
    // waitingForParagraphs, which invokes the view actor with NAVIGATE_NEXT,
    // which the epub view actor processes via rendition.next() — the unwanted
    // double-nav.
    await sendPlayerEvent(bookPage, 'PLAY')

    // Watch currentParagraphs[0].index over a 2s window and fail fast on any
    // change. waitForFunction resolves the moment an unwanted nav appears
    // (carrying the diff in the error), and a timeout means the page held
    // steady — which is the post-condition we want.
    const navObserved = await bookPage
      .waitForFunction(
        (before) => {
          const w = window as unknown as {
            __rishi: {
              playerStore: {
                getState: () => { currentParagraphs: { index: string }[] }
              }
            }
          }
          const current = w.__rishi.playerStore.getState().currentParagraphs[0]?.index ?? null
          // Treat null → non-null as "page populated", not "navigation". Only
          // a different non-null CFI counts as an unwanted nav.
          return current !== null && current !== before
        },
        pageBefore,
        { timeout: 2000 }
      )
      .then(() => true)
      .catch(() => false)

    const pageAfter = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => { currentParagraphs: { index: string }[] }
          }
        }
      }
      return w.__rishi.playerStore.getState().currentParagraphs[0]?.index ?? null
    })

    expect(
      navObserved,
      `STUCK LOOP DETECTED: clicking Play after pageNavigating timeout caused ` +
        `an unwanted page advance. Page first-paragraph CFI was ${pageBefore}, now ${pageAfter}. ` +
        `The user's PLAY click was misinterpreted as a request for the next page.`
    ).toBe(false)

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  // ---------------------------------------------------------------------
  // T3 — `paused.clean → click Play UI button → resumes via RESUME (not PLAY)`.
  //
  // The TTSControls handlePlay sends RESUME when playingState starts with
  // "paused". Verify the user's UI click does NOT cause a fresh PLAY
  // (which would re-fetch the audio blob and skip the resume optimization).
  //
  // Invariant: audioElement.src does NOT change between PAUSE and the
  // post-click `playing` re-entry. RESUME reuses the existing blob; PLAY
  // would fetch a new one.
  // ---------------------------------------------------------------------
  test('T3: paused.clean -> click Play UI button -> resumes (RESUME, not PLAY)', async () => {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Stuck T3'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)
    await installMockTts(bookPage)

    await sendPlayerEvent(bookPage, 'PLAY')
    await waitForPlayerState(bookPage, 'playing', 8000)
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: { audioElement: HTMLAudioElement }
        }
        return w.__rishi.audioElement.paused === false && w.__rishi.audioElement.src !== ''
      },
      undefined,
      { timeout: 5000 }
    )

    const srcBefore = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { audioElement: HTMLAudioElement }
      }
      return w.__rishi.audioElement.src
    })
    expect(srcBefore, 'audio element should have a src after PLAY').toBeTruthy()

    await sendPlayerEvent(bookPage, 'PAUSE')
    // Wait for ANY paused state (could be paused.clean or paused.stale).
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi: { playerStore: { getState: () => { playingState: string } } }
        }
        return w.__rishi.playerStore.getState().playingState.startsWith('paused')
      },
      undefined,
      { timeout: 3000 }
    )

    // Confirm src is still the same after PAUSE (no fetch).
    const pauseSnapshot = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          audioElement: HTMLAudioElement
          playerStore: { getState: () => { playingState: string } }
        }
      }
      return {
        src: w.__rishi.audioElement.src,
        state: w.__rishi.playerStore.getState().playingState
      }
    })
    expect(pauseSnapshot.src).toBe(srcBefore)

    // Expand the orb if needed, then click the Play UI button.
    const orbVisible = await bookPage
      .locator('[aria-label="Expand TTS controls"]')
      .isVisible()
      .catch(() => false)
    if (orbVisible) {
      await bookPage.locator('[aria-label="Expand TTS controls"]').click()
    }
    await expect(bookPage.locator('button[aria-label="Play"]')).toBeVisible({ timeout: 3000 })
    await bookPage.locator('button[aria-label="Play"]').click()

    // M-4: no auth dialog (resume should be auth-free anyway since
    // handlePlay bypasses requireAuth in the paused branch).
    await expect(bookPage.locator('[role="dialog"]')).not.toBeVisible({ timeout: 500 })

    await waitForPlayerState(bookPage, 'playing', 3000)

    // Critical invariant: handlePlay in TTSControls sends RESUME (not PLAY)
    // when state starts with "paused". For paused.clean, RESUME → playing
    // (no fetch — src preserved). For paused.stale, RESUME → loading (which
    // DOES fetch — src changes). The test depends on whether the pause
    // landed in clean or stale. If clean, assert src is preserved. If stale,
    // assert RESUME was the path taken (state went through loading first,
    // src changed legitimately).
    const srcAfterPlayClick = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { audioElement: HTMLAudioElement }
      }
      return w.__rishi.audioElement.src
    })
    if (pauseSnapshot.state === 'paused.clean') {
      expect(
        srcAfterPlayClick,
        'After clicking Play in paused.clean state, audioElement.src changed - meaning ' +
          'the UI sent PLAY (fetched a new blob) instead of RESUME (reuse blob). ' +
          'This breaks the resume optimization and signals a TTSControls.handlePlay regression.'
      ).toBe(srcBefore)
    } else {
      // paused.stale: src will change, that's correct (RESUME→loading→fetch).
      // Just verify a new blob was issued — we cannot distinguish PLAY from RESUME
      // by src in this case, only by playingState path. State already reached
      // `playing`, so the path worked.
      expect(srcAfterPlayClick).toBeTruthy()
    }

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  // ---------------------------------------------------------------------
  // Regression: AUDIO_ENDED at the last paragraph of a page must continue
  // playback on the next page (auto-resume).
  //
  // Bug: when the player finished the last paragraph on a page, AUDIO_ENDED
  // → waitingForParagraphs without setting `wantsAutoResume`. The hook then
  // set pageRequest='next' and the rendition started turning the page. The
  // navState idle→non-idle transition fired PAGE_NAVIGATING into the
  // player, which preserved the (false) wantsAutoResume value through to
  // pageNavigating. When PARAGRAPHS_UPDATED arrived for the new page, the
  // guard `wantsAutoResume` was false, so the machine landed in `stopped`
  // instead of `loading`. The user saw playback stop at every page break.
  //
  // Fix: set wantsAutoResume when transitioning from playing →
  // waitingForParagraphs (AUDIO_ENDED, NEXT, PREV at a page boundary).
  // ---------------------------------------------------------------------
  test('auto-advance past last paragraph keeps playing on next page', async () => {
    test.setTimeout(60_000)
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Auto Resume Boundary'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)

    // Silent mock TTS — 100 ms WAV per paragraph. Audio plays naturally to
    // completion and the audio element fires `ended`, which drives AUDIO_ENDED
    // into the state machine. This is the exact lifecycle the user reported.
    await installMockTts(bookPage)

    const startSnap = await readPlayerSnapshot(bookPage)
    const startLocation = startSnap.location
    expect(startSnap.paragraphs.length, 'fixture must have paragraphs on page 1').toBeGreaterThan(0)

    await sendPlayerEvent(bookPage, 'PLAY')
    await waitForPlayerState(bookPage, 'playing', 8000)

    // Each paragraph: ~100 ms of audio. After the last paragraph the player
    // requests the next page, the rendition curls, and PARAGRAPHS_UPDATED
    // lands. Wait up to 25 s for the EPUB location to actually change.
    await waitForLocationChange(bookPage, startLocation, 25000)

    // The bug: player was in 'stopped' after the page change. With the fix it
    // must be in an active state — loading or playing — because wantsAutoResume
    // was set when playing→waitingForParagraphs fired on AUDIO_ENDED.
    const stateAfterNav = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: { playerStore: { getState: () => { playingState: string } } }
      }
      return w.__rishi.playerStore.getState().playingState
    })
    expect(
      stateAfterNav,
      'After auto-advance past the last paragraph and page change, the player ' +
        `must continue playing — got '${stateAfterNav}'. If 'stopped', the ` +
        `wantsAutoResume flag was not carried through playing → waitingForParagraphs ` +
        `→ pageNavigating → PARAGRAPHS_UPDATED.`
    ).not.toBe('stopped')

    // Stronger assertion: the player must reach `playing` again on the new
    // page within a reasonable window. This proves the auto-resume actually
    // completed, not just that the machine briefly transitioned to `loading`
    // before stalling.
    await waitForPlayerState(bookPage, 'playing', 10000)

    // Strongest assertion (Phase 3.4 acceptance gate). The active paragraph
    // must equal paragraph 0 of the NEW view — NOT paragraph 0 of the OLD
    // view that a republish-without-validation path could land on. With the
    // view-actor NAV_NO_PROGRESS rule:
    //  - On a real advance: new view's paragraph 0 (this assertion)
    //  - On no progress: machine transitions to `stopped` (covered in the
    //    sibling "no-progress" test)
    const newViewSnap = await readPlayerSnapshot(bookPage)
    const activeId = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => { activeParagraph: { index: string } | null }
          }
        }
      }
      return w.__rishi.playerStore.getState().activeParagraph?.index ?? null
    })
    expect(
      activeId,
      'After auto-advance, activeParagraph must be set to a paragraph of the NEW view.'
    ).not.toBeNull()
    expect(
      activeId,
      `After auto-advance, activeParagraph (${activeId}) must equal currentParagraphs[0].index ` +
        `(${newViewSnap.paragraphs[0]?.index}) of the NEW view. If activeId belongs to ` +
        `the OLD view, the safety-net's republish-without-validation regression ` +
        `(Phase 3.4 §1) has crept back in.`
    ).toBe(newViewSnap.paragraphs[0]?.index)

    // Phase 3.4 acceptance gate — snap-back / flip-back.
    //
    // Closes a vacuous-pass hole in the assertion above: when the
    // location-changed-then-flipped-back regression fires, BOTH location
    // AND currentParagraphs revert to the OLD view in lock-step. The
    // assertion `activeId === currentParagraphs[0].index` then passes
    // trivially (both are the OLD view's paragraph 0), so the test
    // misses the bug that the user smoke-reported.
    //
    // Sample the EPUB location for 2.5 s after the player reached `playing`
    // on the new view. If the location reverts to startLocation at any
    // point — or even ends up there at the final tick — the snap-back is
    // live. This catches the case where epubjs's mid-animation `relocated`
    // events bypass the view-actor's same-CFI guard via an unvalidated
    // publish path (e.g., a zustand subscriber that writes
    // playerStore.currentParagraphs from epubStore.currentEpubLocation
    // without comparing locators).
    type SnapBackSample = { t: number; location: string; activeIndex: string | null }
    const snapSamples: SnapBackSample[] = []
    const snapStart = Date.now()
    while (Date.now() - snapStart < 2500) {
      const sample = await bookPage.evaluate(() => {
        const w = window as unknown as {
          __rishi: {
            playerStore: { getState: () => { activeParagraph: { index: string } | null } }
            epubStore: { getState: () => { currentEpubLocation: string } }
          }
        }
        return {
          location: w.__rishi.epubStore.getState().currentEpubLocation,
          activeIndex: w.__rishi.playerStore.getState().activeParagraph?.index ?? null
        }
      })
      snapSamples.push({ t: Date.now() - snapStart, ...sample })
      await bookPage.waitForTimeout(100)
    }
    const revertedAt = snapSamples.find((s) => s.location === startLocation)
    const finalSnap = snapSamples[snapSamples.length - 1]
    expect(
      revertedAt,
      `After auto-advance the EPUB location must not flip back to the start ` +
        `view at any point during the next 2.5 s. ` +
        `startLocation='${startLocation}'. ` +
        `Reversion detected at t=${revertedAt?.t}ms ` +
        `(active='${revertedAt?.activeIndex}'). ` +
        `Final at t=${finalSnap.t}ms: location='${finalSnap.location}' ` +
        `active='${finalSnap.activeIndex}'. ` +
        `This is the snap-back regression: the page advances, then an ` +
        `unvalidated publish path resets currentParagraphs (and therefore ` +
        `the highlight) back to the OLD view.`
    ).toBeUndefined()

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  // ---------------------------------------------------------------------
  // Phase 3.4 acceptance gate — the loop-back bug class.
  //
  // Scenario the user reported: TTS reaches the last paragraph of view A
  // and triggers a page nav that DOESN'T actually advance the rendition
  // (end of book, drift restore, image-only page, transient epubjs error).
  // A republish-without-validation path used to land playback on
  // paragraph 0 of view A. The structural fix: the view actor's
  // same-locator / empty-paragraphs check emits NAV_NO_PROGRESS; the
  // machine transitions to `stopped` instead of looping.
  //
  // This test simulates that exact path by sending PAGE_NAVIGATING followed
  // by NAV_NO_PROGRESS directly into the actor — exercising the integration
  // surface that the view actor hits today.
  // ---------------------------------------------------------------------
  test('PAGE_NAVIGATING + NAV_NO_PROGRESS lands in stopped with cleared highlight (no loop-back)', async () => {
    test.setTimeout(60_000)
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS NAV_NO_PROGRESS'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)
    await installMockTts(bookPage)

    const startSnap = await readPlayerSnapshot(bookPage)
    expect(
      startSnap.paragraphs.length,
      'fixture must publish paragraphs before the test runs'
    ).toBeGreaterThan(0)

    await sendPlayerEvent(bookPage, 'PLAY')
    await waitForPlayerState(bookPage, 'playing', 8000)

    // Send PAGE_NAVIGATING (the navStore→player bridge emits this when the
    // rendition starts curling) followed immediately by NAV_NO_PROGRESS
    // (which the view actor emits when the new view matches the old or is
    // empty).
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => { send: ((e: Record<string, unknown>) => void) | null }
          }
        }
      }
      const send = w.__rishi.playerStore.getState().send
      if (!send) throw new Error('playerStore.send is null')
      send({ type: 'PAGE_NAVIGATING', direction: 'forward' })
      send({ type: 'NAV_NO_PROGRESS', reason: 'no-relocation' })
    })

    await waitForPlayerState(bookPage, 'stopped', 5000)

    // The visible highlight must be cleared — without this, the OLD view's
    // paragraph would remain highlighted post-no-progress, which would also
    // contradict the "no loop-back" guarantee.
    const activeAfter = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => { activeParagraph: { index: string } | null }
          }
        }
      }
      return w.__rishi.playerStore.getState().activeParagraph
    })
    expect(
      activeAfter,
      'On NAV_NO_PROGRESS the active highlight must clear — a residual ' +
        "highlight means the OLD view's paragraph 0 was about to be played."
    ).toBeNull()

    // Teardown
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  // ---------------------------------------------------------------------
  // Phase 3.4 acceptance gate — manual NEXT path (smoke-reproducible bug).
  //
  // User scenario: open EPUB, advance to the LAST paragraph on the visible
  // view, press the TTS Next button. The player should:
  //   1. cross to the next view (EPUB location advances), AND
  //   2. land on paragraph 0 of the new view (the highlight follows).
  //
  // This is the EXPLICIT NEXT-event path. The sibling "auto-advance" test
  // exercises the AUDIO_ENDED path; both eventually hit
  // `waitingForParagraphs`, but the manual NEXT entry has a different prior
  // transition (`playing → waitingForParagraphs` on the !hasMoreParagraphs
  // branch) and was reported by the user to still loop back to paragraph 0
  // of the OLD view after the Phase 3.4 fix landed for AUDIO_ENDED.
  //
  // The 2.5 s wait after pressing NEXT is deliberate: the historical bug
  // fires AFTER the new view's paragraphs initially land, when a same-view
  // republish overwrites the highlight back. Reading too early would
  // pass on the optimistic-update window and miss the regression.
  // ---------------------------------------------------------------------
  test('manual NEXT on last paragraph of a view advances to next view at paragraph 0 (no loop-back)', async () => {
    test.setTimeout(60_000)
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Manual NEXT Boundary'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)
    await installMockTts(bookPage)

    const startSnap = await readPlayerSnapshot(bookPage)
    const startLocation = startSnap.location
    const startCount = startSnap.paragraphs.length
    expect(
      startCount,
      'fixture must publish at least 2 paragraphs on the starting view ' +
        'so the test can step from paragraph 0 to the last paragraph'
    ).toBeGreaterThanOrEqual(2)

    // PLAY first so the boundary press happens from `playing`, matching the
    // user-gesture timing exactly (the user reported pressing NEXT during a
    // read-aloud session, not from idle).
    await sendPlayerEvent(bookPage, 'PLAY')
    await waitForPlayerState(bookPage, 'playing', 8000)

    // Step the active paragraph forward to the LAST one on the current view
    // by sending NEXT once per inter-paragraph gap. Between presses, wait
    // for the machine to settle into `playing` on the new index — otherwise
    // a NEXT issued during `loading` is ignored and the loop falls out of
    // sync with the actual paragraphIndex.
    for (let step = 0; step < startCount - 1; step++) {
      await sendPlayerEvent(bookPage, 'NEXT')
      await bookPage.waitForFunction(
        (target) => {
          const w = window as unknown as {
            __rishi: {
              playerStore: {
                getState: () => {
                  activeParagraph: { index: string } | null
                  currentParagraphs: { index: string }[]
                  playingState: string
                }
              }
            }
          }
          const s = w.__rishi.playerStore.getState()
          return (
            s.playingState === 'playing' &&
            s.activeParagraph?.index === s.currentParagraphs[target]?.index
          )
        },
        step + 1,
        { timeout: 10000 }
      )
    }

    // Sanity: we are positioned on the last paragraph of the start view and
    // the EPUB location has NOT changed yet.
    const beforeBoundary = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => {
              activeParagraph: { index: string } | null
              currentParagraphs: { index: string }[]
            }
          }
          epubStore: { getState: () => { currentEpubLocation: string } }
        }
      }
      const s = w.__rishi.playerStore.getState()
      return {
        activeIndex: s.activeParagraph?.index ?? null,
        lastIndex: s.currentParagraphs[s.currentParagraphs.length - 1]?.index ?? null,
        location: w.__rishi.epubStore.getState().currentEpubLocation
      }
    })
    expect(
      beforeBoundary.activeIndex,
      'before the boundary-crossing press, the active paragraph must be ' +
        'the last paragraph of the start view'
    ).toBe(beforeBoundary.lastIndex)
    expect(
      beforeBoundary.location,
      'before the boundary-crossing press, the EPUB location must still be ' +
        'the start view (no nav has happened yet)'
    ).toBe(startLocation)

    // The boundary-crossing press. From `playing` on the last paragraph this
    // takes the `!hasMoreParagraphs` branch:
    //   playing → waitingForParagraphs (direction='forward')
    //   → view actor NAVIGATE_NEXT
    //   → VIEW_CHANGED (good) or NAV_NO_PROGRESS (machine stops)
    await sendPlayerEvent(bookPage, 'NEXT')

    // Sample the player state for 2.5 s after the press at 100 ms ticks so
    // we can distinguish three failure modes the user could observe:
    //   (1) the EPUB location never changes (NAV_NO_PROGRESS or no view-
    //       actor response) — the page didn't turn at all.
    //   (2) the EPUB location flips to a new view, the highlight briefly
    //       lands on paragraph 0, then snaps back to a paragraph that is
    //       not on the visible view — the safety-net republish race.
    //   (3) the EPUB location flips and the highlight ends up on a
    //       paragraph that is NOT on the visible view — loop-back to an
    //       OLD view's paragraph.
    // The silent mock TTS auto-advances via AUDIO_ENDED every ~100 ms, so
    // the highlight can legitimately move off paragraph 0 during the
    // window. The bug we're catching is "highlight points to a paragraph
    // that is not in currentParagraphs" — that's loop-back regardless of
    // index. The "small delay" in the user's report exists to surface (2).
    type Sample = {
      t: number
      location: string
      activeIndex: string | null
      currentIndexes: string[]
      paragraphCount: number
      playingState: string
    }
    const samples: Sample[] = []
    const samplingStart = Date.now()
    while (Date.now() - samplingStart < 2500) {
      const sample = await bookPage.evaluate(() => {
        const w = window as unknown as {
          __rishi: {
            playerStore: {
              getState: () => {
                activeParagraph: { index: string } | null
                currentParagraphs: { index: string }[]
                playingState: string
              }
            }
            epubStore: { getState: () => { currentEpubLocation: string } }
          }
        }
        const s = w.__rishi.playerStore.getState()
        return {
          location: w.__rishi.epubStore.getState().currentEpubLocation,
          activeIndex: s.activeParagraph?.index ?? null,
          currentIndexes: s.currentParagraphs.map((p) => p.index),
          paragraphCount: s.currentParagraphs.length,
          playingState: s.playingState
        }
      })
      samples.push({ t: Date.now() - samplingStart, ...sample })
      await bookPage.waitForTimeout(100)
    }

    // Collapse samples to a state-change timeline. Each entry is a
    // transition (any field that changed from the previous row).
    const timeline: Sample[] = []
    for (const s of samples) {
      const prev = timeline[timeline.length - 1]
      if (
        !prev ||
        prev.location !== s.location ||
        prev.activeIndex !== s.activeIndex ||
        prev.paragraphCount !== s.paragraphCount ||
        prev.playingState !== s.playingState
      ) {
        timeline.push(s)
      }
    }
    const timelineStr = timeline
      .map(
        (s) =>
          `  t=${String(s.t).padStart(4, ' ')}ms  state=${s.playingState.padEnd(10)} ` +
          `loc=${s.location.slice(-32)} ` +
          `firstOfView=${(s.currentIndexes[0] ?? 'null').slice(-32)} ` +
          `active=${(s.activeIndex ?? 'null').slice(-32)}`
      )
      .join('\n')
    // Print the timeline so the next session can see it even when the
    // assertion message gets truncated by Playwright's afterAll-timeout
    // path.
    console.log('=== manual NEXT boundary timeline ===')
    console.log(`startLocation=${startLocation}`)
    console.log(timelineStr)
    console.log('=== end timeline ===')

    const final = samples[samples.length - 1]
    const afterBoundary = {
      location: final.location,
      activeIndex: final.activeIndex,
      firstOfViewIndex: final.currentIndexes[0] ?? null,
      paragraphCount: final.paragraphCount,
      playingState: final.playingState
    }

    // The highlight should follow the page. If the highlight ends up
    // pointing to a paragraph that is NOT in the current view's
    // currentParagraphs, the user is seeing a paragraph that is no longer
    // on screen — the loop-back / snap-back regression.
    const finalActiveOnVisibleView =
      final.activeIndex !== null && final.currentIndexes.includes(final.activeIndex)

    // Did the highlight ever cleanly anchor to paragraph 0 of the new view?
    // True even if the highlight later auto-advances — this guards
    // against "we never landed on paragraph 0 of the new view at all".
    const everAtNewViewIndexZero = samples.some(
      (s) =>
        s.location !== startLocation &&
        s.currentIndexes.length > 0 &&
        s.activeIndex === s.currentIndexes[0]
    )

    // Assertion 1: we are on a NEW page. The EPUB location string must
    // have advanced. If it didn't, either the view actor never navigated
    // or NAV_NO_PROGRESS landed the machine in `stopped` without crossing.
    expect(
      afterBoundary.location,
      `After NEXT at the last paragraph of the start view, the EPUB location ` +
        `must change. Got '${afterBoundary.location}' (start='${startLocation}'). ` +
        `If unchanged, either the view actor failed to navigate or ` +
        `NAV_NO_PROGRESS fired (playingState='${afterBoundary.playingState}').\n` +
        `Timeline:\n${timelineStr}`
    ).not.toBe(startLocation)
    expect(
      afterBoundary.paragraphCount,
      'the new view must publish at least one paragraph'
    ).toBeGreaterThan(0)

    // Assertion 2a: at the end of the sampling window the highlight must
    // be on a paragraph that IS in the currently-visible view. A
    // highlight pointing at a paragraph that isn't in currentParagraphs is
    // the loop-back / snap-back regression — the user sees the highlight
    // disappear from the visible page or, worse, jump back to the previous
    // view.
    expect(
      finalActiveOnVisibleView,
      `After NEXT crossed the view boundary, the active paragraph must be ` +
        `on the currently-visible view. ` +
        `Got: activeIndex='${final.activeIndex}', ` +
        `currentParagraphs.length=${final.paragraphCount}, ` +
        `activeIndex in currentParagraphs? ${finalActiveOnVisibleView}, ` +
        `playingState='${final.playingState}'.\n` +
        `Timeline:\n${timelineStr}`
    ).toBe(true)

    // Assertion 2b: the highlight must have anchored on paragraph 0 of
    // the new view at SOME point during the window. The view-actor
    // protocol's resetIndexByDirection always lands on index 0 on a
    // forward boundary; if this never happened, the machine bypassed
    // resetIndexByDirection — also a regression.
    expect(
      everAtNewViewIndexZero,
      `After NEXT crossed the view boundary, the highlight must anchor to ` +
        `paragraph 0 of the NEW view at least once. It never did during the ` +
        `2.5 s window — resetIndexByDirection on the forward boundary did not ` +
        `take effect.\n` +
        `Timeline:\n${timelineStr}`
    ).toBe(true)

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })

  // ---------------------------------------------------------------------
  // Regression: player PREV at the first paragraph must land on the LAST
  // paragraph of the previous page (not paragraph 0).
  //
  // Bug: the hook hardcoded `direction: 'forward'` in the PAGE_NAVIGATING
  // event fired when navState left 'idle'. The waitingForParagraphs →
  // pageNavigating transition called setNavDirection, which overwrote the
  // player's `direction='backward'` (set by setDirectionBackward on PREV)
  // with 'forward'. When the previous page's paragraphs arrived,
  // resetIndexByDirection saw direction='forward' and placed the player on
  // paragraph 0 instead of the last paragraph.
  //
  // Fixes (both applied):
  //   1. View actor: emit NAVIGATE_PREV when direction is 'backward'.
  //   2. State machine: waitingForParagraphs → pageNavigating preserves
  //      direction (no setNavDirection) so the player's intent survives a
  //      stale or wrong direction in the event.
  // ---------------------------------------------------------------------
  test('player PREV at first paragraph lands on last paragraph of previous page', async () => {
    test.setTimeout(60_000)
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Prev First Paragraph'
    })
    await closeOverlays(app.page)
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await waitForParagraphs(bookPage)
    await installMockTts(bookPage)

    // Step over to page 2 so a previous page exists. Use the EPUB next-page
    // arrow rather than player NEXT — we want a clean external nav, not a
    // player-driven page request.
    const startSnap = await readPlayerSnapshot(bookPage)
    await bookPage.locator('[aria-label="Next page"]').first().click()
    const page2Snap = await waitForLocationChange(bookPage, startSnap.location, 15000)
    expect(
      page2Snap.paragraphs.length,
      'page 2 must have paragraphs for this test'
    ).toBeGreaterThan(0)

    // Start playback on page 2. Wait for the player to actually reach
    // `playing` so the machine is in the right state when we send PREV.
    await sendPlayerEvent(bookPage, 'PLAY')
    await waitForPlayerState(bookPage, 'playing', 8000)

    // Verify the player is at paragraphIndex=0 (first paragraph of page 2)
    // so the PREV at boundary path is exercised.
    const beforePrev = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => {
              activeParagraph: { index: string } | null
              currentParagraphs: { index: string }[]
            }
          }
        }
      }
      const s = w.__rishi.playerStore.getState()
      return {
        activeIndex: s.activeParagraph?.index ?? null,
        firstIndex: s.currentParagraphs[0]?.index ?? null,
        currentCount: s.currentParagraphs.length
      }
    })
    expect(beforePrev.activeIndex).toBe(beforePrev.firstIndex)

    const page2FirstCfi = page2Snap.paragraphs[0]?.index
    expect(page2FirstCfi).toBeTruthy()

    // Click player PREV at the first paragraph of page 2. Player should
    // request the previous page and resume on its LAST paragraph.
    await sendPlayerEvent(bookPage, 'PREV')

    // Wait for the EPUB location to actually change (back to page 1).
    await waitForLocationChange(bookPage, page2Snap.location, 15000)

    // Player must reach `playing` on the previous page (proves auto-resume).
    await waitForPlayerState(bookPage, 'playing', 10000)

    // Verify the active paragraph is the LAST paragraph of the previous page,
    // not the first. The bug landed it on paragraph 0 — this assertion is
    // the precise regression check.
    const afterPrev = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __rishi: {
          playerStore: {
            getState: () => {
              activeParagraph: { index: string; text: string } | null
              currentParagraphs: { index: string; text: string }[]
            }
          }
        }
      }
      const s = w.__rishi.playerStore.getState()
      const last = s.currentParagraphs[s.currentParagraphs.length - 1] ?? null
      const first = s.currentParagraphs[0] ?? null
      return {
        activeIndex: s.activeParagraph?.index ?? null,
        activeText: s.activeParagraph?.text ?? null,
        firstIndex: first?.index ?? null,
        lastIndex: last?.index ?? null,
        currentCount: s.currentParagraphs.length
      }
    })

    expect(
      afterPrev.activeIndex,
      `After PREV at first paragraph, the active paragraph must be the LAST ` +
        `paragraph of the previous page. Got activeIndex='${afterPrev.activeIndex}', ` +
        `firstIndex='${afterPrev.firstIndex}', lastIndex='${afterPrev.lastIndex}'. ` +
        `If activeIndex matches firstIndex, the bug is present: the player landed ` +
        `on paragraph 0 of the previous page instead of its last paragraph.`
    ).toBe(afterPrev.lastIndex)

    // Defense in depth: when the page has > 1 paragraph, first and last
    // differ, so the assertion above is meaningful. Guard against fixtures
    // with single-paragraph pages where the test would pass vacuously.
    if (afterPrev.currentCount > 1) {
      expect(afterPrev.activeIndex).not.toBe(afterPrev.firstIndex)
    }

    // Teardown
    await sendPlayerEvent(bookPage, 'STOP')
    await bookPage.evaluate(() => {
      const w = window as unknown as { __rishi: { setTestTtsService: (s: null) => void } }
      w.__rishi.setTestTtsService(null)
    })
  })
})
