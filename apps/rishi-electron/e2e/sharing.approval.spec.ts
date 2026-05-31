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
  readSessionSnapshot,
  sendSessionEvent
} from './helpers/sharing-helpers'

test('requiresApproval: viewer queued → host approves → both live', async () => {
  const workerUrl = readWranglerDevUrl()
  const host = await launchAppWithSharingEnv({
    workerUrl,
    userId: 'host-a1',
    displayName: 'Host'
  })
  const viewer = await launchAppWithSharingEnv({
    workerUrl,
    userId: 'viewer-a1',
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
  const host = await launchAppWithSharingEnv({
    workerUrl,
    userId: 'host-a2',
    displayName: 'Host'
  })
  const viewer = await launchAppWithSharingEnv({
    workerUrl,
    userId: 'viewer-a2',
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
