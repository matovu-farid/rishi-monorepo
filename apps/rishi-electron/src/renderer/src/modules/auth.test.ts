import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { getAuthToken, clearAuth, getUserFromStore, saveUserToStore } from './auth'

describe('auth module', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  afterEach(() => {
    delete (window as any).Clerk
  })

  describe('getAuthToken', () => {
    it('returns null when window.Clerk is undefined', async () => {
      const token = await getAuthToken()
      expect(token).toBeNull()
    })

    it('returns null when there is no active session', async () => {
      ;(window as any).Clerk = { session: null }
      const token = await getAuthToken()
      expect(token).toBeNull()
    })

    it('returns the Clerk session token when available', async () => {
      const getToken = vi.fn().mockResolvedValue('clerk-jwt')
      ;(window as any).Clerk = { session: { getToken } }
      const token = await getAuthToken()
      expect(token).toBe('clerk-jwt')
      expect(getToken).toHaveBeenCalled()
    })

    it('returns null and swallows errors when getToken throws', async () => {
      const getToken = vi.fn().mockRejectedValue(new Error('boom'))
      ;(window as any).Clerk = { session: { getToken } }
      const token = await getAuthToken()
      expect(token).toBeNull()
    })
  })

  describe('user store delegates', () => {
    it('clearAuth delegates to electron.clearAuth', async () => {
      await clearAuth()
      expect(window.electron.clearAuth).toHaveBeenCalled()
    })

    it('getUserFromStore delegates to electron.getUserFromStore', async () => {
      vi.mocked(window.electron.getUserFromStore).mockResolvedValueOnce({
        id: 'user-1',
        hasImage: false
      })
      const result = await getUserFromStore()
      expect(result).toEqual({ id: 'user-1', hasImage: false })
    })

    it('saveUserToStore delegates to electron.saveUserToStore', async () => {
      const user = { id: 'user-1', hasImage: true }
      await saveUserToStore(user)
      expect(window.electron.saveUserToStore).toHaveBeenCalledWith(user)
    })

    it('getUserFromStore returns null when no user exists', async () => {
      vi.mocked(window.electron.getUserFromStore).mockResolvedValueOnce(null)
      const result = await getUserFromStore()
      expect(result).toBeNull()
    })
  })
})
