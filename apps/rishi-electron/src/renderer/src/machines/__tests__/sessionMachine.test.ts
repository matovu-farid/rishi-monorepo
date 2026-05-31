import { describe, expect, it, vi } from 'vitest'
import { createActor, fromCallback, fromPromise } from 'xstate'
import { sessionMachine } from '../sessionMachine'

const HOST_PROFILE = { displayName: 'Host', avatarUrl: undefined }

/**
 * Tolerant state-value matcher: `connecting` (atomic) or `{ connected: 'connecting' }`
 * (compound, after we wrap the connected lifecycle in a parent state).
 */
function stateMatches(value: unknown, target: string): boolean {
  if (value === target) return true
  if (typeof value === 'object' && value !== null) {
    const obj = value as Record<string, unknown>
    if ('connected' in obj && obj.connected === target) return true
    if ('connected' in obj && typeof obj.connected === 'object' && obj.connected !== null
      && target in (obj.connected as Record<string, unknown>)) return true
  }
  return false
}

/** A signaling stub that exposes a hook so tests can drive ROSTER / PEER events. */
function makeStubSignaling() {
  let sendBackRef: ((e: { type: string; [k: string]: unknown }) => void) | null = null
  const sent: Array<{ type: string; [k: string]: unknown }> = []
  const actor = fromCallback(({ sendBack, receive }) => {
    sendBackRef = sendBack as typeof sendBackRef
    receive((evt) => { sent.push(evt as { type: string; [k: string]: unknown }) })
    return () => { sendBackRef = null }
  })
  return {
    actor,
    sent,
    /** Drive the parent as if a server message arrived. */
    fire(event: { type: string; [k: string]: unknown }) {
      if (!sendBackRef) throw new Error('signaling stub not yet invoked')
      sendBackRef(event)
    },
    /** Whether the signaling actor has been invoked (its callback ran). */
    isInvoked(): boolean { return sendBackRef !== null }
  }
}

function provideDeps(opts: {
  createOk?: boolean
  redeemOk?: boolean
  redeemRequiresApproval?: boolean
  signalingStub?: ReturnType<typeof makeStubSignaling>
} = {}) {
  const stub = opts.signalingStub
  return sessionMachine.provide({
    actors: {
      createSessionOnDO: fromPromise(async () => {
        if (opts.createOk === false) throw new Error('create_failed')
        return {
          sessionId: 's1',
          joinToken: 'jt',
          joinUrl: 'rishi://sharing/join?t=jt',
          wsUrl: 'wss://x/v1/sessions/s1/wss'
        }
      }),
      redeemJoinToken: fromPromise(async () => {
        if (opts.redeemOk === false) throw new Error('redeem_failed')
        return {
          sessionId: 's1',
          bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' as const },
          requiresApproval: opts.redeemRequiresApproval ?? false,
          hostProfile: HOST_PROFILE,
          wsUrl: 'wss://x/v1/sessions/s1/wss'
        }
      }),
      // Always provide a signaling actor; otherwise the invoke would silently
      // fail (or worse: silently succeed by mounting the real WS-backed actor).
      //
      // The cast bypasses a TS2719 "two different types with this name exist"
      // warning where the production `signaling` slot is typed against the
      // SignalingInput/SignalingOutEvent shape (which transitively reaches the
      // protocol package's zod v4 types) while this stub uses xstate's default
      // generic params. The runtime contract is fulfilled.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      signaling: (stub
        ? stub.actor
        : fromCallback(() => { /* inert: no events, no cleanup */ })) as any
    }
  })
}

describe('sessionMachine', () => {
  it('starts in idle with empty receivedBooks', () => {
    const a = createActor(provideDeps())
    a.start()
    expect(a.getSnapshot().value).toBe('idle')
    expect(a.getSnapshot().context.receivedBooks).toEqual([])
  })

  it('CREATE_SESSION → creating → connecting on success', async () => {
    const a = createActor(provideDeps())
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    expect(a.getSnapshot().context.sessionId).toBe('s1')
    expect(a.getSnapshot().context.role).toBe('host')
  })

  it('ACCEPT_INVITE with requiresApproval=true → awaitingApproval', async () => {
    const a = createActor(provideDeps({ redeemRequiresApproval: true }))
    a.start()
    a.send({
      type: 'ACCEPT_INVITE',
      me: { userId: 'u_b', displayName: 'B', authToken: 'jwt' },
      sessionId: 's1',
      joinToken: 'jt'
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('awaitingApproval'))
  })

  it('redeem failure → failed', async () => {
    const a = createActor(provideDeps({ redeemOk: false }))
    a.start()
    a.send({
      type: 'ACCEPT_INVITE',
      me: { userId: 'u_b', displayName: 'B', authToken: 'jwt' },
      sessionId: 's1', joinToken: 'jt'
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('failed'))
  })

  it('BOOK_RECEIVED appends to receivedBooks during live', async () => {
    const a = createActor(provideDeps())
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    a.send({ type: 'ROSTER_READY' })
    a.send({
      type: 'BOOK_RECEIVED',
      bookId: 'b2', contentHash: 'h2', format: 'epub',
      receivedFromUserId: 'u_b', localPath: '/p/h2.epub',
      title: "Friend's Book"
    })
    expect(a.getSnapshot().context.receivedBooks).toHaveLength(1)
    expect(a.getSnapshot().context.receivedBooks[0].bookId).toBe('b2')
  })

  it('LEAVE from live transitions through promptingKeepBooks when books were received', async () => {
    const a = createActor(provideDeps())
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    a.send({ type: 'ROSTER_READY' })
    a.send({
      type: 'BOOK_RECEIVED',
      bookId: 'b2', contentHash: 'h2', format: 'epub',
      receivedFromUserId: 'u_b', localPath: '/p/h2.epub',
      title: "Friend's Book"
    })
    a.send({ type: 'LEAVE' })
    expect(stateMatches(a.getSnapshot().value, 'promptingKeepBooks')).toBe(true)
    a.send({ type: 'KEEP_BOOKS' })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('idle'), { timeout: 2000 })
  })

  it('invokes signaling actor on entering connecting and forwards ROSTER → live', async () => {
    const stub = makeStubSignaling()
    const a = createActor(provideDeps({ signalingStub: stub }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    // Once we reach connecting, the signaling actor MUST be running.
    await vi.waitFor(() => {
      const snap = a.getSnapshot()
      // value is `{ connected: 'connecting' }` once the wrapper state is in place
      const v = snap.value as unknown
      const ok = v === 'connecting'
        || (typeof v === 'object' && v !== null && 'connected' in (v as object))
      expect(ok).toBe(true)
    })
    expect(stub.isInvoked()).toBe(true)

    // Simulate the server saying "welcome, then roster". The machine must reach live
    // *without* anyone calling actor.send({type:'ROSTER_READY'}) — that's the bug.
    stub.fire({
      type: 'WELCOME',
      msg: {
        v: 1, t: 'welcome', you: 'u_a', role: 'host',
        sharerId: 'u_a', reconnectToken: 'rt', reservedUntil: 9999
      }
    })
    stub.fire({
      type: 'ROSTER',
      msg: {
        v: 1, t: 'roster', participants: [],
        requiresApproval: false,
        bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
        status: 'live'
      }
    })

    await vi.waitFor(() => {
      const v = a.getSnapshot().value as unknown
      const isLive = typeof v === 'object' && v !== null
        && 'connected' in (v as Record<string, unknown>)
        && typeof (v as { connected: unknown }).connected === 'object'
        && (v as { connected: Record<string, unknown> }).connected
        && 'live' in (v as { connected: Record<string, unknown> }).connected
      expect(isLive).toBeTruthy()
    })

    expect(a.getSnapshot().context.reconnectToken).toBe('rt')
    expect(a.getSnapshot().context.sharerId).toBe('u_a')
  })

  it('LEAVE from live skips prompt and goes to idle when no books were received', async () => {
    const a = createActor(provideDeps())
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    a.send({ type: 'ROSTER_READY' })
    a.send({ type: 'LEAVE' })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('idle'), { timeout: 2000 })
  })
})
