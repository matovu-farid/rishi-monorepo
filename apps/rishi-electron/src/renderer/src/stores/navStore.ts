import { create } from "zustand";
import { subscribeWithSelector } from "zustand/middleware";
import type { NavState as MachineNavState } from "@/machines/navMachine";

export type NavState = MachineNavState;
export type NavMachineEvent = { type: string; [key: string]: any };

interface NavStore {
  navState: NavState;
  send: ((event: NavMachineEvent) => void) | null;
  setNavState: (s: NavState) => void;
  setSend: (fn: ((event: NavMachineEvent) => void) | null) => void;
}

export const useNavStore = create<NavStore>()(
  subscribeWithSelector((set) => ({
    navState: "idle",
    send: null,
    setNavState: (navState) => set({ navState }),
    setSend: (send) => set({ send }),
  }))
);
