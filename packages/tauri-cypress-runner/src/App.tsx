import { useCallback, useState } from "react";
import { useMachine } from "@xstate/react";
import { invoke } from "@tauri-apps/api/core";
import { PanelLayout } from "./components/PanelLayout";
import { TestSidebar } from "./components/TestSidebar";
import { AppPreview } from "./components/AppPreview";
import { CommandLog } from "./components/CommandLog";
import { IpcInspector } from "./components/IpcInspector";
import { StatusBar } from "./components/StatusBar";
import { BuildOutput } from "./components/BuildOutput";
import { connectionMachine } from "./machines/connectionMachine";
import { executionMachine } from "./machines/executionMachine";
import { timeTravelMachine } from "./machines/timeTravelMachine";
import { useTauriEvent } from "./hooks/useTauriEvents";
import { useTestStore } from "./stores/testStore";
import { useIpcStore } from "./stores/ipcStore";
import { useSnapshotStore } from "./stores/snapshotStore";
import { useCommandStore } from "./stores/commandStore";
import type {
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

  const addResult = useTestStore((s) => s.addResult);
  const addIpc = useIpcStore((s) => s.addEntry);
  const addSnapshot = useSnapshotStore((s) => s.addSnapshot);
  const addCommand = useCommandStore((s) => s.addEntry);

  useTauriEvent<TestRunnerResult>("test-harness://result", useCallback((data) => {
    addResult(data.test_id, data);
    addCommand({
      name: `result: ${data.test_id}`,
      status: data.status === "passed" ? "passed" : "failed",
      snapshotIndex: -1,
      duration: data.duration_ms,
      error: data.error ?? undefined,
    });
    execSend({ type: "TEST_COMPLETE" });
  }, [addResult, addCommand, execSend]));

  useTauriEvent<IpcLogEntry>("test-harness://ipc", useCallback((data) => {
    addIpc(data);
  }, [addIpc]));

  useTauriEvent<DomSnapshot>("test-harness://snapshot", useCallback((data) => {
    addSnapshot(data);
    const newIndex = useSnapshotStore.getState().snapshots.length - 1;
    if (data.command_name) {
      addCommand({
        name: data.command_name,
        status: "passed",
        snapshotIndex: newIndex,
      });
    }
    // Keep time-travel max in sync
    if (ttState.value === "active") {
      ttSend({ type: "UPDATE_MAX", maxIndex: newIndex });
    }
  }, [addSnapshot, addCommand, ttState.value, ttSend]));

  useTauriEvent("test-harness://connected", useCallback(() => {
    connSend({ type: "CONNECTED" });
    execSend({ type: "CONNECTED" });
  }, [connSend, execSend]));

  useTauriEvent("test-harness://disconnected", useCallback(() => {
    connSend({ type: "DISCONNECTED" });
  }, [connSend]));

  useTauriEvent<BuildOutputLine>("test-harness://build-output", useCallback((data) => {
    setBuildLines((prev) => [...prev, data]);
  }, []));

  useTauriEvent<BuildComplete>("test-harness://build-complete", useCallback((data) => {
    if (data.success) {
      execSend({ type: "BUILD_COMPLETE" });
      setBuildVisible(false);
    } else {
      execSend({ type: "BUILD_FAILED", error: `Exit code: ${data.exit_code}` });
      setBuildFailed(true);
    }
  }, [execSend]));

  const handleRun = useCallback(async () => {
    try {
      useIpcStore.getState().clear();
      useSnapshotStore.getState().clear();
      useCommandStore.getState().clear();
      useTestStore.getState().clearResults();
      ttSend({ type: "DEACTIVATE" });

      execSend({ type: "START" });
      setBuildLines([]);
      setBuildFailed(false);
      setBuildVisible(true);

      await invoke("run_build");
      await invoke("launch_app");
      execSend({ type: "APP_READY" });

      connSend({ type: "CONNECT" });
      await invoke("connect_ws");

      await invoke("run_all_tests");
      execSend({ type: "ALL_COMPLETE" });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (execState.value === "building") {
        execSend({ type: "BUILD_FAILED", error: msg });
        setBuildFailed(true);
      } else if (execState.value === "launching") {
        execSend({ type: "LAUNCH_FAILED", error: msg });
      } else if (execState.value === "connecting") {
        execSend({ type: "CONNECT_FAILED", error: msg });
      }
    }
  }, [execSend, connSend, ttSend, execState.value]);

  const handleStop = useCallback(async () => {
    try {
      await invoke("stop_app");
      await invoke("disconnect_ws");
    } catch {
      // ignore errors during stop
    }
    execSend({ type: "RESET" });
    connSend({ type: "DISCONNECTED" });
  }, [execSend, connSend]);

  const handleActivateTimeTravel = useCallback((snapshotIndex: number) => {
    const maxIndex = useSnapshotStore.getState().snapshots.length - 1;
    if (maxIndex >= 0) {
      ttSend({ type: "ACTIVATE", index: snapshotIndex, maxIndex });
    }
  }, [ttSend]);

  const connectionState = String(connState.value) as "disconnected" | "connecting" | "connected" | "error";
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
      </div>
      <PanelLayout
        sidebar={<TestSidebar />}
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
        commandLog={<CommandLog onActivateTimeTravel={handleActivateTimeTravel} />}
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
    </div>
  );
}
