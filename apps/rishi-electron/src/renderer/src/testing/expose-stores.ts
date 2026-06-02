import { usePlayerStore } from '@/stores/playerStore'
import { useEpubStore } from '@/stores/epubStore'
import { useNavStore } from '@/stores/navStore'
import { useSelectionStore } from '@/stores/selectionStore'
import { useAuthStore } from '@/stores/authStore'
import { usePdfStore } from '@/stores/pdfStore'
import { setTestTtsService, getSyncService } from '@/services'
import { audioElement } from '@/hooks/usePlayerMachine'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'
import {
  sessionMachineStore,
  signalingTestHook,
  fileTransferProgress,
  setRtcFactoryOverride
} from './sharing-test-hooks'
import { fakeRtcFactory } from './fakeRtcAdapter'
import type { TtsService } from '@/services/tts'
import type { SyncService } from '@/services/sync'
import type { FooterMask } from '@/components/pdf/utils/buildFooterMask'
import type { RtcFactory } from '@/actors/sharing/rtcAdapter'

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
      /**
       * E2E hook (Plan 3 P3): snapshot accessor for the active sharing
       * `sessionMachine` actor. Returns null when no session is mounted.
       * Returned snapshot has the XState v5 shape `{ value, context, send }`.
       */
      sessionMachineStore: typeof sessionMachineStore
      /**
       * E2E hook (Plan 3 P4): control the active signaling WebSocket — force
       * a disconnect and subscribe to signaling error codes.
       */
      signalingTestHook: typeof signalingTestHook
      /**
       * E2E hook (Plan 3 P5): live snapshot of the current P2P file transfer
       * progress (`{ completed, percent }`). Mutated by the fileTransferActor.
       */
      fileTransferProgress: typeof fileTransferProgress
      /**
       * E2E hook (task #92): install a fake `RtcFactory` so peerActor can
       * be driven without opening UDP sockets in headless Electron. Pass
       * `null` to restore the default factory. A pre-built fake is exposed
       * as `installFakeRtcFactory()`.
       */
      setRtcFactoryOverride: (factory: RtcFactory | null) => void
      /** Shortcut: install the bundled fake RtcFactory. */
      installFakeRtcFactory: () => void
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
  getFooterMask: (bookId: number) => usePdfStore.getState().footerMaskByBookId[bookId],
  sessionMachineStore,
  signalingTestHook,
  fileTransferProgress,
  setRtcFactoryOverride,
  installFakeRtcFactory: () => setRtcFactoryOverride(fakeRtcFactory)
}
