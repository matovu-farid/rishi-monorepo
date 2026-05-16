import { usePlayerStore } from '@/stores/playerStore'
import { useEpubStore } from '@/stores/epubStore'
import { useNavStore } from '@/stores/navStore'
import { setTestTtsService } from '@/services'
import { audioElement } from '@/hooks/usePlayerMachine'
import type { TtsService } from '@/services/tts'

declare global {
  interface Window {
    __rishi?: {
      playerStore: typeof usePlayerStore
      epubStore: typeof useEpubStore
      navStore: typeof useNavStore
      setTestTtsService: (override: TtsService | null) => void
      audioElement: HTMLAudioElement
    }
  }
}

window.__rishi = {
  playerStore: usePlayerStore,
  epubStore: useEpubStore,
  navStore: useNavStore,
  setTestTtsService,
  audioElement
}
