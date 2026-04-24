import { create } from "zustand";
import type { DomSnapshot } from "../types";

interface SnapshotStore {
  snapshots: DomSnapshot[];
  viewMode: "screenshot" | "html";
  /** Temporarily previewed snapshot index (from command hover), null = not previewing */
  hoverPreviewIndex: number | null;

  addSnapshot: (snapshot: DomSnapshot) => void;
  clear: () => void;
  setViewMode: (mode: "screenshot" | "html") => void;
  setHoverPreviewIndex: (index: number | null) => void;
}

export const useSnapshotStore = create<SnapshotStore>((set) => ({
  snapshots: [],
  viewMode: "screenshot",
  hoverPreviewIndex: null,

  addSnapshot: (snapshot) =>
    set((s) => ({ snapshots: [...s.snapshots, snapshot] })),
  clear: () => set({ snapshots: [], hoverPreviewIndex: null }),
  setViewMode: (mode) => set({ viewMode: mode }),
  setHoverPreviewIndex: (index) => set({ hoverPreviewIndex: index }),
}));
