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
