import { describe, it, expect, beforeEach } from 'vitest'
import { useAuthStore } from './authStore'

describe('authStore', () => {
  beforeEach(() => {
    useAuthStore.setState({
      user: null,
      authHydrated: false,
      welcomeSeen: false,
      bannerDismissed: false,
      signInOpen: false
    })
    localStorage.clear()
  })

  it('should start with null user', () => {
    expect(useAuthStore.getState().user).toBeNull()
  })

  it('should set user', () => {
    useAuthStore.getState().setUser({ id: '123', email: 'a@b.com' })
    expect(useAuthStore.getState().user?.id).toBe('123')
    expect(useAuthStore.getState().user?.email).toBe('a@b.com')
  })

  it('should hydrate welcome seen from localStorage', () => {
    localStorage.setItem('rishi:welcome-seen', '1')
    useAuthStore.getState().hydrateAuth()
    expect(useAuthStore.getState().welcomeSeen).toBe(true)
  })

  it('should default welcomeSeen to false when not in localStorage', () => {
    useAuthStore.getState().hydrateAuth()
    expect(useAuthStore.getState().welcomeSeen).toBe(false)
  })

  it('should persist welcome seen on dismissWelcome', () => {
    useAuthStore.getState().dismissWelcome()
    expect(useAuthStore.getState().welcomeSeen).toBe(true)
    expect(localStorage.getItem('rishi:welcome-seen')).toBe('1')
  })

  it('should dismiss banner', () => {
    useAuthStore.getState().dismissBanner()
    expect(useAuthStore.getState().bannerDismissed).toBe(true)
  })

  it('should set auth hydrated', () => {
    useAuthStore.getState().setAuthHydrated(true)
    expect(useAuthStore.getState().authHydrated).toBe(true)
  })

  it('should open and close sign-in modal', () => {
    useAuthStore.getState().openSignIn()
    expect(useAuthStore.getState().signInOpen).toBe(true)
    useAuthStore.getState().closeSignIn()
    expect(useAuthStore.getState().signInOpen).toBe(false)
  })
})
