/**
 * Host-side file transfer wiring tests. We stub the peerWrapper and
 * hostFileSender slots so we can deterministically simulate the
 * connectivity / sender-actor surface without spinning up real
 * RTCPeerConnections.
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

function makeHostSenderStub() {
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
  signaling: ReturnType<typeof makeStubSignaling>
  peers: ReturnType<typeof makePeerWrapperStub>
  senders: ReturnType<typeof makeHostSenderStub>
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
          hostProfile: { displayName: 'H' },
          wsUrl: 'wss://x/v1/sessions/s1/wss'
        })
      ),

      signaling: opts.signaling.actor as any,

      peerWrapper: opts.peers.actor as any,

      hostFileSender: opts.senders.actor as any
    }
  })
}

async function bootHost(opts: {
  signaling: ReturnType<typeof makeStubSignaling>
  peers: ReturnType<typeof makePeerWrapperStub>
  senders: ReturnType<typeof makeHostSenderStub>
}) {
  const a = createActor(provideDeps(opts))
  a.start()
  a.send({
    type: 'CREATE_SESSION',
    me: { userId: 'u_host', displayName: 'Host', authToken: 't' },
    bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
    requiresApproval: false,
    hasBookFile: true
  })
  await new Promise((r) => setTimeout(r, 10))
  // Add a peer that LACKS the book file.
  opts.signaling.fire({
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
  return a
}

describe('sessionMachine host-side file transfer wiring', () => {
  it('spawns a hostFileSender once the peer connects, carrying bookContext + IPC', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const senders = makeHostSenderStub()
    const a = await bootHost({ signaling: sig, peers, senders })

    // Fake the wrapper emitting PEER_CONNECTED so the host transfer trigger fires.
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_b' })
    await new Promise((r) => setTimeout(r, 5))

    expect(senders.spawned.length).toBe(1)
    expect(senders.spawned[0].input.peerUserId).toBe('u_b')
    expect(senders.spawned[0].input.bookId).toBe('b')
    expect(senders.spawned[0].input.contentHash).toBe('h')
    expect(typeof senders.spawned[0].input.readBookBytes).toBe('function')

    // Snapshot context exposes the transfer.
    expect(a.getSnapshot().context.transfers.has('u_b')).toBe(true)
  })

  it('does NOT spawn a sender for a peer that already has the book', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const senders = makeHostSenderStub()
    const a = createActor(provideDeps({ signaling: sig, peers, senders }))
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_host', displayName: 'Host', authToken: 't' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
      requiresApproval: false,
      hasBookFile: true
    })
    await new Promise((r) => setTimeout(r, 10))
    sig.fire({
      type: 'PEER_JOINED',
      msg: {
        v: 1,
        t: 'peer.joined',
        userId: 'u_b',
        profile: { displayName: 'Bob' },
        hasBookFile: true
      }
    })
    await new Promise((r) => setTimeout(r, 5))
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_b' })
    await new Promise((r) => setTimeout(r, 5))
    expect(senders.spawned.length).toBe(0)
  })

  it('routes SEND_FILE_DATA from the sender → matching peer wrapper', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const senders = makeHostSenderStub()
    await bootHost({ signaling: sig, peers, senders })
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_b' })
    await new Promise((r) => setTimeout(r, 5))

    // Sender emits a SEND_FILE_DATA upward; we expect the wrapper to receive it.
    const payload = new Uint8Array([7, 8, 9]).buffer as ArrayBuffer
    senders.spawned[0].sendBack({ type: 'SEND_FILE_DATA', peerUserId: 'u_b', payload })
    await new Promise((r) => setTimeout(r, 5))
    const got = peers.spawned[0].received.find((e) => e.type === 'SEND_FILE_DATA')
    expect(got).toBeTruthy()
    expect(got.payload).toBe(payload)
  })

  it('forwards an inbound FILE_ACK (via the peer wrapper) to the matching sender', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const senders = makeHostSenderStub()
    await bootHost({ signaling: sig, peers, senders })
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_b' })
    await new Promise((r) => setTimeout(r, 5))

    // The peer wrapper decoded an inbound ack frame and bubbled it up.
    peers.spawned[0].sendBack({ type: 'FILE_ACK', remoteUserId: 'u_b', seq: 3 })
    await new Promise((r) => setTimeout(r, 5))
    const ack = senders.spawned[0].received.find((e) => e.type === 'FILE_ACK')
    expect(ack).toBeTruthy()
    expect(ack.seq).toBe(3)
  })

  it('clears the transfer entry once the sender reports TRANSFER_COMPLETED', async () => {
    const sig = makeStubSignaling()
    const peers = makePeerWrapperStub()
    const senders = makeHostSenderStub()
    const a = await bootHost({ signaling: sig, peers, senders })
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_b' })
    await new Promise((r) => setTimeout(r, 5))
    expect(a.getSnapshot().context.transfers.has('u_b')).toBe(true)

    senders.spawned[0].sendBack({
      type: 'TRANSFER_COMPLETED',
      peerUserId: 'u_b',
      contentHash: 'h'
    })
    await new Promise((r) => setTimeout(r, 5))
    expect(a.getSnapshot().context.transfers.has('u_b')).toBe(false)
  })
})
