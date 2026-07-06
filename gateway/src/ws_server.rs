//! The WebSocket tag-sync server: accepts the app's inbound connection,
//! decodes `hello`/`snapshot`/`delta`/`pong` into the shared [`TagMirror`],
//! and forwards outbound `write`/`ping` messages (e.g. from an OPC UA
//! client write) back to the app.
//!
//! The app is always the WebSocket *client*; this module is the server side
//! (`ws://<host>:<port>`), per
//! `docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md`.

use std::sync::{Arc, Mutex};

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio_tungstenite::tungstenite::Message;

use crate::mirror::TagMirror;
use crate::sync::{decode_message, encode_message, SyncMessage};

/// Outcome of handling one inbound frame, so the caller (main loop / tests)
/// can react (e.g. notify "ready" state) without this module owning any
/// OPC UA specifics.
#[derive(Debug, Clone, PartialEq)]
pub enum Inbound {
    /// `hello` received: project metadata (not persisted here; logged).
    Hello { project: String, controller: String, scan_ms: i64 },
    /// `snapshot`/`delta` applied to the mirror.
    MirrorUpdated,
    /// `pong` received (keepalive reply).
    Pong,
    /// Anything else (unknown, or a message type the app never sends).
    Ignored,
}

/// Applies one decoded inbound message to `mirror`, returning what happened.
/// Pure/sync so it's trivially unit-testable without a socket.
pub fn handle_inbound(mirror: &Arc<Mutex<TagMirror>>, msg: &SyncMessage) -> Inbound {
    match msg {
        SyncMessage::Hello { project, controller, scan_ms } => Inbound::Hello {
            project: project.clone(),
            controller: controller.clone(),
            scan_ms: *scan_ms,
        },
        SyncMessage::Snapshot { .. } | SyncMessage::Delta { .. } => {
            let mut mirror = mirror.lock().expect("mirror mutex poisoned");
            mirror.apply_message(msg);
            Inbound::MirrorUpdated
        }
        SyncMessage::Pong {} => Inbound::Pong,
        _ => Inbound::Ignored,
    }
}

/// Runs the accept loop: binds `addr`, accepts connections one at a time
/// (the app reconnects on drop, so this simply loops back to `accept()`
/// after each session ends), and for each connection drives
/// [`run_session`]. Returns only on a bind error or when `shutdown` fires.
pub async fn serve(
    addr: &str,
    mirror: Arc<Mutex<TagMirror>>,
    mut outbound_rx: UnboundedReceiver<SyncMessage>,
) -> std::io::Result<()> {
    let listener = TcpListener::bind(addr).await?;
    log::info!("gateway websocket server listening on {addr}");
    loop {
        let (stream, peer) = listener.accept().await?;
        log::info!("app connected from {peer}");
        if let Err(e) = run_session(stream, &mirror, &mut outbound_rx).await {
            log::warn!("session with {peer} ended: {e}");
        }
        log::info!("app disconnected ({peer}); waiting for reconnect");
    }
}

/// Drives a single accepted TCP connection as a WebSocket session: performs
/// the handshake, sends `ready`, then loops reading inbound frames (applying
/// them to the mirror) and forwarding anything placed on `outbound_rx`
/// (e.g. OPC-client writes) until the socket closes.
pub async fn run_session(
    stream: TcpStream,
    mirror: &Arc<Mutex<TagMirror>>,
    outbound_rx: &mut UnboundedReceiver<SyncMessage>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let ws_stream = tokio_tungstenite::accept_async(stream).await?;
    let (mut write, mut read) = ws_stream.split();

    write.send(Message::Text(encode_message(&SyncMessage::Ready {}))).await?;

    loop {
        tokio::select! {
            frame = read.next() => {
                match frame {
                    Some(Ok(Message::Text(text))) => {
                        let msg = decode_message(&text);
                        let _ = handle_inbound(mirror, &msg);
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        break;
                    }
                    Some(Ok(_)) => {
                        // Binary/ping/pong frames: no sync payload, ignore.
                    }
                    Some(Err(e)) => {
                        return Err(Box::new(e));
                    }
                }
            }
            outbound = outbound_rx.recv() => {
                match outbound {
                    Some(msg) => {
                        write.send(Message::Text(encode_message(&msg))).await?;
                    }
                    None => {
                        // Sender side dropped: keep serving inbound-only.
                    }
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::ExposedTag;
    use serde_json::Value;
    use std::time::Duration;
    use tokio::sync::mpsc;
    use tokio::time::timeout;
    use tokio_tungstenite::tungstenite::Message as WsMessage;

    /// Bound for every await in the round-trip test below: a stuck future
    /// fails fast with a clear panic message instead of hanging the test
    /// (and `cargo test`) forever.
    const TEST_AWAIT_BOUND: Duration = Duration::from_secs(2);

    #[test]
    fn hello_is_reported_but_does_not_touch_the_mirror() {
        let mirror = Arc::new(Mutex::new(TagMirror::new()));
        let outcome = handle_inbound(
            &mirror,
            &SyncMessage::Hello {
                project: "MotorProj".to_string(),
                controller: "PLC_01".to_string(),
                scan_ms: 100,
            },
        );
        assert_eq!(
            outcome,
            Inbound::Hello {
                project: "MotorProj".to_string(),
                controller: "PLC_01".to_string(),
                scan_ms: 100,
            }
        );
        assert!(mirror.lock().unwrap().is_empty());
    }

    #[test]
    fn snapshot_updates_the_mirror() {
        let mirror = Arc::new(Mutex::new(TagMirror::new()));
        let outcome = handle_inbound(
            &mirror,
            &SyncMessage::Snapshot {
                tags: vec![ExposedTag {
                    path: "Start_PB".to_string(),
                    data_type: "BOOL".to_string(),
                    value: Value::Bool(true),
                    access: "ReadWrite".to_string(),
                }],
            },
        );
        assert_eq!(outcome, Inbound::MirrorUpdated);
        assert_eq!(mirror.lock().unwrap().len(), 1);
    }

    #[test]
    fn pong_and_unknown_are_reported() {
        let mirror = Arc::new(Mutex::new(TagMirror::new()));
        assert_eq!(handle_inbound(&mirror, &SyncMessage::Pong {}), Inbound::Pong);
        assert_eq!(
            handle_inbound(&mirror, &SyncMessage::Ready {}),
            Inbound::Ignored
        );
    }

    /// Full local round-trip: bind the real WS server on an ephemeral port,
    /// connect a real `tokio-tungstenite` client (standing in for the
    /// app), send `hello` + `snapshot`, and assert the mirror is updated
    /// and the server greets with `ready`. Then push a `write` onto the
    /// outbound channel (standing in for an OPC UA client write having
    /// happened) and assert the app-side socket receives it.
    ///
    /// This exercises the ws_server.rs transport end-to-end; a live OPC UA
    /// TCP client driving that write via the real `opc.tcp://` port is the
    /// documented external-client step (see the task report) — the
    /// opcua_server.rs tests already exercise the equivalent
    /// value_setter/mirror/channel wiring directly (see
    /// `write_on_read_write_node_forwards_a_pending_write`), so together
    /// these two test suites cover every hop except the live OPC UA wire
    /// protocol itself.
    ///
    /// Every socket/channel await is wrapped in [`timeout`] so a stuck
    /// future fails the test loudly instead of hanging `cargo test`
    /// forever. Note: `futures_util::StreamExt::split` keeps both split
    /// halves backed by the same underlying connection via a shared lock,
    /// so dropping only the write half does *not* close the socket (the
    /// read half still holds it open) — the server-side `read.next()`
    /// would then never observe EOF/Close. We explicitly send a `Close`
    /// frame (and drop both halves) so the server's session loop actually
    /// terminates and `server_task` resolves instead of hanging.
    #[tokio::test]
    async fn ws_round_trip_snapshot_then_forwarded_write() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let mirror = Arc::new(Mutex::new(TagMirror::new()));
        let mirror_for_server = mirror.clone();
        let (outbound_tx, mut outbound_rx) = mpsc::unbounded_channel::<SyncMessage>();

        let server_task = tokio::spawn(async move {
            let (stream, _peer) = timeout(TEST_AWAIT_BOUND, listener.accept())
                .await
                .expect("server should accept the test client within the bound")
                .unwrap();
            run_session(stream, &mirror_for_server, &mut outbound_rx).await
        });

        let (ws_stream, _resp) = timeout(TEST_AWAIT_BOUND, tokio_tungstenite::connect_async(format!("ws://{addr}")))
            .await
            .expect("client connect should not hang")
            .expect("client should connect");
        let (mut client_write, mut client_read) = ws_stream.split();

        // First frame from the server must be `ready`.
        let first = timeout(TEST_AWAIT_BOUND, client_read.next())
            .await
            .expect("server should send `ready` within the bound")
            .unwrap()
            .unwrap();
        let WsMessage::Text(text) = first else {
            panic!("expected a text frame");
        };
        assert_eq!(decode_message(&text), SyncMessage::Ready {});

        // Send hello + snapshot as the app would.
        timeout(
            TEST_AWAIT_BOUND,
            client_write.send(WsMessage::Text(encode_message(&SyncMessage::Hello {
                project: "MotorProj".to_string(),
                controller: "PLC_01".to_string(),
                scan_ms: 100,
            }))),
        )
        .await
        .expect("sending hello should not hang")
        .unwrap();
        timeout(
            TEST_AWAIT_BOUND,
            client_write.send(WsMessage::Text(encode_message(&SyncMessage::Snapshot {
                tags: vec![ExposedTag {
                    path: "Start_PB".to_string(),
                    data_type: "BOOL".to_string(),
                    value: Value::Bool(false),
                    access: "ReadWrite".to_string(),
                }],
            }))),
        )
        .await
        .expect("sending snapshot should not hang")
        .unwrap();

        // Give the server a moment to process (select loop is async).
        // Poll instead of a single fixed sleep so the test isn't flaky
        // under slow CI while still terminating quickly on the happy path.
        let mirror_updated = timeout(TEST_AWAIT_BOUND, async {
            loop {
                if mirror.lock().unwrap().len() == 1 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
        assert!(mirror_updated.is_ok(), "mirror should reflect the snapshot within the bound");
        assert_eq!(
            mirror.lock().unwrap().get("Start_PB").unwrap().value,
            soft_plc_runtime::tag::TagValue::Bool(false)
        );

        // Simulate an OPC UA client write being forwarded to the app: push
        // directly onto the outbound channel, exactly as the OPC UA write
        // callback (see `opcua_server.rs`) does via its own sender.
        outbound_tx
            .send(SyncMessage::Write {
                path: "Start_PB".to_string(),
                value: Value::Bool(true),
            })
            .unwrap();

        let forwarded = timeout(TEST_AWAIT_BOUND, client_read.next())
            .await
            .expect("forwarded write should arrive within the bound")
            .unwrap()
            .unwrap();
        let WsMessage::Text(text) = forwarded else {
            panic!("expected a text frame");
        };
        assert_eq!(
            decode_message(&text),
            SyncMessage::Write {
                path: "Start_PB".to_string(),
                value: Value::Bool(true),
            }
        );

        // Close cleanly so the server's `read.next()` observes a `Close`
        // frame and its session loop returns, letting `server_task` join
        // instead of hanging (see the doc comment above on `split`).
        timeout(TEST_AWAIT_BOUND, client_write.send(WsMessage::Close(None)))
            .await
            .expect("sending close should not hang")
            .unwrap();
        drop(client_write);
        drop(client_read);

        let joined = timeout(TEST_AWAIT_BOUND, server_task)
            .await
            .expect("server session should end within the bound after close");
        let _ = joined.expect("server task should not panic");
    }
}
