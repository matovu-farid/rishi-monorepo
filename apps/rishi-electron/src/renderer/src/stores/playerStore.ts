// apps/main/src/stores/playerStore.ts
import { create } from 'zustand'
import { subscribeWithSelector } from 'zustand/middleware'
import type { ParagraphWithIndex } from '@/models/player_control'
import type { PlayerMachineEvent } from '@/machines/playerMachine'

export type { ParagraphWithIndex }

/** Public send signature for the player xstate actor. Component code dispatches
 *  events through this, mirrored from `ActorRefFrom<typeof playerMachine>['send']`
 *  but kept as a structural function to avoid a circular import. */
export type PlayerSend = (event: PlayerMachineEvent) => void

export type PlayerStoreState =
  | 'idle'
  | 'stopped'
  | 'loading'
  | 'playing'
  | 'paused.clean'
  | 'paused.stale'
  | 'waitingForParagraphs'
  | 'pageNavigating'
  | 'republishingParagraphs'
  | 'error'

interface PlayerStore {
  // --- Player-side state (written by machine, read by React) ---
  playingState: PlayerStoreState
  activeParagraph: ParagraphWithIndex | null
  errors: string[]

  // --- Format-reader-side state (written by readers, read by machine) ---
  currentParagraphs: ParagraphWithIndex[]
  nextPageParagraphs: ParagraphWithIndex[]
  prevPageParagraphs: ParagraphWithIndex[]

  // --- Signals ---
  pageRequest: 'next' | 'prev' | null

  // --- Machine send reference for non-React code ---
  send: PlayerSend | null

  // --- Actions: format readers call these ---
  setCurrentParagraphs: (p: ParagraphWithIndex[]) => void
  setNextPageParagraphs: (p: ParagraphWithIndex[]) => void
  setPrevPageParagraphs: (p: ParagraphWithIndex[]) => void

  // --- Actions: machine calls these ---
  requestNextPage: () => void
  requestPrevPage: () => void
  clearPageRequest: () => void
  setSend: (send: PlayerSend) => void
}

export const usePlayerStore = create<PlayerStore>()(
  subscribeWithSelector((set) => ({
    playingState: 'idle',
    activeParagraph: null,
    errors: [],

    currentParagraphs: [],
    nextPageParagraphs: [],
    prevPageParagraphs: [],

    pageRequest: null,
    send: null,

    setCurrentParagraphs: (p) => set({ currentParagraphs: p }),
    setNextPageParagraphs: (p) => set({ nextPageParagraphs: p }),
    setPrevPageParagraphs: (p) => set({ prevPageParagraphs: p }),

    requestNextPage: () => set({ pageRequest: 'next' }),
    requestPrevPage: () => set({ pageRequest: 'prev' }),
    clearPageRequest: () => set({ pageRequest: null }),
    setSend: (send) => set({ send })
  }))
)
