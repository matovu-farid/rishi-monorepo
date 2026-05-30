import { describe, expect, it, vi } from 'vitest'
import { createActor } from 'xstate'
import { signalingActor } from '../signalingActor'
import type { WsAdapter } from '../wsAdapter'

function makeFakeWs() {
  const sent: string[] = []
  let onMsg: ((s: string) => void) | null = null
  let onOpen: (() => void) | null = null
  let onClose: ((c: number, r: string) => void) | null = null
  const adapter: WsAdapter = {
    send: (d) => sent.push(d),
    close: vi.fn(),
    onMessage: (cb) => { onMsg = cb },
    onOpen: (cb) => { onOpen = cb },
    onClose: (cb) => { onClose = cb },
    onError: () => {}
  }
  return {
    adapter,
    sent,
    fireOpen: () => onOpen?.(),
    deliver: (m: object) => onMsg?.(JSON.stringify(m)),
    fireClose: (c = 1006, r = '') => onClose?.(c, r)
  }
}

describe('signalingActor', () => {
  it('emits CONNECTED on open and sends hello with hasBookFile', () => {
    const fake = makeFakeWs()
    const emitted: any[] = []
    const actor = createActor(signalingActor, {
      input: {
        wsUrl: 'wss://x/v1/sessions/s/wss',
        jwt: 'jwt-tok',
        hasBookFile: true,
        connect: () => fake.adapter
      }
    })
    actor.on('*', (e) => emitted.push(e))
    actor.start()
    fake.fireOpen()
    expect(emitted.find((e) => e.type === 'CONNECTED')).toBeTruthy()
    expect(JSON.parse(fake.sent[0])).toEqual({ v: 1, t: 'hello', hasBookFile: true })
  })

  it('parses ServerMsg frames and re-emits them typed', () => {
    const fake = makeFakeWs()
    const emitted: any[] = []
    const actor = createActor(signalingActor, {
      input: {
        wsUrl: 'wss://x',
        jwt: 'j',
        hasBookFile: false,
        connect: () => fake.adapter
      }
    })
    actor.on('*', (e) => emitted.push(e))
    actor.start()
    fake.fireOpen()
    fake.deliver({
      v: 1, t: 'welcome', you: 'u_a', role: 'host',
      sharerId: 'u_a', reconnectToken: 'rt', reservedUntil: 9999
    })
    const welcome = emitted.find((e) => e.type === 'WELCOME')
    expect(welcome).toBeTruthy()
    expect(welcome.msg.you).toBe('u_a')
  })

  it('drops invalid frames silently and emits PROTOCOL_ERROR', () => {
    const fake = makeFakeWs()
    const emitted: any[] = []
    const actor = createActor(signalingActor, {
      input: { wsUrl: 'wss://x', jwt: 'j', hasBookFile: false, connect: () => fake.adapter }
    })
    actor.on('*', (e) => emitted.push(e))
    actor.start()
    fake.fireOpen()
    fake.deliver({ not: 'a server msg' })
    expect(emitted.find((e) => e.type === 'PROTOCOL_ERROR')).toBeTruthy()
  })

  it('emits SIGNALING_DROPPED on close', () => {
    const fake = makeFakeWs()
    const emitted: any[] = []
    const actor = createActor(signalingActor, {
      input: { wsUrl: 'wss://x', jwt: 'j', hasBookFile: false, connect: () => fake.adapter }
    })
    actor.on('*', (e) => emitted.push(e))
    actor.start()
    fake.fireOpen()
    fake.fireClose(1006, 'lost')
    expect(emitted.find((e) => e.type === 'SIGNALING_DROPPED')).toBeTruthy()
  })

  it('forwards SEND events as ClientMsg JSON', () => {
    const fake = makeFakeWs()
    const actor = createActor(signalingActor, {
      input: { wsUrl: 'wss://x', jwt: 'j', hasBookFile: false, connect: () => fake.adapter }
    })
    actor.start()
    fake.fireOpen()
    actor.send({ type: 'SEND', payload: { v: 1, t: 'request.sharer' } })
    expect(JSON.parse(fake.sent.at(-1)!)).toEqual({ v: 1, t: 'request.sharer' })
  })
})
