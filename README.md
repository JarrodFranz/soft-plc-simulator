# Mobile Soft PLC Simulator

> [!WARNING]
> **SIMULATOR / TRAINING / TESTING TOOL ONLY**  
> This software is a mobile-capable soft PLC simulator designed for training, SCADA integration, virtual commissioning, and protocol testing. **It is NOT a safety-certified PLC** (e.g., IEC 61508 / SIL rated) and **MUST NOT be used for real-world machine safety, physical process control, or production systems.**

---

## 🚀 Overview

The **Mobile Soft PLC Simulator** allows automation engineers, SCADA integrators, students, and system developers to execute IEC 61131-3 style control logic on portable mobile devices (Android/iOS) and desktop platforms. It provides a real-time scan cycle engine that **executes ladder logic for real**, a structured tag database (DUT-typed struct tags, arrays, bit-addressable members), a rule-driven simulated I/O engine, custom HMI dashboard builders, and industrial protocol adapters to expose virtual PLCs to SCADA systems like Ignition, Kepware, UAExpert, MQTT brokers, Modbus clients, DNP3 masters, EtherNet/IP + CIP clients, S7comm drivers, Omron FINS drivers, and Mitsubishi SLMP (MELSEC) drivers.

---

## ✨ Features & Progress (Full Protocol Suite Shipped — OPC UA, Modbus TCP, MQTT+Sparkplug B, DNP3, EtherNet/IP + CIP, S7comm, Omron FINS, Mitsubishi SLMP)

- **ALL IEC 61131-3 Programming Languages Supported**:
  - **Structured Text (ST)**: Textual IDE with live autocomplete suggestions (`IF`, `WHILE`, `FOR`, `TON`), code templates, AST compilation, and real-time AST interpreter.
  - **Ladder Logic (LD) — edited AND executed**: IEC 61131-3 rung editor built on a node-and-wire graph model with a continuous `L1`/`L2` power-rail frame. Contacts (normally-open, normally-closed, rising/falling edge) and output coils (coil, negated, set, reset) — coils pin to the right rail with the coil-terminal rule enforced. Parallel (OR) branches over any span of elements with draggable start/end handles (risers centre in the inter-cell gap), symbols centred on the wire with the tag name captioned above, `TON`/`TOF` timer blocks, and a mode toolbar (Select · Contact · Coil · Block · Branch). Each scan, a power-flow interpreter runs the rungs for real — series = AND, parallel = OR, seal-in latches hold, edge contacts pulse, and timers count live in their `TIMER` struct tags (`JamTimer.ACC` visibly ticks in the Tag Inspector). A session-only **Go-Online** toggle overlays the live power-flow solve directly on the rung canvas (energized/de-energized colors, live timer/counter/compare values) — never persisted (see [`docs/ld-editor.md`](docs/ld-editor.md)).
  - **Function Block Diagram (FBD)**: Graphical Signal Flow Diagram Editor with drag-and-drop block placement (`AND`, `OR`, `NOT`, `TON`, `LIMIT`, `TAG_INPUT`, `TAG_OUTPUT`), signal wires, and FBD block autocomplete palette.
  - **Sequential Function Chart (SFC) — v2, edited AND executed**: a real 2D chart canvas (step boxes and transition blocks as distinct elements, alternative branches drawn as side-by-side columns, parallel fork/join as double-line bars, nested to any depth, GOTO chips for loop-backs/reconvergence) backed by a multi-token engine — a fork activates every branch at once, a join waits for all branches, an alternative divergence keeps first-true-by-priority selection — with a parallel-aware, session-only **Go-Online** live highlight of every currently-active step. Fully additive/backward-compatible persistence: pre-v2 charts load and round-trip unchanged (see [`docs/sfc-branching.md`](docs/sfc-branching.md)). Showcased end-to-end by the **SFC — Batch Mix & Dispatch** default project: a parallel Heat + Fill fork/join (the join waits for both branches — heating runs slower so Go-Online visibly shows the filled branch parked and waiting) followed by an alternative quality gate (`Quality_OK` routes to dispatch or reject, both looping back to idle).
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
  - Data-driven, editable input behaviours in a dedicated **Simulated I/O** screen: `pulse`, `ramp`, `integrate`, `delayedSet`, and `setWhileCondition`, each gated by AND-combined conditions (literal or tag-vs-tag comparisons) with **per-second rates** independent of scan speed. Photo eyes blip while the belt runs, tanks fill while valves open, temperatures drift — all visible and tunable, and manual forcing always wins. An `integrate`/`ramp` rule driven by an actuator tag can also pick a **valve characteristic** (linear/equal-percentage/quick-opening) shaping how the actuator's position maps onto rate — see `docs/valve-curves.md`. A `noise` rule (deterministic bounded measurement noise) can pick its **distribution** (uniform/Gaussian/pink 1-over-f) and add a slow **bounded sensor drift** (amplitude + time-constant period) on top of the fast per-scan jitter — see `docs/measurement-noise.md`.
- **PID Auto-Tune (Relay Feedback)**:
  - A dedicated **PID Auto-Tune** panel runs a closed-loop relay-feedback experiment on a deep copy of the project's simulated process (the live loop is never disturbed), detects the resulting limit cycle, and estimates the ultimate gain `Ku` and period `Pu`. Six classic tuning-rule suggestions (Ziegler-Nichols, Tyreus-Luyben, ZN no-overshoot — each PID and PI) are computed from `Ku`/`Pu`, and **Apply** writes a chosen row's gains straight onto the loop's `CONST`/tag gain sources. Deterministic and reproducible — see `docs/pid-autotune.md`.
- **MIMO Coupled Plant & Interaction Analysis**:
  - The **"MIMO — Two Thermal Zones"** default project models a genuine 2×2 multivariable process — two heater/temperature zones coupled by heat conduction through a shared wall, so a setpoint step on one zone visibly disturbs the other. The **Interaction Analysis** panel runs automated open-loop step tests on a deep copy of the plant to identify the 2×2 steady-state gain matrix, computes the Relative Gain Array (`λ11`) to quantify interaction and recommend a loop pairing, and suggests static-decoupler gains (`d12 = K12/K11`, `d21 = K21/K22`) that cut cross-loop disturbance by roughly half in the shipped demo. Deterministic and non-mutating (the live loop is never disturbed) — see `docs/mimo-coupled-plant.md`.
- **Toggleable Side Dock Tag Inspector**:
  - Searchable tag matrix with live values, quality flags, engineering units, and manual value forcing controls accessible right on the HMI screen.
- **Tag Historian & Trend Charts**:
  - A **Trends** section under Memory to record selected tags into a live, memory-only time-series buffer — each "pen" sets its own color, sample interval, and retention (by point count or time window) — with a live preview chart. Plot the same pens on an HMI screen with the multi-pen `TrendChartDisplay` component (analog pens auto-scaled, BOOL pens as digital step lanes).
  - **Draggable trace cursor** (touch + mouse): tap/drag a vertical scrubber to read each pen's value at any moment, with the time shown both relative (`-1m 12s`) and as wall-clock (`HH:mm:ss`). Samples are transient (never persisted); the pen configuration saves with the project.
- **Configurable Scan Cycle Engine & Debugging**:
  - PLC-faithful scan pipeline each tick: **read/drive simulated inputs → execute ladder programs → write outputs**, with a **Scan Loop Speed Slider** (`50ms` Full Speed down to `2000ms` Slow Motion step debugging), Pause control (`⏸ / ▶`), and **Step Scan** (`⏭`) single-cycle execution. Timers advance by scan ticks, so pause/step debugging stays deterministic.
- **In-App Log / Diagnostics Window**:
  - A source-tagged, filterable **Logs** screen (left dock) makes previously-invisible failures diagnosable from the app alone — e.g. a SCADA client that connects (card reads "Running, Clients: 1") while every request it sends is silently dropped. Every subsystem (all six protocol hosts, the scan engine, project load/save/switch, sim/historian/scheduler) logs to one shared, memory-only ring buffer (2000 entries) with text/source/minimum-level filters, a live-tail toggle that follows the (optionally filtered) tail via the app's throttled repaint tick, and expandable rows for frame-level detail. Per-source DEBUG/TRACE verbosity is off by default and toggled right from the Logs screen; a first-occurrence WARN always announces a dropped request at default verbosity, with repeats demoted to DEBUG so a stuck client can't flood the buffer. The log is never persisted (lost on restart) and is deliberately **not** cleared on project switch, unlike the tag historian — see [`docs/diagnostics.md`](docs/diagnostics.md).
- **Project Catalog & Persistence**:
  - Projects (including the built-in default projects) are stored locally via `SharedPreferences`; edits autosave in the background as you work.
  - Built-in default projects **backfill non-destructively on upgrade**: when a new release adds a default project, it appears in your catalog on the next launch without wiping any of your existing projects or edits — and a default project you previously deleted stays deleted (it is never resurrected).
  - **Reset to Defaults** (project menu) remains the full destructive restore: it wipes every project, including your own, and reseeds only the built-in defaults.

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
  │   — hosted directly by this same app, no companion —   │
  ├─────────┬─────────┬─────────┬────────┬────────┬────────┤
  │ OPC UA  │ Modbus  │MQTT+SpB │  DNP3  │EtherNet│ S7comm │
  │ Server  │   TCP   │Publisher│Outstatn│ IP+CIP │ Server │
  └─────────┴─────────┴─────────┴────────┴────────┴────────┘
```

Per **ADR-010** (`DECISIONS.md`), all six protocol servers run **in-process**
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

> **Superseded by ADR-010.** The app hosts all six industrial protocols
> (OPC UA, Modbus TCP, MQTT + Sparkplug B, DNP3, EtherNet/IP + CIP, S7comm)
> **in-process** — there is no
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

#### Run the EtherNet/IP + CIP E2E (Python probe lane)
EtherNet/IP is verified by a real third-party **Python** client (`pycomm3`)
rather than a Rust crate — see `tool/py/`. The script creates/reuses a venv,
installs the exactly-pinned client, starts the Dart fixture host, runs the
probe, and tears the host down unconditionally:
```bash
bash tool/enip_e2e.sh
```

#### Run the S7comm E2E (Python probe lane)
S7comm is verified by a real third-party **Python** client (`python-snap7`),
sharing the same venv-isolated lane. The fixture host binds port **10102**
rather than S7comm's standard 102, which is privileged on Linux/macOS:
```bash
bash tool/s7_e2e.sh   # prints "S7 PROBE PASS"
```
It drives connect → negotiate → read → write → **independent read-back of the
exact written value** across two memory areas, including a single-bit round
trip and both write-refusal paths. See
[`docs/protocols/s7comm.md`](docs/protocols/s7comm.md).

Both the EtherNet/IP and S7comm probes above run on the **same shared Python
lane**, which the remaining protocol workstreams reuse: a venv-isolated,
exact-pinned client environment under `tool/py/`. Either script requires Python
3.8+ on `PATH` and network access on its first run.

---

### 🧪 Running Tests & Verification

#### Run Rust Runtime Unit & Integration Tests (43 Tests Passing)
```bash
cd runtime
cargo test
```

#### Run Flutter Unit & Integration Tests (1872 Tests Passing)
```bash
cd mobile
flutter test
```
Covers the tag path resolver and Memory Manager value model; all four IEC 61131-3 execution engines (LD power flow/latches/edges, the FBD function-block library, the ST parser/interpreter, and the SFC multi-token engine incl. parallel fork/join) plus their editors; the simulated-process engine (analog rates, first-order lag, transport dead-time, valve curves, and deterministic noise — uniform/Gaussian/pink with bounded sensor drift); the PID relay-feedback auto-tuner and the MIMO gain-matrix/RGA interaction analysis; the six in-app protocol servers (OPC UA incl. the Basic256Sha256 security stack, Modbus TCP, MQTT + Sparkplug B, DNP3, EtherNet/IP + CIP explicit messaging, S7comm); persistence (lossless round-trip, autosave, and non-destructive default-project backfill); responsive layout at 320/360/1400 with a whole-app overflow smoke test; and end-to-end scans of every default project.

Determinism is enforced by construction: the simulated engines take no clock and no randomness, so byte-identity guards (e.g. a golden noise sequence) and closed-loop settling tests are falsifiable rather than flaky. Real third-party protocol clients (the Rust `opcua`, `tokio-modbus`, `rumqttc`, and `dnp3` crates, and the Python `pycomm3` and `python-snap7` libraries for EtherNet/IP and S7comm) verify wire interoperability separately — see `tool/*_e2e.sh`.

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
| **Phase 3** | IEC 61131-3 language editors (ST, LD, FBD, SFC) — LD rebuilt on a node-and-wire graph (right-pinned terminal coils, movable OR branches, continuous power rails); post-ship: gap-centre branch risers, symbol-on-wire layout, and a session-only Go-Online live power-flow monitor | ✅ Completed |
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
| **Phase 14** | Protocol Expansion Program — **EtherNet/IP + CIP** explicit messaging (v1) shipped in-app and E2E-proven against the real `pycomm3` client, plus the shared Python probe lane | ✅ Complete |
| **Phase 15** | Protocol Expansion Program — **S7comm** (v1) shipped in-app (areas DB/M/I/Q, byte-offset addressing) and E2E-proven against the real `python-snap7` client through read → write → independent read-back; FINS/SLMP/BACnet remain | ✅ Complete |

---

## 📄 Documentation Links

- [PROJECT_BRIEF.md](PROJECT_BRIEF.md) — Product vision, target users, and non-goals.
- [ARCHITECTURE.md](ARCHITECTURE.md) — High-level architecture, layer descriptions, and dual-mode operating model.
- [ROADMAP.md](ROADMAP.md) — Multi-phase implementation roadmap.
- [DECISIONS.md](DECISIONS.md) — Architecture Decision Records (ADRs).
- [DEVELOPMENT_RULES.md](DEVELOPMENT_RULES.md) — Guidelines for human & AI developers.
- [SECURITY_AND_SAFETY.md](SECURITY_AND_SAFETY.md) — Security policies and safety disclaimers.
- [docs/protocols/](docs/protocols/) — Protocol adapter specifications (OPC UA, Modbus TCP, MQTT, DNP3, EtherNet/IP, S7comm, Omron FINS).
- [docs/protocols/ethernet-ip.md](docs/protocols/ethernet-ip.md) — EtherNet/IP + CIP explicit messaging: v1 scope, symbolic tag addressing, the `CipMap` exposure model, what is deferred to v2 and why, and the Python probe lane.
- [docs/protocols/s7comm.md](docs/protocols/s7comm.md) — S7comm (device side): v1 scope, memory-area + byte-offset addressing, the `S7Map` exposure model, gap/partial-coverage/refusal semantics, the negotiated-PDU response budget, and the two wire details the real client settled.
- [docs/trends.md](docs/trends.md) — Tag historian & trend charts (pens, the Trends section, the HMI trend component, and the trace cursor).
- [docs/mimo-coupled-plant.md](docs/mimo-coupled-plant.md) — MIMO coupled-plant demo, gain-matrix/RGA interaction analysis, and the static decoupler.
- [docs/diagnostics.md](docs/diagnostics.md) — In-app Logs / diagnostics window: the source list, per-source verbosity, memory-only/not-cleared-on-switch semantics, and a worked example of diagnosing a client that connects but is served nothing.

---

## 🤝 Contributing

Contributions are welcome! Please review [DEVELOPMENT_RULES.md](DEVELOPMENT_RULES.md) before submitting pull requests.

---

## 📜 License

Dual-licensed under MIT or Apache 2.0.
