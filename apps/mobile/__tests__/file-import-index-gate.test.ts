/**
 * Unit test for the indexBook gating logic in lib/file-import.ts.
 *
 * We don't import file-import.ts directly because it depends on
 * expo-file-system (which requires the native module). Instead, we
 * test the pure predicate `shouldSkipIndexing` which both call sites
 * use to decide whether to fire indexBook.
 */
import { describe, it, expect } from '@jest/globals'
import { shouldSkipIndexing } from '@/lib/file-import-index-gate'

describe('shouldSkipIndexing', () => {
  it('skips when E2E mode is on, regardless of token', () => {
    expect(shouldSkipIndexing({ isE2E: true, sessionToken: 'tok' })).toBe(true)
    expect(shouldSkipIndexing({ isE2E: true, sessionToken: null })).toBe(true)
  })

  it('skips in production when no session token is present', () => {
    expect(shouldSkipIndexing({ isE2E: false, sessionToken: null })).toBe(true)
  })

  it('proceeds in production when a session token is present', () => {
    expect(shouldSkipIndexing({ isE2E: false, sessionToken: 'tok' })).toBe(false)
  })

  it('treats empty-string token as missing', () => {
    expect(shouldSkipIndexing({ isE2E: false, sessionToken: '' })).toBe(true)
  })
})
