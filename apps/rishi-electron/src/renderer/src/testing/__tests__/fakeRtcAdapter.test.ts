import { describe, expect, it } from 'vitest'
import { createActor } from 'xstate'
import { fakeRtcFactory } from '../fakeRtcAdapter'
import { peerActor, type PeerOutEvent } from '@/actors/sharing/peerActor'

describe('fakeRtcAdapter', () => {
  it('produces an answer SDP when fed a remote offer', async () => {
    const adapter = fakeRtcFactory({ iceServers: [] })
    await adapter.setRemoteDescription({ type: 'offer', sdp: 'X' })
    const ans = await adapter.createAnswer()
    expect(ans.sdp).toBe('FAKE_ANSWER_SDP')
  })

  it('fires data-channel `open` on the microtask queue', async () => {
    const adapter = fakeRtcFactory({ iceServers: [] })
    const ch = adapter.createDataChannel('sync', { ordered: true })
    let opened = false
    ch.onOpen(() => { opened = true })
    // queueMicrotask drains on the next tick.
    await new Promise<void>((r) => queueMicrotask(r))
    expect(opened).toBe(true)
    expect(ch.readyState).toBe('open')
  })

  it('fires `connected` connectionstate so peerActor emits PEER_CONNECTED', async () => {
    const events: PeerOutEvent[] = []
    const actor = createActor(peerActor, {
      input: {
        remoteUserId: 'u_b',
        initiator: true,
        iceServers: [],
        factory: fakeRtcFactory
      }
    })
    actor.on('*', (e) => events.push(e as PeerOutEvent))
    actor.start()
    // Drain microtasks (queueMicrotask + the actor's own promise chain).
    await new Promise<void>((r) => setTimeout(r, 0))
    expect(events.find((e) => e.type === 'PEER_CONNECTED')).toBeTruthy()
    expect(events.find((e) => e.type === 'LOCAL_SDP' && e.kind === 'offer')).toBeTruthy()
  })
})
