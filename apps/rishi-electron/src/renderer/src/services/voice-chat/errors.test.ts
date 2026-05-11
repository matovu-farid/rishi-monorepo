import { describe, it, expect } from 'vitest'
import {
  MicDeniedError,
  AuthFailedError,
  ConnectTimeoutError,
  ConnectFailedError,
  SessionError,
  reasonOf,
  toPublicError
} from './errors'

describe('voice-chat tagged errors', () => {
  it('MicDeniedError → public Error preserves the NotAllowedError name', () => {
    const e = new MicDeniedError({ name: 'NotAllowedError', message: 'Permission denied' })
    expect(reasonOf(e)).toBe('mic_denied')
    const pub = toPublicError(e)
    expect(pub).toBeInstanceOf(Error)
    expect(pub.name).toBe('NotAllowedError')
    expect(pub.message).toBe('Permission denied')
  })

  it('AuthFailedError → reason "auth_failed" and message preserved', () => {
    const e = new AuthFailedError({ message: 'Not authenticated' })
    expect(reasonOf(e)).toBe('auth_failed')
    expect(toPublicError(e).message).toBe('Not authenticated')
  })

  it('ConnectTimeoutError → message uses the Stage-1 "timed out after Ns" format', () => {
    const e = new ConnectTimeoutError({ ms: 60_000 })
    expect(reasonOf(e)).toBe('timeout')
    expect(toPublicError(e).message).toBe('Realtime session connect timed out after 60s')
  })

  it('ConnectFailedError → reason "connect_failed" with message verbatim', () => {
    const e = new ConnectFailedError({ message: 'boom' })
    expect(reasonOf(e)).toBe('connect_failed')
    expect(toPublicError(e).message).toBe('boom')
  })

  it('SessionError → reason "session_error" with message verbatim', () => {
    const e = new SessionError({ message: 'session blew up' })
    expect(reasonOf(e)).toBe('session_error')
    expect(toPublicError(e).message).toBe('session blew up')
  })
})
