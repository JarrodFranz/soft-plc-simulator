# Companion Gateway Architecture Specification

The Companion Gateway is a standalone Rust binary (`gateway`) that runs on Windows, macOS, Linux, or Raspberry Pi.

- Hosts OPC UA Server (port 4840), Modbus TCP Server (port 502), DNP3 Outstation (port 20000), and MQTT Client.
- Provides a WebSocket API on port 8080 for the Flutter Mobile app to connect, monitor runtime scan metrics, inspect tag values, and trigger manual forcing.
