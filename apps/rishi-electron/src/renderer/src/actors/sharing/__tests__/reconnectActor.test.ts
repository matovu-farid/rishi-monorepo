import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { createActor } from 'xstate'
import { reconnectActor } from '../reconnectActor'

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

describe('reconnectActor', () => {
  it('schedules attempts with exponential backoff and emits RECONNECTED on success', async () => {
    const attemptTimes: number[] = []
    let attempt = 0
    const tryConnect = vi.fn(async () => {
      attemptTimes.push(Date.now())
      attempt++
      if (attempt < 3) throw new Error('still down')
      return { ref: 'fresh' }
    })
    const events: any[] = []
    const start = Date.now()
    const actor = createActor(reconnectActor, {
      input: {
        schedule: [500, 1000, 2000],
        reservedUntil: start + 60_000,
        tryConnect
      }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    await vi.advanceTimersByTimeAsync(500)
    await vi.advanceTimersByTimeAsync(1000)
    await vi.advanceTimersByTimeAsync(2000)
    expect(tryConnect).toHaveBeenCalledTimes(3)
    const reconnected = events.find((e) => e.type === 'RECONNECTED')
    expect(reconnected).toBeTruthy()
    expect(reconnected.freshSignalingRef).toBe('fresh')
  })

  it('emits HARD_FAIL when reservedUntil expires before success', async () => {
    const tryConnect = vi.fn(async () => {
      throw new Error('down')
    })
    const events: any[] = []
    const start = Date.now()
    const actor = createActor(reconnectActor, {
      input: {
        schedule: [500, 1000, 2000, 4000, 8000],
        reservedUntil: start + 1_000,
        tryConnect
      }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    await vi.advanceTimersByTimeAsync(500)
    await vi.advanceTimersByTimeAsync(1000)
    await vi.advanceTimersByTimeAsync(1)
    expect(events.find((e) => e.type === 'HARD_FAIL')).toBeTruthy()
  })

  it('exhausts schedule and emits HARD_FAIL with reason exhausted', async () => {
    const tryConnect = vi.fn(async () => {
      throw new Error('down')
    })
    const events: any[] = []
    const actor = createActor(reconnectActor, {
      input: { schedule: [10, 10], reservedUntil: Date.now() + 60_000, tryConnect }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    await vi.advanceTimersByTimeAsync(10)
    await vi.advanceTimersByTimeAsync(10)
    const fail = events.find((e) => e.type === 'HARD_FAIL')
    expect(fail?.reason).toBe('exhausted')
  })
})
