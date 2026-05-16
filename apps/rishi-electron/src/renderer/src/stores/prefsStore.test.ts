import { describe, it, expect, vi, beforeEach } from 'vitest'

const invalidateKeyMock = vi.fn()
vi.mock('@/services', () => ({
  getVoiceChatService: () => ({
    invalidateKey: invalidateKeyMock
  })
}))

describe('prefsStore', () => {
  beforeEach(() => {
    invalidateKeyMock.mockClear()
    vi.resetModules()
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockReset()
    ;(window.electron.setStoreValue as ReturnType<typeof vi.fn>).mockReset()
    ;(window.electron.setStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
  })

  it('default voiceChatLanguage is "en"', async () => {
    const { usePrefsStore } = await import('./prefsStore')
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('hydrate() reads voiceChatLanguage from the store IPC', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue('es')
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(window.electron.getStoreValue).toHaveBeenCalledWith('voiceChatLanguage')
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('es')
  })

  it('hydrate() falls back to "en" when the IPC returns null', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue(null)
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('hydrate() falls back to "en" when the IPC returns an unknown code', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockResolvedValue('xx')
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('setVoiceChatLanguage writes via setStoreValue, invalidates the key, and updates state', async () => {
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().setVoiceChatLanguage('fr')
    expect(window.electron.setStoreValue).toHaveBeenCalledWith('voiceChatLanguage', 'fr')
    expect(invalidateKeyMock).toHaveBeenCalledTimes(1)
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('fr')
  })

  it('setVoiceChatLanguage rejects an unknown code (no-op)', async () => {
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().setVoiceChatLanguage('xx' as never)
    expect(window.electron.setStoreValue).not.toHaveBeenCalled()
    expect(invalidateKeyMock).not.toHaveBeenCalled()
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })
})
