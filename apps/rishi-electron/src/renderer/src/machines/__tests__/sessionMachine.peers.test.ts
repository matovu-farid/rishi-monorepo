/**
 * Per-peer registry lifecycle tests for sessionMachine. We don't drive
 * real WebRTC here — the peerWrapperActor is exercised in its own unit
 * test. These tests focus on: spawn on join, despawn on leave, route
 * inbound SDP/ICE by `from` userId, and forward outbound LOCAL_SDP/
 * LOCAL_ICE emits to signaling as ClientMsg frames.
 */
import { describe, expect, it } from 'vitest'
import { createActor, fromCallback, fromPromise } from 'xstate'
import { sessionMachine, type Me, type RedeemOutput } from '../sessionMachine'

function makeStubSignaling() {
  let sendBackRef: ((e: { type: string; [k: string]: unknown }) => void) | null = null
  const sent: Array<{ type: string; [k: string]: unknown }> = []
  const actor = fromCallback(({ sendBack, receive }) => {
    sendBackRef = sendBack as typeof sendBackRef
    receive((evt) => {
      sent.push(evt as { type: string; [k: string]: unknown })
    })
    return () => {
      sendBackRef = null
    }
  })
  return {
    actor,
    sent,
    fire(event: { type: string; [k: string]: unknown }) {
      if (!sendBackRef) throw new Error('signaling stub not yet invoked')
      sendBackRef(event)
    }
  }
}

/**
 * A peerWrapper stub that records its input and exposes `fire()` so we
 * can simulate inner peerActor emits without spinning up a real
 * RTCPeerConnection.
 */
function makePeerWrapperStub() {
  const spawned: Array<{ input: any; sendBack: (e: any) => void; received: any[] }> = []
  const actor = fromCallback(({ input, sendBack, receive }) => {
    const entry = { input, sendBack: sendBack as (e: any) => void, received: [] as any[] }
    spawned.push(entry)
    receive((e) => {
      entry.received.push(e)
    })
    return () => {}
  })
  return { actor, spawned }
}

function provideDeps(opts: {
  signalingStub: ReturnType<typeof makeStubSignaling>
  peerStub: ReturnType<typeof makePeerWrapperStub>
}) {
  return sessionMachine.provide({
    actors: {
      createSessionOnDO: fromPromise(async () => ({
        sessionId: 's1',
        joinToken: 'jt',
        joinUrl: 'rishi://sharing/join?t=jt',
        wsUrl: 'wss://x/v1/sessions/s1/wss'
      })),
      redeemJoinToken: fromPromise<RedeemOutput, { me: Me; sessionId: string; joinToken: string }>(
        async () => ({
          sessionId: 's1',
          bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
          requiresApproval: false,
          hostProfile: { displayName: 'Host' },
          wsUrl: 'wss://x/v1/sessions/s1/wss'
        })
      ),

      signaling: opts.signalingStub.actor as any,

      peerWrapper: opts.peerStub.actor as any
    }
  })
}

describe('sessionMachine peers registry', () => {
  it('spawns a peerWrapper on PEER_JOINED and despawns on PEER_LEFT', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const a = createActor(provideDeps({ signalingStub: sig, peerStub: peers }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_host', displayName: 'Host', authToken: 't' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false
    })
    // Wait for the create-session promise to settle.
    await new Promise((r) => setTimeout(r, 10))
    // Drive a peer.joined event.
    sig.fire({
      type: 'PEER_JOINED',
      msg: {
        v: 1,
        t: 'peer.joined',
        userId: 'u_b',
        profile: { displayName: 'Bob' },
        hasBookFile: false
      }
    })
    await new Promise((r) => setTimeout(r, 5))
    expect(peers.spawned.length).toBe(1)
    expect(peers.spawned[0].input.peerUserId).toBe('u_b')
    expect(peers.spawned[0].input.selfUserId).toBe('u_host')

    // Despawn.
    sig.fire({
      type: 'PEER_LEFT',
      msg: { v: 1, t: 'peer.left', userId: 'u_b', reason: 'left' }
    })
    await new Promise((r) => setTimeout(r, 5))
    const snap = a.getSnapshot()
    expect(snap.context.peers.has('u_b')).toBe(false)
  })

  it('routes SDP_OFFER to the matching peer by `from` userId', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const a = createActor(provideDeps({ signalingStub: sig, peerStub: peers }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_host', displayName: 'Host', authToken: 't' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false
    })
    await new Promise((r) => setTimeout(r, 10))
    sig.fire({
      type: 'PEER_JOINED',
      msg: {
        v: 1,
        t: 'peer.joined',
        userId: 'u_b',
        profile: { displayName: 'Bob' },
        hasBookFile: false
      }
    })
    await new Promise((r) => setTimeout(r, 5))
    sig.fire({
      type: 'SDP_OFFER',
      msg: { v: 1, t: 'sdp.offer', from: 'u_b', sdp: 'OFFER_SDP' }
    })
    await new Promise((r) => setTimeout(r, 5))
    const got = peers.spawned[0].received.find((e) => e.type === 'SDP_OFFER')
    expect(got).toBeTruthy()
    expect(got.sdp).toBe('OFFER_SDP')
  })

  it('forwards LOCAL_SDP from a peer back to signaling as a sdp.* ClientMsg', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const a = createActor(provideDeps({ signalingStub: sig, peerStub: peers }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_host', displayName: 'Host', authToken: 't' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false
    })
    await new Promise((r) => setTimeout(r, 10))
    sig.fire({
      type: 'PEER_JOINED',
      msg: {
        v: 1,
        t: 'peer.joined',
        userId: 'u_b',
        profile: { displayName: 'Bob' },
        hasBookFile: false
      }
    })
    await new Promise((r) => setTimeout(r, 5))
    // Simulate the inner peer emitting LOCAL_SDP (an answer).
    peers.spawned[0].sendBack({
      type: 'LOCAL_SDP',
      remoteUserId: 'u_b',
      kind: 'answer',
      sdp: 'A_SDP'
    })
    await new Promise((r) => setTimeout(r, 5))
    const sent = sig.sent.find(
      (e) => e.type === 'SEND' && (e.payload as { t: string }).t === 'sdp.answer'
    )
    expect(sent).toBeTruthy()
    expect((sent!.payload as { sdp: string }).sdp).toBe('A_SDP')
  })

  it('forwards LOCAL_ICE → ice ClientMsg keyed by remoteUserId', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const a = createActor(provideDeps({ signalingStub: sig, peerStub: peers }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_host', displayName: 'Host', authToken: 't' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false
    })
    await new Promise((r) => setTimeout(r, 10))
    sig.fire({
      type: 'PEER_JOINED',
      msg: {
        v: 1,
        t: 'peer.joined',
        userId: 'u_b',
        profile: { displayName: 'Bob' },
        hasBookFile: false
      }
    })
    await new Promise((r) => setTimeout(r, 5))
    peers.spawned[0].sendBack({
      type: 'LOCAL_ICE',
      remoteUserId: 'u_b',
      candidate: { foo: 1 }
    })
    await new Promise((r) => setTimeout(r, 5))
    const sent = sig.sent.find((e) => e.type === 'SEND' && (e.payload as { t: string }).t === 'ice')
    expect(sent).toBeTruthy()
    expect((sent!.payload as { to: string }).to).toBe('u_b')
  })
})
