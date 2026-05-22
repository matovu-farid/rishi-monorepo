/**
 * Tests for the mobile prefsStore (ported from electron).
 *
 * Behaviour: identical public API to electron's prefsStore. Persistence:
 *   - voiceChatLanguage           ← MMKV (rishi.mobile.prefs:voice-chat-language)
 *   - voiceChatVisionEnabled      ← MMKV (rishi.mobile.prefs:voice-chat-vision-enabled)
 *   - ttsVisualCueEnabled         ← MMKV (rishi.mobile.prefs:tts-visual-cue-enabled)
 *
 * The voice-chat side-effect (invalidateKey) goes through an injectable
 * port so mobile can avoid bringing in the not-yet-ported voice-chat
 * service.
 */

// ── Mock react-native-mmkv ────────────────────────────────────────────────────
let backingStore: Map<string, string>

function buildFakeMMKV() {
  const store = backingStore
  return {
    id: 'fake',
    set: (key: string, value: string) => store.set(key, String(value)),
    getString: (key: string): string | undefined => store.get(key),
    remove: (key: string) => store.delete(key),
    getAllKeys: () => Array.from(store.keys()),
    clearAll: () => store.clear(),
  }
}

jest.mock('react-native-mmkv', () => ({
  createMMKV: () => buildFakeMMKV(),
}))

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
})

describe('prefsStore (mobile)', () => {
  it('default voiceChatLanguage is "en"', () => {
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('defaults voiceChatVisionEnabled=true, ttsVisualCueEnabled=true', () => {
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    expect(usePrefsStore.getState().voiceChatVisionEnabled).toBe(true)
    expect(usePrefsStore.getState().ttsVisualCueEnabled).toBe(true)
  })

  it('hydrate() reads each pref from MMKV and writes into state', async () => {
    backingStore.set('rishi.mobile.prefs:voice-chat-language', 'es')
    backingStore.set('rishi.mobile.prefs:voice-chat-vision-enabled', 'false')
    backingStore.set('rishi.mobile.prefs:tts-visual-cue-enabled', 'false')

    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().hydrate()
    const s = usePrefsStore.getState()
    expect(s.voiceChatLanguage).toBe('es')
    expect(s.voiceChatVisionEnabled).toBe(false)
    expect(s.ttsVisualCueEnabled).toBe(false)
  })

  it('hydrate() falls back to true when boolean flags are missing', async () => {
    backingStore.set('rishi.mobile.prefs:voice-chat-language', 'en')
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().hydrate()
    const s = usePrefsStore.getState()
    expect(s.voiceChatVisionEnabled).toBe(true)
    expect(s.ttsVisualCueEnabled).toBe(true)
  })

  it('hydrate() falls back to "en" when the persisted language is unknown', async () => {
    backingStore.set('rishi.mobile.prefs:voice-chat-language', 'xx')
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('setVoiceChatLanguage writes to MMKV, invalidates the key, and updates state', async () => {
    const invalidateKey = jest.fn()
    const { usePrefsStore, setPrefsVoiceChatPort } = require('@/lib/stores/prefsStore')
    setPrefsVoiceChatPort({ invalidateKey })

    await usePrefsStore.getState().setVoiceChatLanguage('fr')
    expect(backingStore.get('rishi.mobile.prefs:voice-chat-language')).toBe('fr')
    expect(invalidateKey).toHaveBeenCalledTimes(1)
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('fr')
  })

  it('setVoiceChatLanguage rejects an unknown code (no persistence, no invalidate)', async () => {
    const invalidateKey = jest.fn()
    const { usePrefsStore, setPrefsVoiceChatPort } = require('@/lib/stores/prefsStore')
    setPrefsVoiceChatPort({ invalidateKey })

    await usePrefsStore.getState().setVoiceChatLanguage('xx' as never)
    expect(backingStore.has('rishi.mobile.prefs:voice-chat-language')).toBe(false)
    expect(invalidateKey).not.toHaveBeenCalled()
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('en')
  })

  it('setVoiceChatLanguage is idempotent (no-op when value unchanged)', async () => {
    const invalidateKey = jest.fn()
    const { usePrefsStore, setPrefsVoiceChatPort } = require('@/lib/stores/prefsStore')
    setPrefsVoiceChatPort({ invalidateKey })

    // First call: "en" -> "fr" performs the write
    await usePrefsStore.getState().setVoiceChatLanguage('fr')
    invalidateKey.mockClear()
    // Second call: "fr" -> "fr" should bail out
    await usePrefsStore.getState().setVoiceChatLanguage('fr')
    expect(invalidateKey).not.toHaveBeenCalled()
  })

  it('setVoiceChatVisionEnabled persists "false" / "true" and updates state', async () => {
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().setVoiceChatVisionEnabled(false)
    expect(backingStore.get('rishi.mobile.prefs:voice-chat-vision-enabled')).toBe('false')
    expect(usePrefsStore.getState().voiceChatVisionEnabled).toBe(false)

    await usePrefsStore.getState().setVoiceChatVisionEnabled(true)
    expect(backingStore.get('rishi.mobile.prefs:voice-chat-vision-enabled')).toBe('true')
    expect(usePrefsStore.getState().voiceChatVisionEnabled).toBe(true)
  })

  it('setTtsVisualCueEnabled persists "false" / "true" and updates state', async () => {
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().setTtsVisualCueEnabled(false)
    expect(backingStore.get('rishi.mobile.prefs:tts-visual-cue-enabled')).toBe('false')
    expect(usePrefsStore.getState().ttsVisualCueEnabled).toBe(false)
  })

  // P1-E — toolbar pinned. Defaults to false (auto-hide is the iOS-Books-y
  // default). When pinned, ReaderShell's 3s auto-hide timer is bypassed.
  it('default toolbarPinned is false', () => {
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    expect(usePrefsStore.getState().toolbarPinned).toBe(false)
  })

  it('hydrate() reads toolbarPinned from MMKV', async () => {
    backingStore.set('rishi.mobile.prefs:reader-toolbar-pinned', 'true')
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(usePrefsStore.getState().toolbarPinned).toBe(true)
  })

  it('hydrate() falls back to false when toolbarPinned flag is missing', async () => {
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().hydrate()
    expect(usePrefsStore.getState().toolbarPinned).toBe(false)
  })

  it('setToolbarPinned persists "true" / "false" and updates state', async () => {
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().setToolbarPinned(true)
    expect(backingStore.get('rishi.mobile.prefs:reader-toolbar-pinned')).toBe('true')
    expect(usePrefsStore.getState().toolbarPinned).toBe(true)

    await usePrefsStore.getState().setToolbarPinned(false)
    expect(backingStore.get('rishi.mobile.prefs:reader-toolbar-pinned')).toBe('false')
    expect(usePrefsStore.getState().toolbarPinned).toBe(false)
  })

  it('toolbarPinned survives a store re-mount when value is persisted (cross-mount persistence)', async () => {
    const { usePrefsStore } = require('@/lib/stores/prefsStore')
    await usePrefsStore.getState().setToolbarPinned(true)

    // Re-mount: re-require the module so the store is reinitialized and
    // hydrate() pulls the previously persisted MMKV value back in.
    jest.resetModules()
    const reloaded = require('@/lib/stores/prefsStore')
    await reloaded.usePrefsStore.getState().hydrate()
    expect(reloaded.usePrefsStore.getState().toolbarPinned).toBe(true)
  })
})
