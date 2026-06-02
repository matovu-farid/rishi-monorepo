import { test, expect } from '@playwright/test'
import { launchAndOpenBookForSharing, closeApp, PDF_FIXTURE } from './helpers/electron-app'
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
      await hostCreateSession(host.page, {
        requiresApproval: true,
        me: { userId: 'host-a1', displayName: 'Host' }
      })
    )
    await viewerAcceptInvite(viewer.page, joinToken, {
      userId: 'viewer-a1',
      displayName: 'Viewer'
    })

    // awaitingApproval is now an internal substate of `connected` (so the
    // WS opens and the worker can queue the pending join). Accept either
    // the legacy top-level shape or the new nested `{ connected: 'awaitingApproval' }`.
    await waitForSessionState(
      viewer.page,
      (v) => {
        if (v === 'awaitingApproval') return true
        if (typeof v === 'object' && v !== null) {
          const inner = (v as { connected?: unknown }).connected
          if (inner === 'awaitingApproval') return true
        }
        return false
      },
      10_000
    )

    // The viewer reaching `awaitingApproval` only proves the worker queued the
    // join — the host still has to receive the `pendingJoiners` broadcast over
    // its WS. Poll the host's snapshot until that broadcast lands so we don't
    // race the WS round-trip.
    await expect
      .poll(async () => (await readSessionSnapshot(host.page)).context.pendingJoiners.length, {
        timeout: 10_000
      })
      .toBeGreaterThan(0)
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
      await hostCreateSession(host.page, {
        requiresApproval: true,
        me: { userId: 'host-a2', displayName: 'Host' }
      })
    )
    await viewerAcceptInvite(viewer.page, joinToken, {
      userId: 'viewer-a2',
      displayName: 'Viewer'
    })
    // awaitingApproval is now an internal substate of `connected` (so the
    // WS opens and the worker can queue the pending join). Accept either
    // the legacy top-level shape or the new nested `{ connected: 'awaitingApproval' }`.
    await waitForSessionState(
      viewer.page,
      (v) => {
        if (v === 'awaitingApproval') return true
        if (typeof v === 'object' && v !== null) {
          const inner = (v as { connected?: unknown }).connected
          if (inner === 'awaitingApproval') return true
        }
        return false
      },
      10_000
    )

    await sendSessionEvent(host.page, { type: 'REJECT_JOIN', userId: 'viewer-a2' })

    await waitForSessionState(
      viewer.page,
      (v) => v === 'failed' || (typeof v === 'object' && v !== null && 'failed' in (v as object)),
      10_000
    )
    const snap = await readSessionSnapshot(viewer.page)
    expect(snap.context.approvalStatus).toBe('rejected')
  } finally {
    await closeApp(host)
    await closeApp(viewer)
  }
})
