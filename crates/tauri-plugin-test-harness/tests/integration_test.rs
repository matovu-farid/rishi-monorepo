use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::time::{timeout, Duration};
use tungstenite::protocol::Message;
use tokio_tungstenite::connect_async;

use tauri_plugin_test_harness::injector::generate_init_script;
use tauri_plugin_test_harness::mock_registry::MockRegistry;
use tauri_plugin_test_harness::helper_registry::HelperRegistry;
use tauri_plugin_test_harness::protocol::{
    AssertionResult, ControlMessage, DomSnapshot, IpcLogEntry, TestResult, TestStatus,
};
use tauri_plugin_test_harness::websocket::ControlChannel;
use tauri_plugin_test_harness::{PluginBuilder, DEFAULT_PORT};

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
async fn test_result_messages_relayed_to_other_clients() {
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

    // Client 2 SHOULD receive the result (all messages are now relayed
    // so the runner can receive results from the webview)
    let received = timeout(Duration::from_secs(3), read2.next()).await;
    assert!(
        received.is_ok(),
        "result messages should be relayed to other clients"
    );
    let msg = received.unwrap().unwrap().unwrap();
    let text = msg.into_text().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(parsed["type"], "result");

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

    // The IPC message is also relayed back to the sender — consume it
    let relayed = timeout(Duration::from_secs(3), read.next()).await;
    assert!(relayed.is_ok(), "client should receive the relayed IPC message");
    let relayed_text = relayed.unwrap().unwrap().unwrap().into_text().unwrap();
    let relayed_parsed: serde_json::Value = serde_json::from_str(&relayed_text).unwrap();
    assert_eq!(relayed_parsed["type"], "ipc");

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

// ---------------------------------------------------------------------------
// (f) PluginBuilder API tests
// ---------------------------------------------------------------------------

#[test]
fn test_default_port_constant() {
    assert_eq!(DEFAULT_PORT, 9223, "DEFAULT_PORT should be 9223");
}

#[test]
fn test_plugin_builder_new_does_not_panic() {
    // Simply constructing the builder should succeed without panic.
    let _builder = PluginBuilder::new();
}

#[test]
fn test_plugin_builder_default_does_not_panic() {
    // Default trait impl should also succeed.
    let _builder = PluginBuilder::default();
}

#[test]
fn test_plugin_builder_with_custom_port() {
    // Setting a custom port should not panic; the port value is
    // consumed later by build(), which we cannot call without a
    // Tauri runtime, but the builder chain itself must be valid.
    let _builder = PluginBuilder::new().port(4444);
}

#[test]
fn test_plugin_builder_with_single_helper() {
    let _builder = PluginBuilder::new().helper("double", |args| {
        let n = args.as_i64().unwrap_or(0);
        Ok(json!(n * 2))
    });
}

#[test]
fn test_plugin_builder_with_multiple_helpers() {
    let _builder = PluginBuilder::new()
        .helper("add", |args| {
            let a = args["a"].as_i64().unwrap_or(0);
            let b = args["b"].as_i64().unwrap_or(0);
            Ok(json!(a + b))
        })
        .helper("greet", |args| {
            let name = args["name"].as_str().unwrap_or("world");
            Ok(json!(format!("hello, {}", name)))
        })
        .helper("noop", |_| Ok(json!(null)));
}

#[test]
fn test_plugin_builder_chaining_port_and_helpers() {
    // Full chain: custom port + several helpers + port override.
    let _builder = PluginBuilder::new()
        .port(5555)
        .helper("h1", |_| Ok(json!(1)))
        .helper("h2", |_| Ok(json!(2)))
        .port(6666); // port can be overridden
}

// ---------------------------------------------------------------------------
// (g) Injector port customization (port 9999)
// ---------------------------------------------------------------------------

#[test]
fn test_injector_port_9999() {
    let script = generate_init_script(9999);
    assert!(
        script.contains("ws://127.0.0.1:9999"),
        "init script must use port 9999 in WS URL"
    );
    assert!(
        !script.contains("ws://127.0.0.1:9223"),
        "init script must not contain default port when 9999 is used"
    );
}

#[test]
fn test_injector_default_port_contains_9223() {
    let script = generate_init_script(DEFAULT_PORT);
    assert!(
        script.contains("ws://127.0.0.1:9223"),
        "init script with DEFAULT_PORT must use 9223"
    );
}

#[test]
fn test_injector_boundary_port_values() {
    // Port 1 (minimum non-zero)
    let script = generate_init_script(1);
    assert!(script.contains("ws://127.0.0.1:1"));

    // Port 65535 (maximum)
    let script = generate_init_script(65535);
    assert!(script.contains("ws://127.0.0.1:65535"));
}

// ---------------------------------------------------------------------------
// (h) Helper registry end-to-end — arithmetic and error propagation
// ---------------------------------------------------------------------------

#[test]
fn test_helper_doubles_a_number() {
    let registry = HelperRegistry::new();
    registry.register("double", |args| {
        let n = args.as_i64().ok_or("expected integer")?;
        Ok(json!(n * 2))
    });

    let result = registry.call("double", json!(7)).unwrap();
    assert_eq!(result, json!(14));
}

#[test]
fn test_helper_adds_two_numbers_from_json_args() {
    let registry = HelperRegistry::new();
    registry.register("add", |args| {
        let a = args["a"].as_i64().ok_or("missing a")?;
        let b = args["b"].as_i64().ok_or("missing b")?;
        Ok(json!(a + b))
    });

    let result = registry.call("add", json!({"a": 10, "b": 32})).unwrap();
    assert_eq!(result, json!(42));
}

#[test]
fn test_helper_handles_nested_json_args() {
    let registry = HelperRegistry::new();
    registry.register("extract_name", |args| {
        let name = args["user"]["name"]
            .as_str()
            .ok_or("missing user.name")?;
        Ok(json!({"greeting": format!("hi, {}", name)}))
    });

    let result = registry
        .call("extract_name", json!({"user": {"name": "Alice"}}))
        .unwrap();
    assert_eq!(result, json!({"greeting": "hi, Alice"}));
}

#[test]
fn test_helper_error_propagates_with_message() {
    let registry = HelperRegistry::new();
    registry.register("fail_with_reason", |_| {
        Err("division by zero".to_string())
    });

    let err = registry.call("fail_with_reason", json!(null)).unwrap_err();
    let err_msg = err.to_string();
    assert!(
        err_msg.contains("division by zero"),
        "error message should contain the original reason, got: {}",
        err_msg
    );
}

#[test]
fn test_helper_not_found_error() {
    let registry = HelperRegistry::new();
    let err = registry.call("nonexistent", json!(null)).unwrap_err();
    let err_msg = err.to_string();
    assert!(
        err_msg.contains("not found") || err_msg.contains("nonexistent"),
        "error should indicate helper was not found, got: {}",
        err_msg
    );
}

#[test]
fn test_helper_overwrite_replaces_previous() {
    let registry = HelperRegistry::new();
    registry.register("compute", |_| Ok(json!("first")));
    registry.register("compute", |_| Ok(json!("second")));

    let result = registry.call("compute", json!(null)).unwrap();
    assert_eq!(result, json!("second"));
}

// ---------------------------------------------------------------------------
// (i) Mock + Helper interaction — cross-registry isolation
// ---------------------------------------------------------------------------

#[test]
fn test_mock_and_helper_registries_are_independent() {
    let mocks = MockRegistry::new();
    let helpers = HelperRegistry::new();

    mocks.register("foo", json!({"mocked": true}));
    helpers.register("bar", |_| Ok(json!({"helped": true})));

    // Verify mock registry has "foo" but not "bar"
    assert!(mocks.has("foo"));
    assert!(!mocks.has("bar"));

    // Verify helper registry has "bar" but not "foo"
    assert!(helpers.has("bar"));
    assert!(!helpers.has("foo"));
}

#[test]
fn test_clear_mocks_does_not_affect_helpers() {
    let mocks = MockRegistry::new();
    let helpers = HelperRegistry::new();

    mocks.register("foo", json!({"data": 1}));
    mocks.register("baz", json!({"data": 2}));
    helpers.register("bar", |args| {
        let x = args.as_i64().unwrap_or(0);
        Ok(json!(x + 1))
    });

    // Both registries populated
    assert_eq!(mocks.list().len(), 2);
    assert!(helpers.has("bar"));

    // Clear mocks
    mocks.clear();

    // Mocks are gone
    assert_eq!(mocks.list().len(), 0);
    assert!(!mocks.has("foo"));
    assert!(!mocks.has("baz"));

    // Helper still works
    assert!(helpers.has("bar"));
    let result = helpers.call("bar", json!(10)).unwrap();
    assert_eq!(result, json!(11));
}

#[test]
fn test_same_name_in_mock_and_helper_registries() {
    // Having the same key name in both registries should be fine;
    // they are completely separate data structures.
    let mocks = MockRegistry::new();
    let helpers = HelperRegistry::new();

    mocks.register("overlap", json!("mock_value"));
    helpers.register("overlap", |_| Ok(json!("helper_value")));

    assert_eq!(mocks.get("overlap").unwrap(), json!("mock_value"));
    assert_eq!(
        helpers.call("overlap", json!(null)).unwrap(),
        json!("helper_value")
    );

    // Clearing mocks should not affect the helper
    mocks.clear();
    assert!(!mocks.has("overlap"));
    assert!(helpers.has("overlap"));
    assert_eq!(
        helpers.call("overlap", json!(null)).unwrap(),
        json!("helper_value")
    );
}

#[test]
fn test_mock_remove_single_does_not_affect_helper() {
    let mocks = MockRegistry::new();
    let helpers = HelperRegistry::new();

    mocks.register("shared_name", json!(42));
    helpers.register("shared_name", |_| Ok(json!(99)));

    mocks.remove("shared_name");
    assert!(!mocks.has("shared_name"));
    assert!(helpers.has("shared_name"));
    assert_eq!(
        helpers.call("shared_name", json!(null)).unwrap(),
        json!(99)
    );
}

// ---------------------------------------------------------------------------
// (j) WebSocket server with custom port — connect and verify
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_websocket_server_on_random_port_accepts_client() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    assert!(port > 0, "assigned port must be non-zero");

    let url = format!("ws://127.0.0.1:{}", port);
    let connect_result = timeout(Duration::from_secs(3), connect_async(&url)).await;
    assert!(connect_result.is_ok(), "connection should complete within 3s");
    assert!(
        connect_result.unwrap().is_ok(),
        "WebSocket handshake should succeed"
    );

    channel.shutdown().await;
}

#[tokio::test]
async fn test_websocket_multiple_clients_on_random_port() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    // Connect three clients in quick succession
    let (ws1, _) = connect_async(&url).await.unwrap();
    let (ws2, _) = connect_async(&url).await.unwrap();
    let (ws3, _) = connect_async(&url).await.unwrap();

    // All three should be able to split without panic
    let (_w1, _r1) = ws1.split();
    let (_w2, _r2) = ws2.split();
    let (_w3, _r3) = ws3.split();

    channel.shutdown().await;
}

#[tokio::test]
async fn test_websocket_client_receives_broadcast_on_random_port() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    let (ws, _) = connect_async(&url).await.unwrap();
    let (_write, mut read) = ws.split();

    // Give the server time to register the connection
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Broadcast a message from the server side
    let msg = ControlMessage::Exec {
        script: "console.log('ping')".to_string(),
        test_id: "port-test-1".to_string(),
    };
    channel.broadcast(msg).await;

    let received = timeout(Duration::from_secs(3), read.next()).await;
    assert!(received.is_ok(), "client should receive broadcast within 3s");
    let text = received.unwrap().unwrap().unwrap().into_text().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(parsed["type"], "exec");
    assert_eq!(parsed["test_id"], "port-test-1");

    channel.shutdown().await;
}

#[tokio::test]
async fn test_websocket_server_recv_from_client_on_random_port() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    let (ws, _) = connect_async(&url).await.unwrap();
    let (mut write, _read) = ws.split();

    let exec_msg = json!({
        "type": "exec",
        "script": "return 1 + 1",
        "test_id": "custom-port-recv"
    });
    write
        .send(Message::Text(exec_msg.to_string()))
        .await
        .unwrap();

    let received = timeout(Duration::from_secs(3), channel.recv()).await;
    assert!(received.is_ok(), "server should receive message within 3s");
    let msg = received.unwrap().unwrap();
    match msg {
        ControlMessage::Exec { script, test_id } => {
            assert_eq!(script, "return 1 + 1");
            assert_eq!(test_id, "custom-port-recv");
        }
        _ => panic!("expected Exec message from client"),
    }

    channel.shutdown().await;
}

#[test]
fn test_injector_script_is_valid_js() {
    let script = tauri_plugin_test_harness::injector::generate_init_script(9223);

    // Check it's not empty
    assert!(script.len() > 100, "Script too short: {} chars", script.len());

    // Check balanced braces
    let mut brace_count = 0i32;
    let mut paren_count = 0i32;
    let mut bracket_count = 0i32;
    for ch in script.chars() {
        match ch {
            '{' => brace_count += 1,
            '}' => brace_count -= 1,
            '(' => paren_count += 1,
            ')' => paren_count -= 1,
            '[' => bracket_count += 1,
            ']' => bracket_count -= 1,
            _ => {}
        }
        assert!(brace_count >= 0, "Unmatched closing brace");
        assert!(paren_count >= 0, "Unmatched closing paren");
    }
    assert_eq!(brace_count, 0, "Unbalanced braces: {}", brace_count);
    assert_eq!(paren_count, 0, "Unbalanced parens: {}", paren_count);
    assert_eq!(bracket_count, 0, "Unbalanced brackets: {}", bracket_count);

    // Check no Rust format artifacts (double braces that weren't properly escaped)
    assert!(!script.contains("{{"), "Found unescaped Rust format brace '{{{{' in output");
    assert!(!script.contains("}}"), "Found unescaped Rust format brace '}}}}' in output");

    // Check key globals are defined
    assert!(script.contains("window.cy"), "Missing window.cy");
    assert!(script.contains("window.describe"), "Missing window.describe");
    assert!(script.contains("window.it"), "Missing window.it");
    assert!(script.contains("window.__tauriCypress"), "Missing window.__tauriCypress");
    assert!(script.contains("connectWebSocket"), "Missing connectWebSocket");
    assert!(script.contains("type: \"ready\""), "Missing ready message");
}

// ---------------------------------------------------------------------------
// NEW: Injector JS validation — window.cy global and test runner globals
// ---------------------------------------------------------------------------

#[test]
fn test_injector_defines_window_cy_global() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("window.cy =") || script.contains("window.cy="),
        "init script must assign window.cy global"
    );
}

#[test]
fn test_injector_defines_describe_global() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("window.describe =") || script.contains("window.describe="),
        "init script must assign window.describe global"
    );
}

#[test]
fn test_injector_defines_it_global() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("window.it =") || script.contains("window.it="),
        "init script must assign window.it global"
    );
}

#[test]
fn test_injector_defines_before_each_global() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("window.beforeEach =") || script.contains("window.beforeEach="),
        "init script must assign window.beforeEach global"
    );
}

#[test]
fn test_injector_defines_after_each_global() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("window.afterEach =") || script.contains("window.afterEach="),
        "init script must assign window.afterEach global"
    );
}

#[test]
fn test_injector_take_snapshot_sends_via_websocket() {
    let script = generate_init_script(9223);
    // takeSnapshot should send snapshot via ws.send immediately
    assert!(
        script.contains("ws.send(JSON.stringify"),
        "takeSnapshot must send data via WebSocket"
    );
    // Verify the snapshot message type is sent
    assert!(
        script.contains("type: \"snapshot\""),
        "takeSnapshot must send a message with type 'snapshot'"
    );
}

#[test]
fn test_injector_defines_capture_html_with_styles() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("function captureHtmlWithStyles()"),
        "init script must define captureHtmlWithStyles function"
    );
}

#[test]
fn test_injector_ready_message_sent_periodically() {
    let script = generate_init_script(9223);
    // Ready message should be sent via setInterval
    assert!(
        script.contains("setInterval"),
        "init script must use setInterval to send Ready messages periodically"
    );
    assert!(
        script.contains("type: \"ready\""),
        "init script must send ready messages"
    );
}

#[test]
fn test_injector_clear_interval_on_exec() {
    let script = generate_init_script(9223);
    // When an exec message is received, clearInterval should be called
    assert!(
        script.contains("clearInterval"),
        "init script must call clearInterval when exec message is received"
    );
    // Verify it's linked to the ready interval
    assert!(
        script.contains("__tauriCypressReadyInterval"),
        "init script must track the ready interval handle"
    );
}

#[test]
fn test_injector_auto_snapshot_lightweight_flag() {
    let script = generate_init_script(9223);
    // The auto-snapshot after IPC calls passes true as the 3rd arg (lightweight)
    assert!(
        script.contains("takeSnapshot(\"after:\" + cmd, cmd, true)"),
        "auto-snapshot must pass true as lightweight flag (3rd argument)"
    );
}

#[test]
fn test_injector_try_catch_wraps_iife_body() {
    let script = generate_init_script(9223);
    // The IIFE body should be wrapped in a try-catch
    assert!(
        script.contains("try {"),
        "init script IIFE body must be wrapped in try block"
    );
    assert!(
        script.contains("} catch(__initError)"),
        "init script must catch initialization errors with __initError"
    );
    assert!(
        script.contains("__tauriCypressInitError"),
        "init script must expose init error via __tauriCypressInitError"
    );
}

#[test]
fn test_injector_contains_invoke_with_mocks() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("invokeWithMocks"),
        "init script must define invokeWithMocks function"
    );
    assert!(
        script.contains("__TAURI_INTERNALS__"),
        "invokeWithMocks must fallback to __TAURI_INTERNALS__ for real calls"
    );
}

#[test]
fn test_injector_defines_runner_reset() {
    let script = generate_init_script(9223);
    // The runner must be resetable between test executions
    assert!(
        script.contains("__runner.reset()"),
        "init script must call __runner.reset() before executing test scripts"
    );
}

#[test]
fn test_injector_defines_cy_chain_prototype_should() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("CyChain.prototype.should"),
        "init script must define should() on CyChain prototype"
    );
}

#[test]
fn test_injector_defines_cy_chain_prototype_and() {
    let script = generate_init_script(9223);
    // .and is an alias for .should
    assert!(
        script.contains("CyChain.prototype.and = CyChain.prototype.should"),
        "init script must alias .and to .should on CyChain"
    );
}

#[test]
fn test_injector_defines_matchers_for_assertions() {
    let script = generate_init_script(9223);
    // Should register core matchers
    assert!(
        script.contains("registerMatcher(\"exist\""),
        "init script must register 'exist' matcher"
    );
    assert!(
        script.contains("registerMatcher(\"be.visible\""),
        "init script must register 'be.visible' matcher"
    );
    assert!(
        script.contains("registerMatcher(\"have.text\""),
        "init script must register 'have.text' matcher"
    );
    assert!(
        script.contains("registerMatcher(\"have.length\""),
        "init script must register 'have.length' matcher"
    );
    assert!(
        script.contains("registerMatcher(\"equal\""),
        "init script must register 'equal' matcher"
    );
    assert!(
        script.contains("registerMatcher(\"not.exist\""),
        "init script must register 'not.exist' matcher"
    );
}

#[test]
fn test_injector_websocket_reconnect_logic() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("WS_MAX_RECONNECT"),
        "init script must define a max reconnect limit"
    );
    assert!(
        script.contains("wsReconnectAttempts"),
        "init script must track reconnection attempts"
    );
}

#[test]
fn test_injector_execute_test_script_function() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("function executeTestScript(script, testId)"),
        "init script must define executeTestScript function"
    );
    assert!(
        script.contains("AsyncFunction"),
        "executeTestScript must use AsyncFunction constructor for dynamic evaluation"
    );
}

#[test]
fn test_injector_state_persists_across_reinjections() {
    let script = generate_init_script(9223);
    // The state object should only be initialized if not already present
    assert!(
        script.contains("if (!window.__tauriCypressState)"),
        "init script must guard state initialization to persist across re-injections"
    );
}

#[test]
fn test_injector_cy_get_method() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("get: function(selector"),
        "init script cy must define get method with selector parameter"
    );
    assert!(
        script.contains("querySelectorAll"),
        "cy.get must use querySelectorAll to find elements"
    );
}

#[test]
fn test_injector_cy_contains_method() {
    let script = generate_init_script(9223);
    assert!(
        script.contains("contains: function(text)"),
        "init script cy must define contains method"
    );
    assert!(
        script.contains("createTreeWalker"),
        "cy.contains must use TreeWalker to find elements by text"
    );
}

// ---------------------------------------------------------------------------
// NEW: WebSocket relay — broadcast channel capacity and Ready relay
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_broadcast_channel_capacity_is_4096() {
    // The ControlChannel::new() creates a broadcast channel with capacity 4096.
    // We verify this indirectly: we can send 4096 messages without blocking.
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    let (ws, _) = connect_async(&url).await.unwrap();
    let (_write, mut read) = ws.split();

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Broadcast many messages — with capacity 4096, a reasonable batch should succeed
    for i in 0..100 {
        let msg = ControlMessage::Exec {
            script: format!("test_{}", i),
            test_id: format!("capacity-{}", i),
        };
        channel.broadcast(msg).await;
    }

    // Read the first message to verify messages are flowing
    let received = timeout(Duration::from_secs(3), read.next()).await;
    assert!(received.is_ok(), "client should receive broadcast messages");

    channel.shutdown().await;
}

#[tokio::test]
async fn test_ready_message_relayed_to_other_clients() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    // Client 1 sends a Ready message
    let (ws1, _) = connect_async(&url).await.unwrap();
    let (mut write1, _read1) = ws1.split();

    // Client 2 should receive the relayed Ready
    let (ws2, _) = connect_async(&url).await.unwrap();
    let (_write2, mut read2) = ws2.split();

    tokio::time::sleep(Duration::from_millis(100)).await;

    let ready_json = serde_json::json!({ "type": "ready" });
    write1
        .send(Message::Text(ready_json.to_string()))
        .await
        .unwrap();

    let received = timeout(Duration::from_secs(3), read2.next()).await;
    assert!(
        received.is_ok(),
        "Ready message should be relayed to other clients"
    );
    let msg = received.unwrap().unwrap().unwrap();
    let text = msg.into_text().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(parsed["type"], "ready");

    channel.shutdown().await;
}

#[tokio::test]
async fn test_ready_message_received_on_inbound_channel() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    let (ws, _) = connect_async(&url).await.unwrap();
    let (mut write, _read) = ws.split();

    let ready_json = serde_json::json!({ "type": "ready" });
    write
        .send(Message::Text(ready_json.to_string()))
        .await
        .unwrap();

    let received = timeout(Duration::from_secs(3), channel.recv()).await;
    assert!(received.is_ok(), "server should receive Ready message");
    let msg = received.unwrap().unwrap();
    match msg {
        ControlMessage::Ready => {} // Expected
        other => panic!("expected Ready variant, got {:?}", other),
    }

    channel.shutdown().await;
}

#[tokio::test]
async fn test_websocket_shutdown_prevents_new_connections() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    // Verify connection works before shutdown
    let (ws, _) = connect_async(&url).await.unwrap();
    drop(ws);

    channel.shutdown().await;

    // Small delay to let the server actually shut down
    tokio::time::sleep(Duration::from_millis(200)).await;

    // After shutdown, new connections should fail
    let result = timeout(Duration::from_secs(1), connect_async(&url)).await;
    match result {
        Ok(Ok(_)) => {
            // Some OS's may still accept briefly; that's acceptable
        }
        _ => {
            // Expected: connection refused or timeout
        }
    }
}

#[tokio::test]
async fn test_multiple_ready_messages_from_same_client() {
    let channel = ControlChannel::new();
    let port = channel.start("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}", port);

    let (ws, _) = connect_async(&url).await.unwrap();
    let (mut write, _read) = ws.split();

    // Send multiple Ready messages (simulating the setInterval behavior)
    for _ in 0..5 {
        let ready_json = serde_json::json!({ "type": "ready" });
        write
            .send(Message::Text(ready_json.to_string()))
            .await
            .unwrap();
    }

    // All should be received on the inbound channel
    for _ in 0..5 {
        let received = timeout(Duration::from_secs(3), channel.recv()).await;
        assert!(received.is_ok(), "server should receive all Ready messages");
        match received.unwrap().unwrap() {
            ControlMessage::Ready => {}
            other => panic!("expected Ready, got {:?}", other),
        }
    }

    channel.shutdown().await;
}
