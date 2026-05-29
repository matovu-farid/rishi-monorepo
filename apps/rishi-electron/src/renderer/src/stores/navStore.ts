// apps/main/src/stores/navStore.ts
//
// Thin zustand store so *any* component (including class components like
// EpubView and ReactReader) can send events to the navigation state
// machine without prop-drilling.

import { create } from 'zustand'
import { subscribeWithSelector } from 'zustand/middleware'
import type { NavMachineEvent, NavState } from '@/machines/navMachine'

interface NavStore {
  /** Current machine state — useful for guards ("is navigation in flight?"). */
  navState: NavState
  /**
   * Direction of the currently in-flight (or most recently completed)
   * navigation, derived from navMachine's pendingAction/curlDirection.
   * The TTS bridge reads this when forwarding PAGE_NAVIGATING to the
   * player — using the player's own context.direction would leak a
   * stale value from a prior PREV nav and cause the new page to land on
   * its last paragraph instead of paragraph 0.
   */
  navDirection: 'forward' | 'backward'
  /** Send an event to the navigation machine.  null until the machine boots. */
  send: ((event: NavMachineEvent) => void) | null

  // internal setters
  setNavState: (s: NavState) => void
  setNavDirection: (d: 'forward' | 'backward') => void
  setSend: (fn: ((event: NavMachineEvent) => void) | null) => void
}

export const useNavStore = create<NavStore>()(
  subscribeWithSelector((set) => ({
    navState: 'idle',
    navDirection: 'forward',
    send: null,

    setNavState: (navState) => set({ navState }),
    setNavDirection: (navDirection) => set({ navDirection }),
    setSend: (send) => set({ send })
  }))
)
