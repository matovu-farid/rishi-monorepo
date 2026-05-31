import type { Page } from '@playwright/test'

export interface SessionSnapshot {
  value: string | Record<string, unknown>
  context: {
    sessionId: string | null
    joinUrl?: string
    role: 'host' | 'viewer' | null
    sharerId: string | null
    reconnectToken?: string
    participants: Array<{
      userId: string
      displayName: string
      hasBookFile: boolean
      micState: string
      connectionState: string
    }>
    pendingJoiners: Array<{ userId: string; displayName: string }>
    approvalStatus: 'none' | 'awaiting' | 'approved' | 'rejected'
    lastSyncedPosition?: { pageIndex?: number }
  }
}

export async function readSessionSnapshot(page: Page): Promise<SessionSnapshot> {
  return await page.evaluate(() => {
    const w = window as unknown as {
      __rishi?: { sessionMachineStore: { getState: () => SessionSnapshot } }
    }
    if (!w.__rishi?.sessionMachineStore)
      throw new Error('window.__rishi.sessionMachineStore not exposed (Plan 2 prerequisite)')
    return w.__rishi.sessionMachineStore.getState()
  })
}

export async function waitForSessionState(
  page: Page,
  predicate: (value: string | Record<string, unknown>) => boolean,
  timeoutMs = 15_000
): Promise<SessionSnapshot> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    // eslint-disable-next-line no-await-in-loop -- Polling loop
    const snap = await readSessionSnapshot(page)
    if (predicate(snap.value)) return snap
    // eslint-disable-next-line no-await-in-loop -- Backoff
    await page.waitForTimeout(200)
  }
  const last = await readSessionSnapshot(page)
  throw new Error(`waitForSessionState timed out. Last value: ${JSON.stringify(last.value)}`)
}

export async function waitForBothLive(hostPage: Page, viewerPage: Page): Promise<void> {
  const isLive = (v: unknown): boolean =>
    typeof v === 'object' && v !== null && 'live' in (v as object)
  await Promise.all([
    waitForSessionState(hostPage, isLive),
    waitForSessionState(viewerPage, isLive)
  ])
}

export async function sendSessionEvent(
  page: Page,
  event: Record<string, unknown>
): Promise<void> {
  await page.evaluate((e) => {
    const w = window as unknown as {
      __rishi: { sessionMachineStore: { getState: () => { send: (ev: unknown) => void } } }
    }
    w.__rishi.sessionMachineStore.getState().send(e)
  }, event)
}

export async function readSyncedPageIndex(page: Page): Promise<number | null> {
  return await page.evaluate(() => {
    const w = window as unknown as {
      __rishi?: {
        sessionMachineStore: {
          getState: () => { context: { lastSyncedPosition?: { pageIndex?: number } } }
        }
      }
    }
    return (
      w.__rishi?.sessionMachineStore.getState().context.lastSyncedPosition?.pageIndex ?? null
    )
  })
}

export async function waitForSyncedPage(
  page: Page,
  pageIndex: number,
  timeoutMs = 15_000
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    // eslint-disable-next-line no-await-in-loop -- Polling
    const idx = await readSyncedPageIndex(page)
    if (idx === pageIndex) return
    // eslint-disable-next-line no-await-in-loop -- Backoff
    await page.waitForTimeout(200)
  }
  throw new Error(`waitForSyncedPage(${pageIndex}) timed out`)
}

export interface TestIdentity {
  userId: string
  displayName: string
}

/**
 * Build a test bearer token of the form `userId:DisplayName`. Recognised by
 * the worker's verifyAuth + SessionRoom WS handshake when the worker is
 * launched with `TEST_AUTH_ALLOWED=1` (see helpers/wrangler-dev.ts).
 */
export function testBearer(id: TestIdentity): string {
  return `${id.userId}:${id.displayName}`
}

/**
 * Decode the sessionId out of a join JWT. Worker-issued tokens are
 * `header.payload.sig` with payload = base64url(JSON({ sessionId, ... })).
 * Viewer flow needs the host's sessionId when calling `/redeem`.
 */
function sessionIdFromJoinToken(joinToken: string): string {
  const parts = joinToken.split('.')
  if (parts.length !== 3) throw new Error(`invalid join token: ${joinToken}`)
  const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/')
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4)
  const json = Buffer.from(padded, 'base64').toString('utf8')
  const payload = JSON.parse(json) as { sessionId?: string }
  if (!payload.sessionId) throw new Error('joinToken payload has no sessionId')
  return payload.sessionId
}

export async function hostCreateSession(
  hostPage: Page,
  opts: { requiresApproval: boolean; me?: TestIdentity } = { requiresApproval: false }
): Promise<string> {
  const me = opts.me ?? { userId: 'e2e-host', displayName: 'E2E Host' }
  await sendSessionEvent(hostPage, {
    type: 'CREATE_SESSION',
    me: { ...me, authToken: testBearer(me) },
    bookContext: { bookId: 'e2e-test-book', contentHash: 'abc123', format: 'pdf' },
    requiresApproval: opts.requiresApproval
  })
  await waitForSessionState(
    hostPage,
    (v) => {
      const s = typeof v === 'string' ? v : JSON.stringify(v)
      return s.includes('live') || s.includes('connecting')
    },
    20_000
  )
  return await hostPage.evaluate(() => {
    const w = window as unknown as {
      __rishi: { sessionMachineStore: { getState: () => { context: { joinUrl?: string } } } }
    }
    const url = w.__rishi.sessionMachineStore.getState().context.joinUrl
    if (!url) throw new Error('joinUrl not present after CREATE_SESSION')
    return url
  })
}

export function extractJoinToken(joinUrl: string): string {
  const u = new URL(joinUrl.replace('rishi://sharing/join', 'https://placeholder/join'))
  const t = u.searchParams.get('t')
  if (!t) throw new Error(`No t= param in join URL: ${joinUrl}`)
  return t
}

export async function viewerAcceptInvite(
  viewerPage: Page,
  joinToken: string,
  me: TestIdentity = { userId: 'e2e-viewer', displayName: 'E2E Viewer' }
): Promise<void> {
  await sendSessionEvent(viewerPage, {
    type: 'ACCEPT_INVITE',
    joinToken,
    sessionId: sessionIdFromJoinToken(joinToken),
    me: { ...me, authToken: testBearer(me) }
  })
}
