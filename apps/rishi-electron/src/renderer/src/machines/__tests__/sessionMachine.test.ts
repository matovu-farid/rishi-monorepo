import { describe, expect, it, vi } from 'vitest'
import { createActor, fromPromise } from 'xstate'
import { sessionMachine } from '../sessionMachine'

const HOST_PROFILE = { displayName: 'Host', avatarUrl: undefined }

function provideDeps(opts: {
  createOk?: boolean
  redeemOk?: boolean
  redeemRequiresApproval?: boolean
} = {}) {
  return sessionMachine.provide({
    actors: {
      createSessionOnDO: fromPromise(async () => {
        if (opts.createOk === false) throw new Error('create_failed')
        return {
          sessionId: 's1',
          joinToken: 'jt',
          joinUrl: 'rishi://sharing/join?t=jt',
          wsUrl: 'wss://x/v1/sessions/s1/wss'
        }
      }),
      redeemJoinToken: fromPromise(async () => {
        if (opts.redeemOk === false) throw new Error('redeem_failed')
        return {
          sessionId: 's1',
          bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' as const },
          requiresApproval: opts.redeemRequiresApproval ?? false,
          hostProfile: HOST_PROFILE,
          wsUrl: 'wss://x/v1/sessions/s1/wss'
        }
      })
    }
  })
}

describe('sessionMachine', () => {
  it('starts in idle with empty receivedBooks', () => {
    const a = createActor(provideDeps())
    a.start()
    expect(a.getSnapshot().value).toBe('idle')
    expect(a.getSnapshot().context.receivedBooks).toEqual([])
  })

  it('CREATE_SESSION → creating → connecting on success', async () => {
    const a = createActor(provideDeps())
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('connecting'))
    expect(a.getSnapshot().context.sessionId).toBe('s1')
    expect(a.getSnapshot().context.role).toBe('host')
  })

  it('ACCEPT_INVITE with requiresApproval=true → awaitingApproval', async () => {
    const a = createActor(provideDeps({ redeemRequiresApproval: true }))
    a.start()
    a.send({
      type: 'ACCEPT_INVITE',
      me: { userId: 'u_b', displayName: 'B', authToken: 'jwt' },
      sessionId: 's1',
      joinToken: 'jt'
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('awaitingApproval'))
  })

  it('redeem failure → failed', async () => {
    const a = createActor(provideDeps({ redeemOk: false }))
    a.start()
    a.send({
      type: 'ACCEPT_INVITE',
      me: { userId: 'u_b', displayName: 'B', authToken: 'jwt' },
      sessionId: 's1', joinToken: 'jt'
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('failed'))
  })

  it('BOOK_RECEIVED appends to receivedBooks during live', async () => {
    const a = createActor(provideDeps())
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('connecting'))
    a.send({ type: 'ROSTER_READY' })
    a.send({
      type: 'BOOK_RECEIVED',
      bookId: 'b2', contentHash: 'h2', format: 'epub',
      receivedFromUserId: 'u_b', localPath: '/p/h2.epub',
      title: "Friend's Book"
    })
    expect(a.getSnapshot().context.receivedBooks).toHaveLength(1)
    expect(a.getSnapshot().context.receivedBooks[0].bookId).toBe('b2')
  })

  it('LEAVE from live transitions through promptingKeepBooks when books were received', async () => {
    const a = createActor(provideDeps())
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('connecting'))
    a.send({ type: 'ROSTER_READY' })
    a.send({
      type: 'BOOK_RECEIVED',
      bookId: 'b2', contentHash: 'h2', format: 'epub',
      receivedFromUserId: 'u_b', localPath: '/p/h2.epub',
      title: "Friend's Book"
    })
    a.send({ type: 'LEAVE' })
    expect(a.getSnapshot().value).toBe('promptingKeepBooks')
    a.send({ type: 'KEEP_BOOKS' })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('idle'), { timeout: 2000 })
  })

  it('LEAVE from live skips prompt and goes to idle when no books were received', async () => {
    const a = createActor(provideDeps())
    a.start()
    a.send({
      type: 'CREATE_SESSION',
      me: { userId: 'u_a', displayName: 'Me', authToken: 'jwt' },
      bookContext: { bookId: 'b', contentHash: 'h', format: 'epub' },
      requiresApproval: false
    })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('connecting'))
    a.send({ type: 'ROSTER_READY' })
    a.send({ type: 'LEAVE' })
    await vi.waitFor(() => expect(a.getSnapshot().value).toBe('idle'), { timeout: 2000 })
  })
})
