import type { ClockPort } from './types'

/**
 * Tiny clock-injected debouncer. Each `trigger(fn)` resets the timer;
 * the most recently passed `fn` runs after `delayMs` of quiet. Internal
 * to the service — not exported from `index.ts`.
 */
export interface Debouncer {
  trigger(fn: () => void): void
  cancel(): void
  isPending(): boolean
}

export function createDebouncer(clock: ClockPort, delayMs: number): Debouncer {
  let handle: ReturnType<ClockPort['setTimeout']> | null = null
  return {
    trigger(fn) {
      if (handle != null) clock.clearTimeout(handle)
      handle = clock.setTimeout(() => {
        handle = null
        fn()
      }, delayMs)
    },
    cancel() {
      if (handle != null) {
        clock.clearTimeout(handle)
        handle = null
      }
    },
    isPending() {
      return handle != null
    }
  }
}
