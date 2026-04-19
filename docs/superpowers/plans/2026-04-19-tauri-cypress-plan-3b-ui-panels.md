# tauri-cypress Runner UI Panels (Phase 3b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5 placeholder UI components (TestSidebar, CommandLog, IpcInspector, AppPreview, StatusBar) with real implementations wired to Zustand stores, XState machines, and Tauri backend commands. Also wire App.tsx to subscribe to Tauri events and feed data into stores/machines.

**Architecture:** Each component reads from its corresponding Zustand store (already created in Phase 3a). App.tsx orchestrates by subscribing to Tauri events (`test-harness://result`, `test-harness://ipc`, `test-harness://snapshot`, etc.) and pushing data into stores. XState machines drive connection and execution state. Components are pure data renderers — no direct Tauri command invocation except for user-triggered actions (run test, stop app).

**Tech Stack:** React 19, Zustand 5, XState 5 + @xstate/react 4, Tailwind CSS v4, @tauri-apps/api (invoke, listen)

**Design spec:** `docs/superpowers/specs/2026-04-19-tauri-cypress-runner-design.md`

---

## File Structure

```
packages/tauri-cypress-runner/src/
  App.tsx                              # MODIFY: Wire event subscriptions, machines, orchestration
  components/
    TestSidebar.tsx                     # MODIFY: File tree with status icons, click-to-select
    CommandLog.tsx                      # MODIFY: Step-by-step command list, click for time-travel
    IpcInspector.tsx                    # MODIFY: IPC traffic table with expandable rows
    AppPreview.tsx                      # MODIFY: Screenshot viewer or placeholder by state
    StatusBar.tsx                       # MODIFY: Connection dot, test counts, run/stop button
    BuildOutput.tsx                     # CREATE: Build progress overlay with streaming terminal
```

No new Rust changes — all backend commands exist from Phase 3a.

---

## Task 1: TestSidebar — File Tree with Status

**Files:**
- Modify: `packages/tauri-cypress-runner/src/components/TestSidebar.tsx`

The TestSidebar reads `files` and `results` from `useTestStore`, and `selectedFile` for highlight state. Each file row shows a status icon and filename. Clicking selects the file.

- [ ] **Step 1: Implement TestSidebar**

```tsx
import { useTestStore } from "../stores/testStore";
import type { TestRunnerResult } from "../types";

function StatusIcon({ result }: { result?: TestRunnerResult }) {
  if (!result) return <span className="w-3 h-3 rounded-full bg-text-muted inline-block" />;
  if (result.status === "passed") return <span className="text-success text-xs">&#10003;</span>;
  if (result.status === "failed") return <span className="text-error text-xs">&#10007;</span>;
  return <span className="text-warning text-xs">&#8722;</span>;
}

export function TestSidebar() {
  const { files, results, selectedFile, selectFile } = useTestStore();

  if (files.length === 0) {
    return (
      <div className="p-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">Tests</div>
        <div className="text-text-muted text-xs">No test files loaded</div>
      </div>
    );
  }

  return (
    <div className="p-2">
      <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">
        Tests ({files.length})
      </div>
      <ul className="space-y-0.5">
        {files.map((file) => (
          <li key={file.path}>
            <button
              onClick={() => selectFile(file.path)}
              className={`w-full text-left flex items-center gap-1.5 px-1.5 py-1 rounded text-xs transition-colors ${
                selectedFile === file.path
                  ? "bg-accent/20 text-accent"
                  : "text-text hover:bg-white/5"
              }`}
            >
              <StatusIcon result={results[file.path]} />
              <span className="truncate">{file.name}</span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): implement TestSidebar with file list and status icons
```

---

## Task 2: CommandLog — Step-by-Step Command List

**Files:**
- Modify: `packages/tauri-cypress-runner/src/components/CommandLog.tsx`

CommandLog reads from `useCommandStore`. Each entry shows a status icon, command name, duration, and optional error. Clicking an entry calls `selectEntry` which App.tsx will later use for time-travel (Phase 3c).

- [ ] **Step 1: Implement CommandLog**

```tsx
import { useCommandStore } from "../stores/commandStore";
import type { CommandEntry } from "../types";

function CmdStatusIcon({ status }: { status: CommandEntry["status"] }) {
  switch (status) {
    case "passed": return <span className="text-success text-[10px]">&#10003;</span>;
    case "failed": return <span className="text-error text-[10px]">&#10007;</span>;
    case "running": return <span className="text-accent text-[10px] animate-pulse">&#9679;</span>;
    default: return <span className="text-text-muted text-[10px]">&#9679;</span>;
  }
}

function formatDuration(ms?: number): string {
  if (ms == null) return "";
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

export function CommandLog() {
  const { entries, selectedIndex, selectEntry } = useCommandStore();

  if (entries.length === 0) {
    return (
      <div className="p-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">Command Log</div>
        <div className="text-text-muted text-xs">Run a test to see commands</div>
      </div>
    );
  }

  return (
    <div className="p-2">
      <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">
        Command Log ({entries.length})
      </div>
      <ol className="space-y-0.5">
        {entries.map((entry, i) => (
          <li key={i}>
            <button
              onClick={() => selectEntry(i)}
              className={`w-full text-left flex items-center gap-1.5 px-1.5 py-1 rounded text-xs transition-colors ${
                selectedIndex === i
                  ? "bg-accent/20 text-accent"
                  : "text-text hover:bg-white/5"
              }`}
            >
              <CmdStatusIcon status={entry.status} />
              <span className="truncate flex-1 font-mono">{entry.name}</span>
              {entry.duration != null && (
                <span className="text-text-muted text-[10px] shrink-0">{formatDuration(entry.duration)}</span>
              )}
            </button>
            {entry.error && selectedIndex === i && (
              <div className="ml-5 mt-0.5 text-[10px] text-error bg-error/10 rounded px-1.5 py-1 break-all">
                {entry.error}
              </div>
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): implement CommandLog with status icons and selection
```

---

## Task 3: IpcInspector — IPC Traffic Table

**Files:**
- Modify: `packages/tauri-cypress-runner/src/components/IpcInspector.tsx`

IpcInspector reads from `useIpcStore`. Shows a table of IPC log entries with command name, mocked badge, duration, and expandable args/response JSON.

- [ ] **Step 1: Implement IpcInspector**

```tsx
import { useState, useCallback } from "react";
import { useIpcStore } from "../stores/ipcStore";

function JsonExpander({ label, data }: { label: string; data: unknown }) {
  const [open, setOpen] = useState(false);
  const json = JSON.stringify(data, null, 2);
  const isLong = json.length > 40;

  if (!isLong) return <span className="text-text-muted">{json}</span>;

  return (
    <span>
      <button onClick={() => setOpen(!open)} className="text-accent hover:underline">
        {open ? "collapse" : label}
      </button>
      {open && (
        <pre className="mt-0.5 text-[10px] text-text-muted bg-surface rounded p-1 overflow-x-auto max-h-32">
          {json}
        </pre>
      )}
    </span>
  );
}

export function IpcInspector() {
  const entries = useIpcStore((s) => s.entries);
  const [filter, setFilter] = useState("");

  const filtered = filter
    ? entries.filter((e) => e.command.toLowerCase().includes(filter.toLowerCase()))
    : entries;

  const onFilterChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    setFilter(e.target.value);
  }, []);

  if (entries.length === 0) {
    return (
      <div className="p-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">IPC Inspector</div>
        <div className="text-text-muted text-xs">No IPC traffic</div>
      </div>
    );
  }

  return (
    <div className="p-2 flex flex-col h-full">
      <div className="flex items-center gap-2 mb-2">
        <div className="text-[9px] uppercase text-text-muted tracking-wider">
          IPC Inspector ({filtered.length})
        </div>
        <input
          type="text"
          value={filter}
          onChange={onFilterChange}
          placeholder="Filter command..."
          className="ml-auto text-[10px] bg-panel-bg border border-border rounded px-1.5 py-0.5 text-text outline-none focus:border-accent w-32"
        />
      </div>
      <div className="flex-1 overflow-auto">
        <table className="w-full text-[11px]">
          <thead>
            <tr className="text-text-muted text-left border-b border-border">
              <th className="py-1 pr-2 font-normal">Command</th>
              <th className="py-1 pr-2 font-normal">Args</th>
              <th className="py-1 pr-2 font-normal">Response</th>
              <th className="py-1 pr-2 font-normal w-12">Mock</th>
              <th className="py-1 font-normal w-14 text-right">Time</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((entry, i) => (
              <tr key={i} className="border-b border-border/50 hover:bg-white/5">
                <td className="py-1 pr-2 font-mono text-accent">{entry.command}</td>
                <td className="py-1 pr-2"><JsonExpander label="args" data={entry.args} /></td>
                <td className="py-1 pr-2"><JsonExpander label="resp" data={entry.response} /></td>
                <td className="py-1 pr-2">
                  {entry.mocked ? (
                    <span className="bg-warning/20 text-warning rounded px-1 py-0.5 text-[9px]">mock</span>
                  ) : (
                    <span className="text-text-muted text-[9px]">real</span>
                  )}
                </td>
                <td className="py-1 text-right text-text-muted">{entry.duration_ms}ms</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): implement IpcInspector with filterable traffic table
```

---

## Task 4: AppPreview — Screenshot / Placeholder View

**Files:**
- Modify: `packages/tauri-cypress-runner/src/components/AppPreview.tsx`

AppPreview shows the most recent screenshot from the snapshot store when available, or a state-based placeholder. Full time-travel is Phase 3c — this just shows the latest snapshot.

- [ ] **Step 1: Implement AppPreview**

```tsx
import { useSnapshotStore } from "../stores/snapshotStore";

export function AppPreview() {
  const { snapshots, viewMode } = useSnapshotStore();
  const latest = snapshots.length > 0 ? snapshots[snapshots.length - 1] : null;

  if (!latest) {
    return (
      <div className="h-full flex items-center justify-center">
        <div className="text-center">
          <div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">App Preview</div>
          <div className="text-text-muted text-xs">Run a test to see preview</div>
        </div>
      </div>
    );
  }

  if (viewMode === "screenshot" && latest.screenshot) {
    return (
      <div className="h-full flex flex-col">
        <div className="flex items-center justify-between px-2 py-1 border-b border-border">
          <span className="text-[9px] uppercase text-text-muted tracking-wider">
            {latest.label || "App Preview"}
          </span>
          <span className="text-[9px] text-text-muted">{latest.url}</span>
        </div>
        <div className="flex-1 overflow-auto flex items-center justify-center bg-black/20 p-2">
          <img
            src={latest.screenshot}
            alt="App screenshot"
            className="max-w-full max-h-full object-contain rounded shadow-lg"
          />
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col">
      <div className="flex items-center justify-between px-2 py-1 border-b border-border">
        <span className="text-[9px] uppercase text-text-muted tracking-wider">
          {latest.label || "App Preview"} (HTML)
        </span>
        <span className="text-[9px] text-text-muted">{latest.url}</span>
      </div>
      <div className="flex-1 overflow-auto">
        <iframe
          srcDoc={latest.html}
          title="App snapshot"
          className="w-full h-full border-none bg-white"
          sandbox="allow-same-origin"
        />
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): implement AppPreview with screenshot and HTML snapshot view
```

---

## Task 5: StatusBar — Connection, Counts, Run/Stop

**Files:**
- Modify: `packages/tauri-cypress-runner/src/components/StatusBar.tsx`

StatusBar reads connection state (passed as props from App.tsx which owns the XState actors), test counts from `useTestStore`, and provides a run/stop button.

- [ ] **Step 1: Implement StatusBar**

```tsx
import { useTestStore } from "../stores/testStore";

interface StatusBarProps {
  connectionState: "disconnected" | "connecting" | "connected" | "error";
  executionState: string;
  onRun: () => void;
  onStop: () => void;
}

const CONNECTION_COLORS: Record<string, string> = {
  disconnected: "bg-text-muted",
  connecting: "bg-warning animate-pulse",
  connected: "bg-success",
  error: "bg-error",
};

const CONNECTION_LABELS: Record<string, string> = {
  disconnected: "Disconnected",
  connecting: "Connecting...",
  connected: "Connected",
  error: "Error",
};

export function StatusBar({ connectionState, executionState, onRun, onStop }: StatusBarProps) {
  const { files, results } = useTestStore();
  const passed = Object.values(results).filter((r) => r.status === "passed").length;
  const failed = Object.values(results).filter((r) => r.status === "failed").length;
  const total = files.length;
  const isRunning = executionState === "building" || executionState === "launching" || executionState === "connecting" || executionState === "running";

  return (
    <div className="h-6 bg-panel-bg border-t border-border flex items-center px-3 text-[11px] gap-4">
      <div className="flex items-center gap-1.5">
        <div className={`w-2 h-2 rounded-full ${CONNECTION_COLORS[connectionState]}`} />
        <span className="text-text-muted">{CONNECTION_LABELS[connectionState]}</span>
      </div>

      {total > 0 && (
        <div className="flex items-center gap-2">
          {passed > 0 && <span className="text-success">{passed} passed</span>}
          {failed > 0 && <span className="text-error">{failed} failed</span>}
          <span className="text-text-muted">{total} total</span>
        </div>
      )}

      {executionState !== "idle" && executionState !== "complete" && (
        <span className="text-accent capitalize">{executionState.replace("_", " ")}</span>
      )}

      <div className="ml-auto flex items-center gap-2">
        {isRunning ? (
          <button
            onClick={onStop}
            className="text-error hover:text-error/80 transition-colors"
            title="Stop"
          >
            &#9632; Stop
          </button>
        ) : (
          <button
            onClick={onRun}
            className="text-success hover:text-success/80 transition-colors"
            title="Run all tests"
          >
            &#9654; Run
          </button>
        )}
        <span className="text-text-muted">tauri-cypress v0.1.0</span>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): implement StatusBar with connection state, test counts, and run/stop
```

---

## Task 6: BuildOutput — Streaming Build Overlay

**Files:**
- Create: `packages/tauri-cypress-runner/src/components/BuildOutput.tsx`

BuildOutput is an overlay that appears during the build step. It streams terminal output lines. It auto-scrolls and dismisses on success.

- [ ] **Step 1: Create BuildOutput**

```tsx
import { useRef, useEffect } from "react";
import type { BuildOutput as BuildOutputLine } from "../types";

interface BuildOutputProps {
  lines: BuildOutputLine[];
  visible: boolean;
  onDismiss: () => void;
  buildFailed: boolean;
}

export function BuildOutput({ lines, visible, onDismiss, buildFailed }: BuildOutputProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [lines.length]);

  if (!visible) return null;

  return (
    <div className="absolute inset-0 z-50 bg-surface/95 flex flex-col">
      <div className="flex items-center justify-between px-3 py-2 border-b border-border">
        <div className="flex items-center gap-2">
          <span className="text-[9px] uppercase text-text-muted tracking-wider">Build Output</span>
          {buildFailed && <span className="text-error text-xs">Build Failed</span>}
          {!buildFailed && lines.length > 0 && <span className="text-accent text-xs animate-pulse">Building...</span>}
        </div>
        <button
          onClick={onDismiss}
          className="text-text-muted hover:text-text text-xs"
        >
          &#10005; Close
        </button>
      </div>
      <div ref={scrollRef} className="flex-1 overflow-auto p-3 font-mono text-[11px]">
        {lines.map((line, i) => (
          <div
            key={i}
            className={line.stream === "stderr" ? "text-error" : "text-text"}
          >
            {line.line}
          </div>
        ))}
        {lines.length === 0 && (
          <div className="text-text-muted">Waiting for build output...</div>
        )}
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): add BuildOutput overlay with streaming terminal
```

---

## Task 7: App.tsx — Wire Events, Machines, and Orchestration

**Files:**
- Modify: `packages/tauri-cypress-runner/src/App.tsx`

This is the central wiring task. App.tsx:
1. Creates XState actors for connection and execution machines
2. Subscribes to all Tauri events and feeds data into stores
3. Manages build output state
4. Passes props to StatusBar
5. Shows BuildOutput overlay

- [ ] **Step 1: Implement wired App.tsx**

```tsx
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
  const [buildLines, setBuildLines] = useState<BuildOutputLine[]>([]);
  const [buildVisible, setBuildVisible] = useState(false);
  const [buildFailed, setBuildFailed] = useState(false);

  const addResult = useTestStore((s) => s.addResult);
  const addIpc = useIpcStore((s) => s.addEntry);
  const addSnapshot = useSnapshotStore((s) => s.addSnapshot);
  const addCommand = useCommandStore((s) => s.addEntry);

  // Subscribe to Tauri events from the backend
  useTauriEvent<TestRunnerResult>("test-harness://result", useCallback((data) => {
    addResult(data.test_id, data);
    addCommand({ name: `result: ${data.test_id}`, status: data.status === "passed" ? "passed" : "failed", snapshotIndex: -1, duration: data.duration_ms, error: data.error ?? undefined });
    execSend({ type: "TEST_COMPLETE" });
  }, [addResult, addCommand, execSend]));

  useTauriEvent<IpcLogEntry>("test-harness://ipc", useCallback((data) => {
    addIpc(data);
  }, [addIpc]));

  useTauriEvent<DomSnapshot>("test-harness://snapshot", useCallback((data) => {
    addSnapshot(data);
    if (data.command_name) {
      addCommand({ name: data.command_name, status: "passed", snapshotIndex: useSnapshotStore.getState().snapshots.length - 1 });
    }
  }, [addSnapshot, addCommand]));

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
      // Clear previous state
      useIpcStore.getState().clear();
      useSnapshotStore.getState().clear();
      useCommandStore.getState().clear();
      useTestStore.getState().clearResults();

      execSend({ type: "START" });
      setBuildLines([]);
      setBuildFailed(false);
      setBuildVisible(true);

      // Step 1: Build
      await invoke("run_build");

      // Step 2: Launch app
      await invoke("launch_app");
      execSend({ type: "APP_READY" });

      // Step 3: Connect WebSocket
      connSend({ type: "CONNECT" });
      await invoke("connect_ws");

      // Step 4: Run all tests
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
  }, [execSend, connSend, execState.value]);

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

  const connectionState = String(connState.value) as "disconnected" | "connecting" | "connected" | "error";
  const executionStateValue = String(execState.value);

  return (
    <div className="flex flex-col h-screen relative">
      <div className="h-9 bg-surface border-b border-border flex items-center px-3 gap-2">
        <span className="text-success">&#9654;</span>
        <span className="text-text text-sm font-medium">tauri-cypress</span>
      </div>
      <PanelLayout
        sidebar={<TestSidebar />}
        preview={<AppPreview />}
        inspector={<IpcInspector />}
        commandLog={<CommandLog />}
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
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): wire App.tsx with event subscriptions, XState machines, and orchestration
```

---

## Task 8: Build Verification

- [ ] **Step 1: Verify Rust compiles**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo check`
Expected: No errors (no Rust changes in this phase).

- [ ] **Step 2: Verify Rust tests pass**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo test`
Expected: All tests pass.

- [ ] **Step 3: Verify frontend compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`
Expected: No errors.

- [ ] **Step 4: Fix any issues found**

- [ ] **Step 5: Commit if fixes needed**

```
chore(tauri-cypress-runner): finalize Phase 3b UI panels
```

---

## Summary

| Task | Component | Reads From | Key Feature |
|------|-----------|------------|-------------|
| 1 | TestSidebar | testStore | File list with pass/fail icons, click-to-select |
| 2 | CommandLog | commandStore | Step-by-step command list, click for time-travel index |
| 3 | IpcInspector | ipcStore | Filterable IPC traffic table with expandable JSON |
| 4 | AppPreview | snapshotStore | Latest screenshot or HTML iframe |
| 5 | StatusBar | testStore + props | Connection dot, test counts, run/stop button |
| 6 | BuildOutput | App state | Streaming terminal overlay |
| 7 | App.tsx | All stores + machines | Event subscriptions, orchestration, machine actors |
| 8 | Verification | — | Compile + test check |
