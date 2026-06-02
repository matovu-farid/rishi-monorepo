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
    type RawSnap = {
      value: SessionSnapshot['value']
      context: Record<string, unknown> & {
        participants?: Map<string, unknown> | Array<unknown>
        pendingJoiners?: Map<string, unknown> | Array<unknown>
      }
    }
    const w = window as unknown as {
      __rishi?: { sessionMachineStore: { getState: () => RawSnap } }
    }
    if (!w.__rishi?.sessionMachineStore)
      throw new Error('window.__rishi.sessionMachineStore not exposed (Plan 2 prerequisite)')
    const raw = w.__rishi.sessionMachineStore.getState()
    // The session-machine context stores `participants` and `pendingJoiners` as
    // `Map<string, ...>`. Map instances are silently dropped by Playwright's
    // `page.evaluate` IPC serializer (which uses structured-clone semantics
    // and converts them to empty objects), so flatten them to plain arrays
    // here. Tests assert `.toHaveLength(...)` against these — without the
    // flatten step they always see length 0.
    const participants = raw?.context?.participants
    const pendingJoiners = raw?.context?.pendingJoiners
    const flattenedParticipants = participants instanceof Map
      ? Array.from(participants.values())
      : Array.isArray(participants) ? participants : []
    const flattenedPending = pendingJoiners instanceof Map
      ? Array.from(pendingJoiners.entries()).map(([userId, v]) => {
          const value = v as { profile?: { displayName?: string } }
          return { userId, displayName: value?.profile?.displayName ?? '' }
        })
      : Array.isArray(pendingJoiners) ? pendingJoiners : []
    return {
      value: raw.value,
      context: {
        ...raw.context,
        participants: flattenedParticipants,
        pendingJoiners: flattenedPending
      }
    } as unknown as SessionSnapshot
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
  // The session machine wraps connecting/live/reconnecting under a parent
  // `connected` state. Accept either the legacy top-level `{ live: ... }` shape
  // or the new wrapped `{ connected: { live: ... } }` shape.
  const isLive = (v: unknown): boolean => {
    if (typeof v !== 'object' || v === null) return false
    if ('live' in (v as object)) return true
    const inner = (v as { connected?: unknown }).connected
    return typeof inner === 'object' && inner !== null && 'live' in (inner as object)
  }
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
 * Build a test bearer token of the form `userId--DisplayName` (with `_`
 * replacing spaces in the display name). Recognised by the worker's
 * verifyAuth + SessionRoom WS handshake when the worker is launched with
 * `TEST_AUTH_ALLOWED=1` (see helpers/wrangler-dev.ts).
 *
 * The double-dash separator and underscore-for-space encoding keep the
 * bearer valid both as an HTTP Authorization header value AND as a
 * WebSocket subprotocol token (RFC 6455 disallows `:` and whitespace in
 * subprotocols — both of which the old `userId:DisplayName` shape used).
 */
export function testBearer(id: TestIdentity): string {
  return `${id.userId}--${id.displayName.replace(/ /g, '_')}`
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
  opts: {
    requiresApproval: boolean
    me?: TestIdentity
    /**
     * Optional bookContext override — file-transfer tests need to pin
     * `contentHash` to the real imported file's SHA-256 so the host can
     * actually serve the bytes from disk.
     */
    bookContext?: { bookId: string; contentHash: string; format: 'epub' | 'pdf' }
  } = { requiresApproval: false }
): Promise<string> {
  const me = opts.me ?? { userId: 'e2e-host', displayName: 'E2E Host' }
  await sendSessionEvent(hostPage, {
    type: 'CREATE_SESSION',
    me: { ...me, authToken: testBearer(me) },
    bookContext: opts.bookContext
      ?? { bookId: 'e2e-test-book', contentHash: 'a'.repeat(64), format: 'pdf' },
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

/**
 * Install the fake `RtcFactory` (task #92) in the renderer so peerActor
 * never tries to open real UDP sockets in headless Electron. Call this
 * AFTER the session machine actor is registered (i.e. after the reader
 * page is mounted) but BEFORE `CREATE_SESSION` / `ACCEPT_INVITE`.
 *
 * Also installs `window.__rishi.__testDataChannelBus` so the fake adapter
 * can shuttle data-channel payloads across Electron processes via the
 * worker's `data.channel.relay` path. The bus is a per-renderer registry
 * of `(remoteUserId, channel) → listener` slots. Production code never
 * looks at the bus — signalingActor's bus dispatch is gated on its
 * presence — so installing it from E2E doesn't leak into production.
 */
export async function installFakeRtcAdapter(page: Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as {
      __rishi?: {
        installFakeRtcFactory?: () => void
        __testDataChannelBus?: unknown
      }
    }
    if (typeof w.__rishi?.installFakeRtcFactory !== 'function')
      throw new Error('window.__rishi.installFakeRtcFactory not exposed (task #92 prerequisite)')
    w.__rishi.installFakeRtcFactory()
    if (!w.__rishi.__testDataChannelBus) {
      type Listener = (data: string | ArrayBuffer) => void
      const slots = new Map<string, Listener>()
      const key = (peer: string, ch: 'sync' | 'files'): string => `${peer}.${ch}`
      const bus = {
        register(peer: string, ch: 'sync' | 'files', cb: Listener): () => void {
          slots.set(key(peer, ch), cb)
          return () => slots.delete(key(peer, ch))
        },
        dispatch(peer: string, ch: 'sync' | 'files', payload: string): void {
          const cb = slots.get(key(peer, ch))
          if (!cb) return
          // The sender's encoding decision (string vs base64) is preserved
          // by the channel: `files` carries binary chunks (base64-encoded),
          // `sync` carries JSON strings. Decode files back to ArrayBuffer
          // so it matches what a real RTCDataChannel onmessage delivers.
          if (ch === 'files') {
            const bin = atob(payload)
            const out = new Uint8Array(bin.length)
            for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
            cb(out.buffer)
          } else {
            cb(payload)
          }
        }
      }
      w.__rishi.__testDataChannelBus = bus
    }
  })
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
