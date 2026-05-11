import { Data } from 'effect'

export class AuthFailedError extends Data.TaggedError('AuthFailedError')<{
  readonly cause: unknown
}> {
  toPublic(): Error {
    return this.cause instanceof Error ? this.cause : new Error(String(this.cause))
  }
}

export class TransportError extends Data.TaggedError('TransportError')<{
  readonly status: number | null
  readonly retryable: boolean
  readonly retryAfterMs: number | null
  readonly message: string
}> {
  toPublic(): Error {
    // Match Stage 1's TtsTransportError.message format byte-for-byte.
    return new Error(this.message)
  }
}

export class ParseError extends Data.TaggedError('ParseError')<{
  readonly reason: string
}> {
  toPublic(): Error {
    return new Error(`TTS API returned ${this.reason}`)
  }
}

export class CancelledError extends Data.TaggedError('CancelledError')<{
  readonly requestId: string
}> {
  toPublic(): Error {
    return new Error('Request cancelled')
  }
}

export class QueueOverflowError extends Data.TaggedError('QueueOverflowError')<{
  readonly requestId: string
}> {
  toPublic(): Error {
    return new Error('Dropped from queue (low priority)')
  }
}

export type TtsTaggedError =
  | AuthFailedError
  | TransportError
  | ParseError
  | CancelledError
  | QueueOverflowError

export function toPublicError(e: TtsTaggedError): Error {
  return e.toPublic()
}
