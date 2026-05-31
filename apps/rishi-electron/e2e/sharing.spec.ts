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
  sendSessionEvent,
  waitForSyncedPage
} from './helpers/sharing-helpers'

test.describe('Shared reading — happy path', () => {
  test('host creates session, viewer joins, both reach live', async () => {
    const workerUrl = readWranglerDevUrl()
    const host = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'host-1',
      displayName: 'Host User'
    })
    const viewer = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'viewer-1',
      displayName: 'Viewer User'
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

      const hostSnap = await readSessionSnapshot(host.page)
      const viewerSnap = await readSessionSnapshot(viewer.page)
      expect(hostSnap.context.participants).toHaveLength(2)
      expect(viewerSnap.context.participants).toHaveLength(2)
      expect(hostSnap.context.role).toBe('host')
      expect(viewerSnap.context.role).toBe('viewer')
    } finally {
      await closeApp(host)
      await closeApp(viewer)
    }
  })

  test('sharer page-turn propagates to viewer within 5s', async () => {
    const workerUrl = readWranglerDevUrl()
    const host = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'host-2',
      displayName: 'Host'
    })
    const viewer = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'viewer-2',
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

      // Sharer advances to page index 3 via the sessionMachine SHARER_POSITION_UPDATE event.
      await sendSessionEvent(host.page, { type: 'SHARER_POSITION_UPDATE', pageIndex: 3 })
      await waitForSyncedPage(viewer.page, 3, 5_000)
    } finally {
      await closeApp(host)
      await closeApp(viewer)
    }
  })

  test('host passes sharer role to viewer, sharerId updates on both sides', async () => {
    const workerUrl = readWranglerDevUrl()
    const host = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'host-3',
      displayName: 'Host'
    })
    const viewer = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'viewer-3',
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

      // Viewer reports it has the book so the DO allows pass.sharer.
      await sendSessionEvent(viewer.page, { type: 'REPORT_HAS_BOOK', value: true })
      await host.page.waitForTimeout(500)

      await sendSessionEvent(host.page, { type: 'PASS_SHARER', userId: 'viewer-3' })

      // Poll until both sides see the updated sharerId.
      const deadline = Date.now() + 10_000
      let hostSnap = await readSessionSnapshot(host.page)
      while (hostSnap.context.sharerId !== 'viewer-3' && Date.now() < deadline) {
        // eslint-disable-next-line no-await-in-loop -- Polling
        await host.page.waitForTimeout(300)
        // eslint-disable-next-line no-await-in-loop -- Polling
        hostSnap = await readSessionSnapshot(host.page)
      }
      expect(hostSnap.context.sharerId).toBe('viewer-3')

      const viewerSnap = await readSessionSnapshot(viewer.page)
      expect(viewerSnap.context.sharerId).toBe('viewer-3')
    } finally {
      await closeApp(host)
      await closeApp(viewer)
    }
  })

  test('host kicks viewer → viewer transitions to failed/idle', async () => {
    const workerUrl = readWranglerDevUrl()
    const host = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'host-4',
      displayName: 'Host'
    })
    const viewer = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'viewer-4',
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

      await sendSessionEvent(host.page, { type: 'KICK_PEER', userId: 'viewer-4' })

      await waitForSessionState(
        viewer.page,
        (v) => v === 'idle' || (typeof v === 'object' && v !== null && 'failed' in (v as object)),
        10_000
      )
    } finally {
      await closeApp(host)
      await closeApp(viewer)
    }
  })

  test('host window closes → viewer sees HostSuspendedBanner; host reopens → session resumes', async () => {
    const workerUrl = readWranglerDevUrl()
    const host = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'host-5',
      displayName: 'Host'
    })
    const viewer = await launchAppWithSharingEnv({
      workerUrl,
      userId: 'viewer-5',
      displayName: 'Viewer'
    })
    let hostReborn: Awaited<ReturnType<typeof launchAppWithSharingEnv>> | null = null
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

      const reconnectToken: string = await host.page.evaluate(() => {
        const w = window as unknown as {
          __rishi: {
            sessionMachineStore: { getState: () => { context: { reconnectToken: string } } }
          }
        }
        return w.__rishi.sessionMachineStore.getState().context.reconnectToken
      })
      const sessionId: string = await host.page.evaluate(() => {
        const w = window as unknown as {
          __rishi: { sessionMachineStore: { getState: () => { context: { sessionId: string } } } }
        }
        return w.__rishi.sessionMachineStore.getState().context.sessionId
      })

      // Kill host app abruptly.
      await host.app.close().catch(() => {})

      // Viewer should see the HostSuspendedBanner within 10s.
      await expect(viewer.page.locator('[data-testid="host-suspended-banner"]')).toBeVisible({
        timeout: 10_000
      })

      // Relaunch host (same userId so reconnectToken is valid).
      hostReborn = await launchAppWithSharingEnv({
        workerUrl,
        userId: 'host-5',
        displayName: 'Host'
      })

      await sendSessionEvent(hostReborn.page, {
        type: 'RECONNECT_SESSION',
        sessionId,
        reconnectToken
      })
      await waitForSessionState(
        hostReborn.page,
        (v) => typeof v === 'object' && v !== null && 'live' in (v as object),
        25_000
      )

      // Banner should clear on viewer side.
      await expect(viewer.page.locator('[data-testid="host-suspended-banner"]')).not.toBeVisible({
        timeout: 10_000
      })
    } finally {
      if (hostReborn) await closeApp(hostReborn)
      else await host.app.close().catch(() => {})
      await closeApp(viewer)
    }
  })
})
