import type { Page } from '@playwright/test'

export interface ParagraphSnapshot {
  location: string
  paragraphs: { text: string; index: string }[]
}

export async function readPlayerSnapshot(page: Page): Promise<ParagraphSnapshot> {
  return await page.evaluate(() => {
    const w = window as unknown as {
      __rishi?: {
        playerStore: { getState: () => { currentParagraphs: { text: string; index: string }[] } }
        epubStore: { getState: () => { currentEpubLocation: string } }
      }
    }
    if (!w.__rishi) throw new Error('window.__rishi not exposed')
    return {
      location: w.__rishi.epubStore.getState().currentEpubLocation,
      paragraphs: w.__rishi.playerStore.getState().currentParagraphs.map((p) => ({
        text: p.text,
        index: p.index
      }))
    }
  })
}

export async function waitForParagraphs(page: Page, timeout = 15000): Promise<void> {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    // eslint-disable-next-line no-await-in-loop -- Polling for the EPUB to settle and publish paragraphs.
    const snap = await readPlayerSnapshot(page)
    if (snap.paragraphs.length > 0 && snap.location) return
    // eslint-disable-next-line no-await-in-loop -- Backoff between polls.
    await page.waitForTimeout(150)
  }
  throw new Error(`No paragraphs/location published within ${timeout}ms`)
}

export async function waitForLocationChange(
  page: Page,
  previousLocation: string,
  timeout = 10000
): Promise<ParagraphSnapshot> {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    // eslint-disable-next-line no-await-in-loop -- Polling for the EPUB CFI to advance after page navigation.
    const snap = await readPlayerSnapshot(page)
    if (snap.location && snap.location !== previousLocation && snap.paragraphs.length > 0) {
      return snap
    }
    // eslint-disable-next-line no-await-in-loop -- Backoff between polls.
    await page.waitForTimeout(150)
  }
  throw new Error(`Location did not change from ${previousLocation} within ${timeout}ms`)
}

export async function sendPlayerEvent(page: Page, type: string): Promise<void> {
  await page.evaluate((t) => {
    const w = window as unknown as {
      __rishi: { playerStore: { getState: () => { send: ((e: { type: string }) => void) | null } } }
    }
    const send = w.__rishi.playerStore.getState().send
    if (!send) throw new Error(`playerStore.send is null when dispatching ${t}`)
    send({ type: t })
  }, type)
}

export async function waitForPlayerState(
  page: Page,
  expected: string,
  timeout = 5000
): Promise<void> {
  await page.waitForFunction(
    (e) => {
      const w = window as unknown as {
        __rishi: { playerStore: { getState: () => { playingState: string } } }
      }
      return w.__rishi.playerStore.getState().playingState === e
    },
    expected,
    { timeout }
  )
}

/**
 * Waits for the player machine to wire up — `playerStore.getState().send`
 * is `null` until the `usePlayerMachine` hook runs and registers the actor.
 * Tests that dispatch events must wait on this before calling
 * `sendPlayerEvent`, otherwise the dispatch throws.
 */
export async function waitForPlayerSendReady(page: Page, timeout = 10000): Promise<void> {
  await page.waitForFunction(
    () => {
      const w = window as unknown as {
        __rishi?: { playerStore: { getState: () => { send: unknown } } }
      }
      return !!w.__rishi && typeof w.__rishi.playerStore.getState().send === 'function'
    },
    undefined,
    { timeout }
  )
}

export async function installSilentMockTts(page: Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as {
      __rishi: { setTestTtsService: (s: unknown) => void }
      __rishiTtsLog?: Array<{ cfiRange: string; text: string; priority: number }>
    }
    w.__rishiTtsLog = []
    // Build a 100 ms silent WAV (44-byte header + 800 bytes silence). The
    // header-only form does not reach `canplaythrough`, so playback never
    // starts in tests.
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
    const wav = u8
    const noop = (): void => {}
    w.__rishi.setTestTtsService({
      requestAudio: async (req: {
        bookId: string
        cfiRange: string
        text: string
        priority?: number
      }) => {
        w.__rishiTtsLog!.push({
          cfiRange: req.cfiRange,
          text: req.text,
          priority: req.priority ?? 0
        })
        return URL.createObjectURL(new Blob([wav], { type: 'audio/wav' }))
      },
      cancelRequest: () => true,
      cancelBookRequests: noop,
      clearBookCache: async () => {},
      getQueueStatus: () => ({ pending: 0, isProcessing: false, active: 0 }),
      onAudioReady: () => noop,
      onError: () => noop
    })
  })
}

export async function clearTtsLog(page: Page): Promise<void> {
  await page.evaluate(() => {
    ;(window as unknown as { __rishiTtsLog: unknown[] }).__rishiTtsLog = []
  })
}

export async function readTtsLog(
  page: Page
): Promise<Array<{ cfiRange: string; text: string; priority: number }>> {
  return await page.evaluate(() => {
    return (
      window as unknown as {
        __rishiTtsLog: Array<{ cfiRange: string; text: string; priority: number }>
      }
    ).__rishiTtsLog
  })
}
