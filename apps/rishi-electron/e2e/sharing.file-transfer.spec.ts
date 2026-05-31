import { test, expect } from '@playwright/test'
import {
  launchAppWithSharingEnv,
  closeApp,
  importBook,
  openBook,
  PDF_FIXTURE
} from './helpers/electron-app'
import { readWranglerDevUrl } from './helpers/wrangler-dev'
import {
  waitForBothLive,
  hostCreateSession,
  viewerAcceptInvite,
  extractJoinToken,
  readSessionSnapshot
} from './helpers/sharing-helpers'

// Cross-process data-channel relay (task #99) is now in place: the fake
// RTC adapter routes `dataChannel.send()` through the worker's
// `data.channel.relay` ServerMsg. Remaining caveats are product-side
// (sessionMachine doesn't yet invoke fileTransferActor on hello-with
// hasBookFile=false on the host side), so this test may still fail with
// `fileTransferProgress.completed` never going true.
test('viewer without book receives P2P file transfer and sync follows', async () => {
  const workerUrl = readWranglerDevUrl()
  // Host has the book; viewer does NOT import it.
  const host = await launchAppWithSharingEnv({
    workerUrl,
    userId: 'host-ft1',
    displayName: 'Host'
  })
  const viewer = await launchAppWithSharingEnv({
    workerUrl,
    userId: 'viewer-ft1',
    displayName: 'Viewer'
  })
  try {
    const hBook = (
      await importBook(host.page, {
        fixturePath: PDF_FIXTURE,
        kind: 'pdf',
        title: 'FT Test Book'
      })
    ).id
    await openBook(host.page, hBook)
    await host.page.waitForTimeout(1000)

    // Viewer does NOT open a book — they have no local copy.

    const joinToken = extractJoinToken(
      await hostCreateSession(host.page, { requiresApproval: false })
    )

    // viewerAcceptInvite triggers ACCEPT_INVITE; Plan 2 detects no local book via
    // sharing:hasBookFile IPC, sends hasBookFile=false in the hello message, which
    // triggers fileTransferActor on the host side over the RTCDataChannel.
    await viewerAcceptInvite(viewer.page, joinToken)
    await waitForBothLive(host.page, viewer.page)

    // Wait for fileTransferProgress.completed = true (Plan 2 prerequisite P5).
    // Timeout is 60s because a real PDF over WebRTC data channel takes time.
    await viewer.page.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi?: { fileTransferProgress?: { completed: boolean } }
        }
        return w.__rishi?.fileTransferProgress?.completed === true
      },
      undefined,
      { timeout: 60_000 }
    )

    // After transfer, IPC sharing:saveTransferredBook wrote the file; getBooks should list it.
    const books = await viewer.page.evaluate(async () => {
      const e = (window as unknown as { electron: { getBooks: () => Promise<{ title: string }[]> } })
        .electron
      return await e.getBooks()
    })
    expect(books.some((b) => b.title === 'FT Test Book')).toBe(true)

    // hasBookFile should now be true in the roster.
    const snap = await readSessionSnapshot(viewer.page)
    const self = snap.context.participants.find((p) => p.userId === 'viewer-ft1')
    expect(self?.hasBookFile).toBe(true)
  } finally {
    await closeApp(host)
    await closeApp(viewer)
  }
})
