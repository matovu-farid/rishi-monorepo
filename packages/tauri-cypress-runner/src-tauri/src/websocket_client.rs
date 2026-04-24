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
    Ready,
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
                                        ControlMessage::Ready => {
                                            debug!("Webview ready");
                                            let _ = app_clone.emit("test-harness://webview-ready", ());
                                        }
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
