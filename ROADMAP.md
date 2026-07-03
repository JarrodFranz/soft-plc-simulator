# Roadmap: Mobile Soft PLC Simulator

## 📌 Overview

This roadmap defines the multi-phase implementation plan for the Mobile Soft PLC Simulator, taking it from an architecture scaffold to a full-featured, multi-protocol industrial soft PLC.

---

## 🚀 Phases

### Phase 0: Project Scaffold and Architecture (CURRENT)
- **Objective**: Establish codebase directory layout, documentation, development rules, JSON project schemas, and initial CI structure.
- **Deliverables**:
  - `README.md`, `PROJECT_BRIEF.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `DECISIONS.md`, `DEVELOPMENT_RULES.md`, `SECURITY_AND_SAFETY.md`.
  - Protocol specifications (`docs/protocols/*.md`) and IEC specifications (`docs/iec61131/*.md`).
  - Example project JSON files & schemas.
  - Rust runtime crate structure & Flutter project scaffold.
- **Acceptance Criteria**:
  - All documentation links valid.
  - Project directory cleanly structured.
  - Rust crate compiles with 0 warnings.

### Phase 1: Tag Database, Scan Engine & Simulated I/O (CURRENT)
- **Objective**: Implement the core PLC scan cycle engine, in-memory tag database, Boolean logic execution, and timer support in Rust.
- **Deliverables**:
  - `TagDatabase` with quality, timestamps, forcing, and retentive support.
  - `ScanEngine` supporting continuous and periodic scan cycles with diagnostics.
  - Basic Boolean logic instructions (`XIC`, `XIO`, `OTE`, `OTL`, `OTU`).
  - `TonTimer` and `TofTimer` implementations following IEC 61131-3.
  - Motor Start/Stop circuit example with E-Stop and Overload permissives.
  - Comprehensive unit test suite (`cargo test`).
- **Acceptance Criteria**:
  - `cargo test` passes 100% of tests.
  - Motor latching, E-Stop dropping, and TON timer behavior verified across multiple scan cycles.

### Phase 2: Structured Text (ST) MVP
- **Objective**: Implement a lexer, parser, and interpreter for Structured Text (ST).
- **Deliverables**:
  - ST AST and parser for variable assignments, IF/THEN/ELSE, CASE, and WHILE statements.
  - ST program compilation into internal instruction model.
  - Unit tests executing ST logic blocks against the tag database.
- **Acceptance Criteria**:
  - Standard ST motor control script executes accurately across scan cycles.

### Phase 3: Ladder Logic (LD) MVP & Visual Rendering
- **Objective**: Build Ladder Logic AST compilation and visual rung rendering in Flutter.
- **Deliverables**:
  - LD parser converting rung definitions into internal instruction execution chain.
  - Flutter UI visual rung renderer showing real-time rung continuity (green/gray lines).
- **Acceptance Criteria**:
  - Rung continuity updates in real-time as inputs change in the Flutter UI.

### Phase 4: OPC UA Server
- **Objective**: Expose the tag database via an embedded OPC UA server.
- **Deliverables**:
  - Rust OPC UA server adapter (`opcua`).
  - Automatic mapping of PLC tags to OPC UA Variable Nodes.
  - Security endpoints (None, Basic256Sha256) and user authentication.
- **Acceptance Criteria**:
  - Kepware or UAExpert successfully connects, browses tag hierarchy, and receives real-time subscription value updates.

### Phase 5: Modbus TCP Server
- **Objective**: Expose tag database over Modbus TCP.
- **Deliverables**:
  - Modbus TCP server supporting FC01, FC02, FC03, FC04, FC05, FC06, FC15, FC16.
  - Configurable register mapping JSON schema.
- **Acceptance Criteria**:
  - Modbus master (e.g., QModMaster / Modscan) reads coils/registers and toggles outputs.

### Phase 6: MQTT Client / Publisher / Subscriber
- **Objective**: Enable IoT/Cloud connectivity via MQTT.
- **Deliverables**:
  - MQTT client adapter publishing tag changes and listening to command topics.
  - Initial Sparkplug B payload framing support.
- **Acceptance Criteria**:
  - Tag updates stream to MQTT broker; write commands update local tag database.

### Phase 7: Mobile UI Polish & Cross-Platform Packaging
- **Objective**: Deliver a refined, mobile-first touch UI for Android, iOS, and desktop.
- **Deliverables**:
  - Mobile touch-optimized tag forcing grid, dynamic HMI controls (gauges, switches, trend lines).
  - Native iOS (`.ipa`) and Android (`.apk`) build configurations.
- **Acceptance Criteria**:
  - Smooth 60 FPS UI on Android & iOS physical devices during 50ms scan cycles.

### Phase 8: DNP3 Outstation
- **Objective**: Add DNP3 outstation protocol support for power & utility SCADA.
- **Deliverables**:
  - DNP3 outstation adapter mapping tags to Binary Inputs/Outputs, Analog Inputs, Counters.
  - Unsolicited response configuration and event buffer management.
- **Acceptance Criteria**:
  - DNP3 master polls Class 0/1/2/3 data and receives unsolicited event updates.

### Phase 9: FBD, SFC, PLCopen XML & Advanced Simulation
- **Objective**: Extend language support and process modeling.
- **Deliverables**:
  - Function Block Diagram (FBD) and Sequential Function Chart (SFC) execution engines.
  - PLCopen XML import/export converter.
  - Physics-based process simulators (tank level, thermal vessel).
- **Acceptance Criteria**:
  - Import standard PLCopen XML project and run full simulation loop.

### Phase 10: Testing, Packaging, Documentation & Examples
- **Objective**: Finalize documentation, example library, and release packages.
- **Deliverables**:
  - User manual, API reference, release binaries, pre-built demo projects.
- **Acceptance Criteria**:
  - Automated integration test suite passes; single-click installer for desktop gateway.
