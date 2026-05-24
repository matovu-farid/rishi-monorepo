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

  it('hydrate() reads all three pref keys via IPC and writes each into the matching field', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockImplementation(
      (key: string) => {
        switch (key) {
          case 'voiceChatLanguage':
            return Promise.resolve('es')
          case 'voiceChatVisionEnabled':
            return Promise.resolve(false)
          case 'ttsVisualCueEnabled':
            return Promise.resolve(false)
          default:
            return Promise.resolve(undefined)
        }
      }
    )
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(window.electron.getStoreValue).toHaveBeenCalledWith('voiceChatLanguage')
    expect(window.electron.getStoreValue).toHaveBeenCalledWith('voiceChatVisionEnabled')
    expect(window.electron.getStoreValue).toHaveBeenCalledWith('ttsVisualCueEnabled')
    const state = usePrefsStore.getState()
    expect(state.voiceChatLanguage).toBe('es')
    expect(state.voiceChatVisionEnabled).toBe(false)
    expect(state.ttsVisualCueEnabled).toBe(false)
  })

  it('hydrate() falls back to true when vision/cue IPC returns a non-boolean value', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockImplementation(
      (key: string) => {
        switch (key) {
          case 'voiceChatLanguage':
            return Promise.resolve('en')
          case 'voiceChatVisionEnabled':
            return Promise.resolve(undefined)
          case 'ttsVisualCueEnabled':
            return Promise.resolve(null)
          default:
            return Promise.resolve(undefined)
        }
      }
    )
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    const state = usePrefsStore.getState()
    expect(state.voiceChatVisionEnabled).toBe(true)
    expect(state.ttsVisualCueEnabled).toBe(true)
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

  // -------------------------------------------------------------------------
  // pdfFooterDetection — sibling of ttsVisualCueEnabled
  // -------------------------------------------------------------------------

  it('pdfFooterDetection defaults to true', async () => {
    const { usePrefsStore } = await import('./prefsStore')
    expect(usePrefsStore.getState().pdfFooterDetection).toBe(true)
  })

  it('setPdfFooterDetection persists via window.electron.setStoreValue', async () => {
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().setPdfFooterDetection(false)
    expect(window.electron.setStoreValue).toHaveBeenCalledWith('pdfFooterDetection', false)
    expect(usePrefsStore.getState().pdfFooterDetection).toBe(false)
  })

  it('pdfFooterDetection hydrates from window.electron.getStoreValue on init', async () => {
    ;(window.electron.getStoreValue as ReturnType<typeof vi.fn>).mockImplementation(
      (key: string) => {
        switch (key) {
          case 'pdfFooterDetection':
            return Promise.resolve(false)
          default:
            return Promise.resolve(undefined)
        }
      }
    )
    const { usePrefsStore } = await import('./prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(window.electron.getStoreValue).toHaveBeenCalledWith('pdfFooterDetection')
    expect(usePrefsStore.getState().pdfFooterDetection).toBe(false)
  })
})
