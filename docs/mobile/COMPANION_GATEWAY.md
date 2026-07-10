# Companion Gateway Architecture Specification (SUPERSEDED)

> **Superseded by ADR-010 — retired, kept for history only.** The app does
> **not** require this companion process to expose any protocol. As of
> ADR-010 (`DECISIONS.md`), all four industrial protocols (OPC UA, Modbus
> TCP, MQTT + Sparkplug B, DNP3) are hosted **in-process, in pure Dart,
> inside the Flutter app itself** — enable them per project from the
> **Outbound Protocols** screen. See `docs/protocols/opcua.md`,
> `docs/protocols/modbus.md`, `docs/protocols/MQTT.md`, and
> `docs/protocols/DNP3.md` for the shipped design. The `gateway/` Rust crate
> still exists in the repo, but only as a dev-time harness of third-party
> reference clients (`opcua`, `tokio-modbus`, `rumqttd`/`rumqttc`, `dnp3`)
> used to machine-verify the in-app servers — it does not run a WebSocket
> API or synchronize tag state with the app anymore. The original spec below
> is preserved as historical record of the retired design.

The Companion Gateway is a standalone Rust binary (`gateway`) that runs on Windows, macOS, Linux, or Raspberry Pi.

- Hosts OPC UA Server (port 4840), Modbus TCP Server (port 502), DNP3 Outstation (port 20000), and MQTT Client.
- Provides a WebSocket API on port 8080 for the Flutter Mobile app to connect, monitor runtime scan metrics, inspect tag values, and trigger manual forcing.
