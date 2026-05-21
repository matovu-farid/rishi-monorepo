import { describe, it, expect } from 'vitest'
import { createActor } from 'xstate'
import { voiceChatMachine } from './machine'

function startActor() {
  return createActor(voiceChatMachine).start()
}

describe('voiceChatMachine', () => {
  it('starts in idle with no error', () => {
    const actor = startActor()
    expect(actor.getSnapshot().value).toBe('idle')
    expect(actor.getSnapshot().context.error).toBeNull()
  })

  it('idle → connecting → active happy path', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    expect(actor.getSnapshot().value).toBe('connecting')
    actor.send({ type: 'CONNECT_SUCCEEDED' })
    expect(actor.getSnapshot().value).toBe('active')
  })

  it('CONNECT_FAILED stores error and lands in error state', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_FAILED', reason: 'timeout', message: 'too slow' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('error')
    expect(snap.context.error).toEqual({ reason: 'timeout', message: 'too slow' })
  })

  it('active → paused via DEACTIVATE', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_SUCCEEDED' })
    actor.send({ type: 'DEACTIVATE' })
    expect(actor.getSnapshot().value).toBe('paused')
  })

  it('paused → connecting on CONNECT_STARTED (warm path)', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_SUCCEEDED' })
    actor.send({ type: 'DEACTIVATE' })
    actor.send({ type: 'CONNECT_STARTED' })
    expect(actor.getSnapshot().value).toBe('connecting')
  })

  it('OFFLINE event jumps to offline from any state', () => {
    for (const seq of [
      [{ type: 'OFFLINE' as const }],
      [{ type: 'CONNECT_STARTED' as const }, { type: 'OFFLINE' as const }],
      [
        { type: 'CONNECT_STARTED' as const },
        { type: 'CONNECT_SUCCEEDED' as const },
        { type: 'OFFLINE' as const }
      ],
      [
        { type: 'CONNECT_STARTED' as const },
        { type: 'CONNECT_SUCCEEDED' as const },
        { type: 'DEACTIVATE' as const },
        { type: 'OFFLINE' as const }
      ]
    ]) {
      const actor = startActor()
      seq.forEach((evt) => actor.send(evt))
      expect(actor.getSnapshot().value).toBe('offline')
    }
  })

  it('ONLINE from offline returns to idle and clears error', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_FAILED', reason: 'connect_failed' })
    actor.send({ type: 'OFFLINE' })
    actor.send({ type: 'ONLINE' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('idle')
    expect(snap.context.error).toBeNull()
  })

  it('DISMISS_ERROR from error returns to idle and clears error', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_FAILED', reason: 'mic_denied' })
    expect(actor.getSnapshot().value).toBe('error')
    actor.send({ type: 'DISMISS_ERROR' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('idle')
    expect(snap.context.error).toBeNull()
  })

  it('DISPOSE from any state returns to idle and clears error', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_FAILED', reason: 'session_error' })
    actor.send({ type: 'DISPOSE' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('idle')
    expect(snap.context.error).toBeNull()
  })

  it('SESSION_ERROR from active transitions to error with reason', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_SUCCEEDED' })
    actor.send({ type: 'SESSION_ERROR', reason: 'session_error', message: 'lost connection' })
    const snap = actor.getSnapshot()
    expect(snap.value).toBe('error')
    expect(snap.context.error).toEqual({ reason: 'session_error', message: 'lost connection' })
  })

  it('error → connecting on CONNECT_STARTED (retry)', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_FAILED', reason: 'timeout' })
    actor.send({ type: 'CONNECT_STARTED' })
    expect(actor.getSnapshot().value).toBe('connecting')
  })

  it('CONNECT_SUCCEEDED clears any prior error', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_FAILED', reason: 'timeout' })
    actor.send({ type: 'CONNECT_STARTED' })
    actor.send({ type: 'CONNECT_SUCCEEDED' })
    expect(actor.getSnapshot().context.error).toBeNull()
  })
})
