import { create } from "zustand";
import type { DomSnapshot } from "../types";

interface SnapshotStore {
  snapshots: DomSnapshot[]; viewMode: "screenshot" | "html";
  addSnapshot: (snapshot: DomSnapshot) => void;
  clear: () => void;
  setViewMode: (mode: "screenshot" | "html") => void;
}

export const useSnapshotStore = create<SnapshotStore>((set) => ({
  snapshots: [], viewMode: "screenshot",
  addSnapshot: (snapshot) => set((s) => ({ snapshots: [...s.snapshots, snapshot] })),
  clear: () => set({ snapshots: [] }),
  setViewMode: (mode) => set({ viewMode: mode }),
}));
