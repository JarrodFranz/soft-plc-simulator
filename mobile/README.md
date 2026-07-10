# Mobile UI App (`/mobile`)

Flutter application for Android, iOS, Windows, macOS, Linux, and Web — this **is** the soft PLC: it runs the scan engine (LD/FBD/SFC/ST), the simulated I/O engine, the grid HMI, tag table forcing, and, per ADR-010, hosts all four industrial protocol servers **in-process** (OPC UA, Modbus TCP, MQTT + Sparkplug B, DNP3 — `mobile/lib/protocols/`), opt-in from the Outbound Protocols screen. Native platforms (Android/iOS/desktop) can host; a web build compiles but cannot bind protocol server sockets.
