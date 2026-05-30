import { describe, expect, it, vi } from 'vitest'
import { createActor } from 'xstate'
import { peerActor } from '../peerActor'
import type { RtcAdapter, RtcDataChannelLike } from '../rtcAdapter'

function makeFakeChannel(label: string): RtcDataChannelLike & {
  fireOpen: () => void
  fireMessage: (d: string | ArrayBuffer) => void
} {
  let onOpen: (() => void) | null = null
  let onMsg: ((d: string | ArrayBuffer) => void) | null = null
  return {
    label,
    readyState: 'open',
    send: vi.fn(),
    close: vi.fn(),
    onOpen: (cb) => { onOpen = cb },
    onMessage: (cb) => { onMsg = cb },
    onClose: () => {},
    bufferedAmount: () => 0,
    fireOpen: () => onOpen?.(),
    fireMessage: (d) => onMsg?.(d)
  }
}

function makeFakeRtc() {
  const channels = new Map<string, ReturnType<typeof makeFakeChannel>>()
  let onIce: ((c: unknown | null) => void) | null = null
  let onCs: ((s: RTCPeerConnectionState) => void) | null = null
  const adapter: RtcAdapter = {
    createOffer: async () => ({ sdp: 'OFFER_SDP' }),
    createAnswer: async () => ({ sdp: 'ANSWER_SDP' }),
    setLocalDescription: vi.fn(async () => {}),
    setRemoteDescription: vi.fn(async () => {}),
    addIceCandidate: vi.fn(async () => {}),
    addTrack: vi.fn(),
    createDataChannel: (label) => {
      const c = makeFakeChannel(label)
      channels.set(label, c)
      return c
    },
    onIceCandidate: (cb) => { onIce = cb },
    onDataChannel: () => {},
    onTrack: () => {},
    onConnectionStateChange: (cb) => { onCs = cb },
    close: vi.fn()
  }
  return {
    adapter,
    channels,
    fireIce: (c: unknown) => onIce?.(c),
    fireConn: (s: RTCPeerConnectionState) => onCs?.(s)
  }
}

describe('peerActor', () => {
  it('creates offer as initiator and emits LOCAL_SDP', async () => {
    const fake = makeFakeRtc()
    const events: any[] = []
    const actor = createActor(peerActor, {
      input: {
        remoteUserId: 'u_b',
        initiator: true,
        iceServers: [],
        factory: () => fake.adapter
      }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    const offer = events.find((e) => e.type === 'LOCAL_SDP')
    expect(offer).toBeTruthy()
    expect(offer.sdp).toBe('OFFER_SDP')
    expect(offer.kind).toBe('offer')
  })

  it('handles REMOTE_SDP offer by creating answer', async () => {
    const fake = makeFakeRtc()
    const events: any[] = []
    const actor = createActor(peerActor, {
      input: {
        remoteUserId: 'u_b', initiator: false, iceServers: [], factory: () => fake.adapter
      }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({ type: 'REMOTE_SDP', kind: 'offer', sdp: 'X' })
    await new Promise((r) => setTimeout(r, 0))
    expect(fake.adapter.setRemoteDescription).toHaveBeenCalled()
    const ans = events.find((e) => e.type === 'LOCAL_SDP' && e.kind === 'answer')
    expect(ans?.sdp).toBe('ANSWER_SDP')
  })

  it('forwards SEND_SYNC over the sync data channel', async () => {
    const fake = makeFakeRtc()
    const actor = createActor(peerActor, {
      input: { remoteUserId: 'u_b', initiator: true, iceServers: [], factory: () => fake.adapter }
    })
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    actor.send({ type: 'SEND_SYNC', payload: '{"hello":1}' })
    const sync = fake.channels.get('sync')!
    expect(sync.send).toHaveBeenCalledWith('{"hello":1}')
  })

  it('emits SYNC_RECEIVED when a sync-channel message arrives', async () => {
    const fake = makeFakeRtc()
    const events: any[] = []
    const actor = createActor(peerActor, {
      input: { remoteUserId: 'u_b', initiator: true, iceServers: [], factory: () => fake.adapter }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    fake.channels.get('sync')!.fireMessage('payload')
    expect(events.find((e) => e.type === 'SYNC_RECEIVED' && e.payload === 'payload')).toBeTruthy()
  })

  it('emits PEER_CONNECTED on connectionstate=connected', async () => {
    const fake = makeFakeRtc()
    const events: any[] = []
    const actor = createActor(peerActor, {
      input: { remoteUserId: 'u_b', initiator: true, iceServers: [], factory: () => fake.adapter }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    fake.fireConn('connected')
    expect(events.find((e) => e.type === 'PEER_CONNECTED')).toBeTruthy()
  })

  it('closes the pc on actor stop', async () => {
    const fake = makeFakeRtc()
    const actor = createActor(peerActor, {
      input: { remoteUserId: 'u_b', initiator: true, iceServers: [], factory: () => fake.adapter }
    })
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    actor.stop()
    expect(fake.adapter.close).toHaveBeenCalled()
  })
})
