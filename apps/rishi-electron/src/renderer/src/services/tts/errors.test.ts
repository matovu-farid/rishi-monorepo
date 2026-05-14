import { describe, it, expect } from 'vitest'
import {
  AuthFailedError,
  TransportError,
  ParseError,
  CancelledError,
  QueueOverflowError,
  toPublicError
} from './errors'

describe('tagged errors → toPublic()', () => {
  it('AuthFailedError wraps a non-Error cause into a fresh Error', () => {
    const e = new AuthFailedError({ cause: 'no session' })
    const pub = toPublicError(e)
    expect(pub).toBeInstanceOf(Error)
    expect(pub.message).toBe('no session')
  })

  it('AuthFailedError passes a thrown Error through unchanged', () => {
    const original = new Error('original-msg')
    const e = new AuthFailedError({ cause: original })
    expect(toPublicError(e)).toBe(original)
  })

  it('TransportError.toPublic() returns Error with the stored message verbatim', () => {
    const e = new TransportError({
      status: 503,
      retryable: true,
      retryAfterMs: null,
      message: 'TTS API error 503 Service Unavailable - down'
    })
    expect(toPublicError(e).message).toBe('TTS API error 503 Service Unavailable - down')
  })

  it('ParseError.toPublic() prefixes "TTS API returned "', () => {
    expect(toPublicError(new ParseError({ reason: 'empty buffer' })).message).toBe(
      'TTS API returned empty buffer'
    )
  })

  it('CancelledError and QueueOverflowError have fixed public messages', () => {
    expect(toPublicError(new CancelledError({ requestId: 'b-c' })).message).toBe(
      'Request cancelled'
    )
    expect(toPublicError(new QueueOverflowError({ requestId: 'b-c' })).message).toBe(
      'Dropped from queue (low priority)'
    )
  })
})
