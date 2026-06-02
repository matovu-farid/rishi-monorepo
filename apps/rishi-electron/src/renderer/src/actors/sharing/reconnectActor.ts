import { fromCallback } from 'xstate'
import { recordSharingBreadcrumb, recordSharingError } from '@/sharing/sentryScope'

export type ReconnectInput = {
  schedule: number[]
  reservedUntil: number
  tryConnect: () => Promise<{ ref: unknown }>
}

export type ReconnectOutEvent =
  | { type: 'RECONNECTED'; freshSignalingRef: unknown }
  | { type: 'HARD_FAIL'; reason: 'exhausted' | 'reservation_expired' }

export const reconnectActor = fromCallback<never, ReconnectInput, ReconnectOutEvent>(
  ({ emit, input }) => {
    // `stopped` lives on an object so reads aren't narrowed by TS
    // control-flow analysis. The cleanup callback below mutates it from a
    // closure TS can't observe; without this every `state.stopped` read
    // here would be flagged as dead code.
    const state = { stopped: false }
    let timer: ReturnType<typeof setTimeout> | null = null

    // Sync orchestrator: the actual await happens inside the timer callback,
    // not in `attempt` itself, so this function has no awaits and shouldn't
    // be `async`.
    function attempt(i: number): void {
      if (state.stopped) return
      if (Date.now() >= input.reservedUntil) {
        recordSharingError(new Error('reconnect reservation_expired'), {
          actor: 'reconnectActor',
          reason: 'reservation_expired'
        })
        emit({ type: 'HARD_FAIL', reason: 'reservation_expired' })
        return
      }
      if (i >= input.schedule.length) {
        recordSharingError(new Error('reconnect exhausted'), {
          actor: 'reconnectActor',
          reason: 'exhausted',
          attempts: input.schedule.length
        })
        emit({ type: 'HARD_FAIL', reason: 'exhausted' })
        return
      }
      recordSharingBreadcrumb('reconnect.attempt', {
        attempt: i + 1,
        delayMs: input.schedule[i]
      })
      timer = setTimeout(() => {
        if (state.stopped) return
        void (async () => {
          try {
            const { ref } = await input.tryConnect()
            if (state.stopped) return
            emit({ type: 'RECONNECTED', freshSignalingRef: ref })
          } catch {
            if (Date.now() >= input.reservedUntil) {
              recordSharingError(new Error('reconnect reservation_expired'), {
                actor: 'reconnectActor',
                reason: 'reservation_expired'
              })
              emit({ type: 'HARD_FAIL', reason: 'reservation_expired' })
              return
            }
            attempt(i + 1)
          }
        })()
      }, input.schedule[i])
    }

    attempt(0)

    return () => {
      state.stopped = true
      if (timer) clearTimeout(timer)
    }
  }
)
