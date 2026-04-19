# tauri-cypress Runner Core (Phase 3a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Tauri 2 app scaffold for the test runner — Rust backend (process spawning, WebSocket client, test file discovery, config loading, build orchestration) and a React shell with resizable 4-panel layout and placeholder components.

**Architecture:** A Tauri 2 app at `packages/tauri-cypress-runner/`. The Rust backend spawns the app-under-test, connects to its WebSocket, discovers test files, and streams events to the React frontend via Tauri `emit()`. The React frontend uses Zustand for data stores, XState for state machines, and Tailwind CSS v4 for styling. This plan builds the infrastructure — UI panel content comes in Phase 3b.

**Tech Stack:** Rust (Tauri 2, tokio-tungstenite, walkdir, notify, serde), TypeScript/React 19, Vite, Tailwind CSS v4, Zustand, XState v5, react-resizable-panels

**Design spec:** `docs/superpowers/specs/2026-04-19-tauri-cypress-runner-design.md`

---

## File Structure

```
packages/tauri-cypress-runner/
  package.json
  vite.config.ts
  tsconfig.json
  index.html
  src/
    main.tsx                           # React entry
    App.tsx                            # Root: 4-panel resizable layout
    App.css                            # Tailwind imports + theme
    components/
      PanelLayout.tsx                  # Resizable split-pane wrapper
      TestSidebar.tsx                  # Placeholder (Phase 3b)
      AppPreview.tsx                   # Placeholder (Phase 3b)
      CommandLog.tsx                   # Placeholder (Phase 3b)
      IpcInspector.tsx                 # Placeholder (Phase 3b)
      StatusBar.tsx                    # Connection + test count bar
    machines/
      connectionMachine.ts             # WebSocket lifecycle
      executionMachine.ts              # Build, launch, run lifecycle
    stores/
      testStore.ts                     # Test files + results
      ipcStore.ts                      # IPC log entries
      snapshotStore.ts                 # DOM snapshots
      commandStore.ts                  # Command log entries
      uiStore.ts                       # Panel sizes, prefs
    hooks/
      useTauriEvents.ts                # Subscribe to backend events
    types.ts                           # Shared TypeScript types
  src-tauri/
    Cargo.toml
    build.rs
    tauri.conf.json
    capabilities/default.json
    src/
      main.rs                          # Tauri entry
      lib.rs                           # Plugin + command registration
      config.rs                        # Parse tauri-cypress.config.json
      test_discovery.rs                # Walk filesystem, find test files
      process.rs                       # Spawn/kill app-under-test
      websocket_client.rs              # Connect to plugin WebSocket
      build_runner.rs                  # Run buildCommand
      commands.rs                      # Tauri commands
      types.rs                         # Shared Rust types
    tests/
      config_test.rs
      test_discovery_test.rs
```

---

## Task 1: Tauri App Scaffold

**Files:**
- Create: `packages/tauri-cypress-runner/package.json`
- Create: `packages/tauri-cypress-runner/vite.config.ts`
- Create: `packages/tauri-cypress-runner/tsconfig.json`
- Create: `packages/tauri-cypress-runner/index.html`
- Create: `packages/tauri-cypress-runner/src/main.tsx`
- Create: `packages/tauri-cypress-runner/src/App.tsx`
- Create: `packages/tauri-cypress-runner/src/App.css`
- Create: `packages/tauri-cypress-runner/src-tauri/Cargo.toml`
- Create: `packages/tauri-cypress-runner/src-tauri/build.rs`
- Create: `packages/tauri-cypress-runner/src-tauri/tauri.conf.json`
- Create: `packages/tauri-cypress-runner/src-tauri/capabilities/default.json`
- Create: `packages/tauri-cypress-runner/src-tauri/src/main.rs`
- Create: `packages/tauri-cypress-runner/src-tauri/src/lib.rs`
- Create: `packages/tauri-cypress-runner/src-tauri/src/types.rs`
- Create: `packages/tauri-cypress-runner/src-tauri/src/config.rs` (stub)
- Create: `packages/tauri-cypress-runner/src-tauri/src/commands.rs` (stub)

This task creates the full project scaffold. See the design spec for each file's content. Key files:

- [ ] **Step 1: Create package.json**

```json
{
  "name": "tauri-cypress-runner",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "tauri": "tauri"
  },
  "dependencies": {
    "@tauri-apps/api": "^2.0.0",
    "@tauri-apps/plugin-process": "^2.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "react-resizable-panels": "^2.0.0",
    "xstate": "^5.0.0",
    "@xstate/react": "^4.0.0",
    "zustand": "^5.0.0"
  },
  "devDependencies": {
    "@tailwindcss/vite": "^4.0.0",
    "@tauri-apps/cli": "^2.0.0",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "@vitejs/plugin-react": "^4.0.0",
    "tailwindcss": "^4.0.0",
    "typescript": "^5.5.0",
    "vite": "^6.0.0"
  }
}
```

- [ ] **Step 2: Create vite.config.ts**

```typescript
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [tailwindcss(), react()],
  server: {
    port: 1421,
    strictPort: true,
  },
  resolve: {
    alias: {
      "@": "/src",
    },
  },
});
```

- [ ] **Step 3: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "jsx": "react-jsx",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "paths": { "@/*": ["./src/*"] },
    "outDir": "dist"
  },
  "include": ["src"]
}
```

- [ ] **Step 4: Create index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>tauri-cypress</title>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="/src/main.tsx"></script>
</body>
</html>
```

- [ ] **Step 5: Create src/App.css**

```css
@import "tailwindcss";

@theme inline {
  --color-panel-bg: #16213e;
  --color-surface: #1a1a2e;
  --color-border: #333;
  --color-text: #ccc;
  --color-text-muted: #888;
  --color-accent: #60a5fa;
  --color-success: #4ade80;
  --color-error: #f87171;
  --color-warning: #fbbf24;
}

body {
  margin: 0;
  background: var(--color-surface);
  color: var(--color-text);
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  font-size: 13px;
  overflow: hidden;
  height: 100vh;
}

#root {
  height: 100vh;
  display: flex;
  flex-direction: column;
}
```

- [ ] **Step 6: Create src/main.tsx**

```tsx
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./App.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
```

- [ ] **Step 7: Create src/App.tsx (minimal shell)**

```tsx
export function App() {
  return (
    <div className="flex flex-col h-screen">
      <div className="flex-1 flex items-center justify-center text-text-muted">
        tauri-cypress runner
      </div>
    </div>
  );
}
```

- [ ] **Step 8: Create src-tauri/Cargo.toml**

```toml
[package]
name = "tauri-cypress-runner"
version = "0.1.0"
edition = "2021"

[dependencies]
tauri = { version = "2", features = [] }
tauri-plugin-process = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
tokio-tungstenite = "0.24"
futures-util = { version = "0.3", features = ["sink"] }
walkdir = "2"
notify = "7"
log = "0.4"
thiserror = "2"
tungstenite = "0.24"

[dev-dependencies]
tempfile = "3"

[build-dependencies]
tauri-build = { version = "2", features = [] }
```

- [ ] **Step 9: Create src-tauri/build.rs**

```rust
fn main() {
    tauri_build::build()
}
```

- [ ] **Step 10: Create src-tauri/tauri.conf.json**

```json
{
  "productName": "tauri-cypress",
  "identifier": "com.tauri-cypress.runner",
  "build": {
    "frontendDist": "../dist",
    "devUrl": "http://localhost:1421"
  },
  "app": {
    "windows": [
      {
        "title": "tauri-cypress",
        "width": 1280,
        "height": 800,
        "minWidth": 900,
        "minHeight": 600
      }
    ],
    "security": {
      "csp": null
    }
  }
}
```

- [ ] **Step 11: Create src-tauri/capabilities/default.json**

```json
{
  "identifier": "default",
  "description": "Default capabilities for the runner",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "process:default"
  ]
}
```

- [ ] **Step 12: Create src-tauri/src/main.rs**

```rust
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri_cypress_runner::run();
}
```

- [ ] **Step 13: Create src-tauri/src/types.rs**

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestFile {
    pub path: String,
    pub name: String,
    pub last_modified: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RunnerConfig {
    pub tauri_dir: String,
    pub build_command: String,
    pub binary_path: String,
    pub spec_pattern: String,
    pub control_port: u16,
    pub default_command_timeout: u64,
    pub exec_timeout: u64,
    pub screenshots_folder: String,
    pub snapshots_folder: String,
    #[serde(default)]
    pub env: std::collections::HashMap<String, String>,
}
```

Note: The `Default` derive on `RunnerConfig` produces zero-values. The actual defaults (port 9223, timeout 4000, etc.) are in `config.rs`.

- [ ] **Step 14: Create stub src-tauri/src/config.rs**

```rust
use crate::types::RunnerConfig;

pub fn load_config(path: &str) -> Result<RunnerConfig, String> {
    let content = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(&content).map_err(|e| e.to_string())
}
```

- [ ] **Step 15: Create stub src-tauri/src/commands.rs**

```rust
use tauri::command;
use crate::types::{RunnerConfig, TestFile};

#[command]
pub async fn get_config() -> Result<RunnerConfig, String> {
    Ok(RunnerConfig::default())
}

#[command]
pub async fn get_test_files() -> Result<Vec<TestFile>, String> {
    Ok(vec![])
}
```

- [ ] **Step 16: Create src-tauri/src/lib.rs**

```rust
pub mod commands;
pub mod config;
pub mod types;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .invoke_handler(tauri::generate_handler![
            commands::get_config,
            commands::get_test_files,
        ])
        .run(tauri::generate_context!())
        .expect("error running tauri-cypress-runner");
}
```

- [ ] **Step 17: Install dependencies and verify**

Run: `cd packages/tauri-cypress-runner && pnpm install`
Run: `cd packages/tauri-cypress-runner/src-tauri && cargo check`
Expected: Both succeed.

- [ ] **Step 18: Commit**

```
feat(tauri-cypress-runner): scaffold Tauri app with React frontend
```

---

## Task 2: Config Module with Defaults

**Files:**
- Modify: `packages/tauri-cypress-runner/src-tauri/src/config.rs`
- Create: `packages/tauri-cypress-runner/src-tauri/tests/config_test.rs`

- [ ] **Step 1: Write failing tests**

```rust
// tests/config_test.rs
use tauri_cypress_runner::config::load_config;
use std::io::Write;

#[test]
fn test_load_config_from_json() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("tauri-cypress.config.json");
    let mut file = std::fs::File::create(&config_path).unwrap();
    write!(file, r#"{{"tauriDir":"./src-tauri","buildCommand":"cargo build --features test-harness","binaryPath":"./target/debug/my-app","specPattern":"tests/**/*.cy.ts","controlPort":9999,"defaultCommandTimeout":5000,"execTimeout":30000,"screenshotsFolder":"screenshots","snapshotsFolder":"snapshots","env":{{"DB":"test.db"}}}}"#).unwrap();

    let config = load_config(config_path.to_str().unwrap()).unwrap();
    assert_eq!(config.tauri_dir, "./src-tauri");
    assert_eq!(config.binary_path, "./target/debug/my-app");
    assert_eq!(config.spec_pattern, "tests/**/*.cy.ts");
    assert_eq!(config.control_port, 9999);
    assert_eq!(config.default_command_timeout, 5000);
    assert_eq!(config.env.get("DB").unwrap(), "test.db");
}

#[test]
fn test_load_config_uses_defaults_for_missing_fields() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("tauri-cypress.config.json");
    let mut file = std::fs::File::create(&config_path).unwrap();
    write!(file, r#"{{}}"#).unwrap();

    let config = load_config(config_path.to_str().unwrap()).unwrap();
    assert_eq!(config.tauri_dir, "./src-tauri");
    assert_eq!(config.control_port, 9223);
    assert_eq!(config.default_command_timeout, 4000);
    assert_eq!(config.spec_pattern, "cypress/**/*.cy.{ts,js}");
}

#[test]
fn test_load_config_missing_file_returns_error() {
    let result = load_config("/nonexistent/path.json");
    assert!(result.is_err());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo test --test config_test`
Expected: Fails (config.rs doesn't handle camelCase or defaults yet).

- [ ] **Step 3: Implement config.rs with serde defaults**

```rust
use crate::types::RunnerConfig;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigFile {
    #[serde(default = "default_tauri_dir")]
    tauri_dir: String,
    #[serde(default = "default_build_command")]
    build_command: String,
    #[serde(default)]
    binary_path: String,
    #[serde(default = "default_spec_pattern")]
    spec_pattern: String,
    #[serde(default = "default_control_port")]
    control_port: u16,
    #[serde(default = "default_command_timeout")]
    default_command_timeout: u64,
    #[serde(default = "default_exec_timeout")]
    exec_timeout: u64,
    #[serde(default = "default_screenshots_folder")]
    screenshots_folder: String,
    #[serde(default = "default_snapshots_folder")]
    snapshots_folder: String,
    #[serde(default)]
    env: std::collections::HashMap<String, String>,
}

fn default_tauri_dir() -> String { "./src-tauri".to_string() }
fn default_build_command() -> String { "cargo build --features test-harness".to_string() }
fn default_spec_pattern() -> String { "cypress/**/*.cy.{ts,js}".to_string() }
fn default_control_port() -> u16 { 9223 }
fn default_command_timeout() -> u64 { 4000 }
fn default_exec_timeout() -> u64 { 60000 }
fn default_screenshots_folder() -> String { "cypress/screenshots".to_string() }
fn default_snapshots_folder() -> String { "cypress/snapshots".to_string() }

pub fn load_config(path: &str) -> Result<RunnerConfig, String> {
    let content = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let file: ConfigFile = serde_json::from_str(&content).map_err(|e| e.to_string())?;
    Ok(RunnerConfig {
        tauri_dir: file.tauri_dir,
        build_command: file.build_command,
        binary_path: file.binary_path,
        spec_pattern: file.spec_pattern,
        control_port: file.control_port,
        default_command_timeout: file.default_command_timeout,
        exec_timeout: file.exec_timeout,
        screenshots_folder: file.screenshots_folder,
        snapshots_folder: file.snapshots_folder,
        env: file.env,
    })
}
```

- [ ] **Step 4: Run tests**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo test --test config_test`
Expected: All 3 tests pass.

- [ ] **Step 5: Commit**

```
feat(tauri-cypress-runner): add config loading with camelCase JSON and defaults
```

---

## Task 3: Test Discovery

**Files:**
- Create: `packages/tauri-cypress-runner/src-tauri/src/test_discovery.rs`
- Create: `packages/tauri-cypress-runner/src-tauri/tests/test_discovery_test.rs`
- Modify: `packages/tauri-cypress-runner/src-tauri/src/lib.rs`

- [ ] **Step 1: Write failing tests**

```rust
// tests/test_discovery_test.rs
use tauri_cypress_runner::test_discovery::discover_tests;
use std::fs;

#[test]
fn test_discovers_cy_ts_files() {
    let dir = tempfile::tempdir().unwrap();
    let cypress_dir = dir.path().join("cypress").join("e2e");
    fs::create_dir_all(&cypress_dir).unwrap();
    fs::write(cypress_dir.join("auth.cy.ts"), "// test").unwrap();
    fs::write(cypress_dir.join("books.cy.ts"), "// test").unwrap();
    fs::write(cypress_dir.join("helper.ts"), "// not a test").unwrap();

    let files = discover_tests("cypress/**/*.cy.ts", dir.path().to_str().unwrap()).unwrap();
    assert_eq!(files.len(), 2);
    let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
    assert!(names.contains(&"auth.cy"));
    assert!(names.contains(&"books.cy"));
}

#[test]
fn test_discovers_cy_js_files() {
    let dir = tempfile::tempdir().unwrap();
    let cypress_dir = dir.path().join("cypress").join("e2e");
    fs::create_dir_all(&cypress_dir).unwrap();
    fs::write(cypress_dir.join("login.cy.js"), "// test").unwrap();

    let files = discover_tests("cypress/**/*.cy.js", dir.path().to_str().unwrap()).unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].name, "login.cy");
}

#[test]
fn test_returns_empty_for_no_matches() {
    let dir = tempfile::tempdir().unwrap();
    let files = discover_tests("cypress/**/*.cy.ts", dir.path().to_str().unwrap()).unwrap();
    assert!(files.is_empty());
}

#[test]
fn test_returns_relative_paths() {
    let dir = tempfile::tempdir().unwrap();
    let cypress_dir = dir.path().join("cypress").join("e2e");
    fs::create_dir_all(&cypress_dir).unwrap();
    fs::write(cypress_dir.join("test.cy.ts"), "// test").unwrap();

    let files = discover_tests("cypress/**/*.cy.ts", dir.path().to_str().unwrap()).unwrap();
    assert!(files[0].path.starts_with("cypress"));
    assert!(!files[0].path.starts_with("/"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo test --test test_discovery_test`

- [ ] **Step 3: Implement test_discovery.rs**

```rust
use crate::types::TestFile;
use std::path::Path;
use walkdir::WalkDir;

pub fn discover_tests(spec_pattern: &str, base_dir: &str) -> Result<Vec<TestFile>, String> {
    let base = Path::new(base_dir);
    let (dir_prefix, extensions) = parse_pattern(spec_pattern);
    let search_dir = base.join(&dir_prefix);

    if !search_dir.exists() {
        return Ok(vec![]);
    }

    let mut files = Vec::new();

    for entry in WalkDir::new(&search_dir).into_iter().filter_map(|e| e.ok()) {
        if !entry.file_type().is_file() {
            continue;
        }

        let path = entry.path();
        let file_name = path.file_name().unwrap_or_default().to_string_lossy();

        if !extensions.iter().any(|ext| file_name.ends_with(ext)) {
            continue;
        }

        let relative = path.strip_prefix(base).map_err(|e| e.to_string())?.to_string_lossy().to_string();
        let name = path.file_stem().unwrap_or_default().to_string_lossy().to_string();
        let metadata = entry.metadata().map_err(|e| e.to_string())?;
        let last_modified = metadata
            .modified()
            .map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs())
            .unwrap_or(0);

        files.push(TestFile { path: relative, name, last_modified });
    }

    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

fn parse_pattern(pattern: &str) -> (String, Vec<String>) {
    let parts: Vec<&str> = pattern.splitn(2, "/**/").collect();
    let dir_prefix = if parts.len() == 2 { parts[0].to_string() } else { ".".to_string() };
    let file_glob = if parts.len() == 2 { parts[1] } else { parts[0] };

    let extensions = if let Some(start) = file_glob.find('{') {
        let end = file_glob.find('}').unwrap_or(file_glob.len());
        let prefix = &file_glob[1..start];
        let variants = &file_glob[start + 1..end];
        variants.split(',').map(|v| format!("{}{}", prefix, v.trim())).collect()
    } else {
        vec![file_glob[1..].to_string()]
    };

    (dir_prefix, extensions)
}
```

- [ ] **Step 4: Add module to lib.rs**

Add `pub mod test_discovery;` to lib.rs.

- [ ] **Step 5: Run tests**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo test --test test_discovery_test`
Expected: All 4 tests pass.

- [ ] **Step 6: Commit**

```
feat(tauri-cypress-runner): add test file discovery with glob pattern matching
```

---

## Task 4: Process Management

**Files:**
- Create: `packages/tauri-cypress-runner/src-tauri/src/process.rs`
- Modify: `packages/tauri-cypress-runner/src-tauri/src/lib.rs`

- [ ] **Step 1: Implement process.rs**

```rust
use std::collections::HashMap;
use std::process::{Child, Command, Stdio};
use log::{info, error};

pub struct AppProcess {
    child: Option<Child>,
}

impl AppProcess {
    pub fn new() -> Self {
        Self { child: None }
    }

    pub fn spawn(&mut self, binary_path: &str, env: &HashMap<String, String>) -> Result<u32, String> {
        self.kill().ok();
        let mut cmd = Command::new(binary_path);
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        for (key, value) in env {
            cmd.env(key, value);
        }
        let child = cmd.spawn().map_err(|e| format!("Failed to spawn {}: {}", binary_path, e))?;
        let pid = child.id();
        info!("Spawned app-under-test (pid: {})", pid);
        self.child = Some(child);
        Ok(pid)
    }

    pub fn kill(&mut self) -> Result<(), String> {
        if let Some(ref mut child) = self.child {
            child.kill().map_err(|e| e.to_string())?;
            child.wait().map_err(|e| e.to_string())?;
            info!("Killed app-under-test");
            self.child = None;
        }
        Ok(())
    }

    pub fn is_running(&mut self) -> bool {
        if let Some(ref mut child) = self.child {
            matches!(child.try_wait(), Ok(None))
        } else {
            false
        }
    }
}

impl Drop for AppProcess {
    fn drop(&mut self) {
        if let Err(e) = self.kill() {
            error!("Failed to kill app on drop: {}", e);
        }
    }
}
```

- [ ] **Step 2: Add `pub mod process;` to lib.rs**

- [ ] **Step 3: Verify compiles**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo check`

- [ ] **Step 4: Commit**

```
feat(tauri-cypress-runner): add process management for app-under-test
```

---

## Task 5: WebSocket Client

**Files:**
- Create: `packages/tauri-cypress-runner/src-tauri/src/websocket_client.rs`
- Modify: `packages/tauri-cypress-runner/src-tauri/src/lib.rs`

- [ ] **Step 1: Implement websocket_client.rs**

```rust
use futures_util::{SinkExt, StreamExt};
use log::{debug, error, info};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Runtime};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::connect_async;
use tungstenite::protocol::Message;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ControlMessage {
    Exec { script: String, test_id: String },
    Result { data: serde_json::Value },
    Snapshot { data: serde_json::Value },
    Ipc { data: serde_json::Value },
}

pub struct WsClient {
    send_tx: Option<mpsc::Sender<String>>,
    shutdown_tx: Option<broadcast::Sender<()>>,
}

impl WsClient {
    pub fn new() -> Self {
        Self { send_tx: None, shutdown_tx: None }
    }

    pub async fn connect<R: Runtime>(&mut self, port: u16, app: AppHandle<R>) -> Result<(), String> {
        self.disconnect().await;
        let url = format!("ws://127.0.0.1:{}", port);
        info!("Connecting to {}", url);

        let (ws_stream, _) = connect_async(&url).await.map_err(|e| format!("WebSocket connect failed: {}", e))?;
        let (mut ws_write, mut ws_read) = ws_stream.split();
        let (send_tx, mut send_rx) = mpsc::channel::<String>(256);
        let (shutdown_tx, _) = broadcast::channel::<()>(1);

        self.send_tx = Some(send_tx);
        self.shutdown_tx = Some(shutdown_tx.clone());

        let _ = app.emit("test-harness://connected", ());

        let app_clone = app.clone();
        let mut shutdown_rx_read = shutdown_tx.subscribe();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    msg = ws_read.next() => {
                        match msg {
                            Some(Ok(Message::Text(text))) => {
                                if let Ok(ctrl_msg) = serde_json::from_str::<ControlMessage>(&text) {
                                    match &ctrl_msg {
                                        ControlMessage::Result { data } => { let _ = app_clone.emit("test-harness://result", data.clone()); }
                                        ControlMessage::Ipc { data } => { let _ = app_clone.emit("test-harness://ipc", data.clone()); }
                                        ControlMessage::Snapshot { data } => { let _ = app_clone.emit("test-harness://snapshot", data.clone()); }
                                        ControlMessage::Exec { .. } => { debug!("Received exec (unexpected)"); }
                                    }
                                }
                            }
                            Some(Ok(Message::Close(_))) | None => {
                                let _ = app_clone.emit("test-harness://disconnected", ());
                                break;
                            }
                            Some(Err(e)) => {
                                error!("WebSocket error: {}", e);
                                let _ = app_clone.emit("test-harness://disconnected", ());
                                break;
                            }
                            _ => {}
                        }
                    }
                    _ = shutdown_rx_read.recv() => { break; }
                }
            }
        });

        let mut shutdown_rx_write = shutdown_tx.subscribe();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    msg = send_rx.recv() => {
                        match msg {
                            Some(text) => { if ws_write.send(Message::Text(text)).await.is_err() { break; } }
                            None => break,
                        }
                    }
                    _ = shutdown_rx_write.recv() => { break; }
                }
            }
        });

        Ok(())
    }

    pub async fn send_exec(&self, script: &str, test_id: &str) -> Result<(), String> {
        let msg = serde_json::json!({ "type": "exec", "script": script, "test_id": test_id });
        if let Some(tx) = &self.send_tx {
            tx.send(msg.to_string()).await.map_err(|e| format!("Send failed: {}", e))
        } else {
            Err("Not connected".to_string())
        }
    }

    pub async fn disconnect(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() { let _ = tx.send(()); }
        self.send_tx = None;
    }
}
```

- [ ] **Step 2: Add `pub mod websocket_client;` to lib.rs**

- [ ] **Step 3: Verify compiles**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo check`

- [ ] **Step 4: Commit**

```
feat(tauri-cypress-runner): add WebSocket client for app-under-test connection
```

---

## Task 6: Build Runner

**Files:**
- Create: `packages/tauri-cypress-runner/src-tauri/src/build_runner.rs`
- Modify: `packages/tauri-cypress-runner/src-tauri/src/lib.rs`

- [ ] **Step 1: Implement build_runner.rs**

```rust
use log::{error, info};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use tauri::{AppHandle, Emitter, Runtime};

#[derive(serde::Serialize, Clone)]
struct BuildOutput { line: String, stream: String }

#[derive(serde::Serialize, Clone)]
struct BuildComplete { success: bool, exit_code: Option<i32> }

pub fn run_build<R: Runtime>(build_command: &str, working_dir: &str, app: AppHandle<R>) -> Result<(), String> {
    info!("Running build: {}", build_command);
    let parts: Vec<&str> = build_command.split_whitespace().collect();
    if parts.is_empty() { return Err("Empty build command".to_string()); }

    let mut cmd = Command::new(parts[0]);
    if parts.len() > 1 { cmd.args(&parts[1..]); }
    cmd.current_dir(working_dir).stdout(Stdio::piped()).stderr(Stdio::piped());

    let mut child = cmd.spawn().map_err(|e| format!("Failed to start build: {}", e))?;

    if let Some(stdout) = child.stdout.take() {
        let app_c = app.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().flatten() {
                let _ = app_c.emit("test-harness://build-output", BuildOutput { line, stream: "stdout".to_string() });
            }
        });
    }

    if let Some(stderr) = child.stderr.take() {
        let app_c = app.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().flatten() {
                let _ = app_c.emit("test-harness://build-output", BuildOutput { line, stream: "stderr".to_string() });
            }
        });
    }

    let status = child.wait().map_err(|e| e.to_string())?;
    let success = status.success();
    let _ = app.emit("test-harness://build-complete", BuildComplete { success, exit_code: status.code() });

    if success { info!("Build succeeded"); Ok(()) }
    else { let msg = format!("Build failed (exit {})", status.code().unwrap_or(-1)); error!("{}", msg); Err(msg) }
}
```

- [ ] **Step 2: Add `pub mod build_runner;` to lib.rs**

- [ ] **Step 3: Verify compiles**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo check`

- [ ] **Step 4: Commit**

```
feat(tauri-cypress-runner): add build runner with streaming output
```

---

## Task 7: Full Commands Module + State Wiring

**Files:**
- Modify: `packages/tauri-cypress-runner/src-tauri/src/commands.rs`
- Modify: `packages/tauri-cypress-runner/src-tauri/src/lib.rs`

- [ ] **Step 1: Implement full commands.rs**

```rust
use tauri::{command, AppHandle, Manager, Runtime};
use tokio::sync::Mutex;
use crate::{build_runner, config, process::AppProcess, test_discovery, types::{RunnerConfig, TestFile}, websocket_client::WsClient};

pub struct RunnerState {
    pub config: Mutex<RunnerConfig>,
    pub process: Mutex<AppProcess>,
    pub ws_client: Mutex<WsClient>,
    pub project_dir: Mutex<String>,
}

#[command]
pub async fn start_session<R: Runtime>(app: AppHandle<R>, config_path: Option<String>, project_dir: String) -> Result<RunnerConfig, String> {
    let cfg = if let Some(path) = config_path {
        config::load_config(&path)?
    } else {
        let default_path = format!("{}/tauri-cypress.config.json", project_dir);
        config::load_config(&default_path).unwrap_or_default()
    };
    let state = app.state::<RunnerState>();
    *state.config.lock().await = cfg.clone();
    *state.project_dir.lock().await = project_dir;
    Ok(cfg)
}

#[command]
pub async fn get_config<R: Runtime>(app: AppHandle<R>) -> Result<RunnerConfig, String> {
    Ok(app.state::<RunnerState>().config.lock().await.clone())
}

#[command]
pub async fn get_test_files<R: Runtime>(app: AppHandle<R>) -> Result<Vec<TestFile>, String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await;
    let project_dir = state.project_dir.lock().await;
    test_discovery::discover_tests(&config.spec_pattern, &project_dir)
}

#[command]
pub async fn run_build<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await.clone();
    let project_dir = state.project_dir.lock().await.clone();
    let app_clone = app.clone();
    tokio::task::spawn_blocking(move || build_runner::run_build(&config.build_command, &project_dir, app_clone))
        .await.map_err(|e| e.to_string())?
}

#[command]
pub async fn launch_app<R: Runtime>(app: AppHandle<R>) -> Result<u32, String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await;
    let project_dir = state.project_dir.lock().await;
    let binary = if config.binary_path.is_empty() {
        format!("{}/target/debug/tauri-cypress-app", project_dir)
    } else if config.binary_path.starts_with("./") {
        format!("{}/{}", project_dir, &config.binary_path[2..])
    } else {
        config.binary_path.clone()
    };
    drop(config);
    drop(project_dir);
    state.process.lock().await.spawn(&binary, &state.config.lock().await.env)
}

#[command]
pub async fn stop_app<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    app.state::<RunnerState>().process.lock().await.kill()
}

#[command]
pub async fn connect_ws<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let port = state.config.lock().await.control_port;
    state.ws_client.lock().await.connect(port, app.clone()).await
}

#[command]
pub async fn disconnect_ws<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    app.state::<RunnerState>().ws_client.lock().await.disconnect().await;
    Ok(())
}

#[command]
pub async fn run_test<R: Runtime>(app: AppHandle<R>, file_path: String) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let project_dir = state.project_dir.lock().await;
    let full_path = format!("{}/{}", project_dir, file_path);
    let script = std::fs::read_to_string(&full_path).map_err(|e| format!("Failed to read {}: {}", full_path, e))?;
    state.ws_client.lock().await.send_exec(&script, &file_path).await
}

#[command]
pub async fn run_all_tests<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await.clone();
    let project_dir = state.project_dir.lock().await.clone();
    let files = test_discovery::discover_tests(&config.spec_pattern, &project_dir)?;
    for file in files {
        let full_path = format!("{}/{}", project_dir, file.path);
        let script = std::fs::read_to_string(&full_path).map_err(|e| format!("Failed to read {}: {}", full_path, e))?;
        state.ws_client.lock().await.send_exec(&script, &file.path).await?;
    }
    Ok(())
}
```

- [ ] **Step 2: Update lib.rs with full wiring**

```rust
pub mod build_runner;
pub mod commands;
pub mod config;
pub mod process;
pub mod test_discovery;
pub mod types;
pub mod websocket_client;

use commands::RunnerState;
use process::AppProcess;
use tokio::sync::Mutex;
use types::RunnerConfig;
use websocket_client::WsClient;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .manage(RunnerState {
            config: Mutex::new(RunnerConfig::default()),
            process: Mutex::new(AppProcess::new()),
            ws_client: Mutex::new(WsClient::new()),
            project_dir: Mutex::new(String::new()),
        })
        .invoke_handler(tauri::generate_handler![
            commands::start_session,
            commands::get_config,
            commands::get_test_files,
            commands::run_build,
            commands::launch_app,
            commands::stop_app,
            commands::connect_ws,
            commands::disconnect_ws,
            commands::run_test,
            commands::run_all_tests,
        ])
        .run(tauri::generate_context!())
        .expect("error running tauri-cypress-runner");
}
```

- [ ] **Step 3: Verify compiles**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo check`

- [ ] **Step 4: Commit**

```
feat(tauri-cypress-runner): wire all commands with managed state
```

---

## Task 8: Frontend Types + Event Hook

**Files:**
- Create: `packages/tauri-cypress-runner/src/types.ts`
- Create: `packages/tauri-cypress-runner/src/hooks/useTauriEvents.ts`

- [ ] **Step 1: Create types.ts**

```typescript
export interface TestFile { path: string; name: string; last_modified: number; }
export interface RunnerConfig { tauri_dir: string; build_command: string; binary_path: string; spec_pattern: string; control_port: number; default_command_timeout: number; exec_timeout: number; screenshots_folder: string; snapshots_folder: string; env: Record<string, string>; }
export interface TestRunnerResult { test_id: string; status: "passed" | "failed" | "skipped"; assertions: AssertionResult[]; error: string | null; duration_ms: number; }
export interface AssertionResult { description: string; passed: boolean; expected: unknown; actual: unknown; }
export interface IpcLogEntry { command: string; args: unknown; response: unknown; mocked: boolean; duration_ms: number; timestamp_ms: number; }
export interface DomSnapshot { label: string; html: string; screenshot?: string; url: string; timestamp_ms: number; command_name?: string; }
export interface CommandEntry { name: string; status: "pending" | "running" | "passed" | "failed"; snapshotIndex: number; duration?: number; error?: string; }
export interface BuildOutput { line: string; stream: "stdout" | "stderr"; }
export interface BuildComplete { success: boolean; exit_code: number | null; }
```

- [ ] **Step 2: Create useTauriEvents.ts**

```typescript
import { useEffect } from "react";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export function useTauriEvent<T>(event: string, callback: (payload: T) => void) {
  useEffect(() => {
    let unlisten: UnlistenFn | undefined;
    listen<T>(event, (e) => callback(e.payload)).then((fn) => { unlisten = fn; });
    return () => { unlisten?.(); };
  }, [event, callback]);
}
```

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): add frontend types and Tauri event hook
```

---

## Task 9: Zustand Stores

**Files:**
- Create: `packages/tauri-cypress-runner/src/stores/testStore.ts`
- Create: `packages/tauri-cypress-runner/src/stores/ipcStore.ts`
- Create: `packages/tauri-cypress-runner/src/stores/snapshotStore.ts`
- Create: `packages/tauri-cypress-runner/src/stores/commandStore.ts`
- Create: `packages/tauri-cypress-runner/src/stores/uiStore.ts`

- [ ] **Step 1: Create all stores**

**testStore.ts:**
```typescript
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
```

**ipcStore.ts:**
```typescript
import { create } from "zustand";
import type { IpcLogEntry } from "../types";

interface IpcStore {
  entries: IpcLogEntry[];
  addEntry: (entry: IpcLogEntry) => void;
  clear: () => void;
}

export const useIpcStore = create<IpcStore>((set) => ({
  entries: [],
  addEntry: (entry) => set((s) => ({ entries: [...s.entries, entry] })),
  clear: () => set({ entries: [] }),
}));
```

**snapshotStore.ts:**
```typescript
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
```

**commandStore.ts:**
```typescript
import { create } from "zustand";
import type { CommandEntry } from "../types";

interface CommandStore {
  entries: CommandEntry[]; selectedIndex: number | null;
  addEntry: (entry: CommandEntry) => void;
  updateEntry: (index: number, update: Partial<CommandEntry>) => void;
  selectEntry: (index: number | null) => void;
  clear: () => void;
}

export const useCommandStore = create<CommandStore>((set) => ({
  entries: [], selectedIndex: null,
  addEntry: (entry) => set((s) => ({ entries: [...s.entries, entry] })),
  updateEntry: (index, update) => set((s) => ({ entries: s.entries.map((e, i) => i === index ? { ...e, ...update } : e) })),
  selectEntry: (index) => set({ selectedIndex: index }),
  clear: () => set({ entries: [], selectedIndex: null }),
}));
```

**uiStore.ts:**
```typescript
import { create } from "zustand";

interface UiStore {
  buildOutputVisible: boolean;
  setBuildOutputVisible: (visible: boolean) => void;
}

export const useUiStore = create<UiStore>((set) => ({
  buildOutputVisible: false,
  setBuildOutputVisible: (visible) => set({ buildOutputVisible: visible }),
}));
```

- [ ] **Step 2: Commit**

```
feat(tauri-cypress-runner): add Zustand stores for test, IPC, snapshot, command, and UI state
```

---

## Task 10: XState Machines

**Files:**
- Create: `packages/tauri-cypress-runner/src/machines/connectionMachine.ts`
- Create: `packages/tauri-cypress-runner/src/machines/executionMachine.ts`

- [ ] **Step 1: Create connectionMachine.ts**

```typescript
import { setup, assign } from "xstate";

export const connectionMachine = setup({
  types: {
    context: {} as { retryCount: number; maxRetries: number },
    events: {} as
      | { type: "CONNECT" }
      | { type: "CONNECTED" }
      | { type: "DISCONNECTED" }
      | { type: "ERROR"; error: string }
      | { type: "RETRY" },
  },
}).createMachine({
  id: "connection",
  initial: "disconnected",
  context: { retryCount: 0, maxRetries: 3 },
  states: {
    disconnected: { on: { CONNECT: "connecting" } },
    connecting: {
      on: {
        CONNECTED: { target: "connected", actions: assign({ retryCount: 0 }) },
        ERROR: [
          { target: "connecting", guard: ({ context }) => context.retryCount < context.maxRetries, actions: assign({ retryCount: ({ context }) => context.retryCount + 1 }) },
          { target: "error" },
        ],
      },
    },
    connected: { on: { DISCONNECTED: "disconnected", ERROR: "error" } },
    error: { on: { RETRY: { target: "connecting", actions: assign({ retryCount: 0 }) } } },
  },
});
```

- [ ] **Step 2: Create executionMachine.ts**

```typescript
import { setup, assign } from "xstate";

export const executionMachine = setup({
  types: {
    context: {} as { currentFile: string | null; error: string | null },
    events: {} as
      | { type: "START"; file?: string }
      | { type: "BUILD_COMPLETE" }
      | { type: "BUILD_FAILED"; error: string }
      | { type: "APP_READY" }
      | { type: "LAUNCH_FAILED"; error: string }
      | { type: "CONNECTED" }
      | { type: "CONNECT_FAILED"; error: string }
      | { type: "TEST_COMPLETE" }
      | { type: "ALL_COMPLETE" }
      | { type: "RESET" },
  },
}).createMachine({
  id: "execution",
  initial: "idle",
  context: { currentFile: null, error: null },
  states: {
    idle: { on: { START: { target: "building", actions: assign({ currentFile: ({ event }) => event.file ?? null, error: null }) } } },
    building: { on: { BUILD_COMPLETE: "launching", BUILD_FAILED: { target: "build_failed", actions: assign({ error: ({ event }) => event.error }) } } },
    build_failed: { on: { START: { target: "building", actions: assign({ error: null }) }, RESET: "idle" } },
    launching: { on: { APP_READY: "connecting", LAUNCH_FAILED: { target: "launch_failed", actions: assign({ error: ({ event }) => event.error }) } } },
    launch_failed: { on: { START: "building", RESET: "idle" } },
    connecting: { on: { CONNECTED: "running", CONNECT_FAILED: { target: "connect_failed", actions: assign({ error: ({ event }) => event.error }) } } },
    connect_failed: { on: { START: "building", RESET: "idle" } },
    running: { on: { TEST_COMPLETE: "running", ALL_COMPLETE: "complete" } },
    complete: { on: { START: "building", RESET: "idle" } },
  },
});
```

- [ ] **Step 3: Commit**

```
feat(tauri-cypress-runner): add XState machines for connection and execution lifecycle
```

---

## Task 11: Panel Layout + App Shell

**Files:**
- Create: `packages/tauri-cypress-runner/src/components/PanelLayout.tsx`
- Create: `packages/tauri-cypress-runner/src/components/TestSidebar.tsx`
- Create: `packages/tauri-cypress-runner/src/components/AppPreview.tsx`
- Create: `packages/tauri-cypress-runner/src/components/CommandLog.tsx`
- Create: `packages/tauri-cypress-runner/src/components/IpcInspector.tsx`
- Create: `packages/tauri-cypress-runner/src/components/StatusBar.tsx`
- Modify: `packages/tauri-cypress-runner/src/App.tsx`

- [ ] **Step 1: Create PanelLayout.tsx**

```tsx
import { Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import type { ReactNode } from "react";

function Handle({ dir = "vertical" }: { dir?: "vertical" | "horizontal" }) {
  return <PanelResizeHandle className={`${dir === "vertical" ? "w-1" : "h-1"} bg-border hover:bg-accent transition-colors`} />;
}

export function PanelLayout({ sidebar, preview, inspector, commandLog }: { sidebar: ReactNode; preview: ReactNode; inspector: ReactNode; commandLog: ReactNode }) {
  return (
    <PanelGroup direction="horizontal" className="flex-1">
      <Panel defaultSize={18} minSize={12} maxSize={30}>
        <div className="h-full bg-panel-bg overflow-auto">{sidebar}</div>
      </Panel>
      <Handle />
      <Panel defaultSize={54} minSize={30}>
        <PanelGroup direction="vertical">
          <Panel defaultSize={55} minSize={20}>
            <div className="h-full bg-surface overflow-auto">{preview}</div>
          </Panel>
          <Handle dir="horizontal" />
          <Panel defaultSize={45} minSize={15}>
            <div className="h-full bg-surface overflow-auto">{inspector}</div>
          </Panel>
        </PanelGroup>
      </Panel>
      <Handle />
      <Panel defaultSize={28} minSize={15} maxSize={40}>
        <div className="h-full bg-panel-bg overflow-auto">{commandLog}</div>
      </Panel>
    </PanelGroup>
  );
}
```

- [ ] **Step 2: Create placeholder components**

**TestSidebar.tsx:**
```tsx
export function TestSidebar() {
  return (<div className="p-2"><div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">Tests</div><div className="text-text-muted text-xs">No test files loaded</div></div>);
}
```

**AppPreview.tsx:**
```tsx
export function AppPreview() {
  return (<div className="h-full flex items-center justify-center"><div className="text-center"><div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">App Preview</div><div className="text-text-muted text-xs">Not connected</div></div></div>);
}
```

**CommandLog.tsx:**
```tsx
export function CommandLog() {
  return (<div className="p-2"><div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">Command Log</div><div className="text-text-muted text-xs">Run a test to see commands</div></div>);
}
```

**IpcInspector.tsx:**
```tsx
export function IpcInspector() {
  return (<div className="p-2"><div className="text-[9px] uppercase text-text-muted tracking-wider mb-2">IPC Inspector</div><div className="text-text-muted text-xs">No IPC traffic</div></div>);
}
```

**StatusBar.tsx:**
```tsx
export function StatusBar() {
  return (<div className="h-6 bg-panel-bg border-t border-border flex items-center px-3 text-[11px] gap-4"><div className="flex items-center gap-1.5"><div className="w-2 h-2 rounded-full bg-text-muted" /><span className="text-text-muted">Disconnected</span></div><div className="text-text-muted ml-auto">tauri-cypress v0.1.0</div></div>);
}
```

- [ ] **Step 3: Update App.tsx**

```tsx
import { PanelLayout } from "./components/PanelLayout";
import { TestSidebar } from "./components/TestSidebar";
import { AppPreview } from "./components/AppPreview";
import { CommandLog } from "./components/CommandLog";
import { IpcInspector } from "./components/IpcInspector";
import { StatusBar } from "./components/StatusBar";

export function App() {
  return (
    <div className="flex flex-col h-screen">
      <div className="h-9 bg-surface border-b border-border flex items-center px-3 gap-2">
        <span className="text-success">&#9654;</span>
        <span className="text-text text-sm font-medium">tauri-cypress</span>
      </div>
      <PanelLayout sidebar={<TestSidebar />} preview={<AppPreview />} inspector={<IpcInspector />} commandLog={<CommandLog />} />
      <StatusBar />
    </div>
  );
}
```

- [ ] **Step 4: Commit**

```
feat(tauri-cypress-runner): add resizable 4-panel layout with placeholder components
```

---

## Task 12: Build Verification

- [ ] **Step 1: Verify Rust compiles**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo check`

- [ ] **Step 2: Verify Rust tests pass**

Run: `cd packages/tauri-cypress-runner/src-tauri && cargo test`

- [ ] **Step 3: Verify frontend compiles**

Run: `cd packages/tauri-cypress-runner && npx tsc --noEmit`

- [ ] **Step 4: Fix any issues**

- [ ] **Step 5: Commit if fixes needed**

```
chore(tauri-cypress-runner): finalize Phase 3a runner core
```

---

## Summary

| Task | Description | Tests |
|------|-------------|-------|
| 1 | Tauri app scaffold | compile check |
| 2 | Config module | 3 Rust tests |
| 3 | Test discovery | 4 Rust tests |
| 4 | Process management | compile check |
| 5 | WebSocket client | compile check |
| 6 | Build runner | compile check |
| 7 | Commands + state wiring | compile check |
| 8 | Frontend types + event hook | compile check |
| 9 | Zustand stores | compile check |
| 10 | XState machines | compile check |
| 11 | Panel layout + components | compile check |
| 12 | Build verification | full check |
