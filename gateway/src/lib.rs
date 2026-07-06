// Companion Gateway library: WebSocket tag-sync server + tag mirror + OPC UA
// address-space builder (and, when available, an OPC UA server).
//
// The gateway is a thin protocol shell: the Flutter app owns the tag
// database and runs all logic (see
// docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md). This
// crate never executes PLC logic — it only mirrors tag values synced from
// the app and relays OPC-client writes back.
//
// NOT safety certified. Simulator/training tool only.

pub mod sync;
pub mod mirror;
pub mod opcua_map;
pub mod opcua_server;
pub mod ws_server;
