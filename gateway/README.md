# Gateway — E2E Reference-Client Harness (`/gateway`)

**Not a runtime dependency of the app.** Per ADR-010, the Flutter app hosts
OPC UA, Modbus TCP, MQTT + Sparkplug B, and DNP3 **in-process** in pure Dart
(`mobile/lib/protocols/`) — no companion process, no WebSocket sync.

This crate's current role is a dev-time **E2E verification harness**: real
third-party protocol **clients** (the `opcua`, `tokio-modbus`, `rumqttc`, and
`dnp3` crates) that connect to the in-app Dart servers over the real wire
protocol and prove interoperability (`gateway/examples/*_probe.rs`, driven by
`tool/*_e2e.sh`). See `docs/protocols/` for what each probe verifies.
