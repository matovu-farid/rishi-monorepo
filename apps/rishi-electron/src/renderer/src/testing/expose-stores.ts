import { usePlayerStore } from '@/stores/playerStore'
import { useEpubStore } from '@/stores/epubStore'
import { useNavStore } from '@/stores/navStore'
import { useSelectionStore } from '@/stores/selectionStore'
import { useAuthStore } from '@/stores/authStore'
import { usePdfStore } from '@/stores/pdfStore'
import { setTestTtsService, getSyncService } from '@/services'
import { audioElement } from '@/hooks/usePlayerMachine'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'
import type { TtsService } from '@/services/tts'
import type { SyncService } from '@/services/sync'
import type { FooterMask } from '@/components/pdf/utils/buildFooterMask'

declare global {
  interface Window {
    __rishi?: {
      playerStore: typeof usePlayerStore
      epubStore: typeof useEpubStore
      navStore: typeof useNavStore
      selectionStore: typeof useSelectionStore
      authStore: typeof useAuthStore
      pdfStore: typeof usePdfStore
      setTestTtsService: (override: TtsService | null) => void
      audioElement: HTMLAudioElement
      navigationHistoryActor: typeof navigationHistoryActor
      /**
       * E2E hook: gives Playwright a way to force a sync push without waiting
       * for the 5-min interval. Used by the cross-platform-sync test
       * (tests/cross-platform-sync/playwright/desktop-import.spec.ts). Always
       * exposed — it's a thin wrapper over the same `triggerWrite()` the rest
       * of the app already calls; production code never reads it.
       */
      getSyncService: () => SyncService
      /** E2E hook for #142: read the raw FooterMask without the pref short-circuit. */
      getFooterMask: (bookId: number) => FooterMask | undefined
    }
  }
}

window.__rishi = {
  playerStore: usePlayerStore,
  epubStore: useEpubStore,
  navStore: useNavStore,
  selectionStore: useSelectionStore,
  authStore: useAuthStore,
  pdfStore: usePdfStore,
  setTestTtsService,
  audioElement,
  navigationHistoryActor,
  getSyncService,
  getFooterMask: (bookId: number) => usePdfStore.getState().footerMaskByBookId[bookId]
}
