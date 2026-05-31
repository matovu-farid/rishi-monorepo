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
    // After the joining-into-connected refactor, awaitingApproval is an
    // internal substate of `connected` (so the WS opens and the worker can
    // register the pending join). The state value is now nested.
    await vi.waitFor(() =>
      expect(stateMatches(a.getSnapshot().value, 'awaitingApproval')).toBe(true)
    )
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

  it('SHARER_POSITION_UPDATE forwards a SyncMsg over signaling and updates lastSyncedPosition', async () => {
    const stub = makeStubSignaling()
    const a = createActor(provideDeps({ signalingStub: stub }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    a.send({ type: 'SHARER_POSITION_UPDATE', pageIndex: 3 })
    expect(a.getSnapshot().context.lastSyncedPosition?.pageIndex).toBe(3)
    const sent = stub.sent.find((e) => e.type === 'SEND')
    expect(sent).toBeTruthy()
    const payload = (sent as unknown as { payload: { t: string; frame: { t: string; position: { page: number } } } }).payload
    expect(payload.t).toBe('sync.frame')
    expect(payload.frame.t).toBe('reader.position')
    expect(payload.frame.position.page).toBe(3)
  })

  it('SYNC_FRAME with reader.position updates lastSyncedPosition', async () => {
    const stub = makeStubSignaling()
    const a = createActor(provideDeps({ signalingStub: stub }))
    a.start()
    a.send({
      type: 'ACCEPT_INVITE',
      me: { userId: 'u_b', displayName: 'B', authToken: 'jwt' },
      sessionId: 's1', joinToken: 'jt'
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    stub.fire({
      type: 'SYNC_FRAME',
      msg: {
        v: 1, t: 'sync.frame', from: 'u_a',
        frame: {
          v: 1, t: 'reader.position', ts: Date.now(), bookId: 'b',
          position: { format: 'pdf', page: 7, offsetY: 0, ts: Date.now() }
        }
      }
    })
    expect(a.getSnapshot().context.lastSyncedPosition?.pageIndex).toBe(7)
  })

  it('APPROVAL_RESULT(approved=true) transitions awaitingApproval → connecting', async () => {
    const stub = makeStubSignaling()
    const a = createActor(provideDeps({ redeemRequiresApproval: true, signalingStub: stub }))
    a.start()
    a.send({
      type: 'ACCEPT_INVITE',
      me: { userId: 'u_b', displayName: 'B', authToken: 'jwt' },
      sessionId: 's1', joinToken: 'jt'
    })
    await vi.waitFor(() =>
      expect(stateMatches(a.getSnapshot().value, 'awaitingApproval')).toBe(true)
    )
    stub.fire({
      type: 'APPROVAL_RESULT',
      msg: { v: 1, t: 'approval.result', approved: true }
    })
    await vi.waitFor(() =>
      expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true)
    )
    expect(a.getSnapshot().context.approvalStatus).toBe('approved')
  })

  it('APPROVAL_RESULT(approved=false) transitions awaitingApproval → failed', async () => {
    const stub = makeStubSignaling()
    const a = createActor(provideDeps({ redeemRequiresApproval: true, signalingStub: stub }))
    a.start()
    a.send({
      type: 'ACCEPT_INVITE',
      me: { userId: 'u_b', displayName: 'B', authToken: 'jwt' },
      sessionId: 's1', joinToken: 'jt'
    })
    await vi.waitFor(() =>
      expect(stateMatches(a.getSnapshot().value, 'awaitingApproval')).toBe(true)
    )
    stub.fire({
      type: 'APPROVAL_RESULT',
      msg: { v: 1, t: 'approval.result', approved: false, reason: 'no' }
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('failed'))
    expect(a.getSnapshot().context.approvalStatus).toBe('rejected')
  })

  it('KICK_PEER from host forwards a kick.peer frame over signaling while live', async () => {
    const stub = makeStubSignaling()
    const a = createActor(provideDeps({ signalingStub: stub }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    // Drive to live via ROSTER so the substate is live, not connecting.
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
        bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
        status: 'live'
      }
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'live')).toBe(true))
    a.send({ type: 'KICK_PEER', userId: 'u_b' })
    const sent = stub.sent.filter((e) => e.type === 'SEND')
    const payload = sent.map((e) => (e as { payload: { t: string; userId: string } }).payload)
      .find((p) => p.t === 'kick.peer')
    expect(payload).toBeTruthy()
    expect(payload?.userId).toBe('u_b')
  })

  it('REPORT_HAS_BOOK forwards a has.book frame over signaling', async () => {
    const stub = makeStubSignaling()
    const a = createActor(provideDeps({ signalingStub: stub }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    a.send({ type: 'REPORT_HAS_BOOK', value: true })
    const sent = stub.sent.find((e) => e.type === 'SEND')
    const payload = (sent as { payload: { t: string; value: boolean } } | undefined)?.payload
    expect(payload?.t).toBe('has.book')
    expect(payload?.value).toBe(true)
  })

  it('SIGNALING_DROPPED → reconnecting → reconnectDriver auto-fires RECONNECTED', async () => {
    vi.useFakeTimers()
    try {
      const stub = makeStubSignaling()
      const a = createActor(provideDeps({ signalingStub: stub }))
      a.start()
      a.send({
        type: 'CREATE_SESSION',
        me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
        bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
        requiresApproval: false
      })
      await vi.advanceTimersByTimeAsync(10)
      expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true)
      a.send({ type: 'SIGNALING_DROPPED', code: 4000, reason: 'test' })
      expect(a.getSnapshot().value).toBe('reconnecting')
      // The default reconnect actor is the inert driver — it fires
      // RECONNECTED after `input.delayMs` (1500ms by default).
      await vi.advanceTimersByTimeAsync(2000)
      expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true)
    } finally {
      vi.useRealTimers()
    }
  })

  it('SIGNALING_DROPPED → reconnecting → RECONNECTED → reconnects to connected', async () => {
    const stub = makeStubSignaling()
    const a = createActor(provideDeps({ signalingStub: stub }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
    a.send({ type: 'SIGNALING_DROPPED', code: 4000, reason: 'test' })
    expect(a.getSnapshot().value).toBe('reconnecting')
    a.send({ type: 'RECONNECTED' })
    await vi.waitFor(() => expect(stateMatches(a.getSnapshot().value, 'connecting')).toBe(true))
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
