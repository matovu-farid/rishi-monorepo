// Pins the `rishi://sharing/join?t=<token>` URL parser. The deep-link
// handler routes join tokens captured from macOS open-url events, the
// first-launch argv, and the second-instance argv — all three sources feed
// `parseJoinToken`. A bug here lands the user in the wrong session or
// silently drops the join.
import { describe, it, expect } from 'vitest'
import { parseJoinToken } from '../deepLink.js'

describe('parseJoinToken', () => {
  it('extracts the token from a well-formed join URL', () => {
    expect(parseJoinToken('rishi://sharing/join?t=abc123')).toBe('abc123')
  })

  it('returns null when the protocol is not rishi:', () => {
    expect(parseJoinToken('https://sharing/join?t=abc123')).toBeNull()
  })

  it('returns null when the host is not "sharing"', () => {
    expect(parseJoinToken('rishi://other/join?t=abc123')).toBeNull()
  })

  it('returns null when the pathname does not start with "join"', () => {
    expect(parseJoinToken('rishi://sharing/leave?t=abc123')).toBeNull()
  })

  it('returns null when the pathname is a join-prefixed segment like "joinx"', () => {
    // `startsWith('join')` would incorrectly accept this; the tightened
    // parser splits on `/` and requires an exact `join` segment.
    expect(parseJoinToken('rishi://sharing/joinx?t=abc123')).toBeNull()
  })

  it('returns null when the t param is missing', () => {
    expect(parseJoinToken('rishi://sharing/join')).toBeNull()
  })

  it('returns null on malformed input (does not throw)', () => {
    expect(parseJoinToken('not-a-url')).toBeNull()
    expect(parseJoinToken('')).toBeNull()
  })
})
