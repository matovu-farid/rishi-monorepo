/**
 * When `saveTransferredBook` rejects, the machine should surface the failure
 * via `context.persistFailures` (instead of just `console.warn`) so the UI
 * can render a toast or banner. The receiver actor is stopped in the same
 * transition either way — without this signal the viewer has no idea their
 * received book never made it to disk.
 */
import { describe, expect, it, vi } from 'vitest'
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

function makeFromCallbackSpy() {
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

function provide(opts: {
  signaling: ReturnType<typeof makeStubSignaling>
  peers: ReturnType<typeof makeFromCallbackSpy>
  receivers: ReturnType<typeof makeFromCallbackSpy>
}) {
  const senders = makeFromCallbackSpy()
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

      signaling: opts.signaling.actor as any,

      peerWrapper: opts.peers.actor as any,

      hostFileSender: senders.actor as any,

      viewerFileReceiver: opts.receivers.actor as any
    }
  })
}

async function bootViewerWithSave(save: ReturnType<typeof vi.fn>) {
  const sig = makeStubSignaling()
  const peers = makeFromCallbackSpy()
  const receivers = makeFromCallbackSpy()
  const a = createActor(provide({ signaling: sig, peers, receivers }))
  a.start()
  a.send({
    type: 'ACCEPT_INVITE',
    me: { userId: 'u_v', displayName: 'Viewer', authToken: 't' },
    sessionId: 's1',
    joinToken: 'jt',
    hasBookFile: false
  })
  await new Promise((r) => setTimeout(r, 10))
  ;(a.getSnapshot().context as { saveTransferredBook: any }).saveTransferredBook = save
  sig.fire({
    type: 'PEER_JOINED',
    msg: {
      v: 1,
      t: 'peer.joined',
      userId: 'u_host',
      profile: { displayName: 'Host' },
      hasBookFile: true
    }
  })
  await new Promise((r) => setTimeout(r, 5))
  peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_host' })
  await new Promise((r) => setTimeout(r, 5))
  return { actor: a, sig, peers, receivers }
}

describe('sessionMachine — saveTransferredBook failure surfacing', () => {
  it('records a persistFailures entry when saveTransferredBook rejects', async () => {
    const save = vi.fn().mockRejectedValue(new Error('ENOSPC: out of disk'))
    const { actor, receivers } = await bootViewerWithSave(save)
    const blob = new Uint8Array([1, 2, 3]).buffer as ArrayBuffer
    receivers.spawned[0].sendBack({
      type: 'TRANSFER_RECEIVED',
      peerUserId: 'u_host',
      bookId: 'b',
      contentHash: 'h',
      format: 'pdf',
      title: 'T',
      blob,
      hash: 'h_sha'
    })
    await new Promise((r) => setTimeout(r, 30))
    const failures = actor.getSnapshot().context.persistFailures
    expect(failures.length).toBe(1)
    expect(failures[0]).toMatchObject({
      peerUserId: 'u_host',
      bookId: 'b',
      contentHash: 'h'
    })
    expect(failures[0].error).toMatch(/ENOSPC/)
    expect(typeof failures[0].at).toBe('number')
    // No `receivedBook` appended because the disk write failed.
    expect(actor.getSnapshot().context.receivedBooks.length).toBe(0)
  })

  it('appends a second failure when two TRANSFER_RECEIVED events fail back-to-back', async () => {
    const save = vi
      .fn()
      .mockRejectedValueOnce(new Error('fail-1'))
      .mockRejectedValueOnce(new Error('fail-2'))
    const { actor, receivers, peers, sig } = await bootViewerWithSave(save)
    const blob1 = new Uint8Array([1]).buffer as ArrayBuffer
    receivers.spawned[0].sendBack({
      type: 'TRANSFER_RECEIVED',
      peerUserId: 'u_host',
      bookId: 'b1',
      contentHash: 'h1',
      format: 'pdf',
      title: 'T1',
      blob: blob1,
      hash: 'h_sha'
    })
    await new Promise((r) => setTimeout(r, 20))
    // Simulate a second incoming transfer from a different peer so the
    // receivers map can re-spawn.
    sig.fire({
      type: 'PEER_JOINED',
      msg: {
        v: 1,
        t: 'peer.joined',
        userId: 'u_p2',
        profile: { displayName: 'P2' },
        hasBookFile: true
      }
    })
    await new Promise((r) => setTimeout(r, 5))
    peers.spawned[1].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_p2' })
    await new Promise((r) => setTimeout(r, 5))
    const blob2 = new Uint8Array([2]).buffer as ArrayBuffer
    receivers.spawned[1].sendBack({
      type: 'TRANSFER_RECEIVED',
      peerUserId: 'u_p2',
      bookId: 'b2',
      contentHash: 'h2',
      format: 'pdf',
      title: 'T2',
      blob: blob2,
      hash: 'h_sha'
    })
    await new Promise((r) => setTimeout(r, 30))
    const failures = actor.getSnapshot().context.persistFailures
    expect(failures.length).toBe(2)
    expect(failures[0].bookId).toBe('b1')
    expect(failures[1].bookId).toBe('b2')
  })
})
