import { describe, expect, it, vi } from 'vitest'
import { createActor, fromPromise } from 'xstate'
import { sessionMachine } from '../sessionMachine'

function host() {
  return sessionMachine.provide({
    actors: {
      createSessionOnDO: fromPromise(async () => ({
        sessionId: 's1', joinToken: 'jt',
        joinUrl: 'rishi://sharing/join?t=jt',
        wsUrl: 'wss://x/v1/sessions/s1/wss'
      })),
      redeemJoinToken: fromPromise(async () => { throw new Error('not used') })
    }
  })
}

async function intoLive() {
  const a = createActor(host())
  a.start()
  a.send({
    type: 'CREATE_SESSION',
    me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
    bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
    requiresApproval: false
  })
  await vi.waitFor(() => expect(a.getSnapshot().value).toBe('connecting'))
  a.send({ type: 'ROSTER_READY' })
  return a
}

describe('sessionMachine recovery', () => {
  it('SIGNALING_DROPPED → reconnecting → RECONNECTED → live', async () => {
    const a = await intoLive()
    a.send({ type: 'SIGNALING_DROPPED' })
    expect(a.getSnapshot().value).toBe('reconnecting')
    a.send({ type: 'RECONNECTED' })
    expect(typeof a.getSnapshot().value).toBe('object')
  })

  it('HARD_FAIL while reconnecting → ending → idle', async () => {
    const a = await intoLive()
    a.send({ type: 'SIGNALING_DROPPED' })
    a.send({ type: 'HARD_FAIL', reason: 'exhausted' })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('idle'), { timeout: 2000 })
  })

  it('KICKED → ending (no books) and stores error', async () => {
    const a = await intoLive()
    a.send({ type: 'KICKED', reason: 'host_kicked_you' })
    expect(['ending', 'idle']).toContain(a.getSnapshot().value as string)
    expect(a.getSnapshot().context.error?.code).toBe('kicked')
  })

  it('KICKED with received books → promptingKeepBooks', async () => {
    const a = await intoLive()
    a.send({
      type: 'BOOK_RECEIVED',
      bookId: 'b2', contentHash: 'h2', format: 'epub',
      receivedFromUserId: 'u_b', localPath: '/p/h2.epub', title: 'X'
    })
    a.send({ type: 'KICKED', reason: 'host_kicked_you' })
    expect(a.getSnapshot().value).toBe('promptingKeepBooks')
  })

  it('DISCARD_BOOKS clears receivedBooks on the way out', async () => {
    const a = await intoLive()
    a.send({
      type: 'BOOK_RECEIVED',
      bookId: 'b2', contentHash: 'h2', format: 'epub',
      receivedFromUserId: 'u_b', localPath: '/p/h2.epub', title: 'X'
    })
    a.send({ type: 'LEAVE' })
    expect(a.getSnapshot().value).toBe('promptingKeepBooks')
    a.send({ type: 'DISCARD_BOOKS' })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('idle'), { timeout: 2000 })
    expect(a.getSnapshot().context.receivedBooks).toEqual([])
  })

  it('PEER_JOINED + PEER_LEFT update participants map', async () => {
    const a = await intoLive()
    a.send({
      type: 'PEER_JOINED', userId: 'u_b',
      participant: {
        userId: 'u_b',
        profile: { displayName: 'B' },
        joinedAt: 1, hasBookFile: true,
        micState: 'unmuted', connectionState: 'connected'
      }
    })
    expect(a.getSnapshot().context.participants.has('u_b')).toBe(true)
    a.send({ type: 'PEER_LEFT', userId: 'u_b' })
    expect(a.getSnapshot().context.participants.has('u_b')).toBe(false)
  })
})
