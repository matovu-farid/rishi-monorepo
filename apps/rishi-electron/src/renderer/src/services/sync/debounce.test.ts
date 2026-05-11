import { describe, it, expect, vi } from 'vitest'
import type { ClockPort } from './types'
import { createDebouncer } from './debounce'

/**
 * Virtual clock with manual tick advancement. Models setTimeout /
 * clearTimeout / setInterval / clearInterval against an internal queue.
 */
export function makeClock(): ClockPort & {
  tick(ms: number): void
  pendingTimers(): number
} {
  type Entry = {
    id: number
    runAt: number
    fn: () => void
    intervalMs: number | null
  }
  let now = 0
  let nextId = 1
  const entries = new Map<number, Entry>()

  function runUntil(target: number): void {
    while (true) {
      let next: Entry | null = null
      for (const e of entries.values()) {
        if (e.runAt <= target && (next === null || e.runAt < next.runAt)) next = e
      }
      if (!next) break
      now = next.runAt
      if (next.intervalMs == null) {
        entries.delete(next.id)
      } else {
        next.runAt += next.intervalMs
      }
      next.fn()
    }
    now = target
  }

  return {
    now: () => now,
    setTimeout(fn, ms) {
      const id = nextId++
      entries.set(id, { id, runAt: now + ms, fn, intervalMs: null })
      return id as unknown as ReturnType<typeof setTimeout>
    },
    clearTimeout(handle) {
      entries.delete(handle as unknown as number)
    },
    setInterval(fn, ms) {
      const id = nextId++
      entries.set(id, { id, runAt: now + ms, fn, intervalMs: ms })
      return id as unknown as ReturnType<typeof setInterval>
    },
    clearInterval(handle) {
      entries.delete(handle as unknown as number)
    },
    tick(ms) {
      runUntil(now + ms)
    },
    pendingTimers() {
      return entries.size
    }
  }
}

describe('createDebouncer', () => {
  it('runs the callback once after the delay window elapses', () => {
    const clock = makeClock()
    const cb = vi.fn()
    const d = createDebouncer(clock, 100)

    d.trigger(cb)
    clock.tick(99)
    expect(cb).not.toHaveBeenCalled()
    clock.tick(1)
    expect(cb).toHaveBeenCalledTimes(1)
  })

  it('coalesces consecutive triggers within the window into a single run', () => {
    const clock = makeClock()
    const cb = vi.fn()
    const d = createDebouncer(clock, 100)

    d.trigger(cb)
    clock.tick(50)
    d.trigger(cb)
    clock.tick(50) // 100ms since first trigger, but only 50ms since second
    expect(cb).not.toHaveBeenCalled()
    clock.tick(50)
    expect(cb).toHaveBeenCalledTimes(1)
  })

  it('cancel() drops the pending callback', () => {
    const clock = makeClock()
    const cb = vi.fn()
    const d = createDebouncer(clock, 100)

    d.trigger(cb)
    expect(d.isPending()).toBe(true)
    d.cancel()
    expect(d.isPending()).toBe(false)
    clock.tick(200)
    expect(cb).not.toHaveBeenCalled()
  })
})
