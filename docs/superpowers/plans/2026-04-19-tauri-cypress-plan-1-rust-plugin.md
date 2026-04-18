# tauri-plugin-test-harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Rust plugin that enables E2E testing of Tauri apps — WebSocket control channel, JS injection, IPC interception, command mocking, state inspection, window control, and user-defined helpers.

**Architecture:** A Tauri 2 plugin that uses `js_init_script` to inject a test runtime into the webview before app code loads, starts a WebSocket server for communication with the test runner, and intercepts IPC at both JS and Rust levels. All functionality is behind a compile-time feature flag.

**Tech Stack:** Rust, Tauri 2 plugin API, tokio-tungstenite (WebSocket), serde/serde_json (serialization)

**Design spec:** `docs/superpowers/specs/2026-04-19-tauri-cypress-design.md`

**Correction from spec:** The spec mentions `on_page_load` for injection. The correct API is `js_init_script` which runs before HTML parsing. `on_page_load` fires too late.

---

## File Structure

```
crates/tauri-plugin-test-harness/
  Cargo.toml
  build.rs                    # Tauri plugin build-time setup
  src/
    lib.rs                    # Plugin entry: Builder API, init(), wires everything together
    protocol.rs               # WebSocket message types (exec, result, snapshot, ipc)
    mock_registry.rs          # Thread-safe command mock storage and matching
    helper_registry.rs        # User-defined Rust helper functions
    websocket.rs              # WebSocket server (tokio-tungstenite)
    injector.rs               # JS init script generation (the __tauriCypress global)
    interceptor.rs            # Rust-level IPC interception via invoke_handler
    commands.rs               # Tauri commands exposed by the plugin to JS
    error.rs                  # Error types
  tests/
    protocol_test.rs
    mock_registry_test.rs
    helper_registry_test.rs
    websocket_test.rs
```

---

## Task 1: Project Scaffold and Protocol Types

**Files:**
- Create: `crates/tauri-plugin-test-harness/Cargo.toml`
- Create: `crates/tauri-plugin-test-harness/build.rs`
- Create: `crates/tauri-plugin-test-harness/src/lib.rs`
- Create: `crates/tauri-plugin-test-harness/src/error.rs`
- Create: `crates/tauri-plugin-test-harness/src/protocol.rs`
- Test: `crates/tauri-plugin-test-harness/tests/protocol_test.rs`

- [ ] **Step 1: Create Cargo.toml**

```toml
[package]
name = "tauri-plugin-test-harness"
version = "0.1.0"
edition = "2021"
description = "E2E testing plugin for Tauri applications"
license = "MIT"

[dependencies]
tauri = { version = "2", default-features = false }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
tokio-tungstenite = "0.24"
futures-util = { version = "0.3", features = ["sink"] }
log = "0.4"
thiserror = "2"

[build-dependencies]
tauri-plugin = { version = "2", features = ["build"] }

[dev-dependencies]
tokio = { version = "1", features = ["full", "test-util"] }
tungstenite = "0.24"
```

- [ ] **Step 2: Create build.rs**

```rust
const COMMANDS: &[&str] = &[
    "register_mock",
    "clear_mocks",
    "call_helper",
    "get_app_state",
    "resize_window",
    "minimize_window",
    "maximize_window",
    "fullscreen_window",
    "get_window_position",
    "get_window_size",
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS).build();
}
```

- [ ] **Step 3: Create error.rs**

```rust
use serde::Serialize;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("WebSocket error: {0}")]
    WebSocket(String),

    #[error("Mock not found for command: {0}")]
    MockNotFound(String),

    #[error("Helper not found: {0}")]
    HelperNotFound(String),

    #[error("Helper execution failed: {0}")]
    HelperFailed(String),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("Tauri error: {0}")]
    Tauri(#[from] tauri::Error),
}

impl Serialize for Error {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
```

- [ ] **Step 4: Write failing test for protocol types**

```rust
// tests/protocol_test.rs
use tauri_plugin_test_harness::protocol::{
    ControlMessage, TestResult, TestStatus, DomSnapshot, IpcLogEntry,
};

#[test]
fn test_exec_message_serializes() {
    let msg = ControlMessage::Exec {
        script: "cy.get('.btn').click()".to_string(),
        test_id: "test-1".to_string(),
    };
    let json = serde_json::to_string(&msg).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["type"], "exec");
    assert_eq!(parsed["script"], "cy.get('.btn').click()");
    assert_eq!(parsed["test_id"], "test-1");
}

#[test]
fn test_result_message_serializes() {
    let msg = ControlMessage::Result {
        data: TestResult {
            test_id: "test-1".to_string(),
            status: TestStatus::Passed,
            assertions: vec![],
            error: None,
            duration_ms: 42,
        },
    };
    let json = serde_json::to_string(&msg).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["type"], "result");
    assert_eq!(parsed["data"]["status"], "passed");
    assert_eq!(parsed["data"]["duration_ms"], 42);
}

#[test]
fn test_snapshot_message_serializes() {
    let msg = ControlMessage::Snapshot {
        data: DomSnapshot {
            label: "after-click".to_string(),
            html: "<div>hello</div>".to_string(),
            url: "http://localhost/books/1".to_string(),
            timestamp_ms: 1000,
        },
    };
    let json = serde_json::to_string(&msg).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["type"], "snapshot");
    assert_eq!(parsed["data"]["label"], "after-click");
}

#[test]
fn test_ipc_log_entry_serializes() {
    let msg = ControlMessage::Ipc {
        data: IpcLogEntry {
            command: "get_book_data".to_string(),
            args: serde_json::json!({"path": "/test.epub"}),
            response: Some(serde_json::json!({"title": "Test"})),
            mocked: false,
            duration_ms: 15,
            timestamp_ms: 2000,
        },
    };
    let json = serde_json::to_string(&msg).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["type"], "ipc");
    assert_eq!(parsed["data"]["command"], "get_book_data");
    assert_eq!(parsed["data"]["mocked"], false);
}

#[test]
fn test_control_message_deserializes_exec() {
    let json = r#"{"type":"exec","script":"cy.visit('/')","test_id":"t-2"}"#;
    let msg: ControlMessage = serde_json::from_str(json).unwrap();
    match msg {
        ControlMessage::Exec { script, test_id } => {
            assert_eq!(script, "cy.visit('/')");
            assert_eq!(test_id, "t-2");
        }
        _ => panic!("expected Exec variant"),
    }
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `cd crates/tauri-plugin-test-harness && cargo test --test protocol_test`
Expected: Compilation failure, `protocol` module does not exist yet.

- [ ] **Step 6: Implement protocol.rs**

```rust
use serde::{Deserialize, Serialize};

/// Messages sent over the WebSocket control channel between the test runner and app-under-test.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ControlMessage {
    Exec {
        script: String,
        test_id: String,
    },
    Result {
        data: TestResult,
    },
    Snapshot {
        data: DomSnapshot,
    },
    Ipc {
        data: IpcLogEntry,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestResult {
    pub test_id: String,
    pub status: TestStatus,
    pub assertions: Vec<AssertionResult>,
    pub error: Option<String>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TestStatus {
    Passed,
    Failed,
    Skipped,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssertionResult {
    pub description: String,
    pub passed: bool,
    pub expected: Option<serde_json::Value>,
    pub actual: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DomSnapshot {
    pub label: String,
    pub html: String,
    pub url: String,
    pub timestamp_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IpcLogEntry {
    pub command: String,
    pub args: serde_json::Value,
    pub response: Option<serde_json::Value>,
    pub mocked: bool,
    pub duration_ms: u64,
    pub timestamp_ms: u64,
}
```

- [ ] **Step 7: Create lib.rs with module declarations and re-exports**

```rust
pub mod protocol;
pub mod error;

pub use error::{Error, Result};
pub use protocol::*;
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd crates/tauri-plugin-test-harness && cargo test --test protocol_test`
Expected: All 5 tests pass.

- [ ] **Step 9: Commit**

```
feat(test-harness): scaffold plugin crate with protocol types
```

---

## Task 2: Mock Registry

**Files:**
- Create: `crates/tauri-plugin-test-harness/src/mock_registry.rs`
- Test: `crates/tauri-plugin-test-harness/tests/mock_registry_test.rs`
- Modify: `crates/tauri-plugin-test-harness/src/lib.rs`

- [ ] **Step 1: Write failing tests for mock registry**

```rust
// tests/mock_registry_test.rs
use tauri_plugin_test_harness::mock_registry::MockRegistry;

#[test]
fn test_register_and_get_mock() {
    let registry = MockRegistry::new();
    let response = serde_json::json!({"title": "Mock Book"});

    registry.register("get_book_data", response.clone());

    let mock = registry.get("get_book_data");
    assert!(mock.is_some());
    assert_eq!(mock.unwrap(), response);
}

#[test]
fn test_get_nonexistent_mock_returns_none() {
    let registry = MockRegistry::new();
    assert!(registry.get("no_such_command").is_none());
}

#[test]
fn test_clear_removes_all_mocks() {
    let registry = MockRegistry::new();
    registry.register("cmd_a", serde_json::json!("a"));
    registry.register("cmd_b", serde_json::json!("b"));

    registry.clear();

    assert!(registry.get("cmd_a").is_none());
    assert!(registry.get("cmd_b").is_none());
}

#[test]
fn test_register_overwrites_existing_mock() {
    let registry = MockRegistry::new();
    registry.register("cmd", serde_json::json!("first"));
    registry.register("cmd", serde_json::json!("second"));

    assert_eq!(registry.get("cmd").unwrap(), serde_json::json!("second"));
}

#[test]
fn test_remove_single_mock() {
    let registry = MockRegistry::new();
    registry.register("cmd_a", serde_json::json!("a"));
    registry.register("cmd_b", serde_json::json!("b"));

    registry.remove("cmd_a");

    assert!(registry.get("cmd_a").is_none());
    assert!(registry.get("cmd_b").is_some());
}

#[test]
fn test_has_mock() {
    let registry = MockRegistry::new();
    assert!(!registry.has("cmd"));

    registry.register("cmd", serde_json::json!(null));
    assert!(registry.has("cmd"));
}

#[test]
fn test_list_mocked_commands() {
    let registry = MockRegistry::new();
    registry.register("cmd_b", serde_json::json!("b"));
    registry.register("cmd_a", serde_json::json!("a"));

    let mut commands = registry.list();
    commands.sort();
    assert_eq!(commands, vec!["cmd_a", "cmd_b"]);
}

#[test]
fn test_registry_is_thread_safe() {
    use std::sync::Arc;
    use std::thread;

    let registry = Arc::new(MockRegistry::new());
    let mut handles = vec![];

    for i in 0..10 {
        let reg = Arc::clone(&registry);
        handles.push(thread::spawn(move || {
            let name = format!("cmd_{}", i);
            reg.register(&name, serde_json::json!(i));
        }));
    }

    for handle in handles {
        handle.join().unwrap();
    }

    assert_eq!(registry.list().len(), 10);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd crates/tauri-plugin-test-harness && cargo test --test mock_registry_test`
Expected: Compilation failure, `mock_registry` module does not exist.

- [ ] **Step 3: Implement mock_registry.rs**

```rust
use std::collections::HashMap;
use std::sync::RwLock;

/// Thread-safe registry for storing command mock responses.
/// When a command is mocked, the interceptor returns the stored response
/// instead of calling the real Tauri command handler.
pub struct MockRegistry {
    mocks: RwLock<HashMap<String, serde_json::Value>>,
}

impl MockRegistry {
    pub fn new() -> Self {
        Self {
            mocks: RwLock::new(HashMap::new()),
        }
    }

    pub fn register(&self, command: &str, response: serde_json::Value) {
        self.mocks
            .write()
            .expect("MockRegistry lock poisoned")
            .insert(command.to_string(), response);
    }

    pub fn get(&self, command: &str) -> Option<serde_json::Value> {
        self.mocks
            .read()
            .expect("MockRegistry lock poisoned")
            .get(command)
            .cloned()
    }

    pub fn has(&self, command: &str) -> bool {
        self.mocks
            .read()
            .expect("MockRegistry lock poisoned")
            .contains_key(command)
    }

    pub fn remove(&self, command: &str) {
        self.mocks
            .write()
            .expect("MockRegistry lock poisoned")
            .remove(command);
    }

    pub fn clear(&self) {
        self.mocks
            .write()
            .expect("MockRegistry lock poisoned")
            .clear();
    }

    pub fn list(&self) -> Vec<String> {
        self.mocks
            .read()
            .expect("MockRegistry lock poisoned")
            .keys()
            .cloned()
            .collect()
    }
}
```

- [ ] **Step 4: Add module to lib.rs**

```rust
pub mod protocol;
pub mod error;
pub mod mock_registry;

pub use error::{Error, Result};
pub use protocol::*;
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd crates/tauri-plugin-test-harness && cargo test --test mock_registry_test`
Expected: All 8 tests pass.

- [ ] **Step 6: Commit**

```
feat(test-harness): add thread-safe mock registry
```

---

## Task 3: Helper Registry

**Files:**
- Create: `crates/tauri-plugin-test-harness/src/helper_registry.rs`
- Test: `crates/tauri-plugin-test-harness/tests/helper_registry_test.rs`
- Modify: `crates/tauri-plugin-test-harness/src/lib.rs`

- [ ] **Step 1: Write failing tests for helper registry**

```rust
// tests/helper_registry_test.rs
use tauri_plugin_test_harness::helper_registry::HelperRegistry;
use serde_json::json;

#[test]
fn test_register_and_call_helper() {
    let registry = HelperRegistry::new();
    registry.register("seedDatabase", |args| {
        let count = args["count"].as_u64().unwrap_or(0);
        Ok(json!({"seeded": count}))
    });

    let result = registry.call("seedDatabase", json!({"count": 5}));
    assert!(result.is_ok());
    assert_eq!(result.unwrap(), json!({"seeded": 5}));
}

#[test]
fn test_call_nonexistent_helper_returns_error() {
    let registry = HelperRegistry::new();
    let result = registry.call("noSuchHelper", json!(null));
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("not found"));
}

#[test]
fn test_helper_that_returns_error() {
    let registry = HelperRegistry::new();
    registry.register("failingHelper", |_args| {
        Err("something went wrong".to_string())
    });

    let result = registry.call("failingHelper", json!(null));
    assert!(result.is_err());
    assert!(result
        .unwrap_err()
        .to_string()
        .contains("something went wrong"));
}

#[test]
fn test_list_helpers() {
    let registry = HelperRegistry::new();
    registry.register("helperA", |_| Ok(json!(null)));
    registry.register("helperB", |_| Ok(json!(null)));

    let mut helpers = registry.list();
    helpers.sort();
    assert_eq!(helpers, vec!["helperA", "helperB"]);
}

#[test]
fn test_has_helper() {
    let registry = HelperRegistry::new();
    assert!(!registry.has("myHelper"));

    registry.register("myHelper", |_| Ok(json!(null)));
    assert!(registry.has("myHelper"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd crates/tauri-plugin-test-harness && cargo test --test helper_registry_test`
Expected: Compilation failure, `helper_registry` module does not exist.

- [ ] **Step 3: Implement helper_registry.rs**

```rust
use std::collections::HashMap;
use std::sync::RwLock;
use crate::error::Error;

type HelperFn = Box<
    dyn Fn(serde_json::Value) -> std::result::Result<serde_json::Value, String>
        + Send
        + Sync,
>;

/// Registry for user-defined Rust helper functions.
/// App developers register helpers (e.g., seedDatabase, resetDatabase) that
/// test code can invoke via `cy.rustHelper(name, args)`.
pub struct HelperRegistry {
    helpers: RwLock<HashMap<String, HelperFn>>,
}

impl HelperRegistry {
    pub fn new() -> Self {
        Self {
            helpers: RwLock::new(HashMap::new()),
        }
    }

    pub fn register<F>(&self, name: &str, f: F)
    where
        F: Fn(serde_json::Value) -> std::result::Result<serde_json::Value, String>
            + Send
            + Sync
            + 'static,
    {
        self.helpers
            .write()
            .expect("HelperRegistry lock poisoned")
            .insert(name.to_string(), Box::new(f));
    }

    pub fn call(
        &self,
        name: &str,
        args: serde_json::Value,
    ) -> crate::Result<serde_json::Value> {
        let helpers = self.helpers.read().expect("HelperRegistry lock poisoned");
        let helper = helpers
            .get(name)
            .ok_or_else(|| Error::HelperNotFound(name.to_string()))?;
        helper(args).map_err(Error::HelperFailed)
    }

    pub fn has(&self, name: &str) -> bool {
        self.helpers
            .read()
            .expect("HelperRegistry lock poisoned")
            .contains_key(name)
    }

    pub fn list(&self) -> Vec<String> {
        self.helpers
            .read()
            .expect("HelperRegistry lock poisoned")
            .keys()
            .cloned()
            .collect()
    }
}
```

- [ ] **Step 4: Add module to lib.rs**

```rust
pub mod protocol;
pub mod error;
pub mod mock_registry;
pub mod helper_registry;

pub use error::{Error, Result};
pub use protocol::*;
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd crates/tauri-plugin-test-harness && cargo test --test helper_registry_test`
Expected: All 5 tests pass.

- [ ] **Step 6: Commit**

```
feat(test-harness): add helper registry for user-defined Rust test helpers
```

---

## Task 4: WebSocket Control Channel

**Files:**
- Create: `crates/tauri-plugin-test-harness/src/websocket.rs`
- Test: `crates/tauri-plugin-test-harness/tests/websocket_test.rs`
- Modify: `crates/tauri-plugin-test-harness/src/lib.rs`

- [ ] **Step 1: Write failing tests for WebSocket server**

```rust
// tests/websocket_test.rs
use tokio::time::{timeout, Duration};
use tokio_tungstenite::connect_async;
use futures_util::{SinkExt, StreamExt};
use tungstenite::protocol::Message;
use tauri_plugin_test_harness::protocol::ControlMessage;
use tauri_plugin_test_harness::websocket::ControlChannel;

#[tokio::test]
async fn test_server_starts_and_accepts_connection() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();

    let url = format!("ws://127.0.0.1:{}", port);
    let result = timeout(Duration::from_secs(2), connect_async(&url)).await;

    assert!(result.is_ok(), "should connect within 2 seconds");
    assert!(result.unwrap().is_ok(), "WebSocket handshake should succeed");

    channel.shutdown().await;
}

#[tokio::test]
async fn test_send_message_to_connected_client() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();

    let url = format!("ws://127.0.0.1:{}", port);
    let (ws_stream, _) = connect_async(&url).await.unwrap();
    let (_write, mut read) = ws_stream.split();

    // Wait for client to register
    tokio::time::sleep(Duration::from_millis(50)).await;

    let msg = ControlMessage::Ipc {
        data: tauri_plugin_test_harness::protocol::IpcLogEntry {
            command: "test_cmd".to_string(),
            args: serde_json::json!(null),
            response: None,
            mocked: false,
            duration_ms: 10,
            timestamp_ms: 1000,
        },
    };
    channel.broadcast(msg).await;

    let received = timeout(Duration::from_secs(2), read.next()).await;
    assert!(received.is_ok(), "should receive message within 2 seconds");
    let text = received.unwrap().unwrap().unwrap().into_text().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(parsed["type"], "ipc");
    assert_eq!(parsed["data"]["command"], "test_cmd");

    channel.shutdown().await;
}

#[tokio::test]
async fn test_receive_message_from_client() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();

    let url = format!("ws://127.0.0.1:{}", port);
    let (ws_stream, _) = connect_async(&url).await.unwrap();
    let (mut write, _read) = ws_stream.split();

    let exec_msg = serde_json::json!({
        "type": "exec",
        "script": "cy.get('.btn').click()",
        "test_id": "test-1"
    });
    write
        .send(Message::Text(exec_msg.to_string()))
        .await
        .unwrap();

    let received = timeout(Duration::from_secs(2), channel.recv()).await;
    assert!(received.is_ok(), "should receive message within 2 seconds");
    let msg = received.unwrap().unwrap();
    match msg {
        ControlMessage::Exec { script, test_id } => {
            assert_eq!(script, "cy.get('.btn').click()");
            assert_eq!(test_id, "test-1");
        }
        _ => panic!("expected Exec message"),
    }

    channel.shutdown().await;
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd crates/tauri-plugin-test-harness && cargo test --test websocket_test`
Expected: Compilation failure, `websocket` module does not exist.

- [ ] **Step 3: Implement websocket.rs**

```rust
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::{broadcast, mpsc, Mutex};
use tokio_tungstenite::accept_async;
use futures_util::{SinkExt, StreamExt};
use tungstenite::protocol::Message;
use log::{info, error, debug};

use crate::protocol::ControlMessage;

/// WebSocket-based control channel for communication between
/// the test runner and the app-under-test.
pub struct ControlChannel {
    /// Send messages to all connected clients (runner to app broadcast).
    outbound_tx: broadcast::Sender<String>,
    /// Receive messages from clients (app to runner).
    inbound_rx: Arc<Mutex<mpsc::Receiver<ControlMessage>>>,
    inbound_tx: mpsc::Sender<ControlMessage>,
    /// Signal to shut down the server.
    shutdown_tx: broadcast::Sender<()>,
}

impl ControlChannel {
    pub fn new() -> Self {
        let (outbound_tx, _) = broadcast::channel(256);
        let (inbound_tx, inbound_rx) = mpsc::channel(256);
        let (shutdown_tx, _) = broadcast::channel(1);

        Self {
            outbound_tx,
            inbound_rx: Arc::new(Mutex::new(inbound_rx)),
            inbound_tx,
            shutdown_tx,
        }
    }

    /// Start the WebSocket server. Binds to the given address.
    /// Use "127.0.0.1:0" to let the OS pick a free port.
    /// Returns the actual port the server is listening on.
    pub async fn start(
        &self,
        addr: &str,
    ) -> std::result::Result<u16, crate::error::Error> {
        let listener = TcpListener::bind(addr)
            .await
            .map_err(|e| crate::error::Error::WebSocket(e.to_string()))?;

        let port = listener
            .local_addr()
            .map_err(|e| crate::error::Error::WebSocket(e.to_string()))?
            .port();

        info!(
            "Test harness WebSocket server listening on 127.0.0.1:{}",
            port
        );

        let outbound_tx = self.outbound_tx.clone();
        let inbound_tx = self.inbound_tx.clone();
        let mut shutdown_rx = self.shutdown_tx.subscribe();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    accept_result = listener.accept() => {
                        match accept_result {
                            Ok((stream, peer_addr)) => {
                                debug!("New connection from {}", peer_addr);
                                let outbound_rx = outbound_tx.subscribe();
                                let inbound_tx = inbound_tx.clone();
                                tokio::spawn(handle_connection(
                                    stream,
                                    outbound_rx,
                                    inbound_tx,
                                ));
                            }
                            Err(e) => {
                                error!("Accept failed: {}", e);
                            }
                        }
                    }
                    _ = shutdown_rx.recv() => {
                        info!("WebSocket server shutting down");
                        break;
                    }
                }
            }
        });

        Ok(port)
    }

    /// Broadcast a message to all connected clients.
    pub async fn broadcast(&self, msg: ControlMessage) {
        let json = match serde_json::to_string(&msg) {
            Ok(j) => j,
            Err(e) => {
                error!("Failed to serialize message: {}", e);
                return;
            }
        };
        // Ignore send error (no receivers connected)
        let _ = self.outbound_tx.send(json);
    }

    /// Receive the next message from any connected client.
    pub async fn recv(&self) -> Option<ControlMessage> {
        self.inbound_rx.lock().await.recv().await
    }

    /// Shut down the WebSocket server.
    pub async fn shutdown(&self) {
        let _ = self.shutdown_tx.send(());
    }
}

async fn handle_connection(
    stream: tokio::net::TcpStream,
    mut outbound_rx: broadcast::Receiver<String>,
    inbound_tx: mpsc::Sender<ControlMessage>,
) {
    let ws_stream = match accept_async(stream).await {
        Ok(ws) => ws,
        Err(e) => {
            error!("WebSocket handshake failed: {}", e);
            return;
        }
    };

    let (mut ws_write, mut ws_read) = ws_stream.split();

    loop {
        tokio::select! {
            // Forward outbound messages to this client
            outbound = outbound_rx.recv() => {
                match outbound {
                    Ok(json) => {
                        if ws_write.send(Message::Text(json)).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        debug!("Client lagged, skipped {} messages", n);
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            // Forward inbound messages from this client
            inbound = ws_read.next() => {
                match inbound {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<ControlMessage>(&text) {
                            Ok(msg) => {
                                if inbound_tx.send(msg).await.is_err() {
                                    break;
                                }
                            }
                            Err(e) => {
                                error!("Failed to parse message: {}", e);
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Err(e)) => {
                        error!("WebSocket read error: {}", e);
                        break;
                    }
                    _ => {} // Ignore ping/pong/binary
                }
            }
        }
    }
}
```

- [ ] **Step 4: Add module to lib.rs**

```rust
pub mod protocol;
pub mod error;
pub mod mock_registry;
pub mod helper_registry;
pub mod websocket;

pub use error::{Error, Result};
pub use protocol::*;
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd crates/tauri-plugin-test-harness && cargo test --test websocket_test`
Expected: All 3 tests pass.

- [ ] **Step 6: Commit**

```
feat(test-harness): add WebSocket control channel server
```

---

## Task 5: JS Init Script Generation

**Files:**
- Create: `crates/tauri-plugin-test-harness/src/injector.rs`
- Modify: `crates/tauri-plugin-test-harness/src/lib.rs`

- [ ] **Step 1: Implement injector.rs**

This generates the JavaScript that `js_init_script` injects into the webview. It runs before any app code and sets up the `__tauriCypress` global, IPC monkey-patching, and WebSocket client.

```rust
/// Generates the JavaScript init script injected into the webview before
/// app code loads. Sets up `__tauriCypress` global, monkey-patches
/// `invoke()` for IPC interception, and connects to the plugin's
/// WebSocket server.
pub fn generate_init_script(ws_port: u16) -> String {
    format!(
        r#"
(function() {{
  var mocks = new Map();
  var interceptors = new Map();
  var ipcLog = [];
  var snapshotHistory = [];

  function mockCommand(name, response) {{
    mocks.set(name, response);
  }}

  function interceptCommand(name, handler) {{
    interceptors.set(name, handler);
  }}

  function removeMock(name) {{
    mocks.delete(name);
  }}

  function clearMocks() {{
    mocks.clear();
    interceptors.clear();
  }}

  function takeSnapshot(label) {{
    var snapshot = {{
      label: label,
      html: document.documentElement.outerHTML,
      url: window.location.href,
      timestamp_ms: Date.now()
    }};
    snapshotHistory.push(snapshot);
    if (ws && ws.readyState === WebSocket.OPEN) {{
      ws.send(JSON.stringify({{ type: "snapshot", data: snapshot }}));
    }}
    return snapshot;
  }}

  var originalInvoke = null;

  function patchInvoke() {{
    if (!window.__TAURI_INTERNALS__ || !window.__TAURI_INTERNALS__.invoke) {{
      setTimeout(patchInvoke, 1);
      return;
    }}
    if (originalInvoke) return;

    originalInvoke = window.__TAURI_INTERNALS__.invoke.bind(
      window.__TAURI_INTERNALS__
    );

    window.__TAURI_INTERNALS__.invoke = async function(cmd, args, options) {{
      var startTime = Date.now();
      var response;
      var mocked = false;

      if (mocks.has(cmd)) {{
        response = mocks.get(cmd);
        mocked = true;
      }} else if (interceptors.has(cmd)) {{
        try {{
          response = await interceptors.get(cmd)(args);
          mocked = true;
        }} catch (e) {{
          var entry = {{
            command: cmd,
            args: args || null,
            response: null,
            mocked: true,
            duration_ms: Date.now() - startTime,
            timestamp_ms: startTime
          }};
          ipcLog.push(entry);
          sendIpcLog(entry);
          throw e;
        }}
      }} else {{
        response = await originalInvoke(cmd, args, options);
      }}

      var entry = {{
        command: cmd,
        args: args || null,
        response: response,
        mocked: mocked,
        duration_ms: Date.now() - startTime,
        timestamp_ms: startTime
      }};
      ipcLog.push(entry);
      sendIpcLog(entry);

      return response;
    }};
  }}

  var ws = null;
  var wsReconnectAttempts = 0;
  var WS_MAX_RECONNECT = 3;

  function connectWebSocket() {{
    ws = new WebSocket("ws://127.0.0.1:{port}");

    ws.onopen = function() {{
      wsReconnectAttempts = 0;
    }};

    ws.onmessage = function(event) {{
      try {{
        var msg = JSON.parse(event.data);
        if (msg.type === "exec") {{
          executeTestScript(msg.script, msg.test_id);
        }}
      }} catch (e) {{
        console.error("[tauri-cypress] Failed to parse message:", e);
      }}
    }};

    ws.onclose = function() {{
      if (wsReconnectAttempts < WS_MAX_RECONNECT) {{
        wsReconnectAttempts++;
        setTimeout(connectWebSocket, 500);
      }}
    }};

    ws.onerror = function() {{}};
  }}

  function sendIpcLog(entry) {{
    if (ws && ws.readyState === WebSocket.OPEN) {{
      ws.send(JSON.stringify({{ type: "ipc", data: entry }}));
    }}
  }}

  async function executeTestScript(script, testId) {{
    var startTime = Date.now();
    try {{
      var fn = new Function("__tauriCypress", script);
      await fn(window.__tauriCypress);
      if (ws && ws.readyState === WebSocket.OPEN) {{
        ws.send(JSON.stringify({{
          type: "result",
          data: {{
            test_id: testId,
            status: "passed",
            assertions: [],
            error: null,
            duration_ms: Date.now() - startTime
          }}
        }}));
      }}
    }} catch (e) {{
      if (ws && ws.readyState === WebSocket.OPEN) {{
        ws.send(JSON.stringify({{
          type: "result",
          data: {{
            test_id: testId,
            status: "failed",
            assertions: [],
            error: e.message || String(e),
            duration_ms: Date.now() - startTime
          }}
        }}));
      }}
    }}
  }}

  window.__tauriCypress = {{
    bridge: {{
      mockCommand: mockCommand,
      interceptCommand: interceptCommand,
      removeMock: removeMock,
      clearMocks: clearMocks,
      getState: async function(key) {{
        if (!originalInvoke) return null;
        return originalInvoke(
          "plugin:test-harness|get_app_state",
          {{ key: key }}
        );
      }},
      callHelper: async function(name, args) {{
        if (!originalInvoke) return null;
        return originalInvoke(
          "plugin:test-harness|call_helper",
          {{ name: name, args: args || null }}
        );
      }}
    }},
    ipc: {{
      intercept: interceptCommand,
      passthrough: function(name) {{
        interceptors.delete(name);
        mocks.delete(name);
      }},
      get log() {{ return ipcLog.slice(); }}
    }},
    snapshot: {{
      take: takeSnapshot,
      get history() {{ return snapshotHistory.slice(); }}
    }},
    __exec: executeTestScript
  }};

  patchInvoke();
  connectWebSocket();
}})();
"#,
        port = ws_port
    )
}
```

- [ ] **Step 2: Add module to lib.rs**

```rust
pub mod protocol;
pub mod error;
pub mod mock_registry;
pub mod helper_registry;
pub mod websocket;
pub mod injector;

pub use error::{Error, Result};
pub use protocol::*;
```

- [ ] **Step 3: Verify it compiles**

Run: `cd crates/tauri-plugin-test-harness && cargo check`
Expected: Compiles successfully.

- [ ] **Step 4: Commit**

```
feat(test-harness): add JS init script generation for webview injection
```

---

## Task 6: Tauri Commands

**Files:**
- Create: `crates/tauri-plugin-test-harness/src/commands.rs`
- Modify: `crates/tauri-plugin-test-harness/src/lib.rs`

- [ ] **Step 1: Implement commands.rs**

```rust
use tauri::{command, AppHandle, Runtime, Webview, Manager};
use crate::mock_registry::MockRegistry;
use crate::helper_registry::HelperRegistry;

#[command]
pub async fn register_mock<R: Runtime>(
    app: AppHandle<R>,
    command_name: String,
    response: serde_json::Value,
) -> std::result::Result<(), String> {
    let registry = app.state::<MockRegistry>();
    registry.register(&command_name, response);
    Ok(())
}

#[command]
pub async fn clear_mocks<R: Runtime>(
    app: AppHandle<R>,
) -> std::result::Result<(), String> {
    let registry = app.state::<MockRegistry>();
    registry.clear();
    Ok(())
}

#[command]
pub async fn call_helper<R: Runtime>(
    app: AppHandle<R>,
    name: String,
    args: Option<serde_json::Value>,
) -> std::result::Result<serde_json::Value, String> {
    let registry = app.state::<HelperRegistry>();
    registry
        .call(&name, args.unwrap_or(serde_json::Value::Null))
        .map_err(|e| e.to_string())
}

#[command]
pub async fn get_app_state<R: Runtime>(
    app: AppHandle<R>,
    key: String,
) -> std::result::Result<serde_json::Value, String> {
    match key.as_str() {
        "mocks" => {
            let registry = app.state::<MockRegistry>();
            Ok(serde_json::json!(registry.list()))
        }
        "helpers" => {
            let registry = app.state::<HelperRegistry>();
            Ok(serde_json::json!(registry.list()))
        }
        _ => Err(format!("Unknown state key: {}", key)),
    }
}

#[command]
pub async fn resize_window<R: Runtime>(
    webview: Webview<R>,
    width: f64,
    height: f64,
) -> std::result::Result<(), String> {
    let window = webview.window();
    window
        .set_size(tauri::Size::Logical(tauri::LogicalSize {
            width,
            height,
        }))
        .map_err(|e| e.to_string())
}

#[command]
pub async fn minimize_window<R: Runtime>(
    webview: Webview<R>,
) -> std::result::Result<(), String> {
    webview.window().minimize().map_err(|e| e.to_string())
}

#[command]
pub async fn maximize_window<R: Runtime>(
    webview: Webview<R>,
) -> std::result::Result<(), String> {
    webview.window().maximize().map_err(|e| e.to_string())
}

#[command]
pub async fn fullscreen_window<R: Runtime>(
    webview: Webview<R>,
    fullscreen: bool,
) -> std::result::Result<(), String> {
    webview
        .window()
        .set_fullscreen(fullscreen)
        .map_err(|e| e.to_string())
}

#[command]
pub async fn get_window_position<R: Runtime>(
    webview: Webview<R>,
) -> std::result::Result<serde_json::Value, String> {
    let pos = webview
        .window()
        .outer_position()
        .map_err(|e| e.to_string())?;
    Ok(serde_json::json!({"x": pos.x, "y": pos.y}))
}

#[command]
pub async fn get_window_size<R: Runtime>(
    webview: Webview<R>,
) -> std::result::Result<serde_json::Value, String> {
    let size = webview
        .window()
        .outer_size()
        .map_err(|e| e.to_string())?;
    Ok(serde_json::json!({
        "width": size.width,
        "height": size.height,
    }))
}
```

- [ ] **Step 2: Add module to lib.rs**

```rust
pub mod protocol;
pub mod error;
pub mod mock_registry;
pub mod helper_registry;
pub mod websocket;
pub mod injector;
pub mod commands;

pub use error::{Error, Result};
pub use protocol::*;
```

- [ ] **Step 3: Verify it compiles**

Run: `cd crates/tauri-plugin-test-harness && cargo check`
Expected: Compiles successfully.

- [ ] **Step 4: Commit**

```
feat(test-harness): add Tauri commands for mocking, helpers, and window control
```

---

## Task 7: IPC Interceptor (Rust Level)

**Files:**
- Create: `crates/tauri-plugin-test-harness/src/interceptor.rs`
- Modify: `crates/tauri-plugin-test-harness/src/lib.rs`

- [ ] **Step 1: Implement interceptor.rs**

```rust
use std::sync::Arc;
use tauri::{Runtime, ipc::Invoke};
use crate::mock_registry::MockRegistry;

/// Creates an invoke handler that checks the mock registry before passing
/// commands through to the app's real handlers.
///
/// Returns `true` if the command was intercepted (mocked), `false` to
/// pass through.
pub fn create_invoke_handler<R: Runtime>(
    mock_registry: Arc<MockRegistry>,
) -> impl Fn(Invoke<R>) -> bool + Send + Sync + 'static {
    move |invoke: Invoke<R>| {
        let cmd = invoke.message.command();

        // Don't intercept our own plugin commands
        if cmd.starts_with("plugin:test-harness|") {
            return false;
        }

        // Check if this command has a mock registered
        if let Some(response) = mock_registry.get(cmd) {
            log::debug!(
                "Intercepted command '{}' with mock response",
                cmd
            );
            invoke.resolver.resolve(response);
            return true;
        }

        // No mock, pass through to real handlers
        false
    }
}
```

Note: The Rust-level interceptor using `invoke_handler` on the plugin Builder
conflicts with `tauri::generate_handler!` (only the last `invoke_handler` call
is used). The actual interception strategy is:
- JS-level interception handles mocks via the monkey-patched `invoke()` (Task 5)
- Rust-level mocks are registered via the `register_mock` command (Task 6)
- The `interceptor.rs` module is provided for advanced use cases where the app
  developer wants to add custom Rust-level interception

This module is kept as a utility. The primary mock path is JS-level.

- [ ] **Step 2: Add module to lib.rs**

```rust
pub mod protocol;
pub mod error;
pub mod mock_registry;
pub mod helper_registry;
pub mod websocket;
pub mod injector;
pub mod commands;
pub mod interceptor;

pub use error::{Error, Result};
pub use protocol::*;
```

- [ ] **Step 3: Verify it compiles**

Run: `cd crates/tauri-plugin-test-harness && cargo check`
Expected: Compiles successfully.

- [ ] **Step 4: Commit**

```
feat(test-harness): add Rust-level IPC interceptor utility
```

---

## Task 8: Plugin Entry Point and Builder API

**Files:**
- Modify: `crates/tauri-plugin-test-harness/src/lib.rs`

- [ ] **Step 1: Implement the full lib.rs with Builder and init**

Replace the contents of lib.rs with:

```rust
pub mod protocol;
pub mod error;
pub mod mock_registry;
pub mod helper_registry;
pub mod websocket;
pub mod injector;
pub mod commands;
pub mod interceptor;

pub use error::{Error, Result};
pub use protocol::*;

use tauri::{plugin::TauriPlugin, Manager, Runtime};
use mock_registry::MockRegistry;
use helper_registry::HelperRegistry;
use websocket::ControlChannel;

/// Default WebSocket port for the control channel.
pub const DEFAULT_PORT: u16 = 9223;

type HelperFnBox = Box<
    dyn Fn(serde_json::Value) -> std::result::Result<serde_json::Value, String>
        + Send
        + Sync
        + 'static,
>;

/// Builder for configuring the test harness plugin.
///
/// # Example
///
/// ```rust,no_run
/// use tauri_plugin_test_harness::PluginBuilder;
/// use serde_json::Value;
///
/// let plugin = PluginBuilder::new()
///     .port(9223)
///     .helper("seedDatabase", |args: Value| {
///         Ok(serde_json::json!({"seeded": true}))
///     })
///     .helper("resetDatabase", |_args: Value| {
///         Ok(serde_json::json!(null))
///     })
///     .build::<tauri::Wry>();
/// ```
pub struct PluginBuilder {
    port: u16,
    helpers: Vec<(String, HelperFnBox)>,
}

impl PluginBuilder {
    pub fn new() -> Self {
        Self {
            port: DEFAULT_PORT,
            helpers: Vec::new(),
        }
    }

    /// Set the WebSocket port for the control channel. Defaults to 9223.
    pub fn port(mut self, port: u16) -> Self {
        self.port = port;
        self
    }

    /// Register a Rust helper function that test code can invoke via
    /// `cy.rustHelper(name, args)`.
    pub fn helper<F>(mut self, name: &str, f: F) -> Self
    where
        F: Fn(serde_json::Value)
                -> std::result::Result<serde_json::Value, String>
            + Send
            + Sync
            + 'static,
    {
        self.helpers.push((name.to_string(), Box::new(f)));
        self
    }

    /// Build the Tauri plugin.
    pub fn build<R: Runtime>(self) -> TauriPlugin<R> {
        let port = self.port;
        let helpers = self.helpers;
        let init_script = injector::generate_init_script(port);

        tauri::plugin::Builder::<R>::new("test-harness")
            .js_init_script(init_script)
            .setup(move |app, _api| {
                // Register mock registry as managed state
                app.manage(MockRegistry::new());

                // Register helper registry with user-defined helpers
                let helper_registry = HelperRegistry::new();
                for (name, f) in helpers {
                    helper_registry.register(&name, f);
                }
                app.manage(helper_registry);

                // Start WebSocket control channel
                let channel = ControlChannel::new();
                tauri::async_runtime::spawn(async move {
                    match channel
                        .start(&format!("127.0.0.1:{}", port))
                        .await
                    {
                        Ok(actual_port) => {
                            log::info!(
                                "Test harness control channel on port {}",
                                actual_port
                            );
                        }
                        Err(e) => {
                            log::error!(
                                "Failed to start test harness WebSocket: {}",
                                e
                            );
                        }
                    }
                });

                Ok(())
            })
            .invoke_handler(tauri::generate_handler![
                commands::register_mock,
                commands::clear_mocks,
                commands::call_helper,
                commands::get_app_state,
                commands::resize_window,
                commands::minimize_window,
                commands::maximize_window,
                commands::fullscreen_window,
                commands::get_window_position,
                commands::get_window_size,
            ])
            .build()
    }
}

impl Default for PluginBuilder {
    fn default() -> Self {
        Self::new()
    }
}

/// Create the plugin with default settings (no custom helpers, port 9223).
pub fn init<R: Runtime>() -> TauriPlugin<R> {
    PluginBuilder::new().build()
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd crates/tauri-plugin-test-harness && cargo check`
Expected: Compiles successfully.

- [ ] **Step 3: Commit**

```
feat(test-harness): add PluginBuilder API and plugin entry point
```

---

## Task 9: Example App Integration

**Files:**
- Create: `examples/basic-app/src-tauri/Cargo.toml`
- Create: `examples/basic-app/src-tauri/src/main.rs`
- Create: `examples/basic-app/src-tauri/src/lib.rs`
- Create: `examples/basic-app/src-tauri/tauri.conf.json`
- Create: `examples/basic-app/index.html`
- Create: `examples/basic-app/package.json`

- [ ] **Step 1: Create example Cargo.toml**

```toml
[package]
name = "basic-app"
version = "0.1.0"
edition = "2021"

[dependencies]
tauri = { version = "2", features = [] }
tauri-plugin-test-harness = { path = "../../crates/tauri-plugin-test-harness" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"

[features]
test-harness = []
```

- [ ] **Step 2: Create example lib.rs**

```rust
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct Greeting {
    pub message: String,
}

#[tauri::command]
pub fn greet(name: String) -> Greeting {
    Greeting {
        message: format!("Hello, {}!", name),
    }
}

pub fn run() {
    let mut builder = tauri::Builder::default();

    #[cfg(feature = "test-harness")]
    {
        builder = builder.plugin(
            tauri_plugin_test_harness::PluginBuilder::new()
                .port(9223)
                .helper("resetState", |_args| {
                    Ok(serde_json::json!({"reset": true}))
                })
                .build(),
        );
    }

    builder
        .invoke_handler(tauri::generate_handler![greet])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

- [ ] **Step 3: Create example main.rs**

```rust
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    basic_app::run();
}
```

- [ ] **Step 4: Create example index.html**

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Test Harness Example</title>
</head>
<body>
  <h1>Test Harness Example App</h1>
  <input id="name-input" type="text" placeholder="Enter name" />
  <button id="greet-btn">Greet</button>
  <p id="greeting"></p>
  <script>
    document.getElementById('greet-btn').addEventListener('click', async function() {
      var invoke = window.__TAURI_INTERNALS__.invoke;
      var name = document.getElementById('name-input').value;
      var result = await invoke('greet', { name: name });
      document.getElementById('greeting').textContent = result.message;
    });
  </script>
</body>
</html>
```

- [ ] **Step 5: Create minimal tauri.conf.json**

```json
{
  "productName": "basic-app",
  "identifier": "com.tauri-cypress.example",
  "build": {
    "frontendDist": "../"
  },
  "app": {
    "windows": [
      {
        "title": "Test Harness Example",
        "width": 800,
        "height": 600
      }
    ],
    "withGlobalTauri": true
  }
}
```

- [ ] **Step 6: Create example package.json**

```json
{
  "name": "basic-app",
  "version": "0.1.0",
  "private": true
}
```

- [ ] **Step 7: Verify the example compiles**

Run: `cd examples/basic-app/src-tauri && cargo check`
Expected: Compiles successfully.

Run: `cd examples/basic-app/src-tauri && cargo check --features test-harness`
Expected: Compiles successfully with test harness.

- [ ] **Step 8: Commit**

```
feat(test-harness): add example app demonstrating plugin integration
```

---

## Task 10: Run All Tests and Final Verification

- [ ] **Step 1: Run the full test suite**

Run: `cd crates/tauri-plugin-test-harness && cargo test`
Expected: All tests pass (protocol: 5, mock_registry: 8, helper_registry: 5, websocket: 3 = 21 total).

- [ ] **Step 2: Run clippy**

Run: `cd crates/tauri-plugin-test-harness && cargo clippy -- -D warnings`
Expected: No warnings.

- [ ] **Step 3: Verify example compiles with and without the feature flag**

Run: `cd examples/basic-app/src-tauri && cargo check`
Expected: Compiles without test harness code.

Run: `cd examples/basic-app/src-tauri && cargo check --features test-harness`
Expected: Compiles with test harness code.

- [ ] **Step 4: Commit if any fixups were needed**

```
chore(test-harness): fix clippy warnings and finalize v0.1
```
