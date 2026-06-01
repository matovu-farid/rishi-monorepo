import { describe, expect, it, vi } from 'vitest'
import { createActor } from 'xstate'
import { peerWrapperActor } from '../peerWrapperActor'
import type { RtcAdapter } from '../rtcAdapter'

function makeFakeChannel(label: string) {
  let onOpenCb: (() => void) | null = null
  let onMsgCb: ((d: string | ArrayBuffer) => void) | null = null
  const ch = {
    label,
    readyState: 'open' as const,
    send: vi.fn(),
    close: vi.fn(),
    onOpen: (cb: () => void) => { onOpenCb = cb },
    onMessage: (cb: (d: string | ArrayBuffer) => void) => { onMsgCb = cb },
    onClose: () => {},
    bufferedAmount: () => 0
  }
  return Object.assign(ch, {
    fireOpen: () => onOpenCb?.(),
    fireMessage: (d: string | ArrayBuffer) => onMsgCb?.(d)
  })
}

function makeFakeRtc() {
  const channels = new Map<string, ReturnType<typeof makeFakeChannel>>()
  let onIce: ((c: unknown) => void) | null = null
  let onCs: ((s: RTCPeerConnectionState) => void) | null = null
  const adapter: RtcAdapter = {
    createOffer: async () => ({ sdp: 'OFFER' }),
    createAnswer: async () => ({ sdp: 'ANSWER' }),
    setLocalDescription: vi.fn(async () => {}),
    setRemoteDescription: vi.fn(async () => {}),
    addIceCandidate: vi.fn(async () => {}),
    addTrack: vi.fn(),
    createDataChannel: (label: string) => {
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
  return { adapter, channels, fireIce: (c: unknown) => onIce?.(c), fireConn: (s: RTCPeerConnectionState) => onCs?.(s) }
}

describe('peerWrapperActor', () => {
  it('forwards inner peer emits to the parent via sendBack', async () => {
    const fake = makeFakeRtc()
    const got: any[] = []
    const actor = createActor(peerWrapperActor, {
      input: {
        selfUserId: 'u_a',
        peerUserId: 'u_b',
        isInitiator: true,
        iceServers: [],
        rtcFactory: () => fake.adapter
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    // Inner peerActor emits LOCAL_SDP as the initiator → wrapper sendBacks it.
    expect(got.find((e) => e.type === 'LOCAL_SDP' && e.remoteUserId === 'u_b')).toBeTruthy()
  })

  it('forwards SEND_SYNC down into the inner peer', async () => {
    const fake = makeFakeRtc()
    const actor = createActor(peerWrapperActor, {
      input: {
        selfUserId: 'u_a', peerUserId: 'u_b', isInitiator: true,
        iceServers: [], rtcFactory: () => fake.adapter
      }
    })
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    actor.send({ type: 'SEND_SYNC', payload: '{"x":1}' })
    expect(fake.channels.get('sync')!.send).toHaveBeenCalledWith('{"x":1}')
  })

  it('SEND_FILE_DATA wraps the inner payload in a wire data frame and pushes it', async () => {
    const fake = makeFakeRtc()
    const actor = createActor(peerWrapperActor, {
      input: {
        selfUserId: 'u_a', peerUserId: 'u_b', isInitiator: true,
        iceServers: [], rtcFactory: () => fake.adapter
      }
    })
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    actor.send({
      type: 'SEND_FILE_DATA',
      payload: new Uint8Array([7, 8, 9]).buffer as ArrayBuffer
    })
    const sent = fake.channels.get('files')!.send.mock.calls[0]?.[0] as ArrayBuffer
    expect(sent).toBeInstanceOf(ArrayBuffer)
    // First byte = data tag (0x01); rest = our 3 payload bytes.
    expect(new Uint8Array(sent)).toEqual(new Uint8Array([0x01, 7, 8, 9]))
  })

  it('SEND_FILE_ACK encodes a wire ack frame', async () => {
    const fake = makeFakeRtc()
    const actor = createActor(peerWrapperActor, {
      input: {
        selfUserId: 'u_a', peerUserId: 'u_b', isInitiator: true,
        iceServers: [], rtcFactory: () => fake.adapter
      }
    })
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    actor.send({ type: 'SEND_FILE_ACK', seq: 5 })
    const sent = fake.channels.get('files')!.send.mock.calls[0]?.[0] as ArrayBuffer
    const u8 = new Uint8Array(sent)
    expect(u8[0]).toBe(0x02) // ack tag
  })

  it('decodes inbound data frames into FILE_DATA emits', async () => {
    const fake = makeFakeRtc()
    const got: any[] = []
    const actor = createActor(peerWrapperActor, {
      input: {
        selfUserId: 'u_a', peerUserId: 'u_b', isInitiator: true,
        iceServers: [], rtcFactory: () => fake.adapter
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    // Fire an inbound wire data frame from the fake files channel.
    const wire = new Uint8Array([0x01, 42, 43])
    fake.channels.get('files')!.fireMessage(wire.buffer as ArrayBuffer)
    const evt = got.find((e) => e.type === 'FILE_DATA' && e.remoteUserId === 'u_b')
    expect(evt).toBeTruthy()
    expect(new Uint8Array(evt.payload)).toEqual(new Uint8Array([42, 43]))
  })

  it('decodes inbound ack frames into FILE_ACK emits', async () => {
    const fake = makeFakeRtc()
    const got: any[] = []
    const actor = createActor(peerWrapperActor, {
      input: {
        selfUserId: 'u_a', peerUserId: 'u_b', isInitiator: true,
        iceServers: [], rtcFactory: () => fake.adapter
      }
    })
    actor.on('*', (e) => got.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    // Hand-build an ack frame: [0x02][seq LE u32]
    const wire = new ArrayBuffer(5)
    const view = new DataView(wire)
    view.setUint8(0, 0x02)
    view.setUint32(1, 11, true)
    fake.channels.get('files')!.fireMessage(wire)
    const evt = got.find((e) => e.type === 'FILE_ACK' && e.remoteUserId === 'u_b')
    expect(evt).toBeTruthy()
    expect(evt.seq).toBe(11)
  })

  it('stops the inner peer when the wrapper stops', async () => {
    const fake = makeFakeRtc()
    const actor = createActor(peerWrapperActor, {
      input: {
        selfUserId: 'u_a', peerUserId: 'u_b', isInitiator: true,
        iceServers: [], rtcFactory: () => fake.adapter
      }
    })
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    actor.stop()
    expect(fake.adapter.close).toHaveBeenCalled()
  })
})
