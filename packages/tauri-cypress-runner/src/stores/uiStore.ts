import { create } from "zustand";

interface UiStore {
  buildOutputVisible: boolean;
  /** Path of the selected failed test (to show ErrorPanel) */
  selectedFailedTest: string | null;

  setBuildOutputVisible: (visible: boolean) => void;
  setSelectedFailedTest: (testId: string | null) => void;
}

export const useUiStore = create<UiStore>((set) => ({
  buildOutputVisible: false,
  selectedFailedTest: null,

  setBuildOutputVisible: (visible) => set({ buildOutputVisible: visible }),
  setSelectedFailedTest: (testId) => set({ selectedFailedTest: testId }),
}));
