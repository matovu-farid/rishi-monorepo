import { test, expect } from '@playwright/test'
import {
  launchAndOpenBookForSharing,
  closeApp,
  PDF_FIXTURE
} from './helpers/electron-app'
import { readWranglerDevUrl } from './helpers/wrangler-dev'
import {
  waitForBothLive,
  waitForSessionState,
  hostCreateSession,
  viewerAcceptInvite,
  extractJoinToken,
  readSessionSnapshot,
  sendSessionEvent
} from './helpers/sharing-helpers'

test('requiresApproval: viewer queued → host approves → both live', async () => {
  const workerUrl = readWranglerDevUrl()
  const host = await launchAndOpenBookForSharing({
    workerUrl,
    userId: 'host-a1',
    displayName: 'Host',
    fixturePath: PDF_FIXTURE,
    kind: 'pdf'
  })
  const viewer = await launchAndOpenBookForSharing({
    workerUrl,
    userId: 'viewer-a1',
    displayName: 'Viewer',
    fixturePath: PDF_FIXTURE,
    kind: 'pdf'
  })
  try {
    const joinToken = extractJoinToken(
      await hostCreateSession(host.page, { requiresApproval: true })
    )
    await viewerAcceptInvite(viewer.page, joinToken)

    await waitForSessionState(viewer.page, (v) => v === 'awaitingApproval', 10_000)

    const hostSnap = await readSessionSnapshot(host.page)
    expect(hostSnap.context.pendingJoiners.length).toBeGreaterThan(0)

    await sendSessionEvent(host.page, { type: 'APPROVE_JOIN', userId: 'viewer-a1' })
    await waitForBothLive(host.page, viewer.page)

    const finalSnap = await readSessionSnapshot(host.page)
    expect(finalSnap.context.participants).toHaveLength(2)
  } finally {
    await closeApp(host)
    await closeApp(viewer)
  }
})

test('requiresApproval: host rejects → viewer reaches failed', async () => {
  const workerUrl = readWranglerDevUrl()
  const host = await launchAndOpenBookForSharing({
    workerUrl,
    userId: 'host-a2',
    displayName: 'Host',
    fixturePath: PDF_FIXTURE,
    kind: 'pdf'
  })
  const viewer = await launchAndOpenBookForSharing({
    workerUrl,
    userId: 'viewer-a2',
    displayName: 'Viewer',
    fixturePath: PDF_FIXTURE,
    kind: 'pdf'
  })
  try {
    const joinToken = extractJoinToken(
      await hostCreateSession(host.page, { requiresApproval: true })
    )
    await viewerAcceptInvite(viewer.page, joinToken)
    await waitForSessionState(viewer.page, (v) => v === 'awaitingApproval', 10_000)

    await sendSessionEvent(host.page, { type: 'REJECT_JOIN', userId: 'viewer-a2' })

    await waitForSessionState(
      viewer.page,
      (v) => typeof v === 'object' && v !== null && 'failed' in (v as object),
      10_000
    )
    const snap = await readSessionSnapshot(viewer.page)
    expect(snap.context.approvalStatus).toBe('rejected')
  } finally {
    await closeApp(host)
    await closeApp(viewer)
  }
})
