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

### 4. Protocol Adapter Layer (`/gateway` & `/docs/protocols`)
- **Responsibility**: Exposes tag database state over standard industrial protocols.
- **Adapters**:
  - **OPC UA**: Maps tags to OPC UA Variable Nodes under custom namespaces.
  - **Modbus TCP**: Maps tags to standard coil and register tables.
  - **MQTT**: Publishes tag state changes to broker topics and handles command subscriptions.
  - **DNP3**: Exposes outstation point types (Binary Inputs, Analog Inputs, Counters, CROB).

---

## 🔄 Dual Operating Modes

Because mobile platforms enforce stringent background runtime limits, socket port restrictions, and battery saver throttling, the system is designed around two operating modes:

```
MODE A: Local Mobile Simulator
┌────────────────────────────────────────────────────────┐
  Mobile Device (iOS / Android)
  ┌────────────────────────────────────────────────────┐
  │ Flutter UI                                         │
  │    └─► Native FFI Bridge (flutter_rust_bridge)     │
  │            └─► Embedded Rust Runtime Core          │
  └────────────────────────────────────────────────────┘
└────────────────────────────────────────────────────────┘

MODE B: Companion Gateway Mode
┌───────────────────────┐         ┌───────────────────────┐
│     Mobile App        │         │   Companion Gateway   │
│ (HMI & Control View)  │◄───────►│    (Desktop Server)   │
│ (Flutter)             │ WebSocket│ - Rust Runtime Core   │
└───────────────────────┘         │ - Protocol Servers    │
                                  └───────────┬───────────┘
                                              │
                                  ┌───────────┴───────────┐
                                  │   Industrial SCADA    │
                                  │ (Ignition, Kepware)   │
                                  └───────────────────────┘
```

### Mode A: Local Mobile Simulator
- The Rust runtime is compiled into a C-dynamic library (`.so`, `.dylib`, `.dll`) and linked directly into the Flutter app via `flutter_rust_bridge`.
- Perfect for offline logic testing, learning, and self-contained I/O simulation directly on a phone or tablet.

### Mode B: Companion Gateway Mode
- A standalone Rust binary (`gateway`) runs on a desktop, server, or edge gateway device on the same local network.
- Hosts high-performance, long-running protocol servers (OPC UA port 4840, Modbus TCP port 502, DNP3 port 20000).
- The mobile app connects over WebSocket/HTTP to monitor and control the gateway's soft PLC.
