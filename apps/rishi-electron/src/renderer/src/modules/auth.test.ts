import { describe, it, expect, vi, beforeEach } from 'vitest'
import { getAuthToken } from './auth'

describe('auth module', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('getAuthToken', () => {
    it('delegates to window.api.auth.getToken', async () => {
      vi.mocked(window.api.auth.getToken).mockResolvedValueOnce('better-auth-token')
      const token = await getAuthToken()
      expect(window.api.auth.getToken).toHaveBeenCalled()
      expect(token).toBe('better-auth-token')
    })

    it('returns null when no session is active', async () => {
      vi.mocked(window.api.auth.getToken).mockResolvedValueOnce(null)
      const token = await getAuthToken()
      expect(token).toBeNull()
    })
  })
})
