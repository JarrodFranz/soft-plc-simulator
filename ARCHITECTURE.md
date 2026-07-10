# Architecture Specification: Mobile Soft PLC Simulator

## 📌 System Architecture

The Mobile Soft PLC Simulator is architected as a modular, decoupled system separating presentation, control logic execution, data storage, simulation, and protocol networking.

```
  ┌────────────────────────────────────────────────────────┐
  │              UI Layer (Flutter / Dart)                 │
  │  - Tag Table & Inspector    - Logic Diagram Viewer     │
  │  - I/O Simulation Panel     - Protocol Diagnostic View │
  └───────────────────────────┬────────────────────────────┘
                              │ FFI / WebSocket API
  ┌───────────────────────────┴────────────────────────────┐
  │              PLC Runtime Core (Rust)                   │
  │  - Program Manager          - Instruction Interpreter  │
  │  - Task Scheduler           - Timer / Counter Manager  │
  ├────────────────────────────────────────────────────────┤
  │             Tag Database & I/O Image                   │
  │  - In-Memory Hash Map       - Value/Quality/Timestamp  │
  │  - Forced Values Table      - Retentive Storage        │
  ├────────────────────────────────────────────────────────┤
  │            Simulated Process & I/O Engine              │
  │  - Manual Input Overrides   - Process Models (Tank, PID)│
  ├────────────────────────────────────────────────────────┤
  │                 Protocol Adapter Layer                 │
  │  - OPC UA Server            - Modbus TCP Server        │
  │  - MQTT Publisher / Sub     - DNP3 Outstation          │
  └────────────────────────────────────────────────────────┘
```

> This is the generic layer stack; see **"Operating Modes"** below for how
> these layers are actually deployed today — a single app hosts every layer
> in-process (ADR-010), with no separate companion process required.

---

## 🏛️ Layer Descriptions

### 1. Presentation & Editor Layer (`/mobile`)
- **Technology**: Flutter (Dart)
- **Responsibility**: Provides responsive cross-platform visual controls for mobile (iOS/Android), desktop (Windows/macOS/Linux), and web.
- **Key Views**:
  - **Runtime Dashboard**: Controller status (Running, Stopped, Faulted), scan time metrics, scan overrun alerts.
  - **Tag Browser**: Real-time value table with searching, filtering, and forced value indicators.
  - **I/O Control Surface**: Pushbutton switches, sliders for analog inputs, LED output indicators.
  - **Logic Viewer**: Rendered Ladder Logic rungs and Structured Text source editor.

### 1b. In-App Dart Simulation Stack (`/mobile/lib/models`) — current standalone engine
- **Technology**: Pure Dart (no Flutter imports) — widget-free modules unit-tested in isolation.
- **Responsibility**: Powers the standalone/web simulator today, ahead of the Rust core being wired in via FFI. Runs a PLC-faithful scan pipeline each tick: **drive simulated inputs → execute ladder programs → remaining auxiliary logic**.
- **Key Modules**:
  - `tag_resolver.dart`: structured tag values (struct `Map`s, array `List`s, bit-addressable ints) resolved by dotted/indexed path (`TONTimer.DN`, `Word.5`, `Recipe[3]`); DUT-typed tags are the struct instances (no separate data-block concept).
  - `sim_engine.dart`: data-driven Simulated I/O rules (`pulse`, `ramp`, `integrate`, `delayedSet`, `setWhileCondition`), condition-gated, per-second rates, forcing-aware.
  - `ld_exec.dart`: ladder execution — power-flow interpretation of the LD node/wire graph in topological order (series=AND, parallel=OR), latch/edge/pulse coils, `TON`/`TOF` timers whose state lives in the real `TIMER` struct tags, advanced by scan ticks.
- **Relationship to the Rust core**: these engines reproduce the same scan-cycle semantics the Rust runtime targets (read inputs → execute → write outputs; tick-based timer clock). When Mode A/B wiring lands, the Rust core becomes the authoritative engine for native/protocol deployments; the Dart stack remains the zero-install web/demo engine.

### 2. Runtime Core Layer (`/runtime`)
- **Technology**: Rust
- **Responsibility**: Houses the scan cycle execution engine, task manager, and program interpreter.
- **Key Modules**:
  - `Runtime`: Top-level orchestrator holding tag database, programs, scan engine state.
  - `ScanEngine`: Drives the standard 5-step PLC scan cycle.
  - `TagDatabase`: Thread-safe in-memory store for tag records.
  - `Instructions`: Internal Instruction Set Architecture (ISA) execution (NO/NC contacts, coils, timers).

### 3. Tag Database & I/O Image (`runtime/src/tag.rs`, `io_image.rs`)
- **Responsibility**: Holds the authoritative state of all controller tags.
- **Tag Structure**:
  ```rust
  pub struct Tag {
      pub name: String,
      pub path: String,
      pub data_type: DataType,
      pub value: TagValue,
      pub quality: TagQuality,
      pub timestamp: DateTime<Utc>,
      pub access: AccessMode,
      pub retentive: bool,
      pub forced_value: Option<TagValue>,
  }
  ```

### 4. Protocol Adapter Layer (`mobile/lib/protocols/` & `/docs/protocols`) — shipped in-app, per ADR-010
- **Responsibility**: Exposes tag database state over standard industrial protocols. All four adapters are pure Dart, run **in-process inside the app** (no companion service — see "Operating Modes" below), and are opt-in per project from the Outbound Protocols screen.
- **Adapters** (all shipped):
  - **OPC UA**: Maps tags to OPC UA Variable Nodes under a project namespace; Browse/Read/Write + Subscriptions.
  - **Modbus TCP**: Maps tags to standard coil and register tables (8 function codes).
  - **MQTT + Sparkplug B**: Publishes tag state changes (JSON or Sparkplug B) to a broker the app dials out to; opt-in remote writes.
  - **DNP3**: Exposes outstation point types (Binary/Analog Inputs & Outputs) with Class 0 polling and SELECT/OPERATE/DIRECT_OPERATE control.
- The `/gateway` Rust crate is **not** part of this runtime layer — it is a dev-time harness of third-party reference clients used to machine-verify the in-app servers (see ADR-010 below).

---

## 🔄 Operating Modes

**Per ADR-010** (see `DECISIONS.md`): the shipped architecture is a
**single mobile-first app that hosts everything itself** — no companion
process. The former "Mode A/B" split (local simulator vs. a separate
companion-gateway process) is retired as the primary design; Mode A's
description below is still accurate, Mode B is not.

```
PRIMARY: In-App Hosting (single app, all platforms)
┌────────────────────────────────────────────────────────┐
  Device (iOS / Android / Desktop)
  ┌────────────────────────────────────────────────────┐
  │ Flutter UI                                         │
  │    └─► Dart scan engine + Tag DB (in-process)      │
  │    └─► Pure-Dart Protocol Servers (dart:io sockets)│
  │            - OPC UA (opc.tcp, hand-rolled, v1)     │
  │            - Modbus TCP / MQTT / DNP3 (planned)    │
  └────────────────────────────────────────────────────┘
└────────────────────────────────────────────────────────┘
                              ▲
                              │ opc.tcp / Modbus TCP / MQTT / DNP3
                  ┌───────────┴───────────┐
                  │   Industrial SCADA    │
                  │ (UAExpert, Ignition,  │
                  │  Kepware, ...)        │
                  └───────────────────────┘

MODE A: Local Mobile Simulator (native FFI core, unaffected by ADR-010)
┌────────────────────────────────────────────────────────┐
  Mobile Device (iOS / Android)
  ┌────────────────────────────────────────────────────┐
  │ Flutter UI                                         │
  │    └─► Native FFI Bridge (flutter_rust_bridge)     │
  │            └─► Embedded Rust Runtime Core          │
  └────────────────────────────────────────────────────┘
└────────────────────────────────────────────────────────┘
```

### Primary: In-App Protocol Hosting
- The app itself binds the protocol listener (e.g. `opc.tcp` port 4840) and
  serves clients directly — no second process, no FFI, one Dart codebase
  across Android, iOS, and desktop.
- The protocol server reads the project's tag database **live** at request
  time and applies writes through the same force-aware rule the scan engine
  uses — there is no mirror/sync layer to go stale.
- OPC UA v1 ships this way (`mobile/lib/protocols/opcua/`,
  `mobile/lib/services/opcua_host.dart`) — see `docs/protocols/opcua.md` and
  the design spec `docs/superpowers/specs/2026-07-06-in-app-opcua-server-design.md`.
  Modbus TCP / MQTT / DNP3 are planned to follow the same pure-Dart,
  in-app-socket pattern.
- Mobile platform constraints apply directly to this listener: iOS accepts
  connections only while the app is foregrounded; Android requires the
  client to be on the same LAN (no NAT traversal/port-forwarding). These are
  OS/network constraints, not gaps in the implementation.

### Mode A: Local Mobile Simulator
- The Rust runtime is compiled into a C-dynamic library (`.so`, `.dylib`, `.dll`) and linked directly into the Flutter app via `flutter_rust_bridge`.
- Perfect for offline logic testing, learning, and self-contained I/O simulation directly on a phone or tablet.
- Independent of ADR-010 — this mode describes the Rust core embedding, not protocol hosting.

### Retired: Companion Gateway Mode
- The previous design ran a standalone Rust binary (`gateway/`) as a second
  process bridging the app to protocol clients over WebSocket. ADR-010
  retired this as the primary architecture in favor of in-app hosting
  (single app, no companion process, no per-platform native build
  complexity).
- The `gateway/` crate is **not deleted** — it lives on as a dev-time
  third-party **test-client** harness: its Rust `opcua` client
  (`gateway/examples/opcua_probe.rs`) is the machine-verifiable E2E proof
  that the in-app Dart OPC UA server is compatible with a real OPC UA
  client (see `tool/opcua_e2e.sh` and `docs/protocols/opcua.md`). Its old
  server-side/WebSocket-sync code is kept inert pending a harness cleanup on
  branch `feat/opcua-hardening`.
