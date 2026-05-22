/**
 * Mobile prefsStore — ported from
 * `apps/rishi-electron/src/renderer/src/stores/prefsStore.ts`.
 *
 * Same public API as electron:
 *   - State: `voiceChatLanguage`, `voiceChatVisionEnabled`, `ttsVisualCueEnabled`
 *   - Actions: `hydrate`, `setVoiceChatLanguage`, `setVoiceChatVisionEnabled`,
 *              `setTtsVisualCueEnabled`
 *
 * Behavioural diffs from electron:
 *   - Persistence: `window.electron.{get,set}StoreValue` (IPC) →
 *                  MMKV via `createStorage('rishi.mobile.prefs')`.
 *                  Storage is sync on RN; we keep the action signatures
 *                  `async` so call sites remain interchangeable.
 *   - `getVoiceChatService().invalidateKey()` → injectable port
 *     (`setPrefsVoiceChatPort`). Default port is a no-op until the voice
 *     chat service lands on mobile (see Batch 1B notes #4).
 */
import { create } from 'zustand'
import {
  ALLOWED_LANGUAGES,
  DEFAULT_LANGUAGE,
  isAllowedLanguage,
  type AllowedLanguage,
} from '@rishi/shared/lib/languages'
import { createStorage } from '@/lib/storage/mmkv'

const bucket = createStorage('rishi.mobile.prefs')

const LANGUAGE_KEY = 'voice-chat-language'
const VISION_KEY = 'voice-chat-vision-enabled'
const TTS_CUE_KEY = 'tts-visual-cue-enabled'
// P1-E — reader toolbar pinning. When true the 3s auto-hide timer is
// bypassed and the chrome stays visible until the user pins-off.
const TOOLBAR_PINNED_KEY = 'reader-toolbar-pinned'

// ── Voice-chat port (replaces electron's getVoiceChatService) ────────────────
export interface PrefsVoiceChatPort {
  /** Invalidate the cached realtime ephemeral key (e.g. on language change). */
  invalidateKey(): void
}

const noopVoiceChatPort: PrefsVoiceChatPort = {
  invalidateKey: () => undefined,
}

let voiceChatPort: PrefsVoiceChatPort = noopVoiceChatPort

/**
 * Inject a real voice-chat port. Call this once the voice-chat service is
 * available on mobile. Until then, the default no-op port is fine —
 * language changes simply won't trigger a key refresh.
 */
export function setPrefsVoiceChatPort(port: PrefsVoiceChatPort): void {
  voiceChatPort = port
}

// ── Helpers ──────────────────────────────────────────────────────────────────
function readBool(key: string): boolean | undefined {
  const raw = bucket.getItem(key)
  if (raw === null || raw === undefined) return undefined
  if (raw === 'true') return true
  if (raw === 'false') return false
  return undefined
}

function writeBool(key: string, value: boolean): void {
  bucket.setItem(key, value ? 'true' : 'false')
}

// ── Store ────────────────────────────────────────────────────────────────────
interface PrefsState {
  voiceChatLanguage: AllowedLanguage
  voiceChatVisionEnabled: boolean
  ttsVisualCueEnabled: boolean
  /**
   * P1-E — when true, the reader chrome (top + bottom toolbars) stays
   * visible indefinitely instead of being hidden by the 3s auto-hide
   * timer. Toggled by long-pressing the Back chevron.
   */
  toolbarPinned: boolean

  hydrate: () => Promise<void>
  setVoiceChatLanguage: (lang: AllowedLanguage) => Promise<void>
  setVoiceChatVisionEnabled: (enabled: boolean) => Promise<void>
  setTtsVisualCueEnabled: (enabled: boolean) => Promise<void>
  setToolbarPinned: (pinned: boolean) => Promise<void>
}

export const usePrefsStore = create<PrefsState>()((set, get) => ({
  voiceChatLanguage: DEFAULT_LANGUAGE,
  voiceChatVisionEnabled: true,
  ttsVisualCueEnabled: true,
  // P1-E — default off (Apple-Books-style auto-hide is the expected
  // first-run behaviour). Long-press Back to flip it on.
  toolbarPinned: false,

  async hydrate() {
    const rawLang = bucket.getItem(LANGUAGE_KEY)
    const nextLang: AllowedLanguage = isAllowedLanguage(rawLang) ? rawLang : DEFAULT_LANGUAGE
    const visionVal = readBool(VISION_KEY)
    const ttsCueVal = readBool(TTS_CUE_KEY)
    const pinnedVal = readBool(TOOLBAR_PINNED_KEY)
    set({
      voiceChatLanguage: nextLang,
      voiceChatVisionEnabled: typeof visionVal === 'boolean' ? visionVal : true,
      ttsVisualCueEnabled: typeof ttsCueVal === 'boolean' ? ttsCueVal : true,
      toolbarPinned: typeof pinnedVal === 'boolean' ? pinnedVal : false,
    })
  },

  async setVoiceChatLanguage(lang) {
    if (!isAllowedLanguage(lang)) return
    if (get().voiceChatLanguage === lang) return
    bucket.setItem(LANGUAGE_KEY, lang)
    // Invalidate AFTER the write succeeds so a failed write doesn't leave the
    // cache in an inconsistent state.
    voiceChatPort.invalidateKey()
    set({ voiceChatLanguage: lang })
  },

  async setVoiceChatVisionEnabled(enabled) {
    if (get().voiceChatVisionEnabled === enabled) return
    writeBool(VISION_KEY, enabled)
    set({ voiceChatVisionEnabled: enabled })
  },

  async setTtsVisualCueEnabled(enabled) {
    if (get().ttsVisualCueEnabled === enabled) return
    writeBool(TTS_CUE_KEY, enabled)
    set({ ttsVisualCueEnabled: enabled })
  },

  async setToolbarPinned(pinned) {
    if (get().toolbarPinned === pinned) return
    writeBool(TOOLBAR_PINNED_KEY, pinned)
    set({ toolbarPinned: pinned })
  },
}))

// Re-export for callers that want the allow-list directly.
export { ALLOWED_LANGUAGES, DEFAULT_LANGUAGE, isAllowedLanguage }
export type { AllowedLanguage }
