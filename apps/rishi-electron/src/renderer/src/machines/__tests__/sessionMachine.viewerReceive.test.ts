/**
 * Viewer-side file transfer wiring tests.
 */
import { describe, expect, it, vi } from 'vitest'
import { createActor, fromCallback, fromPromise } from 'xstate'
import { sessionMachine, type Me, type RedeemOutput } from '../sessionMachine'

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
    receive((e) => { entry.received.push(e) })
    return () => {}
  })
  return { actor, spawned }
}

function provideDeps(opts: {
  signaling: ReturnType<typeof makeStubSignaling>
  peers: ReturnType<typeof makeFromCallbackSpy>
  receivers: ReturnType<typeof makeFromCallbackSpy>
  senders?: ReturnType<typeof makeFromCallbackSpy>
}) {
  const senders = opts.senders ?? makeFromCallbackSpy()
  return sessionMachine.provide({
    actors: {
      createSessionOnDO: fromPromise(async () => ({
        sessionId: 's1', joinToken: 'jt',
        joinUrl: 'rishi://sharing/join?t=jt',
        wsUrl: 'wss://x/v1/sessions/s1/wss'
      })),
      redeemJoinToken: fromPromise<RedeemOutput, { me: Me; sessionId: string; joinToken: string }>(async () => ({
        sessionId: 's1',
        bookContext: { bookId: 'b', contentHash: 'h', format: 'pdf' },
        requiresApproval: false,
        hostProfile: { displayName: 'Host' },
        wsUrl: 'wss://x/v1/sessions/s1/wss'
      })),
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      signaling: opts.signaling.actor as any,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      peerWrapper: opts.peers.actor as any,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      hostFileSender: senders.actor as any,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      viewerFileReceiver: opts.receivers.actor as any
    }
  })
}

async function bootViewer(opts: {
  signaling: ReturnType<typeof makeStubSignaling>
  peers: ReturnType<typeof makeFromCallbackSpy>
  receivers: ReturnType<typeof makeFromCallbackSpy>
  saveTransferredBook?: ReturnType<typeof vi.fn>
}) {
  const a = createActor(provideDeps(opts))
  a.start()
  a.send({
    type: 'ACCEPT_INVITE',
    me: { userId: 'u_v', displayName: 'Viewer', authToken: 't' },
    sessionId: 's1',
    joinToken: 'jt',
    hasBookFile: false
  })
  await new Promise((r) => setTimeout(r, 10))
  // Override pluggable IPC after construction if test wants to inspect saves.
  if (opts.saveTransferredBook) {
    ;(a.getSnapshot().context as { saveTransferredBook: any }).saveTransferredBook =
      opts.saveTransferredBook
  }
  // Host peer with the book file.
  opts.signaling.fire({
    type: 'PEER_JOINED',
    msg: {
      v: 1, t: 'peer.joined', userId: 'u_host',
      profile: { displayName: 'Host' }, hasBookFile: true
    }
  })
  await new Promise((r) => setTimeout(r, 5))
  return a
}

describe('sessionMachine viewer-side file receive wiring', () => {
  it('spawns a viewerFileReceiver on PEER_CONNECTED when local lacks the book', async () => {
    const sig = makeStubSignaling()
    const peers = makeFromCallbackSpy()
    const receivers = makeFromCallbackSpy()
    const a = await bootViewer({ signaling: sig, peers, receivers })
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_host' })
    await new Promise((r) => setTimeout(r, 5))
    expect(receivers.spawned.length).toBe(1)
    expect(receivers.spawned[0].input.peerUserId).toBe('u_host')
    expect(receivers.spawned[0].input.bookId).toBe('b')
    expect(receivers.spawned[0].input.contentHash).toBe('h')
    expect(a.getSnapshot().context.receivers.has('u_host')).toBe(true)
  })

  it('forwards inbound FILE_DATA to the matching receiver', async () => {
    const sig = makeStubSignaling()
    const peers = makeFromCallbackSpy()
    const receivers = makeFromCallbackSpy()
    await bootViewer({ signaling: sig, peers, receivers })
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_host' })
    await new Promise((r) => setTimeout(r, 5))
    const payload = new Uint8Array([1, 2, 3]).buffer as ArrayBuffer
    peers.spawned[0].sendBack({ type: 'FILE_DATA', remoteUserId: 'u_host', payload })
    await new Promise((r) => setTimeout(r, 5))
    const fwd = receivers.spawned[0].received.find((e) => e.type === 'FILE_DATA')
    expect(fwd).toBeTruthy()
    expect(fwd.payload).toBe(payload)
  })

  it('routes a SEND_FILE_ACK from the receiver → matching peer wrapper', async () => {
    const sig = makeStubSignaling()
    const peers = makeFromCallbackSpy()
    const receivers = makeFromCallbackSpy()
    await bootViewer({ signaling: sig, peers, receivers })
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_host' })
    await new Promise((r) => setTimeout(r, 5))
    receivers.spawned[0].sendBack({ type: 'SEND_FILE_ACK', peerUserId: 'u_host', seq: 2 })
    await new Promise((r) => setTimeout(r, 5))
    const ack = peers.spawned[0].received.find((e) => e.type === 'SEND_FILE_ACK')
    expect(ack).toBeTruthy()
    expect(ack.seq).toBe(2)
  })

  it('on TRANSFER_RECEIVED: saves via IPC, reports hasBookFile=true, appends receivedBook', async () => {
    const sig = makeStubSignaling()
    const peers = makeFromCallbackSpy()
    const receivers = makeFromCallbackSpy()
    const save = vi.fn().mockResolvedValue({ localPath: '/p/x.pdf', dbBookId: 99 })
    const a = await bootViewer({
      signaling: sig, peers, receivers, saveTransferredBook: save
    })
    peers.spawned[0].sendBack({ type: 'PEER_CONNECTED', remoteUserId: 'u_host' })
    await new Promise((r) => setTimeout(r, 5))
    const blob = new Uint8Array([10, 20, 30]).buffer as ArrayBuffer
    receivers.spawned[0].sendBack({
      type: 'TRANSFER_RECEIVED',
      peerUserId: 'u_host',
      bookId: 'b', contentHash: 'h', format: 'pdf', title: 'T',
      blob, hash: 'h_sha'
    })
    await new Promise((r) => setTimeout(r, 20))
    expect(save).toHaveBeenCalledTimes(1)
    expect(save.mock.calls[0][0]).toMatchObject({
      bookId: 'b', contentHash: 'h', format: 'pdf', title: 'T',
      receivedFromUserId: 'u_host'
    })
    // After save resolves we expect REPORT_HAS_BOOK to flow over signaling.
    await new Promise((r) => setTimeout(r, 5))
    const hb = sig.sent.find(
      (e) => e.type === 'SEND'
        && (e.payload as { t: string }).t === 'has.book'
    )
    expect(hb).toBeTruthy()
    expect((hb!.payload as { value: boolean }).value).toBe(true)

    // receivedBooks should include the new entry.
    const rb = a.getSnapshot().context.receivedBooks
    expect(rb.length).toBe(1)
    expect(rb[0].bookId).toBe('b')
    expect(rb[0].localPath).toBe('/p/x.pdf')

    // Cleanup: the receiver entry is dropped.
    expect(a.getSnapshot().context.receivers.has('u_host')).toBe(false)
  })
})
