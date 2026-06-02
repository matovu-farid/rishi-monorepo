import { test, expect } from '@playwright/test'
import { launchAndOpenBookForSharing, closeApp, PDF_FIXTURE } from './helpers/electron-app'
import { readWranglerDevUrl } from './helpers/wrangler-dev'
import {
  waitForBothLive,
  hostCreateSession,
  viewerAcceptInvite,
  extractJoinToken,
  sendSessionEvent
} from './helpers/sharing-helpers'

test('request.sharer rate-limit: second request within 15s receives rate_limited error', async () => {
  const workerUrl = readWranglerDevUrl()
  const host = await launchAndOpenBookForSharing({
    workerUrl,
    userId: 'host-rl1',
    displayName: 'Host',
    fixturePath: PDF_FIXTURE,
    kind: 'pdf'
  })
  const viewer = await launchAndOpenBookForSharing({
    workerUrl,
    userId: 'viewer-rl1',
    displayName: 'Viewer',
    fixturePath: PDF_FIXTURE,
    kind: 'pdf'
  })
  try {
    const joinToken = extractJoinToken(
      await hostCreateSession(host.page, { requiresApproval: false })
    )
    await viewerAcceptInvite(viewer.page, joinToken)
    await waitForBothLive(host.page, viewer.page)

    // Capture DO errors via signalingActor test hook (Plan 2 prerequisite P4).
    const errors: string[] = []
    await viewer.page.exposeFunction('__captureSharerError', (code: string) => {
      errors.push(code)
    })
    await viewer.page.evaluate(() => {
      const w = window as unknown as {
        __rishi: { signalingTestHook?: { onError: (cb: (code: string) => void) => void } }
      }
      if (!w.__rishi.signalingTestHook)
        throw new Error('signalingTestHook not exposed (Plan 2 prerequisite P4)')
      w.__rishi.signalingTestHook.onError((code: string) => {
        ;(window as unknown as { __captureSharerError: (c: string) => void }).__captureSharerError(
          code
        )
      })
    })

    // First request — should pass silently (host gets notified).
    await sendSessionEvent(viewer.page, { type: 'REQUEST_SHARER' })
    await viewer.page.waitForTimeout(300)

    // Second request within the 15s cooldown — DO returns rate_limited.
    await sendSessionEvent(viewer.page, { type: 'REQUEST_SHARER' })
    await viewer.page.waitForTimeout(1000)

    expect(errors).toContain('rate_limited')
  } finally {
    await closeApp(host)
    await closeApp(viewer)
  }
})
