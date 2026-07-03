# Mobile Soft PLC Simulator

> [!WARNING]
> **SIMULATOR / TRAINING / TESTING TOOL ONLY**  
> This software is a mobile-capable soft PLC simulator designed for training, SCADA integration, virtual commissioning, and protocol testing. **It is NOT a safety-certified PLC** (e.g., IEC 61508 / SIL rated) and **MUST NOT be used for real-world machine safety, physical process control, or production systems.**

---

## 🚀 Overview

The **Mobile Soft PLC Simulator** allows automation engineers, SCADA integrators, and students to run an IEC 61131-3-style control engine on mobile (Android/iOS) and desktop platforms. It provides a real-time scan cycle engine, tag database, simulated field I/O, and protocol adapters to expose virtual PLCs to industrial SCADA systems like Ignition, Kepware, UAExpert, MQTT brokers, Modbus clients, and DNP3 masters.

---

## ✨ Features

- **IEC 61131-3 Control Logic Execution**:
  - Structured Text (ST) & Ladder Logic (LD) MVP support.
  - Basic Boolean logic (Normally Open/Closed contacts, Coils, Set/Reset coils, Timers like TON/TOF).
- **In-Memory Tag Database & I/O Image**:
  - Fully typed tags (`BOOL`, `INT16/32/64`, `REAL/LREAL`, `STRING`).
  - Quality flags (`Good`, `Bad`, `Uncertain`), timestamps, engineering units, forcing, and retention flags.
- **Configurable Scan Cycle Engine**:
  - Deterministic scan execution, diagnostics (scan time, scan count, min/max/avg timing, overruns).
- **Simulated I/O Engine**:
  - Manual forcing, pattern generators, and process simulation inputs/outputs.
- **Industrial Protocol Gateway & Adapters**:
  - **OPC UA Server**: Expose tags as OPC UA nodes with subscriptions and standard namespaces.
  - **Modbus TCP Server**: Map tags to Coils, Discrete Inputs, Input Registers, and Holding Registers.
  - **MQTT Client / Publisher**: Publish tag changes, subscribe to command topics, Sparkplug B support planned.
  - **DNP3 Outstation**: Binary/Analog inputs & outputs, event buffering, unsolicited responses.
- **Dual Operating Modes**:
  - **Mode A (Local Mobile Simulator)**: Standalone execution on mobile devices via native FFI bindings.
  - **Mode B (Companion Gateway Mode)**: Mobile app acts as HMI/Controller while a companion desktop/server process hosts high-performance industrial protocol servers.

---

## 📐 Architecture Overview

```
  ┌────────────────────────────────────────────────────────┐
  │         Mobile / Desktop UI (Flutter & Dart)           │
  └───────────────────────────┬────────────────────────────┘
                              │ Native FFI (Local) / WebSocket (Gateway)
  ┌───────────────────────────┴────────────────────────────┐
  │             Soft PLC Runtime Core (Rust)               │
  ├────────────────────────────────────────────────────────┤
  │             Tag Database & I/O Image                   │
  ├────────────────────────────────────────────────────────┤
  │          Simulated Process & Field I/O Engine          │
  ├────────────────────────────────────────────────────────┤
  │                 Protocol Adapter Layer                 │
  ├──────────────┬──────────────┬──────────────┬───────────┤
  │    OPC UA    │  Modbus TCP  │     MQTT     │   DNP3    │
  │   Server     │   Server     │ Client/Bridge│ Outstation│
  └──────────────┴──────────────┴──────────────┴───────────┘
```

---

## 🛠️ Getting Started

### Prerequisites
- **Rust**: `stable` toolchain (`cargo` 1.80+)
- **Flutter**: SDK 3.22+ with Dart 3.4+
- **Android Studio / Xcode** (optional for native mobile device deployment)

### Running the Rust Runtime Core Tests
```bash
cd runtime
cargo test
```

### Running the Mobile UI
```bash
cd mobile
flutter run
```

### Running the Companion Gateway
```bash
cd gateway
cargo run
```

---

## 📈 Project Status

**Current Phase**: Phase 0 & 1 — Project Scaffold, Architecture & Core Runtime MVP  
- ✅ In-memory Tag Database with quality, forcing, and timestamps.
- ✅ Scan Engine with configurable scan period and performance diagnostics.
- ✅ Basic Boolean logic instructions (NO, NC, Coil, Set, Reset, TON/TOF timers).
- ✅ Motor Start/Stop circuit example with permissives (E-Stop, Overload).
- 🔄 Flutter UI Scaffold & Protocol Adapters under development.

---

## 📄 Documentation

For full technical details, consult:
- [PROJECT_BRIEF.md](PROJECT_BRIEF.md) — Product vision, target users, and non-goals.
- [ARCHITECTURE.md](ARCHITECTURE.md) — High-level architecture, layer descriptions, and dual-mode operating model.
- [ROADMAP.md](ROADMAP.md) — Implementation roadmap (Phases 0 to 10).
- [DECISIONS.md](DECISIONS.md) — Architecture Decision Records (ADRs).
- [DEVELOPMENT_RULES.md](DEVELOPMENT_RULES.md) — Guidelines for contributors and AI agents.
- [SECURITY_AND_SAFETY.md](SECURITY_AND_SAFETY.md) — Security policies and safety disclaimers.
- [docs/protocols/](docs/protocols/) — Protocol adapter specs (OPC UA, Modbus TCP, MQTT, DNP3).

---

## 🤝 Contributing

Contributions are welcome! Please review [DEVELOPMENT_RULES.md](DEVELOPMENT_RULES.md) before submitting pull requests.

---

## 📜 License

Dual-licensed under MIT or Apache 2.0.
