import { describe, it, expect, vi } from 'vitest'
import { createSubscribers } from './subscribers'

describe('createSubscribers', () => {
  it('notifies a single subscriber with the boolean payload', () => {
    const subs = createSubscribers()
    const listener = vi.fn()
    subs.add(listener)

    subs.notify(true)

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith(true)
  })

  it('fans a notification out to every subscriber', () => {
    const subs = createSubscribers()
    const a = vi.fn()
    const b = vi.fn()
    subs.add(a)
    subs.add(b)

    subs.notify(false)

    expect(a).toHaveBeenCalledWith(false)
    expect(b).toHaveBeenCalledWith(false)
  })

  it('remove() stops further deliveries to that listener; others still fire', () => {
    const subs = createSubscribers()
    const a = vi.fn()
    const b = vi.fn()
    subs.add(a)
    subs.add(b)

    subs.notify(true)
    subs.remove(a)
    subs.notify(false)

    expect(a).toHaveBeenCalledTimes(1)
    expect(a).toHaveBeenCalledWith(true)
    expect(b).toHaveBeenCalledTimes(2)
    expect(b).toHaveBeenNthCalledWith(1, true)
    expect(b).toHaveBeenNthCalledWith(2, false)
  })
})
