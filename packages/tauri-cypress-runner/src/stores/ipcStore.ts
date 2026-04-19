import { create } from "zustand";
import type { IpcLogEntry } from "../types";

interface IpcStore {
  entries: IpcLogEntry[];
  addEntry: (entry: IpcLogEntry) => void;
  clear: () => void;
}

export const useIpcStore = create<IpcStore>((set) => ({
  entries: [],
  addEntry: (entry) => set((s) => ({ entries: [...s.entries, entry] })),
  clear: () => set({ entries: [] }),
}));
