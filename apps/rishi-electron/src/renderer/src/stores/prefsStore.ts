import { create } from 'zustand'
import { devtools } from 'zustand/middleware'
import { getVoiceChatService } from '@/services'
import {
  ALLOWED_LANGUAGES,
  DEFAULT_LANGUAGE,
  isAllowedLanguage,
  type AllowedLanguage
} from '@/lib/languages'

interface PrefsState {
  voiceChatLanguage: AllowedLanguage
  /** Expose page screenshots + inspectCurrentPage tool to the voice-chat agent. */
  voiceChatVisionEnabled: boolean
  /** Show the "Equation/Figure on page" cue during TTS read-aloud. */
  ttsVisualCueEnabled: boolean
  /** Detect and hide running-footer chrome on PDFs (#142). */
  pdfFooterDetection: boolean
  /**
   * Read the persisted value from the main-process store. Safe to call
   * multiple times; later calls overwrite the in-memory value.
   */
  hydrate: () => Promise<void>
  /**
   * Persist a new language choice and invalidate the realtime ephemeral
   * key so the next voice-chat activation uses the new language.
   *
   * Note: changes do NOT apply to a currently-active voice chat session.
   * The user must close and reopen the chat for the new language to take
   * effect mid-stream.
   */
  setVoiceChatLanguage: (lang: AllowedLanguage) => Promise<void>
  setVoiceChatVisionEnabled: (enabled: boolean) => Promise<void>
  setTtsVisualCueEnabled: (enabled: boolean) => Promise<void>
  setPdfFooterDetection: (enabled: boolean) => Promise<void>
}

export const usePrefsStore = create<PrefsState>()(
  devtools((set, get) => ({
    voiceChatLanguage: DEFAULT_LANGUAGE,
    voiceChatVisionEnabled: true,
    ttsVisualCueEnabled: true,
    pdfFooterDetection: true,

    async hydrate() {
      const raw = await window.electron.getStoreValue('voiceChatLanguage')
      const next: AllowedLanguage = isAllowedLanguage(raw) ? raw : DEFAULT_LANGUAGE
      const visionRaw = await window.electron.getStoreValue('voiceChatVisionEnabled')
      const cueRaw = await window.electron.getStoreValue('ttsVisualCueEnabled')
      const footerRaw = await window.electron.getStoreValue('pdfFooterDetection')
      set({
        voiceChatLanguage: next,
        voiceChatVisionEnabled: typeof visionRaw === 'boolean' ? visionRaw : true,
        ttsVisualCueEnabled: typeof cueRaw === 'boolean' ? cueRaw : true,
        pdfFooterDetection: typeof footerRaw === 'boolean' ? footerRaw : true
      })
    },

    async setVoiceChatLanguage(lang) {
      if (!isAllowedLanguage(lang)) return
      if (get().voiceChatLanguage === lang) return
      await window.electron.setStoreValue('voiceChatLanguage', lang)
      // Invalidate AFTER the write succeeds so a failed write doesn't
      // leave the cache in an inconsistent state.
      getVoiceChatService().invalidateKey()
      set({ voiceChatLanguage: lang })
    },

    async setVoiceChatVisionEnabled(enabled) {
      if (get().voiceChatVisionEnabled === enabled) return
      await window.electron.setStoreValue('voiceChatVisionEnabled', enabled)
      set({ voiceChatVisionEnabled: enabled })
    },

    async setTtsVisualCueEnabled(enabled) {
      if (get().ttsVisualCueEnabled === enabled) return
      await window.electron.setStoreValue('ttsVisualCueEnabled', enabled)
      set({ ttsVisualCueEnabled: enabled })
    },

    async setPdfFooterDetection(enabled) {
      if (get().pdfFooterDetection === enabled) return
      await window.electron.setStoreValue('pdfFooterDetection', enabled)
      set({ pdfFooterDetection: enabled })
    }
  }))
)

// Re-export so consumers don't need a second import for the allow-list.
export { ALLOWED_LANGUAGES }
