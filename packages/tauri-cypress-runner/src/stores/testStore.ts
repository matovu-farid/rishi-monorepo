import { create } from "zustand";
import type { TestFile, TestRunnerResult } from "../types";

interface TestStore {
  files: TestFile[];
  results: Record<string, TestRunnerResult>;
  /** Individual test-level results keyed by test name (e.g. "App Shell > has root") */
  testResults: Record<string, TestRunnerResult>;
  selectedFile: string | null;
  searchFilter: string;
  /** The test_id of the currently running test (if any) */
  currentlyRunningTest: string | null;
  /** Start time when the run began, for computing total duration */
  runStartTime: number | null;
  /** Total duration of the completed run in ms */
  totalDuration: number | null;

  setFiles: (files: TestFile[]) => void;
  addResult: (path: string, result: TestRunnerResult) => void;
  addTestResult: (testName: string, result: TestRunnerResult) => void;
  selectFile: (path: string | null) => void;
  clearResults: () => void;
  setSearchFilter: (filter: string) => void;
  setCurrentlyRunningTest: (testId: string | null) => void;
  startRun: () => void;
  endRun: () => void;
}

export const useTestStore = create<TestStore>((set, get) => ({
  files: [],
  results: {},
  testResults: {},
  selectedFile: null,
  searchFilter: "",
  currentlyRunningTest: null,
  runStartTime: null,
  totalDuration: null,

  setFiles: (files) => set({ files }),
  addResult: (path, result) =>
    set((s) => ({ results: { ...s.results, [path]: result } })),
  addTestResult: (testName, result) =>
    set((s) => ({ testResults: { ...s.testResults, [testName]: result } })),
  selectFile: (path) => set({ selectedFile: path }),
  clearResults: () =>
    set({
      results: {},
      testResults: {},
      currentlyRunningTest: null,
      totalDuration: null,
    }),
  setSearchFilter: (filter) => set({ searchFilter: filter }),
  setCurrentlyRunningTest: (testId) => set({ currentlyRunningTest: testId }),
  startRun: () => set({ runStartTime: Date.now(), totalDuration: null }),
  endRun: () => {
    const start = get().runStartTime;
    set({
      totalDuration: start ? Date.now() - start : null,
      currentlyRunningTest: null,
    });
  },
}));
