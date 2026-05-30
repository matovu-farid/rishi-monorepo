import { describe, expect, it, vi } from 'vitest'
import { createActor, fromPromise } from 'xstate'
import { sessionMachine } from '@/machines/sessionMachine'
import { signalingActor } from '@/actors/sharing/signalingActor'
import { syncActor } from '@/actors/sharing/syncActor'
import type { WsAdapter } from '@/actors/sharing/wsAdapter'

function makeWsPair() {
  const buses = { a: [] as string[], b: [] as string[] }
  const listeners = {
    a: { msg: [] as Array<(s: string) => void>, open: [] as Array<() => void>, close: [] as Array<(c: number, r: string) => void> },
    b: { msg: [] as Array<(s: string) => void>, open: [] as Array<() => void>, close: [] as Array<(c: number, r: string) => void> }
  }
  function makeSide(side: 'a' | 'b'): WsAdapter {
    const other = side === 'a' ? 'b' : 'a'
    return {
      send: (d) => {
        buses[other].push(d)
        for (const cb of listeners[other].msg) cb(d)
      },
      close: () => {},
      onMessage: (cb) => void listeners[side].msg.push(cb),
      onOpen: (cb) => void listeners[side].open.push(cb),
      onClose: (cb) => void listeners[side].close.push(cb),
      onError: () => {}
    }
  }
  return {
    a: makeSide('a'),
    b: makeSide('b'),
    openBoth: () => {
      for (const cb of listeners.a.open) cb()
      for (const cb of listeners.b.open) cb()
    }
  }
}

describe('full-stack integration (no real network)', () => {
  it('two sessionMachines reach live via mock signaling', async () => {
    const host = createActor(
      sessionMachine.provide({
        actors: {
          createSessionOnDO: fromPromise(async () => ({
            sessionId: 's1', joinToken: 'jt',
            joinUrl: 'rishi://sharing/join?t=jt',
            wsUrl: 'wss://x/v1/sessions/s1/wss'
          })),
          redeemJoinToken: fromPromise(async () => { throw new Error('not used') })
        }
      })
    )
    const viewer = createActor(
      sessionMachine.provide({
        actors: {
          createSessionOnDO: fromPromise(async () => { throw new Error('not used') }),
          redeemJoinToken: fromPromise(async () => ({
            sessionId: 's1',
            bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' as const },
            requiresApproval: false,
            hostProfile: { displayName: 'Host' },
            wsUrl: 'wss://x/v1/sessions/s1/wss'
          }))
        }
      })
    )
    host.start()
    viewer.start()
    host.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Host', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    viewer.send({
      type: 'ACCEPT_INVITE',
      me: { userId: 'u_b', displayName: 'V', authToken: 'jwt' },
      sessionId: 's1', joinToken: 'jt'
    })
    await vi.waitFor(() => expect(host.getSnapshot().value).toBe('connecting'))
    await vi.waitFor(() => expect(viewer.getSnapshot().value).toBe('connecting'))
    host.send({ type: 'ROSTER_READY' })
    viewer.send({ type: 'ROSTER_READY' })
    expect(typeof host.getSnapshot().value).toBe('object')
    expect(typeof viewer.getSnapshot().value).toBe('object')
  })

  it('signalingActor pair: server-style frame on the bus reaches the typed event', async () => {
    const pair = makeWsPair()
    const eventsB: any[] = []
    const a = createActor(signalingActor, {
      input: { wsUrl: 'x', jwt: 'j', hasBookFile: true, connect: () => pair.a }
    })
    const b = createActor(signalingActor, {
      input: { wsUrl: 'x', jwt: 'j', hasBookFile: true, connect: () => pair.b }
    })
    b.on('*', (e) => eventsB.push(e))
    a.start(); b.start()
    pair.openBoth()
    pair.a.send(JSON.stringify({
      v: 1, t: 'welcome', you: 'u_b', role: 'viewer',
      sharerId: 'u_a', reconnectToken: 'rt', reservedUntil: 9
    }))
    await vi.waitFor(() => expect(eventsB.find((e) => e.type === 'WELCOME')).toBeTruthy())
    a.stop(); b.stop()
  })

  it('syncActors round-trip a format-native pdf reader.position', async () => {
    const producer = createActor(syncActor, { input: { mode: 'producer', coalesceMs: 0 } })
    const consumer = createActor(syncActor, { input: { mode: 'consumer' } })
    const consumed: any[] = []
    consumer.on('*', (e) => consumed.push(e))
    producer.on('*', (e) => {
      if (e.type === 'OUTGOING_SYNC') consumer.send({ type: 'SYNC_RECEIVED', msg: e.msg })
    })
    producer.start(); consumer.start()
    producer.send({
      type: 'BROADCAST',
      msg: {
        v: 1, t: 'reader.position', bookId: 'b', ts: 1,
        position: { format: 'pdf', page: 4, offsetY: 16, ts: 1 }
      }
    })
    await vi.waitFor(() => expect(consumed.find((e) => e.type === 'APPLY_TO_READER')).toBeTruthy())
    const applied = consumed.find((e) => e.type === 'APPLY_TO_READER')
    expect(applied.msg.position.format).toBe('pdf')
    expect(applied.msg.position.page).toBe(4)
  })

  it('syncActors round-trip a format-native epub reader.position', async () => {
    const producer = createActor(syncActor, { input: { mode: 'producer', coalesceMs: 0 } })
    const consumer = createActor(syncActor, { input: { mode: 'consumer' } })
    const consumed: any[] = []
    consumer.on('*', (e) => consumed.push(e))
    producer.on('*', (e) => {
      if (e.type === 'OUTGOING_SYNC') consumer.send({ type: 'SYNC_RECEIVED', msg: e.msg })
    })
    producer.start(); consumer.start()
    producer.send({
      type: 'BROADCAST',
      msg: {
        v: 1, t: 'reader.position', bookId: 'b', ts: 1,
        position: { format: 'epub', cfi: 'cfi/x', ts: 1 }
      }
    })
    await vi.waitFor(() => expect(consumed.find((e) => e.type === 'APPLY_TO_READER')).toBeTruthy())
    const applied = consumed.find((e) => e.type === 'APPLY_TO_READER')
    expect(applied.msg.position.format).toBe('epub')
    expect(applied.msg.position.cfi).toBe('cfi/x')
  })
})
