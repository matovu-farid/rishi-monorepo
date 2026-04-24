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
    /// Sent by the webview when the injected JS connects to the WebSocket server.
    Ready,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screenshot: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command_name: Option<String>,
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
