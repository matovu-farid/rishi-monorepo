import { create } from "zustand";

interface UiStore {
  buildOutputVisible: boolean;
  setBuildOutputVisible: (visible: boolean) => void;
}

export const useUiStore = create<UiStore>((set) => ({
  buildOutputVisible: false,
  setBuildOutputVisible: (visible) => set({ buildOutputVisible: visible }),
}));
