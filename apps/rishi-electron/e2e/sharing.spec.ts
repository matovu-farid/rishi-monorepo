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
  sendSessionEvent,
  waitForSyncedPage
} from './helpers/sharing-helpers'

test.describe('Shared reading — happy path', () => {
  test('host creates session, viewer joins, both reach live', async () => {
    const workerUrl = readWranglerDevUrl()
    const host = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'host-1',
      displayName: 'Host User',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    const viewer = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'viewer-1',
      displayName: 'Viewer User',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    try {
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
    const host = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'host-2',
      displayName: 'Host',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    const viewer = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'viewer-2',
      displayName: 'Viewer',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    try {
      const joinToken = extractJoinToken(
        await hostCreateSession(host.page, {
          requiresApproval: false,
          me: { userId: 'host-2', displayName: 'Host' }
        })
      )
      await viewerAcceptInvite(viewer.page, joinToken, {
        userId: 'viewer-2',
        displayName: 'Viewer'
      })
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
    const host = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'host-3',
      displayName: 'Host',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    const viewer = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'viewer-3',
      displayName: 'Viewer',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    try {
      const joinToken = extractJoinToken(
        await hostCreateSession(host.page, {
          requiresApproval: false,
          me: { userId: 'host-3', displayName: 'Host' }
        })
      )
      await viewerAcceptInvite(viewer.page, joinToken, {
        userId: 'viewer-3',
        displayName: 'Viewer'
      })
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
    const host = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'host-4',
      displayName: 'Host',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    const viewer = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'viewer-4',
      displayName: 'Viewer',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    try {
      const joinToken = extractJoinToken(
        await hostCreateSession(host.page, {
          requiresApproval: false,
          me: { userId: 'host-4', displayName: 'Host' }
        })
      )
      await viewerAcceptInvite(viewer.page, joinToken, {
        userId: 'viewer-4',
        displayName: 'Viewer'
      })
      await waitForBothLive(host.page, viewer.page)

      await sendSessionEvent(host.page, { type: 'KICK_PEER', userId: 'viewer-4' })

      await waitForSessionState(
        viewer.page,
        (v) =>
          v === 'idle' ||
          v === 'failed' ||
          v === 'ending' ||
          (typeof v === 'object' && v !== null && 'failed' in (v as object)),
        10_000
      )
    } finally {
      await closeApp(host)
      await closeApp(viewer)
    }
  })

  test('host window closes → viewer sees HostSuspendedBanner; host reopens → session resumes', async () => {
    const workerUrl = readWranglerDevUrl()
    const host = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'host-5',
      displayName: 'Host',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    const viewer = await launchAndOpenBookForSharing({
      workerUrl,
      userId: 'viewer-5',
      displayName: 'Viewer',
      fixturePath: PDF_FIXTURE,
      kind: 'pdf'
    })
    let hostReborn: Awaited<ReturnType<typeof launchAndOpenBookForSharing>> | null = null
    try {
      const joinToken = extractJoinToken(
        await hostCreateSession(host.page, {
          requiresApproval: false,
          me: { userId: 'host-5', displayName: 'Host' }
        })
      )
      await viewerAcceptInvite(viewer.page, joinToken, {
        userId: 'viewer-5',
        displayName: 'Viewer'
      })
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

      // Kill host app abruptly. Use SIGKILL directly (rather than
      // `app.close()`) because the host's auto-updater + persistent
      // WebSocket can keep the Electron event loop open well past the
      // 120s test budget. SIGKILL closes the WS instantly, which is
      // exactly the "host crashed" semantics this test is exercising.
      try {
        const proc = host.app.process()
        if (proc && !proc.killed) proc.kill('SIGKILL')
      } catch {
        /* already gone */
      }
      // Give the worker a beat to observe the WS drop and broadcast
      // host.suspended before the viewer checks the banner.
      await viewer.page.waitForTimeout(500)

      // Viewer should see the HostSuspendedBanner within 10s.
      await expect(viewer.page.locator('[data-testid="host-suspended-banner"]')).toBeVisible({
        timeout: 10_000
      })

      // Relaunch host (same userId so reconnectToken is valid). The reborn
      // host needs a reader window open so its sessionMachine actor is
      // registered for the RECONNECT_SESSION event below.
      hostReborn = await launchAndOpenBookForSharing({
        workerUrl,
        userId: 'host-5',
        displayName: 'Host',
        fixturePath: PDF_FIXTURE,
        kind: 'pdf'
      })

      // Provide `me` so the WS handshake uses the same `host-5` bearer as
      // the original host; the worker's reconnectToken is keyed by userId.
      // wsUrl must be supplied — the reborn process has no prior context
      // for it.
      const wsUrl = workerUrl.replace(/^http/, 'ws') + `/v1/sessions/${sessionId}/wss`
      await sendSessionEvent(hostReborn.page, {
        type: 'RECONNECT_SESSION',
        sessionId,
        reconnectToken,
        wsUrl,
        me: {
          userId: 'host-5',
          displayName: 'Host',
          authToken: 'host-5--Host'
        }
      })
      await waitForSessionState(
        hostReborn.page,
        (v) => {
          if (typeof v !== 'object' || v === null) return false
          if ('live' in (v as object)) return true
          const inner = (v as { connected?: unknown }).connected
          return typeof inner === 'object' && inner !== null && 'live' in (inner as object)
        },
        25_000
      )

      // Banner should clear on viewer side.
      await expect(viewer.page.locator('[data-testid="host-suspended-banner"]')).not.toBeVisible({
        timeout: 10_000
      })
    } finally {
      if (hostReborn) await closeApp(hostReborn)
      else {
        // Host was already SIGKILL'd above; this is a defensive fallback in
        // case we never reached the kill step. Bound at 2s.
        await Promise.race([
          host.app.close().catch(() => {}),
          new Promise<void>((resolve) => setTimeout(resolve, 2_000))
        ])
        try {
          const proc = host.app.process()
          if (proc && !proc.killed) proc.kill('SIGKILL')
        } catch {
          /* gone */
        }
      }
      await closeApp(viewer)
    }
  })
})
