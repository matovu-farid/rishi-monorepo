// apps/main/src/stores/navStore.ts
//
// Thin zustand store so *any* component (including class components like
// EpubView and ReactReader) can send events to the navigation state
// machine without prop-drilling.

import { create } from "zustand";
import { subscribeWithSelector } from "zustand/middleware";
import type { NavMachineEvent, NavState } from "@/machines/navMachine";

interface NavStore {
  /** Current machine state — useful for guards ("is navigation in flight?"). */
  navState: NavState;
  /** Send an event to the navigation machine.  null until the machine boots. */
  send: ((event: NavMachineEvent) => void) | null;

  // internal setters
  setNavState: (s: NavState) => void;
  setSend: (fn: ((event: NavMachineEvent) => void) | null) => void;
}

export const useNavStore = create<NavStore>()(subscribeWithSelector((set) => ({
  navState: "idle",
  send: null,

  setNavState: (navState) => set({ navState }),
  setSend: (send) => set({ send }),
})));
