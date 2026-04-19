use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::time::{timeout, Duration};
use tungstenite::protocol::Message;
use tokio_tungstenite::connect_async;

use tauri_plugin_test_harness::injector::generate_init_script;
use tauri_plugin_test_harness::mock_registry::MockRegistry;
use tauri_plugin_test_harness::protocol::{
    AssertionResult, ControlMessage, DomSnapshot, IpcLogEntry, TestResult, TestStatus,
};
use tauri_plugin_test_harness::websocket::ControlChannel;

// ---------------------------------------------------------------------------
// (a) WebSocket relay test — two clients, exec relay
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_exec_message_relayed_to_second_client() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    // Connect client 1 (the "runner" that sends exec)
    let (ws1, _) = connect_async(&url).await.unwrap();
    let (mut write1, _read1) = ws1.split();

    // Connect client 2 (the "webview" that should receive the relayed exec)
    let (ws2, _) = connect_async(&url).await.unwrap();
    let (_write2, mut read2) = ws2.split();

    // Small delay to let both connections register with the server
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Client 1 sends an exec message
    let exec_json = json!({
        "type": "exec",
        "script": "cy.get('.btn').click()",
        "test_id": "relay-test-1"
    });
    write1
        .send(Message::Text(exec_json.to_string()))
        .await
        .unwrap();

    // Client 2 should receive the relayed exec message
    let received = timeout(Duration::from_secs(3), read2.next()).await;
    assert!(received.is_ok(), "client 2 should receive a message within 3 seconds");
    let msg = received.unwrap().unwrap().unwrap();
    let text = msg.into_text().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();

    assert_eq!(parsed["type"], "exec");
    assert_eq!(parsed["script"], "cy.get('.btn').click()");
    assert_eq!(parsed["test_id"], "relay-test-1");

    channel.shutdown().await;
}

#[tokio::test]
async fn test_non_exec_messages_not_relayed_to_other_clients() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    // Connect client 1 (sends a result message)
    let (ws1, _) = connect_async(&url).await.unwrap();
    let (mut write1, _read1) = ws1.split();

    // Connect client 2 (should NOT receive result messages via relay)
    let (ws2, _) = connect_async(&url).await.unwrap();
    let (_write2, mut read2) = ws2.split();

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Client 1 sends a result message (not exec — should NOT be relayed)
    let result_json = json!({
        "type": "result",
        "data": {
            "test_id": "t-1",
            "status": "passed",
            "assertions": [],
            "error": null,
            "duration_ms": 10
        }
    });
    write1
        .send(Message::Text(result_json.to_string()))
        .await
        .unwrap();

    // Client 2 should NOT receive anything (timeout is expected)
    let received = timeout(Duration::from_millis(500), read2.next()).await;
    assert!(
        received.is_err(),
        "non-exec messages should not be relayed to other clients"
    );

    channel.shutdown().await;
}

// ---------------------------------------------------------------------------
// (b) Snapshot with optional fields
// ---------------------------------------------------------------------------

#[test]
fn test_snapshot_with_optional_fields_present() {
    let snapshot = DomSnapshot {
        label: "after-click".to_string(),
        html: "<div>hello</div>".to_string(),
        url: "http://localhost/page".to_string(),
        timestamp_ms: 5000,
        screenshot: Some("base64data".to_string()),
        command_name: Some("get('.btn')".to_string()),
    };

    let json_str = serde_json::to_string(&snapshot).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();

    assert_eq!(parsed["screenshot"], "base64data");
    assert_eq!(parsed["command_name"], "get('.btn')");
    assert_eq!(parsed["label"], "after-click");
}

#[test]
fn test_snapshot_with_optional_fields_none_omitted() {
    let snapshot = DomSnapshot {
        label: "initial".to_string(),
        html: "<html></html>".to_string(),
        url: "http://localhost".to_string(),
        timestamp_ms: 1000,
        screenshot: None,
        command_name: None,
    };

    let json_str = serde_json::to_string(&snapshot).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();

    // With skip_serializing_if = "Option::is_none", these keys should be absent
    assert!(
        parsed.get("screenshot").is_none(),
        "screenshot should be omitted when None"
    );
    assert!(
        parsed.get("command_name").is_none(),
        "command_name should be omitted when None"
    );

    // Required fields still present
    assert_eq!(parsed["label"], "initial");
    assert_eq!(parsed["html"], "<html></html>");
}

#[test]
fn test_snapshot_with_mixed_optional_fields() {
    let snapshot = DomSnapshot {
        label: "mid-test".to_string(),
        html: "<p>content</p>".to_string(),
        url: "http://localhost/test".to_string(),
        timestamp_ms: 2000,
        screenshot: Some("png-data".to_string()),
        command_name: None,
    };

    let json_str = serde_json::to_string(&snapshot).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();

    assert_eq!(parsed["screenshot"], "png-data");
    assert!(
        parsed.get("command_name").is_none(),
        "command_name should be omitted when None even if screenshot is present"
    );
}

// ---------------------------------------------------------------------------
// (c) Full message round-trip (serialize -> deserialize -> re-serialize)
// ---------------------------------------------------------------------------

#[test]
fn test_roundtrip_exec_message() {
    let msg = ControlMessage::Exec {
        script: "cy.visit('/')".to_string(),
        test_id: "rt-1".to_string(),
    };
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);

    // Also verify the inner values
    match deserialized {
        ControlMessage::Exec { script, test_id } => {
            assert_eq!(script, "cy.visit('/')");
            assert_eq!(test_id, "rt-1");
        }
        _ => panic!("expected Exec variant after round-trip"),
    }
}

#[test]
fn test_roundtrip_result_passed() {
    let msg = ControlMessage::Result {
        data: TestResult {
            test_id: "rt-2".to_string(),
            status: TestStatus::Passed,
            assertions: vec![AssertionResult {
                description: "button exists".to_string(),
                passed: true,
                expected: Some(json!(true)),
                actual: Some(json!(true)),
            }],
            error: None,
            duration_ms: 150,
        },
    };
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);
}

#[test]
fn test_roundtrip_result_failed() {
    let msg = ControlMessage::Result {
        data: TestResult {
            test_id: "rt-3".to_string(),
            status: TestStatus::Failed,
            assertions: vec![],
            error: Some("Element not found".to_string()),
            duration_ms: 300,
        },
    };
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);
}

#[test]
fn test_roundtrip_result_skipped() {
    let msg = ControlMessage::Result {
        data: TestResult {
            test_id: "rt-skip".to_string(),
            status: TestStatus::Skipped,
            assertions: vec![],
            error: None,
            duration_ms: 0,
        },
    };
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);
}

#[test]
fn test_roundtrip_snapshot_with_optional_fields() {
    let msg = ControlMessage::Snapshot {
        data: DomSnapshot {
            label: "step-1".to_string(),
            html: "<div>step</div>".to_string(),
            url: "http://localhost/step".to_string(),
            timestamp_ms: 3000,
            screenshot: Some("data:image/png;base64,abc123".to_string()),
            command_name: Some("click('.next')".to_string()),
        },
    };
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);
}

#[test]
fn test_roundtrip_snapshot_without_optional_fields() {
    let msg = ControlMessage::Snapshot {
        data: DomSnapshot {
            label: "bare".to_string(),
            html: "<p></p>".to_string(),
            url: "http://localhost".to_string(),
            timestamp_ms: 100,
            screenshot: None,
            command_name: None,
        },
    };
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);
}

#[test]
fn test_roundtrip_ipc_message() {
    let msg = ControlMessage::Ipc {
        data: IpcLogEntry {
            command: "save_settings".to_string(),
            args: json!({"theme": "dark"}),
            response: Some(json!({"ok": true})),
            mocked: true,
            duration_ms: 5,
            timestamp_ms: 9000,
        },
    };
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);
}

#[test]
fn test_roundtrip_ipc_with_null_response() {
    let msg = ControlMessage::Ipc {
        data: IpcLogEntry {
            command: "fire_and_forget".to_string(),
            args: json!(null),
            response: None,
            mocked: false,
            duration_ms: 1,
            timestamp_ms: 500,
        },
    };
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);
}

// ---------------------------------------------------------------------------
// (d) Injector script validity
// ---------------------------------------------------------------------------

#[test]
fn test_injector_contains_tauri_cypress_global() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("__tauriCypress"),
        "init script must set up the __tauriCypress global"
    );
}

#[test]
fn test_injector_contains_correct_websocket_url() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("ws://127.0.0.1:9223"),
        "init script must connect to ws://127.0.0.1:9223"
    );
}

#[test]
fn test_injector_uses_custom_port() {
    let script = generate_init_script(4567);
    assert!(
        script.contains("ws://127.0.0.1:4567"),
        "init script must use the provided port"
    );
    assert!(
        !script.contains("ws://127.0.0.1:9223"),
        "init script must not contain default port when custom port is used"
    );
}

#[test]
fn test_injector_contains_capture_screenshot_function() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("captureScreenshot"),
        "init script must define captureScreenshot function"
    );
}

#[test]
fn test_injector_contains_auto_snapshot_enabled() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("autoSnapshotEnabled"),
        "init script must reference autoSnapshotEnabled flag"
    );
}

#[test]
fn test_injector_has_balanced_braces() {
    let script = generate_init_script(9223);

    let open_braces = script.chars().filter(|&c| c == '{').count();
    let close_braces = script.chars().filter(|&c| c == '}').count();
    assert_eq!(
        open_braces, close_braces,
        "init script must have balanced curly braces (open={}, close={})",
        open_braces, close_braces
    );

    let open_parens = script.chars().filter(|&c| c == '(').count();
    let close_parens = script.chars().filter(|&c| c == ')').count();
    assert_eq!(
        open_parens, close_parens,
        "init script must have balanced parentheses (open={}, close={})",
        open_parens, close_parens
    );
}

#[test]
fn test_injector_contains_iife_wrapper() {
    let script = generate_init_script(9223);
    // Should be wrapped in an IIFE
    assert!(
        script.contains("(function()"),
        "init script must be wrapped in an IIFE"
    );
    assert!(
        script.contains("})();"),
        "init script IIFE must be self-invoking"
    );
}

#[test]
fn test_injector_contains_core_api_surface() {
    let script = generate_init_script(9223);

    // bridge API
    assert!(script.contains("mockCommand"), "must expose mockCommand");
    assert!(
        script.contains("interceptCommand"),
        "must expose interceptCommand"
    );
    assert!(script.contains("removeMock"), "must expose removeMock");
    assert!(script.contains("clearMocks"), "must expose clearMocks");
    assert!(script.contains("getState"), "must expose getState");
    assert!(script.contains("callHelper"), "must expose callHelper");

    // ipc API
    assert!(script.contains("ipcLog"), "must track ipcLog");
    assert!(script.contains("passthrough"), "must expose passthrough");

    // snapshot API
    assert!(script.contains("takeSnapshot"), "must expose takeSnapshot");
    assert!(
        script.contains("snapshotHistory"),
        "must track snapshotHistory"
    );
    assert!(
        script.contains("setAutoCapture"),
        "must expose setAutoCapture"
    );
}

// ---------------------------------------------------------------------------
// (e) Mock registry concurrent access
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_mock_registry_concurrent_access() {
    let registry = Arc::new(MockRegistry::new());

    let mut handles = vec![];

    for i in 0..10 {
        let reg = Arc::clone(&registry);
        handles.push(tokio::spawn(async move {
            let cmd = format!("concurrent_cmd_{}", i);
            reg.register(&cmd, json!({"task": i}));

            // Read back what we just wrote
            let val = reg.get(&cmd);
            assert!(val.is_some(), "task {} should be able to read its own mock", i);
            assert_eq!(val.unwrap()["task"], i);

            // Also exercise has/list while other tasks are writing
            assert!(reg.has(&cmd));
            let _list = reg.list();
        }));
    }

    for handle in handles {
        handle.await.expect("task should not panic");
    }

    // All 10 mocks should be present
    assert_eq!(registry.list().len(), 10);

    // Now clear concurrently while others are reading
    let mut handles = vec![];
    for _ in 0..5 {
        let reg = Arc::clone(&registry);
        handles.push(tokio::spawn(async move {
            let _list = reg.list();
            let _get = reg.get("concurrent_cmd_0");
        }));
    }
    // One task clears
    let reg = Arc::clone(&registry);
    handles.push(tokio::spawn(async move {
        reg.clear();
    }));

    for handle in handles {
        handle.await.expect("concurrent clear should not panic");
    }

    // After clear, registry should be empty
    assert_eq!(registry.list().len(), 0);
}

// ---------------------------------------------------------------------------
// (e2) Mock registry + WebSocket together
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_mock_registry_and_websocket_combined() {
    // Set up mock registry with a mocked command
    let registry = MockRegistry::new();
    registry.register("get_user", json!({"id": 1, "name": "Test User"}));

    // Start a WebSocket channel
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    // Connect a client
    let (ws, _) = connect_async(&url).await.unwrap();
    let (mut write, mut read) = ws.split();

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Client sends an IPC log entry indicating a mocked command was used
    let ipc_msg = json!({
        "type": "ipc",
        "data": {
            "command": "get_user",
            "args": null,
            "response": registry.get("get_user"),
            "mocked": true,
            "duration_ms": 0,
            "timestamp_ms": 1000
        }
    });
    write
        .send(Message::Text(ipc_msg.to_string()))
        .await
        .unwrap();

    // The server should parse it as a ControlMessage::Ipc and place it inbound
    let received = timeout(Duration::from_secs(3), channel.recv()).await;
    assert!(received.is_ok(), "server should receive the IPC message");
    let msg = received.unwrap().unwrap();

    match msg {
        ControlMessage::Ipc { data } => {
            assert_eq!(data.command, "get_user");
            assert!(data.mocked);
            assert_eq!(
                data.response,
                Some(json!({"id": 1, "name": "Test User"}))
            );
        }
        _ => panic!("expected Ipc message"),
    }

    // Now broadcast a snapshot back to the client
    let snapshot_msg = ControlMessage::Snapshot {
        data: DomSnapshot {
            label: "after:get_user".to_string(),
            html: "<div>User: Test User</div>".to_string(),
            url: "http://localhost/users/1".to_string(),
            timestamp_ms: 2000,
            screenshot: None,
            command_name: Some("get_user".to_string()),
        },
    };
    channel.broadcast(snapshot_msg).await;

    let received = timeout(Duration::from_secs(3), read.next()).await;
    assert!(received.is_ok(), "client should receive the snapshot");
    let text = received.unwrap().unwrap().unwrap().into_text().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();

    assert_eq!(parsed["type"], "snapshot");
    assert_eq!(parsed["data"]["label"], "after:get_user");
    assert_eq!(parsed["data"]["command_name"], "get_user");
    assert!(
        parsed["data"].get("screenshot").is_none()
            || parsed["data"]["screenshot"].is_null(),
        "screenshot should be omitted or null"
    );

    channel.shutdown().await;
}
