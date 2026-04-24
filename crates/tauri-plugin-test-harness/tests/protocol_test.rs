use tauri_plugin_test_harness::protocol::{
    AssertionResult, ControlMessage, TestResult, TestStatus, DomSnapshot, IpcLogEntry,
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
            screenshot: None,
            command_name: None,
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

// ---------------------------------------------------------------------------
// Ready variant serialization / deserialization
// ---------------------------------------------------------------------------

#[test]
fn test_ready_variant_serializes_correctly() {
    let msg = ControlMessage::Ready;
    let json = serde_json::to_string(&msg).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed["type"], "ready");
    // Ready has no extra fields
    assert_eq!(parsed.as_object().unwrap().len(), 1, "Ready should only have 'type' field");
}

#[test]
fn test_ready_variant_deserializes_correctly() {
    let json = r#"{"type":"ready"}"#;
    let msg: ControlMessage = serde_json::from_str(json).unwrap();
    match msg {
        ControlMessage::Ready => {} // Expected
        _ => panic!("expected Ready variant"),
    }
}

#[test]
fn test_ready_roundtrip() {
    let msg = ControlMessage::Ready;
    let json_str = serde_json::to_string(&msg).unwrap();
    let deserialized: ControlMessage = serde_json::from_str(&json_str).unwrap();
    let re_serialized = serde_json::to_string(&deserialized).unwrap();
    assert_eq!(json_str, re_serialized);
    match deserialized {
        ControlMessage::Ready => {}
        _ => panic!("expected Ready variant after round-trip"),
    }
}

// ---------------------------------------------------------------------------
// Deserialization of all variants from JSON strings
// ---------------------------------------------------------------------------

#[test]
fn test_control_message_deserializes_result() {
    let json = r#"{"type":"result","data":{"test_id":"t-1","status":"passed","assertions":[],"error":null,"duration_ms":50}}"#;
    let msg: ControlMessage = serde_json::from_str(json).unwrap();
    match msg {
        ControlMessage::Result { data } => {
            assert_eq!(data.test_id, "t-1");
            match data.status {
                TestStatus::Passed => {}
                _ => panic!("expected Passed status"),
            }
            assert_eq!(data.duration_ms, 50);
            assert!(data.error.is_none());
        }
        _ => panic!("expected Result variant"),
    }
}

#[test]
fn test_control_message_deserializes_snapshot() {
    let json = r#"{"type":"snapshot","data":{"label":"test","html":"<div></div>","url":"http://localhost","timestamp_ms":1000}}"#;
    let msg: ControlMessage = serde_json::from_str(json).unwrap();
    match msg {
        ControlMessage::Snapshot { data } => {
            assert_eq!(data.label, "test");
            assert_eq!(data.html, "<div></div>");
            assert_eq!(data.url, "http://localhost");
            assert_eq!(data.timestamp_ms, 1000);
            assert!(data.screenshot.is_none());
            assert!(data.command_name.is_none());
        }
        _ => panic!("expected Snapshot variant"),
    }
}

#[test]
fn test_control_message_deserializes_ipc() {
    let json = r#"{"type":"ipc","data":{"command":"test_cmd","args":null,"response":null,"mocked":false,"duration_ms":5,"timestamp_ms":100}}"#;
    let msg: ControlMessage = serde_json::from_str(json).unwrap();
    match msg {
        ControlMessage::Ipc { data } => {
            assert_eq!(data.command, "test_cmd");
            assert!(!data.mocked);
            assert_eq!(data.duration_ms, 5);
        }
        _ => panic!("expected Ipc variant"),
    }
}

#[test]
fn test_invalid_type_fails_to_deserialize() {
    let json = r#"{"type":"unknown","data":{}}"#;
    let result = serde_json::from_str::<ControlMessage>(json);
    assert!(result.is_err(), "unknown message type should fail to deserialize");
}

#[test]
fn test_exec_missing_fields_fails() {
    let json = r#"{"type":"exec","script":"test"}"#;
    let result = serde_json::from_str::<ControlMessage>(json);
    assert!(result.is_err(), "exec without test_id should fail");
}

#[test]
fn test_test_status_all_variants_serialize() {
    let passed = serde_json::to_string(&TestStatus::Passed).unwrap();
    let failed = serde_json::to_string(&TestStatus::Failed).unwrap();
    let skipped = serde_json::to_string(&TestStatus::Skipped).unwrap();

    assert_eq!(passed, "\"passed\"");
    assert_eq!(failed, "\"failed\"");
    assert_eq!(skipped, "\"skipped\"");
}

#[test]
fn test_test_status_deserializes_all_variants() {
    let passed: TestStatus = serde_json::from_str("\"passed\"").unwrap();
    let failed: TestStatus = serde_json::from_str("\"failed\"").unwrap();
    let skipped: TestStatus = serde_json::from_str("\"skipped\"").unwrap();

    match passed {
        TestStatus::Passed => {}
        _ => panic!("expected Passed"),
    }
    match failed {
        TestStatus::Failed => {}
        _ => panic!("expected Failed"),
    }
    match skipped {
        TestStatus::Skipped => {}
        _ => panic!("expected Skipped"),
    }
}

#[test]
fn test_assertion_result_with_all_fields() {
    let assertion = serde_json::json!({
        "description": "element exists",
        "passed": true,
        "expected": true,
        "actual": true
    });
    let parsed: AssertionResult = serde_json::from_value(assertion).unwrap();
    assert_eq!(parsed.description, "element exists");
    assert!(parsed.passed);
    assert_eq!(parsed.expected, Some(serde_json::json!(true)));
    assert_eq!(parsed.actual, Some(serde_json::json!(true)));
}

#[test]
fn test_assertion_result_with_null_expected_and_actual() {
    let assertion = serde_json::json!({
        "description": "check",
        "passed": false,
        "expected": null,
        "actual": null
    });
    let parsed: AssertionResult = serde_json::from_value(assertion).unwrap();
    assert!(!parsed.passed);
}

#[test]
fn test_dom_snapshot_optional_fields_deserialization() {
    // With optional fields present
    let json = r#"{"label":"test","html":"<p>hi</p>","url":"http://x","timestamp_ms":1,"screenshot":"data","command_name":"click"}"#;
    let snap: DomSnapshot = serde_json::from_str(json).unwrap();
    assert_eq!(snap.screenshot, Some("data".to_string()));
    assert_eq!(snap.command_name, Some("click".to_string()));

    // Without optional fields
    let json = r#"{"label":"test","html":"<p>hi</p>","url":"http://x","timestamp_ms":1}"#;
    let snap: DomSnapshot = serde_json::from_str(json).unwrap();
    assert!(snap.screenshot.is_none());
    assert!(snap.command_name.is_none());
}

#[test]
fn test_ipc_log_entry_serializes_args_correctly() {
    let entry = IpcLogEntry {
        command: "cmd".to_string(),
        args: serde_json::json!({"key": "value", "nested": {"a": 1}}),
        response: Some(serde_json::json!([1, 2, 3])),
        mocked: true,
        duration_ms: 100,
        timestamp_ms: 5000,
    };
    let json = serde_json::to_string(&entry).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed["args"]["key"], "value");
    assert_eq!(parsed["args"]["nested"]["a"], 1);
    assert_eq!(parsed["response"][0], 1);
    assert_eq!(parsed["response"][1], 2);
    assert_eq!(parsed["response"][2], 3);
}
