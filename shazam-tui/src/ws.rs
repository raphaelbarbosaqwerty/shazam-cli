/// WebSocket transport — alternative to fd 3/4 pipes for daemon mode.
///
/// Uses TcpStream::try_clone() to get two independent handles to the same socket:
/// - Reader thread: owns the original stream, reads WebSocket frames
/// - Writer thread: owns the cloned stream, sends commands
/// No Mutex, no timeout hacks.
use std::io::Write;
use std::net::TcpStream;
use std::sync::mpsc;

use tungstenite::protocol::WebSocket;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{connect, Message};

use crate::protocol::*;
use crate::AppEvent;

/// Messages to send to the daemon
pub enum WsOutbound {
    Command(String),
    Paste { content: String, line_count: usize },
    Raw(String),
}

/// Connect to daemon, spawn reader + writer threads, return sender channel
pub fn start_ws_transport(
    url: &str,
    subscribe_json: Option<String>,
    event_tx: mpsc::Sender<AppEvent>,
) -> Result<mpsc::Sender<WsOutbound>, String> {
    tui_log(&format!("ws: connecting to {}", url));

    let (ws, _) = connect(url)
        .map_err(|e| format!("WebSocket connect failed: {}", e))?;

    tui_log("ws: connected");

    // Split the WebSocket into reader and writer by cloning the underlying TCP stream
    let (mut ws_reader, mut ws_writer) = split_websocket(ws)?;

    // Send subscribe on the writer half
    if let Some(ref sub_json) = subscribe_json {
        let mut data: serde_json::Value = serde_json::from_str(sub_json).unwrap_or_default();
        if let Some(obj) = data.as_object_mut() {
            obj.insert("action".to_string(), serde_json::Value::String("subscribe".to_string()));
        }
        let _ = ws_writer.send(Message::Text(data.to_string()));
        tui_log("ws: subscribe sent");
    }

    // Send auto-start
    let start_msg = serde_json::json!({"action": "command", "raw": "/start"});
    let _ = ws_writer.send(Message::Text(start_msg.to_string()));
    tui_log("ws: /start sent");

    // Outbound channel
    let (out_tx, out_rx) = mpsc::channel::<WsOutbound>();

    // Reader thread — blocking reads, no lock contention
    std::thread::spawn(move || {
        tui_log("ws-reader: started");
        loop {
            match ws_reader.read() {
                Ok(Message::Text(text)) => {
                    if text.trim().is_empty() { continue; }
                    match serde_json::from_str::<InboundMsg>(&text) {
                        Ok(msg) => {
                            if event_tx.send(AppEvent::Elixir(msg)).is_err() {
                                break;
                            }
                        }
                        Err(e) => {
                            tui_log(&format!("ws-reader: parse error: {}", e));
                        }
                    }
                }
                Ok(Message::Close(_)) => {
                    tui_log("ws-reader: server closed");
                    break;
                }
                Ok(_) => {}
                Err(e) => {
                    tui_log(&format!("ws-reader: error: {}", e));
                    break;
                }
            }
        }
        let _ = event_tx.send(AppEvent::ElixirClosed);
        tui_log("ws-reader: exiting");
    });

    // Writer thread — sends outbound messages, no lock contention
    std::thread::spawn(move || {
        tui_log("ws-writer: started");
        while let Ok(out_msg) = out_rx.recv() {
            let json = match out_msg {
                WsOutbound::Command(raw) => {
                    serde_json::json!({"action": "command", "raw": raw}).to_string()
                }
                WsOutbound::Paste { content, line_count } => {
                    serde_json::json!({"type": "paste", "content": content, "line_count": line_count}).to_string()
                }
                WsOutbound::Raw(json) => json,
            };
            if ws_writer.send(Message::Text(json)).is_err() {
                tui_log("ws-writer: send failed");
                break;
            }
        }
        tui_log("ws-writer: exiting");
    });

    Ok(out_tx)
}

/// Split a WebSocket into independent reader and writer halves.
/// Clones the underlying TCP stream so each thread owns its handle.
fn split_websocket(
    mut ws: WebSocket<MaybeTlsStream<TcpStream>>,
) -> Result<(
    WebSocket<MaybeTlsStream<TcpStream>>,
    WebSocket<MaybeTlsStream<TcpStream>>,
), String> {
    // Clone the underlying TCP stream
    let cloned: MaybeTlsStream<TcpStream> = match ws.get_ref() {
        MaybeTlsStream::Plain(tcp) => {
            MaybeTlsStream::Plain(
                tcp.try_clone().map_err(|e| format!("Failed to clone TCP: {}", e))?
            )
        }
        _ => return Err("TLS not supported for split".to_string()),
    };

    // Writer gets the cloned stream
    let writer = WebSocket::from_raw_socket(cloned, tungstenite::protocol::Role::Client, None);

    // Reader keeps the original WebSocket (preserves any buffered data)
    Ok((ws, writer))
}

fn tui_log(msg: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/shazam-tui.log")
    {
        let _ = writeln!(f, "{}", msg);
    }
}
