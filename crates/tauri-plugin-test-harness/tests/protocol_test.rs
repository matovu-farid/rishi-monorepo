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
