import { create } from "zustand";
import type { TestFile, TestRunnerResult } from "../types";

interface TestStore {
  files: TestFile[]; results: Record<string, TestRunnerResult>; selectedFile: string | null;
  setFiles: (files: TestFile[]) => void;
  addResult: (path: string, result: TestRunnerResult) => void;
  selectFile: (path: string | null) => void;
  clearResults: () => void;
}

export const useTestStore = create<TestStore>((set) => ({
  files: [], results: {}, selectedFile: null,
  setFiles: (files) => set({ files }),
  addResult: (path, result) => set((s) => ({ results: { ...s.results, [path]: result } })),
  selectFile: (path) => set({ selectedFile: path }),
  clearResults: () => set({ results: {} }),
}));
