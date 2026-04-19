# tauri-cypress Test Runner UI Design

**Date:** 2026-04-19
**Status:** Design approved
**Depends on:** `crates/tauri-plugin-test-harness/` (Phase 1), `packages/tauri-cypress/` (Phase 2)

## Overview

A Tauri 2 desktop app that serves as the interactive test runner for tauri-cypress. It discovers test files, builds and spawns the app-under-test, connects via WebSocket, orchestrates test execution, and displays results in a 4-panel Cypress-style UI with time-travel debugging.

## Decomposition

The full runner is built across four sub-phases:

| Sub-phase | Scope |
|-----------|-------|
| **3a: Runner Core** | Tauri app scaffold, Rust backend (process spawning, WebSocket client, test discovery, config, build orchestration), React shell with panel layout |
| **3b: UI Panels** | TestSidebar, CommandLog, IpcInspector components with real data from backend |
| **3c: App Preview + Time Travel** | Hybrid snapshot system, AppPreview panel, time-travel mode in CommandLog |
| **3d: Polish** | Hot reload, screenshot diffing, re-run on click, keyboard shortcuts |

This spec covers **all sub-phases** as a complete design. Each sub-phase gets its own implementation plan.

## Decisions

- **Frontend:** React (matches main app)
- **Styling:** Tailwind CSS
- **State machines:** XState (connection, execution, time-travel lifecycles)
- **Data stores:** Zustand (IPC logs, snapshots, command log, test results, UI state)
- **Test discovery:** Rust filesystem scan with `walkdir` + `notify` for file watching
- **Build step:** Runner owns the build — runs `buildCommand` from config, shows progress, then launches binary
- **Layout:** Cypress-style — test sidebar left, app preview center-top, IPC inspector center-bottom, command log right
- **Time-travel:** Hybrid snapshots — both pixel-perfect canvas screenshots AND inlined-CSS HTML snapshots captured after each command. Defaults to screenshot view, toggle to HTML for DOM inspection.

## Architecture

### Data Flow

```
Runner (Tauri App)                     App-Under-Test (Tauri + plugin)
     |                                        |
     | 1. Run buildCommand                    |
     |   (cargo build --features test-harness)|
     |                                        |
     | 2. Spawn binary as child process       |
     |--------------------------------------->|
     |                                        | Plugin starts WebSocket on :9223
     | 3. Connect WebSocket to :9223          |
     |--------------------------------------->|
     |                                        |
     | 4. Send "exec" with test script        |
     |--------------------------------------->| Executes in webview
     |                                        |
     | 5. Receive "ipc" entries (streaming)   |
     |<---------------------------------------|
     |                                        |
     | 6. Receive "snapshot" after each cmd    |
     |<---------------------------------------|
     |                                        |
     | 7. Receive "result" per test           |
     |<---------------------------------------|
```

Rust backend streams WebSocket messages to React frontend via Tauri `emit()`. Frontend subscribes via `listen()`.

### Project Structure

```
packages/tauri-cypress-runner/
  package.json
  tailwind.config.ts
  vite.config.ts
  tsconfig.json
  src-tauri/
    Cargo.toml
    src/
      main.rs                    # Tauri app entry
      lib.rs                     # Plugin registration, app setup
      process.rs                 # Spawn/kill app-under-test child process
      websocket_client.rs        # Connect to plugin WebSocket, send/receive
      test_discovery.rs          # Walk filesystem, find *.cy.{ts,js}, watch changes
      config.rs                  # Parse tauri-cypress.config.json
      commands.rs                # Tauri commands exposed to frontend
      build_runner.rs            # Execute buildCommand, stream output
  src/
    main.tsx                     # React entry
    App.tsx                      # Root layout — 4 resizable panels
    machines/
      connectionMachine.ts       # XState: disconnected → connecting → connected → error
      executionMachine.ts        # XState: idle → building → running → complete
      timeTravelMachine.ts       # XState: off → active (with snapshot index)
    stores/
      testStore.ts               # Zustand: test files, results, selected test
      ipcStore.ts                # Zustand: IPC log entries (streaming append)
      snapshotStore.ts           # Zustand: DOM snapshots + screenshots for time-travel
      commandStore.ts            # Zustand: command log entries per test
      uiStore.ts                 # Zustand: panel sizes, selected tab, preferences
    components/
      TestSidebar.tsx            # File tree with pass/fail/running/pending status
      AppPreview.tsx             # Screenshot view or HTML snapshot iframe
      CommandLog.tsx             # Step-by-step log, clickable for time-travel
      IpcInspector.tsx           # Real-time IPC traffic table
      BuildOutput.tsx            # Build progress/errors overlay
      StatusBar.tsx              # Connection status, test count, timing
      PanelLayout.tsx            # Resizable split-pane container
    hooks/
      useTauriEvents.ts          # Subscribe to Tauri event channels
      useWebSocket.ts            # Connection state management hook
```

## Rust Backend

### process.rs — Process Management

Spawns the app-under-test as a child process. Captures stdout/stderr for debugging. Kills the process on shutdown or re-run.

```rust
// Key functions:
spawn_app(binary_path: &str, env: HashMap<String, String>) -> Result<Child>
kill_app(child: &mut Child) -> Result<()>
is_running(child: &Child) -> bool
```

The child process is stored in Tauri managed state. Only one app instance runs at a time — re-running kills the previous process first.

### websocket_client.rs — WebSocket Client

Connects to `ws://127.0.0.1:{port}` (default 9223). Receives `ControlMessage` variants and emits them as Tauri events. Sends `exec` messages when the frontend triggers test runs.

Events emitted to frontend:
- `test-harness://ipc` — IPC log entry
- `test-harness://result` — Test result
- `test-harness://snapshot` — DOM snapshot (HTML + screenshot data)
- `test-harness://connected` — Connection established
- `test-harness://disconnected` — Connection lost

Auto-reconnects on disconnect (3 attempts, 1s interval).

### test_discovery.rs — Test File Discovery

Walks `specPattern` directory (default `cypress/**/*.cy.{ts,js}`). Returns a tree structure matching the filesystem hierarchy. Watches for file changes and emits `test-harness://files-changed` event.

```rust
struct TestFile {
    path: String,          // relative to project root
    name: String,          // filename without extension
    last_modified: u64,    // unix timestamp
}

// Key functions:
discover_tests(spec_pattern: &str, base_dir: &str) -> Result<Vec<TestFile>>
watch_tests(spec_pattern: &str, base_dir: &str, app: AppHandle) -> Result<()>
```

### config.rs — Configuration

Reads `tauri-cypress.config.json` from the project root. Falls back to defaults for missing fields.

```rust
struct RunnerConfig {
    tauri_dir: String,                    // default: "./src-tauri"
    build_command: String,                // default: "cargo build --features test-harness"
    binary_path: String,                  // default: "./src-tauri/target/debug/{app-name}"
    spec_pattern: String,                 // default: "cypress/**/*.cy.{ts,js}"
    control_port: u16,                    // default: 9223
    default_command_timeout: u64,         // default: 4000
    exec_timeout: u64,                    // default: 60000
    screenshots_folder: String,           // default: "cypress/screenshots"
    snapshots_folder: String,             // default: "cypress/snapshots"
    env: HashMap<String, String>,         // extra env vars for app process
}
```

### build_runner.rs — Build Orchestration

Runs the `buildCommand` as a subprocess. Streams stdout/stderr to the frontend via `test-harness://build-output` events. Reports success/failure via `test-harness://build-complete`.

```rust
async fn run_build(config: &RunnerConfig, app: AppHandle) -> Result<()>
```

### commands.rs — Tauri Commands

```rust
// Exposed to frontend:
start_session(config_path: String) -> Result<()>     // load config, discover tests
run_build() -> Result<()>                              // execute buildCommand
launch_app() -> Result<()>                             // spawn app-under-test
stop_app() -> Result<()>                               // kill app process
connect_ws() -> Result<()>                             // connect to plugin WebSocket
run_test(file_path: String) -> Result<()>              // send test script via WebSocket
run_all_tests() -> Result<()>                          // run all discovered tests sequentially
get_test_files() -> Result<Vec<TestFile>>              // return discovered test files
get_config() -> Result<RunnerConfig>                   // return loaded config
```

## React Frontend

### XState Machines

**connectionMachine** — Manages WebSocket lifecycle:
```
disconnected → connecting → connected
                    ↓            ↓
                  error    disconnected
```
Events: `CONNECT`, `CONNECTED`, `DISCONNECTED`, `ERROR`, `RETRY`

**executionMachine** — Manages the full test run lifecycle:
```
idle → building → build_failed
         ↓
      launching → launch_failed
         ↓
      connecting → connect_failed
         ↓
      running → complete
         ↓
       idle
```
Events: `START`, `BUILD_COMPLETE`, `BUILD_FAILED`, `APP_READY`, `CONNECTED`, `TEST_RESULT`, `ALL_COMPLETE`, `RESET`

**timeTravelMachine** — Controls snapshot replay:
```
off → active { snapshotIndex: number }
       ↓
      off
```
Events: `ACTIVATE(index)`, `NEXT`, `PREV`, `DEACTIVATE`

When active, `AppPreview` shows the snapshot at the current index instead of the live state.

### Zustand Stores

**testStore** — Test file list and results:
```typescript
interface TestStore {
  files: TestFile[];
  results: Map<string, TestRunnerResult>;   // keyed by file path
  selectedFile: string | null;
  setFiles(files: TestFile[]): void;
  addResult(path: string, result: TestRunnerResult): void;
  selectFile(path: string): void;
}
```

**ipcStore** — IPC log with streaming append:
```typescript
interface IpcStore {
  entries: IpcLogEntry[];
  addEntry(entry: IpcLogEntry): void;
  clear(): void;
  getByCommand(name: string): IpcLogEntry[];
}
```

**snapshotStore** — Hybrid snapshots for time-travel:
```typescript
interface Snapshot {
  html: string;           // inlined CSS + data URI images
  screenshot: string;     // base64 PNG from canvas capture
  timestamp: number;
  commandName: string;    // which command triggered this snapshot
  testId: string;
}

interface SnapshotStore {
  snapshots: Snapshot[];
  viewMode: 'screenshot' | 'html';
  addSnapshot(snapshot: Snapshot): void;
  clear(): void;
  setViewMode(mode: 'screenshot' | 'html'): void;
}
```

**commandStore** — Command log per test:
```typescript
interface CommandEntry {
  name: string;              // e.g., "get('.btn')"
  status: 'pending' | 'running' | 'passed' | 'failed';
  snapshotIndex: number;     // index into snapshotStore for time-travel
  duration?: number;
  error?: string;
}

interface CommandStore {
  entries: CommandEntry[];
  selectedIndex: number | null;
  addEntry(entry: CommandEntry): void;
  updateEntry(index: number, update: Partial<CommandEntry>): void;
  selectEntry(index: number): void;
  clear(): void;
}
```

### Components

**PanelLayout** — Uses a resizable split-pane library (e.g., `react-resizable-panels`). Four panels arranged as:
```
┌──────────┬──────────────────┬──────────────┐
│          │                  │              │
│  Test    │   App Preview    │  Command     │
│ Sidebar  │                  │    Log       │
│          ├──────────────────┤              │
│          │  IPC Inspector   │              │
│          │                  │              │
└──────────┴──────────────────┴──────────────┘
```
Panel sizes are persisted in `uiStore`.

**TestSidebar** — Tree view of test files. Each file shows:
- Icon: green check (passed), red x (failed), blue spinner (running), gray dot (pending)
- Filename
- Click to select → loads results in CommandLog and IpcInspector

**AppPreview** — Two modes controlled by `timeTravelMachine`:
- **Live mode (time-travel off):** Shows the most recent screenshot or a "Running..." label
- **Time-travel mode (time-travel active):** Shows snapshot at `snapshotIndex`. Toggle between screenshot (default) and HTML iframe view. Navigation arrows to step through snapshots.

**CommandLog** — Vertical list of command entries for the selected test. Each entry shows:
- Status icon (check/x/spinner/dot)
- Command name (e.g., `get('.btn')`)
- Duration
- Click → activates time-travel at that command's snapshot index

**IpcInspector** — Table of IPC log entries:
- Columns: Command, Args (expandable), Response (expandable), Mocked (yes/no badge), Duration
- Filterable by command name
- Rows highlight on hover, expandable to show full args/response JSON

**BuildOutput** — Overlay that appears during build step. Shows streaming terminal output. Dismissable on success, stays on failure with error details.

**StatusBar** — Bottom bar showing: connection status dot, test count (passed/failed/total), elapsed time, run/stop button.

## Hybrid Snapshot System

To support time-travel, the TS library's injected JS needs modification. After each command executes in the webview, it automatically captures:

1. **HTML snapshot** — `document.documentElement.outerHTML` with all `<style>` tags inlined and external images converted to data URIs via canvas drawImage
2. **Canvas screenshot** — render the page to a canvas via `html2canvas` or `document.querySelector('body').getClientRects()` approach, export as base64 PNG

Both are sent to the runner via WebSocket as a `snapshot` message:

```json
{
  "type": "snapshot",
  "data": {
    "label": "after:get('.btn')",
    "html": "<html>...inlined...</html>",
    "screenshot": "data:image/png;base64,...",
    "url": "http://localhost/books/1",
    "timestamp_ms": 1234567890,
    "command_name": "get('.btn')"
  }
}
```

**Performance:** Snapshots are taken asynchronously and don't block command execution. The canvas screenshot is the expensive part (~50-100ms). For fast command sequences, snapshots may be slightly delayed. This is acceptable for debugging purposes.

**Storage:** Snapshots are kept in memory (Zustand store) for the current test run only. They are not persisted to disk unless the user explicitly saves via screenshot diffing (Phase 3d).

## Configuration File

The runner reads `tauri-cypress.config.json` from the project being tested:

```json
{
  "tauriDir": "./src-tauri",
  "buildCommand": "cargo build --features test-harness",
  "binaryPath": "./src-tauri/target/debug/my-app",
  "specPattern": "cypress/**/*.cy.{ts,js}",
  "controlPort": 9223,
  "baseUrl": "/",
  "screenshots": {
    "folder": "cypress/screenshots",
    "onFailure": true
  },
  "snapshots": {
    "folder": "cypress/snapshots"
  },
  "env": {
    "DATABASE_URL": "sqlite::memory:"
  },
  "defaultCommandTimeout": 4000,
  "execTimeout": 60000
}
```

JSON format chosen over TypeScript config to avoid needing a TS runtime in the runner.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Build fails | BuildOutput overlay stays visible with error. executionMachine → `build_failed`. User fixes and re-runs. |
| App crashes during test | Runner detects child process exit. Marks current test as failed with "App crashed". Emits `test-harness://app-crashed`. |
| WebSocket won't connect | connectionMachine retries 3x at 1s intervals. After 3 failures → `error` state. StatusBar shows red dot. |
| WebSocket disconnects mid-test | Current test marked as failed with "Connection lost". connectionMachine → `disconnected`. Auto-reconnect attempts. |
| Test timeout | executionMachine enforces `execTimeout`. Marks test as failed with timeout error. |
| Config file missing | Runner uses defaults. Logs warning in StatusBar. |
| No test files found | TestSidebar shows empty state with "No test files found in {specPattern}". |

## CLI Entry Point

The runner is launched via:
```bash
npx tauri-cypress open              # interactive mode
npx tauri-cypress open --config ./custom-config.json
```

The `open` command:
1. Reads config
2. Launches the runner Tauri app
3. The app handles everything from there (build, launch, connect, run)

Headless mode (`npx tauri-cypress run`) is Phase 3d scope.

## Prerequisites (changes to existing crates/packages)

The hybrid snapshot system requires two changes to existing code:

1. **Rust plugin protocol extension** — `DomSnapshot` in `crates/tauri-plugin-test-harness/src/protocol.rs` needs two new fields: `screenshot: Option<String>` (base64 PNG) and `command_name: Option<String>`. These are `Option` for backwards compatibility.

2. **Injected JS auto-snapshot** — The init script in `crates/tauri-plugin-test-harness/src/injector.rs` needs to auto-capture a snapshot after each command execution (not just when explicitly called). It also needs to include a lightweight canvas-to-PNG capture function. `html2canvas` is too heavy to inject; instead, use the native `html2canvas`-lite approach: create a foreign object SVG wrapping the HTML, draw to canvas, export as PNG. This is ~30 lines of JS, not an external dependency.

These changes are backwards-compatible — the existing plugin API is unchanged, new fields are optional.

## Limitations (this phase)

- No parallel test execution — tests run sequentially
- No headless/CI mode — interactive only
- JSON config only — no TypeScript config file support
- No screenshot diffing — snapshots captured but not compared (Phase 3d)
- Single project — runner doesn't support switching between projects
