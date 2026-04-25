import { useCallback, useEffect, useRef, useState } from "react";
import { useMachine } from "@xstate/react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { PanelLayout } from "./components/PanelLayout";
import { TestSidebar } from "./components/TestSidebar";
import { AppPreview } from "./components/AppPreview";
import { CommandLog } from "./components/CommandLog";
import { IpcInspector } from "./components/IpcInspector";
import { StatusBar } from "./components/StatusBar";
import { BuildOutput } from "./components/BuildOutput";
import { ErrorPanel } from "./components/ErrorPanel";
import { connectionMachine } from "./machines/connectionMachine";
import { executionMachine } from "./machines/executionMachine";
import { timeTravelMachine } from "./machines/timeTravelMachine";
import { useTauriEvent } from "./hooks/useTauriEvents";
import { useKeyboardShortcuts } from "./hooks/useKeyboardShortcuts";
import { useTestStore } from "./stores/testStore";
import { useIpcStore } from "./stores/ipcStore";
import { useSnapshotStore } from "./stores/snapshotStore";
import { useCommandStore } from "./stores/commandStore";
import { useUiStore } from "./stores/uiStore";
import type {
  TestFile,
  TestRunnerResult,
  IpcLogEntry,
  DomSnapshot,
  BuildOutput as BuildOutputLine,
  BuildComplete,
} from "./types";

export function App() {
  const [connState, connSend] = useMachine(connectionMachine);
  const [execState, execSend] = useMachine(executionMachine);
  const [ttState, ttSend] = useMachine(timeTravelMachine);
  const [buildLines, setBuildLines] = useState<BuildOutputLine[]>([]);
  const [buildVisible, setBuildVisible] = useState(false);
  const [buildFailed, setBuildFailed] = useState(false);

  // --- Debug snapshot capture ---
  const captureDebugSnapshot = useCallback(async (name: string) => {
    try {
      let styles = '';
      for (let i = 0; i < document.styleSheets.length; i++) {
        try {
          const rules = document.styleSheets[i].cssRules;
          if (rules) for (let j = 0; j < rules.length; j++) styles += rules[j].cssText + '\n';
        } catch { /* cross-origin sheets */ }
      }
      const html = '<!DOCTYPE html><html>' +
        document.documentElement.innerHTML.replace('</head>', '<style>' + styles + '</style></head>') +
        '</html>';
      await invoke('save_debug_html', { filename: name + '.html', html });
      console.log(`[debug] Saved snapshot: ${name}`);
    } catch (e) {
      console.error('[debug] Failed to save snapshot:', e);
    }
  }, []);

  const addResult = useTestStore((s) => s.addResult);
  const addTestResult = useTestStore((s) => s.addTestResult);
  const setFiles = useTestStore((s) => s.setFiles);
  const setCurrentlyRunningTest = useTestStore(
    (s) => s.setCurrentlyRunningTest
  );
  const startRun = useTestStore((s) => s.startRun);
  const endRun = useTestStore((s) => s.endRun);
  const addIpc = useIpcStore((s) => s.addEntry);
  const addSnapshot = useSnapshotStore((s) => s.addSnapshot);
  const addCommand = useCommandStore((s) => s.addEntry);
  const setCurrentTestGroup = useCommandStore((s) => s.setCurrentTestGroup);
  const selectedFailedTest = useUiStore((s) => s.selectedFailedTest);

  // Subscribe to Tauri backend events
  useTauriEvent<TestRunnerResult>(
    "test-harness://result",
    useCallback(
      (data) => {
        // Add file-level result
        addResult(data.test_id, data);
        // Also add as individual test result
        addTestResult(data.test_id, data);
        // Update currently running test
        setCurrentlyRunningTest(null);
        // Set test group for command log grouping
        setCurrentTestGroup(data.test_id);

        addCommand({
          name: `result: ${data.test_id}`,
          status: data.status === "passed" ? "passed" : "failed",
          snapshotIndex: -1,
          duration: data.duration_ms,
          error: data.error ?? undefined,
          testName: data.test_id,
          assertions: data.assertions?.map((a) => ({
            description: a.description,
            passed: a.passed,
            expected: a.expected,
            actual: a.actual,
          })),
        });
        execSend({ type: "TEST_COMPLETE" });
      },
      [
        addResult,
        addTestResult,
        addCommand,
        execSend,
        setCurrentlyRunningTest,
        setCurrentTestGroup,
      ]
    )
  );

  useTauriEvent<IpcLogEntry>(
    "test-harness://ipc",
    useCallback(
      (data) => {
        addIpc(data);
      },
      [addIpc]
    )
  );

  useTauriEvent<DomSnapshot>(
    "test-harness://snapshot",
    useCallback(
      (data) => {
        addSnapshot(data);
        const newIndex = useSnapshotStore.getState().snapshots.length - 1;
        if (data.command_name) {
          addCommand({
            name: data.command_name,
            status: "passed",
            snapshotIndex: newIndex,
          });
        }
        if (ttState.value === "active") {
          ttSend({ type: "UPDATE_MAX", maxIndex: newIndex });
        }
      },
      [addSnapshot, addCommand, ttState.value, ttSend]
    )
  );

  useTauriEvent(
    "test-harness://connected",
    useCallback(() => {
      connSend({ type: "CONNECTED" });
      execSend({ type: "CONNECTED" });
    }, [connSend, execSend])
  );

  useTauriEvent(
    "test-harness://disconnected",
    useCallback(() => {
      connSend({ type: "DISCONNECTED" });
      // Mark app as not ready so next run rebuilds
      appReadyRef.current = false;
    }, [connSend])
  );

  useTauriEvent<BuildOutputLine>(
    "test-harness://build-output",
    useCallback((data) => {
      setBuildLines((prev) => [...prev, data]);
    }, [])
  );

  useTauriEvent<BuildComplete>(
    "test-harness://build-complete",
    useCallback(
      (data) => {
        if (data.success) {
          execSend({ type: "BUILD_COMPLETE" });
          setBuildVisible(false);
        } else {
          execSend({
            type: "BUILD_FAILED",
            error: `Exit code: ${data.exit_code}`,
          });
          setBuildFailed(true);
        }
      },
      [execSend]
    )
  );

  // Hot reload: update test file list when files change
  useTauriEvent<TestFile[]>(
    "test-harness://files-changed",
    useCallback(
      (files) => {
        setFiles(files);
      },
      [setFiles]
    )
  );

  // Auto-initialize: load project, discover tests, then auto-run all
  const autoRunTriggered = useRef(false);
  const handleRunRef = useRef<() => void>(() => {});
  useEffect(() => {
    async function init() {
      try {
        const dir = (await invoke("get_initial_project_dir")) as string | null;
        if (dir) {
          await invoke("start_session", { projectDir: dir });
          const files = (await invoke("get_test_files")) as TestFile[];
          setFiles(files);
          invoke("watch_tests").catch(() => {});

          // Capture initial state with test files loaded
          setTimeout(() => captureDebugSnapshot('initial-load'), 500);

          // Auto-run all tests on first load
          if (!autoRunTriggered.current && files.length > 0) {
            autoRunTriggered.current = true;
            setTimeout(() => handleRunRef.current(), 300);
          }
        }
      } catch (e) {
        console.error("Failed to initialize:", e);
      }
    }
    init();
  }, [setFiles, captureDebugSnapshot]);

  // Track whether the app-under-test is built, launched, and connected
  const appReadyRef = useRef(false);

  /** Build, launch, and connect to the app-under-test. No-op if already ready. */
  const ensureAppReady = useCallback(async () => {
    if (appReadyRef.current) return;

    let currentStep = "init";
    const log = (step: string, detail?: string) => {
      currentStep = step;
      console.log(`[tauri-cypress] ${step}${detail ? ": " + detail : ""}`);
    };

    execSend({ type: "START" });
    startRun();
    setBuildLines([]);
    setBuildFailed(false);
    setBuildVisible(true);

    log("build_backend");
    await invoke("run_build");

    log("build_frontend");
    await invoke("build_frontend");

    log("start_frontend_server");
    await invoke("start_frontend_server");

    log("launch_app");
    await invoke("launch_app");
    execSend({ type: "APP_READY" });

    // Set up ready listener BEFORE connecting (avoid race)
    log("setup_ready_listener");
    const unlistenRef: { current: (() => void) | null } = { current: null };
    const webviewReady = new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error(`[${currentStep}] Webview did not send 'ready' within 30s.`));
      }, 30000);
      listen("test-harness://webview-ready", () => {
        clearTimeout(timeout);
        resolve();
      }).then((fn) => { unlistenRef.current = fn; });
    });

    log("connect_ws");
    connSend({ type: "CONNECT" });
    await invoke("connect_ws");
    log("connect_ws", "connected");

    log("wait_webview_ready");
    try {
      await webviewReady;
    } finally {
      unlistenRef.current?.();
    }
    log("webview_ready", "received");

    setBuildVisible(false);
    appReadyRef.current = true;
  }, [execSend, connSend, startRun]);

  /** Show the error in the build output panel */
  const showRunError = useCallback((step: string, err: unknown) => {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[tauri-cypress] FAILED at '${step}':`, err);
    setBuildLines((prev) => [
      ...prev,
      { line: `\n--- ERROR at step: ${step} ---`, stream: "stderr" },
      { line: msg, stream: "stderr" },
    ]);
    setBuildVisible(true);
    setBuildFailed(true);
    if (step.startsWith("build")) {
      execSend({ type: "BUILD_FAILED", error: `[${step}] ${msg}` });
      setTimeout(() => captureDebugSnapshot('build-failed'), 500);
    } else if (step === "launch_app") {
      execSend({ type: "LAUNCH_FAILED", error: `[${step}] ${msg}` });
      setTimeout(() => captureDebugSnapshot('launch-failed'), 500);
    } else {
      execSend({ type: "CONNECT_FAILED", error: `[${step}] ${msg}` });
      setTimeout(() => captureDebugSnapshot('connect-failed'), 500);
    }
    endRun();
  }, [execSend, endRun, captureDebugSnapshot]);

  /** Run all tests (always rebuilds and relaunches for a clean run) */
  const handleRun = useCallback(async () => {
    try {
      // Reset all state
      useIpcStore.getState().clear();
      useSnapshotStore.getState().clear();
      useCommandStore.getState().clear();
      useTestStore.getState().clearResults();
      ttSend({ type: "DEACTIVATE" });

      // Tear down previous session (ignore errors — it may already be dead)
      appReadyRef.current = false;
      try { await invoke("stop_app"); } catch { /* ok - app may already be dead */ }
      try { await invoke("disconnect_ws"); } catch { /* ok */ }

      await ensureAppReady();

      console.log("[tauri-cypress] Running all tests...");
      await invoke("run_all_tests");
      execSend({ type: "ALL_COMPLETE" });
      endRun();
      // Capture completed state
      setTimeout(() => captureDebugSnapshot('tests-complete'), 500);
    } catch (err) {
      // If it failed, make sure we're marked as not ready for next attempt
      appReadyRef.current = false;
      showRunError("run_all", err);
      // Capture error state
      setTimeout(() => captureDebugSnapshot('run-error'), 500);
    }
  }, [execSend, ttSend, ensureAppReady, showRunError, endRun, captureDebugSnapshot]);

  // Keep ref in sync for auto-run
  useEffect(() => { handleRunRef.current = handleRun; }, [handleRun]);

  const handleStop = useCallback(async () => {
    appReadyRef.current = false;
    try { await invoke("stop_app"); } catch { /* ok */ }
    try { await invoke("disconnect_ws"); } catch { /* ok */ }
    execSend({ type: "RESET" });
    connSend({ type: "DISCONNECTED" });
    endRun();
  }, [execSend, connSend, endRun]);

  /** Run a single test file (build + launch if needed, auto-recover on crash) */
  const handleRunSingleTest = useCallback(
    async (filePath: string) => {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          useCommandStore.getState().clear();
          useSnapshotStore.getState().clear();
          ttSend({ type: "DEACTIVATE" });

          // Ensure app is built and connected
          if (!appReadyRef.current) {
            // Tear down stale state
            try { await invoke("stop_app"); } catch { /* ok */ }
            try { await invoke("disconnect_ws"); } catch { /* ok */ }
            useTestStore.getState().clearResults();
            await ensureAppReady();
          }

          setCurrentlyRunningTest(filePath);
          console.log(`[tauri-cypress] Running single test: ${filePath}`);
          await invoke("run_test", { filePath });
          return; // success
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          // If channel closed / connection lost, mark not ready and retry once
          if (attempt === 0 && (msg.includes("channel closed") || msg.includes("Not connected"))) {
            console.warn("[tauri-cypress] App connection lost, relaunching...");
            appReadyRef.current = false;
            continue;
          }
          showRunError("run_single_test", err);
          return;
        }
      }
    },
    [ttSend, setCurrentlyRunningTest, ensureAppReady, showRunError]
  );

  const handleActivateTimeTravel = useCallback(
    (snapshotIndex: number) => {
      const maxIndex = useSnapshotStore.getState().snapshots.length - 1;
      if (maxIndex >= 0) {
        ttSend({ type: "ACTIVATE", index: snapshotIndex, maxIndex });
      }
    },
    [ttSend]
  );

  const handleSnapshotHover = useCallback(
    (snapshotIndex: number | null) => {
      useSnapshotStore.getState().setHoverPreviewIndex(snapshotIndex);
    },
    []
  );

  const isRunning = ["building", "launching", "connecting", "running"].includes(
    String(execState.value)
  );

  // Keyboard shortcuts
  useKeyboardShortcuts({
    onRunAll: handleRun,
    onStop: handleStop,
    onTimeTravelPrev: () => ttSend({ type: "PREV" }),
    onTimeTravelNext: () => ttSend({ type: "NEXT" }),
    onTimeTravelExit: () => ttSend({ type: "DEACTIVATE" }),
    isTimeTravelActive: ttState.value === "active",
    isRunning,
  });

  const connectionState = String(connState.value) as
    | "disconnected"
    | "connecting"
    | "connected"
    | "error";
  const executionStateValue = String(execState.value);
  const timeTravelActive = ttState.value === "active";

  return (
    <div className="flex flex-col h-screen relative">
      <div className="h-9 bg-surface border-b border-border flex items-center px-3 gap-2">
        <span className="text-success">&#9654;</span>
        <span className="text-text text-sm font-medium">tauri-cypress</span>
        {timeTravelActive && (
          <span className="text-accent text-xs ml-2">Time Travel</span>
        )}
        <span className="text-text-muted text-[9px] ml-auto">
          R run &middot; Esc stop &middot; &#8592;&#8594; navigate
        </span>
      </div>
      <PanelLayout
        sidebar={<TestSidebar onRunSingleTest={handleRunSingleTest} />}
        preview={
          <AppPreview
            timeTravelActive={timeTravelActive}
            timeTravelIndex={ttState.context.snapshotIndex}
            timeTravelMax={ttState.context.maxIndex}
            onPrev={() => ttSend({ type: "PREV" })}
            onNext={() => ttSend({ type: "NEXT" })}
            onDeactivate={() => ttSend({ type: "DEACTIVATE" })}
          />
        }
        inspector={<IpcInspector />}
        commandLog={
          <CommandLog
            onActivateTimeTravel={handleActivateTimeTravel}
            onSnapshotHover={handleSnapshotHover}
          />
        }
      />
      <StatusBar
        connectionState={connectionState}
        executionState={executionStateValue}
        onRun={handleRun}
        onStop={handleStop}
      />
      <BuildOutput
        lines={buildLines}
        visible={buildVisible}
        onDismiss={() => setBuildVisible(false)}
        buildFailed={buildFailed}
      />
      {selectedFailedTest && <ErrorPanel />}
    </div>
  );
}
