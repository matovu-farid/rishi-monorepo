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
    let stopped = false
    let timer: ReturnType<typeof setTimeout> | null = null

    async function attempt(i: number): Promise<void> {
      if (stopped) return
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
      timer = setTimeout(async () => {
        if (stopped) return
        try {
          const { ref } = await input.tryConnect()
          if (stopped) return
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
      }, input.schedule[i])
    }

    attempt(0)

    return () => {
      stopped = true
      if (timer) clearTimeout(timer)
    }
  }
)
