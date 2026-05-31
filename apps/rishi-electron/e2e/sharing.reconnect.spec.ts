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
  waitForSessionState,
  hostCreateSession,
  viewerAcceptInvite,
  extractJoinToken,
  readSessionSnapshot
} from './helpers/sharing-helpers'

test('viewer WS drop → reconnecting → seamless rejoin within 30s grace', async () => {
  const workerUrl = readWranglerDevUrl()
  const host = await launchAppWithSharingEnv({
    workerUrl,
    userId: 'host-r1',
    displayName: 'Host'
  })
  const viewer = await launchAppWithSharingEnv({
    workerUrl,
    userId: 'viewer-r1',
    displayName: 'Viewer'
  })
  try {
    const hBook = (await importBook(host.page, { fixturePath: PDF_FIXTURE, kind: 'pdf' })).id
    const vBook = (await importBook(viewer.page, { fixturePath: PDF_FIXTURE, kind: 'pdf' })).id
    await openBook(host.page, hBook)
    await openBook(viewer.page, vBook)
    await host.page.waitForTimeout(1000)
    await viewer.page.waitForTimeout(1000)

    const joinToken = extractJoinToken(
      await hostCreateSession(host.page, { requiresApproval: false })
    )
    await viewerAcceptInvite(viewer.page, joinToken)
    await waitForBothLive(host.page, viewer.page)

    // Force-disconnect via test hook exposed by signalingActor (Plan 2 prerequisite P4).
    await viewer.page.evaluate(() => {
      const w = window as unknown as {
        __rishi: { signalingTestHook?: { forceDisconnect: () => void } }
      }
      if (!w.__rishi.signalingTestHook)
        throw new Error('signalingTestHook not exposed (Plan 2 prerequisite P4)')
      w.__rishi.signalingTestHook.forceDisconnect()
    })

    // Viewer enters reconnecting.
    await waitForSessionState(
      viewer.page,
      (v) =>
        (typeof v === 'string' && v === 'reconnecting') ||
        (typeof v === 'object' && v !== null && 'reconnecting' in (v as object)),
      10_000
    )

    // reconnectActor brings viewer back to live via exponential backoff (max 8s + network).
    await waitForSessionState(
      viewer.page,
      (v) => typeof v === 'object' && v !== null && 'live' in (v as object),
      35_000
    )

    // Host still shows viewer as connected in the roster.
    const hostSnap = await readSessionSnapshot(host.page)
    const viewerEntry = hostSnap.context.participants.find((p) => p.userId === 'viewer-r1')
    expect(viewerEntry).toBeDefined()
    expect(viewerEntry!.connectionState).toBe('connected')
  } finally {
    await closeApp(host)
    await closeApp(viewer)
  }
})
