import { create } from "zustand";
import type { CommandEntry } from "../types";

/** A command entry enriched with grouping info */
export interface GroupedCommandEntry extends CommandEntry {
  /** The test name this command belongs to, if any */
  testName?: string;
  /** Nested assertion results for result entries */
  assertions?: Array<{
    description: string;
    passed: boolean;
    expected: unknown;
    actual: unknown;
  }>;
}

interface CommandStore {
  entries: GroupedCommandEntry[];
  selectedIndex: number | null;
  /** Index of command being hovered (for snapshot preview) */
  hoveredIndex: number | null;
  /** Currently active test group name (for grouping commands) */
  currentTestGroup: string | null;

  addEntry: (entry: GroupedCommandEntry) => void;
  updateEntry: (index: number, update: Partial<GroupedCommandEntry>) => void;
  selectEntry: (index: number | null) => void;
  setHoveredIndex: (index: number | null) => void;
  setCurrentTestGroup: (name: string | null) => void;
  clear: () => void;
}

export const useCommandStore = create<CommandStore>((set, get) => ({
  entries: [],
  selectedIndex: null,
  hoveredIndex: null,
  currentTestGroup: null,

  addEntry: (entry) =>
    set((s) => ({
      entries: [
        ...s.entries,
        { ...entry, testName: entry.testName ?? s.currentTestGroup ?? undefined },
      ],
    })),
  updateEntry: (index, update) =>
    set((s) => ({
      entries: s.entries.map((e, i) =>
        i === index ? { ...e, ...update } : e
      ),
    })),
  selectEntry: (index) => set({ selectedIndex: index }),
  setHoveredIndex: (index) => set({ hoveredIndex: index }),
  setCurrentTestGroup: (name) => set({ currentTestGroup: name }),
  clear: () =>
    set({
      entries: [],
      selectedIndex: null,
      hoveredIndex: null,
      currentTestGroup: null,
    }),
}));
