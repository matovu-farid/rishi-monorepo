import { describe, it, expect } from 'vitest'
import { createActor } from 'xstate'
import { connectivityMachine } from '../connectivityMachine'

describe('connectivityMachine', () => {
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
})
