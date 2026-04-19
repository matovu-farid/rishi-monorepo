use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::{broadcast, mpsc, Mutex};
use tokio_tungstenite::accept_async;
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::protocol::Message;
use log::{info, error, debug};

use crate::protocol::ControlMessage;

/// WebSocket-based control channel for communication between
/// the test runner and the app-under-test.
#[derive(Clone)]
pub struct ControlChannel {
    outbound_tx: broadcast::Sender<String>,
    inbound_rx: Arc<Mutex<mpsc::Receiver<ControlMessage>>>,
    inbound_tx: mpsc::Sender<ControlMessage>,
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

        info!("Test harness WebSocket server listening on 127.0.0.1:{}", port);

        let outbound_tx = self.outbound_tx.clone();
        let inbound_tx = self.inbound_tx.clone();
        let mut shutdown_rx = self.shutdown_tx.subscribe();

        let outbound_tx_relay = outbound_tx.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    accept_result = listener.accept() => {
                        match accept_result {
                            Ok((stream, peer_addr)) => {
                                debug!("New connection from {}", peer_addr);
                                let outbound_rx = outbound_tx.subscribe();
                                let inbound_tx = inbound_tx.clone();
                                let relay_tx = outbound_tx_relay.clone();
                                tokio::spawn(handle_connection(
                                    stream,
                                    outbound_rx,
                                    inbound_tx,
                                    relay_tx,
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

    pub async fn broadcast(&self, msg: ControlMessage) {
        let json = match serde_json::to_string(&msg) {
            Ok(j) => j,
            Err(e) => {
                error!("Failed to serialize message: {}", e);
                return;
            }
        };
        let _ = self.outbound_tx.send(json);
    }

    pub async fn recv(&self) -> Option<ControlMessage> {
        self.inbound_rx.lock().await.recv().await
    }

    pub async fn shutdown(&self) {
        let _ = self.shutdown_tx.send(());
    }
}

async fn handle_connection(
    stream: tokio::net::TcpStream,
    mut outbound_rx: broadcast::Receiver<String>,
    inbound_tx: mpsc::Sender<ControlMessage>,
    relay_tx: broadcast::Sender<String>,
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
            inbound = ws_read.next() => {
                match inbound {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<ControlMessage>(&text) {
                            Ok(msg) => {
                                // Relay Exec messages to all connected clients (including the
                                // webview) via the broadcast channel. Without this, exec
                                // messages from the runner stay in the inbound mpsc and
                                // never reach the webview's injected JS.
                                if matches!(&msg, ControlMessage::Exec { .. }) {
                                    let _ = relay_tx.send(text.clone());
                                }
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
                    _ => {}
                }
            }
        }
    }
}
