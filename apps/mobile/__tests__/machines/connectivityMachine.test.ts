/**
 * Tests for connectivityMachine ported from electron.
 *
 * Mirrors the electron test contract verbatim (online -> offline -> online,
 * idempotent OFFLINE while offline). The machine itself has zero electron
 * dependencies, so this port is a 1:1 copy.
 */
import { createActor } from 'xstate'
import { connectivityMachine } from '@/lib/machines/connectivityMachine'

describe('connectivityMachine (mobile)', () => {
  it('starts in online state by default', () => {
    const actor = createActor(connectivityMachine).start()
    expect(actor.getSnapshot().value).toBe('online')
  })

  it('transitions to offline on OFFLINE event', () => {
    const actor = createActor(connectivityMachine).start()
    actor.send({ type: 'OFFLINE' })
    expect(actor.getSnapshot().value).toBe('offline')
  })

  it('transitions back to online on ONLINE event', () => {
    const actor = createActor(connectivityMachine).start()
    actor.send({ type: 'OFFLINE' })
    actor.send({ type: 'ONLINE' })
    expect(actor.getSnapshot().value).toBe('online')
  })

  it('OFFLINE while already offline is a no-op', () => {
    const actor = createActor(connectivityMachine).start()
    actor.send({ type: 'OFFLINE' })
    actor.send({ type: 'OFFLINE' })
    expect(actor.getSnapshot().value).toBe('offline')
  })

  it('ONLINE while already online is a no-op', () => {
    const actor = createActor(connectivityMachine).start()
    actor.send({ type: 'ONLINE' })
    expect(actor.getSnapshot().value).toBe('online')
  })
})
