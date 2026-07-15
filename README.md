# Mobile Soft PLC Simulator

> [!WARNING]
> **SIMULATOR / TRAINING / TESTING TOOL ONLY**  
> This software is a mobile-capable soft PLC simulator designed for training, SCADA integration, virtual commissioning, and protocol testing. **It is NOT a safety-certified PLC** (e.g., IEC 61508 / SIL rated) and **MUST NOT be used for real-world machine safety, physical process control, or production systems.**

---

## 🚀 Overview

The **Mobile Soft PLC Simulator** allows automation engineers, SCADA integrators, students, and system developers to execute IEC 61131-3 style control logic on portable mobile devices (Android/iOS) and desktop platforms. It provides a real-time scan cycle engine that **executes ladder logic for real**, a structured tag database (DUT-typed struct tags, arrays, bit-addressable members), a rule-driven simulated I/O engine, custom HMI dashboard builders, and industrial protocol adapters to expose virtual PLCs to SCADA systems like Ignition, Kepware, UAExpert, MQTT brokers, Modbus clients, and DNP3 masters.

---

## ✨ Features & Progress (Full Protocol Suite Shipped — OPC UA, Modbus TCP, MQTT+Sparkplug B, DNP3)

- **ALL IEC 61131-3 Programming Languages Supported**:
  - **Structured Text (ST)**: Textual IDE with live autocomplete suggestions (`IF`, `WHILE`, `FOR`, `TON`), code templates, AST compilation, and real-time AST interpreter.
  - **Ladder Logic (LD) — edited AND executed**: IEC 61131-3 rung editor built on a node-and-wire graph model with a continuous `L1`/`L2` power-rail frame. Contacts (normally-open, normally-closed, rising/falling edge) and output coils (coil, negated, set, reset) — coils pin to the right rail with the coil-terminal rule enforced. Parallel (OR) branches over any span of elements with draggable start/end handles, `TON`/`TOF` timer blocks, and a mode toolbar (Select · Contact · Coil · Block · Branch). Each scan, a power-flow interpreter runs the rungs for real — series = AND, parallel = OR, seal-in latches hold, edge contacts pulse, and timers count live in their `TIMER` struct tags (`JamTimer.ACC` visibly ticks in the Tag Inspector).
  - **Function Block Diagram (FBD)**: Graphical Signal Flow Diagram Editor with drag-and-drop block placement (`AND`, `OR`, `NOT`, `TON`, `LIMIT`, `TAG_INPUT`, `TAG_OUTPUT`), signal wires, and FBD block autocomplete palette.
  - **Sequential Function Chart (SFC)**: State Machine Chart Editor with Initial Steps, Steps, Transitions, ST Actions, and Condition Autocomplete Palette.
- **Categorized Tasks & Multi-Program Architecture**:
  - Task organization under **`Startup Tasks`**, **`Continuous Tasks`**, **`Periodic Tasks`**, and **`Event Tasks`** with program counts and language badges (`ST`, `LD`, `FBD`, `SFC`).
- **Memory & Data Storage Manager**:
  - **Global Tags**: Fully typed tags (`BOOL`, `INT16/32/64`, `FLOAT64`, `STRING`, `TIMER`), plus **array tags** (`INT16[8]`) and **DUT-typed struct tags** — a struct-typed tag *is* the instance.
  - **Struct Definitions (DUT)**: User Defined Types with custom fields and defaults; fields can themselves be structs, timers, or arrays.
  - **Recursive expansion & path addressing**: any structured tag expands to its members (`TONTimer.DN`), integers expand to individual bits (`Word.5`), arrays to elements (`Recipe[3]`) — all addressable in logic, HMI bindings, and forcing via one path resolver.
- **Custom Grid HMI Dashboard Builder**:
  - **`RUN MODE`**: Interactive operation surface linked to live PLC tags.
  - **`EDIT BUILDER MODE`**: Component Drag-and-Drop Palette dock + Direct Grid Drag & Place positioning.
  - **Input Components**: `PushbuttonSwitch` (BOOL), `ToggleSwitch` (BOOL), `NumericSliderInput` (INT/FLOAT), `TextInputField` (STRING/NUM).
  - **Output & Display Components**: `LedIndicatorLight` (BOOL pilot lights), `DigitalGaugeDisplay` (progress gauges), `StatusPillDisplay` (value pills), `TankGraphicDisplay` (vessel liquid level graphics), `TrendChartDisplay` (multi-pen historical trend chart).
  - **Grid Column Resizer**: Snap width controls (`1 Col`, `2 Col`, `3 Col`, `4 Col`).
- **Simulated I/O Rules Engine**:
  - Data-driven, editable input behaviours in a dedicated **Simulated I/O** screen: `pulse`, `ramp`, `integrate`, `delayedSet`, and `setWhileCondition`, each gated by AND-combined conditions (literal or tag-vs-tag comparisons) with **per-second rates** independent of scan speed. Photo eyes blip while the belt runs, tanks fill while valves open, temperatures drift — all visible and tunable, and manual forcing always wins.
- **Toggleable Side Dock Tag Inspector**:
  - Searchable tag matrix with live values, quality flags, engineering units, and manual value forcing controls accessible right on the HMI screen.
- **Tag Historian & Trend Charts**:
  - A **Trends** section under Memory to record selected tags into a live, memory-only time-series buffer — each "pen" sets its own color, sample interval, and retention (by point count or time window) — with a live preview chart. Plot the same pens on an HMI screen with the multi-pen `TrendChartDisplay` component (analog pens auto-scaled, BOOL pens as digital step lanes).
  - **Draggable trace cursor** (touch + mouse): tap/drag a vertical scrubber to read each pen's value at any moment, with the time shown both relative (`-1m 12s`) and as wall-clock (`HH:mm:ss`). Samples are transient (never persisted); the pen configuration saves with the project.
- **Configurable Scan Cycle Engine & Debugging**:
  - PLC-faithful scan pipeline each tick: **read/drive simulated inputs → execute ladder programs → write outputs**, with a **Scan Loop Speed Slider** (`50ms` Full Speed down to `2000ms` Slow Motion step debugging), Pause control (`⏸ / ▶`), and **Step Scan** (`⏭`) single-cycle execution. Timers advance by scan ticks, so pause/step debugging stays deterministic.

---

## 📐 Architecture Overview

```
  ┌────────────────────────────────────────────────────────┐
  │         Mobile / Desktop UI (Flutter & Dart)           │
  │  - Left Project Tree Explorer   - ST IDE & Autocomplete│
  │  - Ladder Logic (LD) Editor     - FBD Diagram Editor   │
  │  - SFC Chart Editor             - Memory Manager (DUT) │
  │  - Grid HMI Dashboard Builder   - Simulated I/O Rules  │
  ├────────────────────────────────────────────────────────┤
  │       In-App Simulation Stack (pure Dart models)       │
  │  - Path Resolver (structs/bits/arrays)                 │
  │  - Simulated I/O Rules Engine (pulse/ramp/integrate)   │
  │  - LD/FBD/SFC/ST Execution Engines (scan-tick clock)   │
  │  - Scan pipeline: sim inputs → programs → outputs      │
  ├────────────────────────────────────────────────────────┤
  │   In-App Protocol Servers (pure Dart, dart:io sockets) │
  │   — hosted directly by this same app, no companion —  │
  ├──────────────┬──────────────┬──────────────┬───────────┤
  │    OPC UA    │  Modbus TCP  │  MQTT + SpB  │   DNP3    │
  │   Server     │   Server     │  Publisher   │ Outstation│
  └──────────────┴──────────────┴──────────────┴───────────┘
```

Per **ADR-010** (`DECISIONS.md`), all four protocol servers run **in-process**
inside this one app — there is no companion/gateway process at runtime. The
`gateway/` Rust crate still exists in the repo, but only as a set of
third-party reference clients used to machine-verify the in-app servers (see
`docs/protocols/`).

---

## 📱 How to Open and Run the App (All Modes)

### Prerequisites
- **Rust**: `stable` toolchain (`cargo` 1.80+)
- **Flutter SDK**: 3.22+ with Dart 3.4+
- **Android Studio** (for Android emulator/device deployment)
- **Xcode** (for iOS simulator/device deployment - macOS only)

---

### Mode A: Running the Mobile & Desktop UI (Flutter App)

Navigate to the `mobile` directory:
```bash
cd mobile
```

#### 1. Running on Web (Quickest Preview)
```bash
flutter run -d chrome
```

#### 2. Running on Desktop (Windows / macOS / Linux)
```bash
# Windows
flutter run -d windows

# macOS
flutter run -d macos

# Linux
flutter run -d linux
```

#### 3. Running on Android (Device or Emulator)
1. Start an Android Virtual Device (AVD) from Android Studio or plug in an Android phone with USB Debugging enabled.
2. List available devices:
   ```bash
   flutter devices
   ```
3. Run the app:
   ```bash
   flutter run -d android
   ```
4. Build release APK:
   ```bash
   flutter build apk --release
   ```

#### 4. Running on iOS (Simulator or Device - macOS only)
1. Open iOS Simulator:
   ```bash
   open -a Simulator
   ```
2. Run the app:
   ```bash
   flutter run -d iPhone
   ```
3. Build iOS app bundle:
   ```bash
   flutter build ios
   ```

---

### Retired: Companion Gateway (Rust Process)

> **Superseded by ADR-010.** The app hosts all four industrial protocols
> (OPC UA, Modbus TCP, MQTT + Sparkplug B, DNP3) **in-process** — there is no
> companion process to run to expose protocols. The `gateway/` crate below is
> kept only as a dev-time harness of third-party reference clients
> (`opcua`, `tokio-modbus`, `rumqttd`/`rumqttc`, `dnp3`) that machine-verify
> the in-app Dart servers end-to-end (see `docs/protocols/` and the
> `tool/*_e2e.sh` scripts). You do not need to run it to use any protocol
> feature — enable protocols from the app's **Outbound Protocols** screen
> instead.

Navigate to the `gateway` directory:
```bash
cd gateway
```

#### Run the E2E reference-client examples
```bash
cargo run --example opcua_probe
cargo run --example modbus_probe
cargo run --example mqtt_probe
cargo run --example dnp3_probe
```

---

### 🧪 Running Tests & Verification

#### Run Rust Runtime Unit & Integration Tests (43 Tests Passing)
```bash
cd runtime
cargo test
```

#### Run Flutter Unit & Integration Tests (1389 Tests Passing)
```bash
cd mobile
flutter test
```
Covers the tag path resolver, simulated I/O rule behaviours, the ladder execution engine (power flow, latches, edges, TON/TOF), and end-to-end scans of the default projects (motor seal-in, conveyor jam trip, pump control).

#### Run Flutter UI Linter & Code Analysis (0 Errors)
```bash
cd mobile
flutter analyze
```

---

## 📈 Detailed Roadmap & Status

| Phase | Description | Status |
|-------|-------------|--------|
| **Phase 0** | Project Scaffold, Architecture & Schemas | ✅ Completed |
| **Phase 1** | Tag Database, Scan Engine & Ladder Logic ISA | ✅ Completed |
| **Phase 2** | Structured Text (ST) Engine, ST Autocomplete IDE, Memory Manager & Custom HMI Builder | ✅ Completed |
| **Phase 3** | IEC 61131-3 language editors (ST, LD, FBD, SFC) — LD rebuilt on a node-and-wire graph (right-pinned terminal coils, movable OR branches, continuous power rails) | ✅ Completed |
| **Phase 3.5** | Structured tag system (DUT-typed tags, arrays, bit/member path resolver), Simulated I/O rules engine, and in-app execution engines for LD, SFC, FBD, and ST | ✅ Completed |
| **Phase 4** | Industrial OPC UA Server Adapter — in-app pure-Dart server, real-client E2E-verified (ADR-010) | ✅ Shipped |
| **Phase 5** | Modbus TCP Server Adapter — in-app pure-Dart server, real-client E2E-verified | ✅ Shipped |
| **Phase 6** | MQTT Client / Sparkplug B Publisher — in-app pure-Dart publisher, real-broker E2E-verified | ✅ Shipped |
| **Phase 7** | Touch HMI Controls & Mobile UI Polish | 🔄 Active — responsive layout, editor polish, undo/redo, HMI haptic feedback, and landscape-phone chrome compaction shipped; native packaging ⏳ |
| **Phase 8** | DNP3 Outstation Protocol Adapter — in-app pure-Dart outstation, real-master E2E-verified | ✅ Shipped |
| **Phase 9** | Advanced Process Simulation Engine | ✅ Completed |
| **Phase 10** | Release Packaging, Installers & Examples | 🔄 Active — identity/icons/splash done; signed store builds remain |
| **Phase 11** | Task-Type Scheduler, Per-Task Watchdog & `System` Diagnostics Tag | ✅ Completed |
| **Phase 12** | Bulk Simulated Test-Tag Generation (folders, 7-waveform signal engine, per-protocol auto-map) | ✅ Completed |
| **Phase 13** | Tag Historian & Trend Charts — memory-only historian, Trends section, multi-pen chart + HMI component, draggable trace cursor | ✅ Completed |

---

## 📄 Documentation Links

- [PROJECT_BRIEF.md](PROJECT_BRIEF.md) — Product vision, target users, and non-goals.
- [ARCHITECTURE.md](ARCHITECTURE.md) — High-level architecture, layer descriptions, and dual-mode operating model.
- [ROADMAP.md](ROADMAP.md) — Multi-phase implementation roadmap.
- [DECISIONS.md](DECISIONS.md) — Architecture Decision Records (ADRs).
- [DEVELOPMENT_RULES.md](DEVELOPMENT_RULES.md) — Guidelines for human & AI developers.
- [SECURITY_AND_SAFETY.md](SECURITY_AND_SAFETY.md) — Security policies and safety disclaimers.
- [docs/protocols/](docs/protocols/) — Protocol adapter specifications (OPC UA, Modbus TCP, MQTT, DNP3).
- [docs/trends.md](docs/trends.md) — Tag historian & trend charts (pens, the Trends section, the HMI trend component, and the trace cursor).

---

## 🤝 Contributing

Contributions are welcome! Please review [DEVELOPMENT_RULES.md](DEVELOPMENT_RULES.md) before submitting pull requests.

---

## 📜 License

Dual-licensed under MIT or Apache 2.0.
