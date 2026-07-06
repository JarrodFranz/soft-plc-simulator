//! Companion Gateway binary entry point.
//!
//! Starts the two long-running pieces described in
//! `docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md`:
//! - a WebSocket tag-sync server (`ws_server`) that the Flutter app connects
//!   to as a client, feeding `hello`/`snapshot`/`delta` into a shared
//!   [`TagMirror`];
//! - an OPC UA server (`opcua_server`) whose address space is built from an
//!   OPC UA map and mirrors that same `TagMirror`, forwarding OPC-client
//!   writes back to the app over the WebSocket.
//!
//! The gateway executes **no PLC logic**: it only mirrors tag values the app
//! last told it and relays writes back. Before the app connects (or if it's
//! never connected), the OPC UA server still comes up using a bundled
//! default project + map so the address space isn't empty — those values
//! are simply frozen until a real app connection starts streaming updates.

use std::sync::{Arc, Mutex};

use soft_plc_gateway::mirror::TagMirror;
use soft_plc_gateway::opcua_map::OpcuaMap;
use soft_plc_gateway::opcua_server::{build_server, PendingWrite};
use soft_plc_gateway::sync::{tag_value_to_json, ExposedTag, SyncMessage};
use soft_plc_gateway::ws_server;
use soft_plc_runtime::tag::{AccessMode, DataType};
use soft_plc_runtime::Project;
use tokio::sync::mpsc;

/// Default WebSocket tag-sync port. Must match `kDefaultGatewayUrl` in
/// `mobile/lib/services/gateway_client.dart` (`ws://localhost:4855`).
const DEFAULT_WS_PORT: u16 = 4855;
/// Default OPC UA server port: `4840` is the IANA-registered/conventional
/// `opc.tcp://` port used by virtually every OPC UA client and server
/// (including UAExpert's default "Add" dialog), so it needs no
/// documentation beyond "use the default". Distinct from the WS port so
/// both listeners can run side by side on `localhost`.
const DEFAULT_OPCUA_PORT: u16 = 4840;
const OPCUA_HOST: &str = "127.0.0.1";

/// Bundled sample project + OPC UA map, used to populate the OPC UA address
/// space before any app has connected (so `opc.tcp://` isn't an empty
/// server). Once the app connects and sends its own `snapshot`, the mirror
/// (and thus every read) reflects the app's real project instead.
const SAMPLE_PROJECT_JSON: &str = include_str!("../../examples/projects/basic_motor_start_stop.json");
const SAMPLE_MAP_JSON: &str = include_str!("../../examples/protocol-maps/opcua_map_example.json");

/// Maps a runtime [`DataType`] to the wire `dataType` string used by
/// `ExposedTag`/the sync codec (`BOOL`/`INT16`/... ), matching
/// `opcua_server::wire_type_of` and the Dart encoder.
fn wire_type_of(dt: &DataType) -> &'static str {
    match dt {
        DataType::Bool => "BOOL",
        DataType::Int16 | DataType::UInt16 => "INT16",
        DataType::Int32 | DataType::UInt32 => "INT32",
        DataType::Int64 | DataType::UInt64 => "INT64",
        DataType::Float32 => "FLOAT32",
        DataType::Float64 => "FLOAT64",
        DataType::String => "STRING",
    }
}

fn wire_access_of(access: &AccessMode) -> &'static str {
    match access {
        AccessMode::ReadOnly => "ReadOnly",
        AccessMode::ReadWrite | AccessMode::WriteOnly => "ReadWrite",
    }
}

/// Builds the bundled default project's tags as `ExposedTag`s, exactly as
/// the app's own `snapshot` message would encode them, so the mirror (and
/// the OPC UA address space built from it) is populated before any real app
/// connection exists.
fn default_snapshot_tags() -> Vec<ExposedTag> {
    let project = match Project::from_json(SAMPLE_PROJECT_JSON) {
        Ok(p) => p,
        Err(e) => {
            log::warn!("failed to parse bundled sample project (starting with an empty mirror): {e}");
            return Vec::new();
        }
    };
    // `build_tag_database` is the project crate's own tag-definition ->
    // typed-`Tag` conversion (data type / access / initial value coercion);
    // reusing it here avoids re-deriving that logic.
    let db = project.build_tag_database();
    db.all_tags()
        .into_iter()
        .map(|t| ExposedTag {
            path: t.path.clone(),
            data_type: wire_type_of(&t.data_type).to_string(),
            value: tag_value_to_json(&t.value),
            access: wire_access_of(&t.access).to_string(),
        })
        .collect()
}

#[tokio::main]
async fn main() {
    env_logger::init();
    println!("==================================================");
    println!("       Mobile Soft PLC Companion Gateway          ");
    println!("==================================================");
    println!("WARNING: Simulator/Training/Testing Tool Only.");
    println!("NOT safety certified. Do not use for real machine control.\n");

    let ws_port: u16 = std::env::var("GATEWAY_WS_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_WS_PORT);
    let opcua_port: u16 = std::env::var("GATEWAY_OPCUA_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_OPCUA_PORT);

    // Shared tag mirror: populated from the app's snapshot/delta once
    // connected; seeded here with the bundled sample project so the OPC UA
    // address space isn't empty on first boot.
    let mirror = Arc::new(Mutex::new(TagMirror::new()));
    {
        let mut m = mirror.lock().expect("mirror mutex poisoned");
        m.apply_snapshot(&default_snapshot_tags());
    }

    let map = OpcuaMap::from_json_str(SAMPLE_MAP_JSON);

    // Channel from the OPC UA write-setter callbacks to the ws session,
    // which forwards each as a `write` sync message to the app.
    let (write_tx, mut write_rx) = mpsc::unbounded_channel::<PendingWrite>();
    // Channel from "things that want to send a frame to the app" (here: the
    // OPC UA write forwarder) into the ws_server session loop's outbound side.
    let (outbound_tx, outbound_rx) = mpsc::unbounded_channel::<SyncMessage>();

    // Bridge PendingWrite -> SyncMessage::Write to send to the app.
    tokio::spawn(async move {
        while let Some(pending) = write_rx.recv().await {
            let msg = SyncMessage::Write {
                path: pending.path,
                value: pending.value,
            };
            if outbound_tx.send(msg).is_err() {
                // ws_server session loop has no receiver right now (no app
                // connected); the write is simply dropped. The mirror was
                // already optimistically updated, so a future OPC read
                // still reflects it even though the app never saw this
                // particular write go out.
                log::warn!("no active app connection to forward an OPC UA write to");
            }
        }
    });

    let opcua_server = build_server(&map, mirror.clone(), write_tx, OPCUA_HOST, opcua_port);
    log::info!("OPC UA address space built from {} mapped node(s)", map.nodes.len());

    // Run the OPC UA server's accept loop on the current (already-running)
    // tokio runtime. `Server::run`/`run_server` build their own runtime
    // internally, which would panic if called from inside one; the crate
    // also exposes the underlying async task (`new_server_task`) for exactly
    // this composition. Note: the `opcua` crate's own `Arc<RwLock<Server>>`
    // uses its `sync::RwLock` (a `parking_lot` re-export), not
    // `tokio::sync::RwLock` — using the wrong one would fail to type-check.
    let opcua_server = std::sync::Arc::new(opcua::sync::RwLock::new(opcua_server));
    let opcua_task = tokio::spawn(async move {
        opcua::server::prelude::Server::new_server_task(opcua_server).await;
    });

    println!("OPC UA server listening on opc.tcp://{OPCUA_HOST}:{opcua_port}");
    println!("WebSocket tag-sync server listening on ws://0.0.0.0:{ws_port}");
    println!("(waiting for the app to connect and stream its project's tags)\n");

    let ws_addr = format!("0.0.0.0:{ws_port}");
    let ws_task = tokio::spawn(async move {
        if let Err(e) = ws_server::serve(&ws_addr, mirror, outbound_rx).await {
            log::error!("websocket server stopped with an error: {e}");
        }
    });

    // Run both servers until either exits (a bind failure, typically); this
    // binary is meant to run indefinitely otherwise.
    tokio::select! {
        res = ws_task => {
            if let Err(e) = res {
                log::error!("websocket server task panicked: {e}");
            }
        }
        res = opcua_task => {
            if let Err(e) = res {
                log::error!("opc ua server task panicked: {e}");
            }
        }
    }
}
