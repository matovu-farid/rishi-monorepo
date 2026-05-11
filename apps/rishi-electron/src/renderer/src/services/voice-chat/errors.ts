import { Data } from 'effect'
import type { VoiceErrorReason } from './types'

/**
 * Activation-pipeline errors. Each `_tag` maps 1-to-1 to a Stage 1
 * `VoiceErrorReason` value (with `'unknown'` collapsed into `ConnectFailedError`
 * since Stage 1's classifyError() falls through there for unknown causes).
 */

export class MicDeniedError extends Data.TaggedError('MicDeniedError')<{
  readonly name: 'NotAllowedError' | 'NotFoundError' | 'Unknown'
  readonly message: string
}> {}

export class AuthFailedError extends Data.TaggedError('AuthFailedError')<{
  readonly message: string
}> {}

export class ConnectTimeoutError extends Data.TaggedError('ConnectTimeoutError')<{
  readonly ms: number
}> {}

export class ConnectFailedError extends Data.TaggedError('ConnectFailedError')<{
  readonly message: string
}> {}

export class SessionError extends Data.TaggedError('SessionError')<{
  readonly message: string
}> {}

export type ActivationError =
  | MicDeniedError
  | AuthFailedError
  | ConnectTimeoutError
  | ConnectFailedError
  | SessionError

/** Map a tagged activation error to the Stage 1 VoiceErrorReason enum. */
export function reasonOf(e: ActivationError): VoiceErrorReason {
  switch (e._tag) {
    case 'MicDeniedError':
      return 'mic_denied'
    case 'AuthFailedError':
      return 'auth_failed'
    case 'ConnectTimeoutError':
      return 'timeout'
    case 'ConnectFailedError':
      return 'connect_failed'
    case 'SessionError':
      return 'session_error'
  }
}

/**
 * Map an activation error to the plain `Error` the public `activate()` Promise
 * rejects with. Message strings are byte-identical to Stage 1 so that
 * existing service.test.ts assertions pass without modification.
 *
 * IMPORTANT: MicDeniedError preserves `.name` (e.g. 'NotAllowedError') because
 * service.test.ts line 493 asserts `rejects.toMatchObject({ name: 'NotAllowedError' })`.
 */
export function toPublicError(e: ActivationError): Error {
  switch (e._tag) {
    case 'MicDeniedError': {
      const err = new Error(e.message || e.name)
      Object.defineProperty(err, 'name', { value: e.name, writable: false })
      return err
    }
    case 'AuthFailedError':
      return new Error(e.message || 'Not authenticated')
    case 'ConnectTimeoutError':
      return new Error(`Realtime session connect timed out after ${e.ms / 1000}s`)
    case 'ConnectFailedError':
      return new Error(e.message)
    case 'SessionError':
      return new Error(e.message)
  }
}
