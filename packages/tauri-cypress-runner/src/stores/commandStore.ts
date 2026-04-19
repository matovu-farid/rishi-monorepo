import { create } from "zustand";
import type { CommandEntry } from "../types";

interface CommandStore {
  entries: CommandEntry[]; selectedIndex: number | null;
  addEntry: (entry: CommandEntry) => void;
  updateEntry: (index: number, update: Partial<CommandEntry>) => void;
  selectEntry: (index: number | null) => void;
  clear: () => void;
}

export const useCommandStore = create<CommandStore>((set) => ({
  entries: [], selectedIndex: null,
  addEntry: (entry) => set((s) => ({ entries: [...s.entries, entry] })),
  updateEntry: (index, update) => set((s) => ({ entries: s.entries.map((e, i) => i === index ? { ...e, ...update } : e) })),
  selectEntry: (index) => set({ selectedIndex: index }),
  clear: () => set({ entries: [], selectedIndex: null }),
}));
