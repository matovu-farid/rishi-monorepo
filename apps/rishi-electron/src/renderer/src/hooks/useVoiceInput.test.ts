import { describe, expect, it } from 'vitest'
import { buildVoiceTranscriptionHeaders } from './useVoiceInput'

describe('buildVoiceTranscriptionHeaders', () => {
  it('uses a bearer token when the Electron session is authenticated', () => {
    expect(buildVoiceTranscriptionHeaders('session-token', null)).toEqual({
      Authorization: 'Bearer session-token',
      'Content-Type': 'audio/webm'
    })
  })

  it('uses the development bypass without ever sending Bearer null', () => {
    expect(buildVoiceTranscriptionHeaders(null, 'dev-secret')).toEqual({
      'X-Dev-Bypass': 'dev-secret',
      'Content-Type': 'audio/webm'
    })
  })

  it('rejects a request with neither a session token nor a bypass secret', () => {
    expect(() => buildVoiceTranscriptionHeaders(null, null)).toThrow('Not authenticated')
  })
})
