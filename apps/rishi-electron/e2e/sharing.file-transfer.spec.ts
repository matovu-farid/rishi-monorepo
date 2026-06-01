import { test, expect } from '@playwright/test'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
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
  installFakeRtcAdapter,
  readSessionSnapshot
} from './helpers/sharing-helpers'

// Cross-process data-channel relay (task #99) + sessionMachine peer/transfer
// wiring (task #107) are now in place: host spawns a sender fileTransferActor
// on PEER_CONNECTED for any peer missing the book, viewer spawns a receiver
// + saves the assembled blob to disk + reports hasBookFile=true to the worker.
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
    // Compute the real SHA-256 of the fixture and stamp it onto the host's
    // book row so `findBookByHash` resolves it inside the readBookBytes IPC.
    const contentHash = createHash('sha256').update(readFileSync(PDF_FIXTURE)).digest('hex')
    await host.page.evaluate(
      async ({ bookId, hash }) => {
        const e = window.electron as unknown as {
          booksUpdateFileHash: (id: number, h: string, k: string) => Promise<void>
        }
        await e.booksUpdateFileHash(bookId, hash, '')
      },
      { bookId: hBook, hash: contentHash }
    )
    // Switch the host page to the reader window. The library page can't
    // POST to the worker because the worker has no CORS for the library's
    // 127.0.0.1:* origin; the reader window's local-file origin can
    // because of the CSP allowance in the production build.
    const hostReader = await openBook(host.page, hBook)
    await hostReader.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi?: { sessionMachineStore?: { getState: () => unknown } }
        }
        return w.__rishi?.sessionMachineStore?.getState?.() != null
      },
      null,
      { timeout: 15_000, polling: 200 }
    )

    // The viewer doesn't have the target book — but the library page can't
    // POST /redeem to the worker (no CORS). Import a tiny throw-away book
    // on the viewer side just so a reader window mounts; that window's
    // local-file origin can hit the worker. The "no local copy of the
    // shared book" semantics is captured by hasBookFile=false on
    // ACCEPT_INVITE (the viewer doesn't have the shared book's
    // contentHash on disk).
    const vBook = (
      await importBook(viewer.page, {
        fixturePath: PDF_FIXTURE,
        kind: 'pdf',
        title: 'Viewer Placeholder'
      })
    ).id
    const viewerReader = await openBook(viewer.page, vBook)
    await viewerReader.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi?: { sessionMachineStore?: { getState: () => unknown } }
        }
        return w.__rishi?.sessionMachineStore?.getState?.() != null
      },
      null,
      { timeout: 15_000, polling: 200 }
    )

    // Install the fake RTC adapter on both renderers so peerActor never tries
    // to open real UDP sockets in headless Electron, AND so the data-channel
    // bus is set up to shuttle payloads across the two processes through the
    // worker's data.channel.relay path.
    await installFakeRtcAdapter(hostReader)
    await installFakeRtcAdapter(viewerReader)

    const joinToken = extractJoinToken(
      await hostCreateSession(hostReader, {
        requiresApproval: false,
        me: { userId: 'host-ft1', displayName: 'Host' },
        bookContext: { bookId: String(hBook), contentHash, format: 'pdf' }
      })
    )

    // viewerAcceptInvite triggers ACCEPT_INVITE; the viewer reports
    // hasBookFile=false in the hello message, the host spawns a
    // hostFileSender on PEER_CONNECTED, viewer spawns a viewerFileReceiver,
    // bytes flow over the (fake) `files` data channel.
    await viewerAcceptInvite(viewerReader, joinToken, {
      userId: 'viewer-ft1', displayName: 'Viewer'
    })
    await waitForBothLive(hostReader, viewerReader)

    // Wait for fileTransferProgress.completed = true (Plan 2 prerequisite P5).
    // Timeout is 60s because a real PDF over WebRTC data channel takes time.
    await viewerReader.waitForFunction(
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
    // The viewer-side receiver labels the book with the sender's display name
    // ("Host's book") because the BookContext schema doesn't carry a title;
    // we just assert that a freshly-saved book appears in the library.
    // Allow the post-transfer IPC chain (saveTransferredBook → BOOK_RECEIVED →
    // REPORT_HAS_BOOK) a moment to settle before we poll the library.
    await viewerReader.waitForFunction(
      async () => {
        const e = (window as unknown as {
          electron: { getBooks: () => Promise<Array<{ title: string }>> }
        }).electron
        const list = await e.getBooks()
        return list.length >= 2
      },
      null,
      { timeout: 15_000, polling: 250 }
    )
    const books = await viewerReader.evaluate(async () => {
      const e = (window as unknown as {
        electron: { getBooks: () => Promise<Array<{ title: string; file_hash?: string | null }>> }
      }).electron
      return await e.getBooks()
    })
    expect(books.length).toBeGreaterThanOrEqual(2)

    // hasBookFile should now be true in the roster.
    const snap = await readSessionSnapshot(viewerReader)
    const self = snap.context.participants.find((p) => p.userId === 'viewer-ft1')
    expect(self?.hasBookFile).toBe(true)
  } finally {
    await closeApp(host)
    await closeApp(viewer)
  }
})
