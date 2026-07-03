# Mobile Soft PLC Simulator

> [!WARNING]
> **SIMULATOR / TRAINING / TESTING TOOL ONLY**  
> This software is a mobile-capable soft PLC simulator designed for training, SCADA integration, virtual commissioning, and protocol testing. **It is NOT a safety-certified PLC** (e.g., IEC 61508 / SIL rated) and **MUST NOT be used for real-world machine safety, physical process control, or production systems.**

---

## 🚀 Overview

The **Mobile Soft PLC Simulator** allows automation engineers, SCADA integrators, students, and system developers to execute IEC 61131-3 style control logic on portable mobile devices (Android/iOS) and desktop platforms. It provides a real-time scan cycle engine, tag database, simulated field I/O, user-defined Structs (DUT) and Data Blocks (DB), custom HMI dashboard builders, and industrial protocol adapters to expose virtual PLCs to SCADA systems like Ignition, Kepware, UAExpert, MQTT brokers, Modbus clients, and DNP3 masters.

---

## ✨ Features & Progress (Phase 2 Active)

- **IEC 61131-3 Control Logic Execution**:
  - **Structured Text (ST) Engine & Live IDE (Phase 2)**: Lexer, recursive-descent parser, AST compiler, and real-time AST interpreter (`IF/THEN/ELSIF/ELSE`, `WHILE`, `REPEAT`, `FOR`, `TON` timers, boolean/numeric math).
  - **Live Autocomplete Palette**: Code completion for global tags, Data Blocks (`DB_Motor1.Run`), Structs (DUT), built-in function blocks (`TON`, `TOF`, `TP`, `CTU`, `CTD`), math utilities (`LIMIT`, `SEL`, `ABS`, `SQRT`), and control keywords.
  - **Ladder Logic (LD) ISA (Phase 1)**: Internal Instruction Set Architecture (`XIC`, `XIO`, `OTE`, `OTL`, `OTU`, nested parallel branch OR logic, `TON`/`TOF` timers).
- **Categorized Tasks & Multi-Program Architecture**:
  - Task organization under **`Startup Tasks`**, **`Continuous Tasks`**, **`Periodic Tasks`**, and **`Event Tasks`** with program counts and language badges (`ST`, `LD`).
- **Memory & Data Storage Manager**:
  - **Global Tags**: Fully typed tags (`BOOL`, `INT16/32/64`, `REAL/LREAL`, `STRING`).
  - **Struct Definitions (DUT)**: User Defined Types with custom fields and defaults.
  - **Data Blocks (DB)**: Structured data blocks instantiated from Struct definitions.
- **Custom Grid HMI Dashboard Builder**:
  - **`RUN MODE`**: Interactive operation surface linked to live PLC tags.
  - **`EDIT BUILDER MODE`**: Drag-and-drop / grid layout component builder.
  - **Input Components**: `PushbuttonSwitch` (BOOL), `ToggleSwitch` (BOOL), `NumericSliderInput` (INT/FLOAT), `TextInputField` (STRING/NUM).
  - **Output & Display Components**: `LedIndicatorLight` (BOOL pilot lights), `DigitalGaugeDisplay` (progress gauges), `StatusPillDisplay` (value pills), `TankGraphicDisplay` (vessel liquid level graphics).
- **Toggleable Side Dock Tag Inspector**:
  - Searchable tag matrix with live values, quality flags, engineering units, and manual value forcing controls accessible right on the HMI screen.
- **Configurable Scan Cycle Engine & Debugging**:
  - Deterministic scan loop with **Scan Loop Speed Slider** (`50ms` Full Speed down to `2000ms` Slow Motion step debugging), Pause control (`⏸ / ▶`), and **Step Scan** (`⏭`) single-cycle execution.

---

## 📐 Architecture Overview

```
  ┌────────────────────────────────────────────────────────┐
  │         Mobile / Desktop UI (Flutter & Dart)           │
  │  - Left Project Tree Explorer   - ST IDE & Autocomplete│
  │  - Grid HMI Dashboard Builder   - Memory Manager (DUT) │
  │  - Side Dock Tag Inspector      - Scan Speed Controller│
  └───────────────────────────┬────────────────────────────┘
                              │ Native FFI (Local) / WebSocket (Gateway)
  ┌───────────────────────────┴────────────────────────────┐
  │             Soft PLC Runtime Core (Rust)               │
  ├────────────────────────────────────────────────────────┤
  │       Tag Database, Structs (DUT) & Data Blocks (DB)   │
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

### Mode B: Running the Companion Gateway (Rust Process)

The Companion Gateway hosts high-performance protocol adapters on a desktop, server, or edge device (e.g. Raspberry Pi) while synchronizing with mobile apps.

Navigate to the `gateway` directory:
```bash
cd gateway
```

#### 1. Run the Gateway Console Process
```bash
cargo run
```

#### 2. Run Gateway in Release Mode (Optimized Performance)
```bash
cargo run --release
```

---

### 🧪 Running Tests & Verification

#### Run Rust Runtime Unit & Integration Tests (43 Tests Passing)
```bash
cd runtime
cargo test
```

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
| **Phase 2** | Structured Text (ST) Engine, ST Autocomplete IDE, Memory Manager & Custom HMI Builder | 🔄 **ACTIVE / IN PROGRESS** |
| **Phase 3** | Ladder Logic (LD) Visual Rung Renderer & Editor in Flutter | ⏳ Planned |
| **Phase 4** | OPC UA Server Adapter in Gateway | ⏳ Planned |
| **Phase 5** | Modbus TCP Server Adapter in Gateway | ⏳ Planned |
| **Phase 6** | MQTT Client / Sparkplug B Publisher | ⏳ Planned |
| **Phase 7** | Touch HMI Controls & Mobile UI Polish | ⏳ Planned |
| **Phase 8** | DNP3 Outstation Protocol Adapter | ⏳ Planned |
| **Phase 9** | FBD, SFC & Process Simulation Engine | ⏳ Planned |
| **Phase 10** | Release Packaging, Installers & Examples | ⏳ Planned |

---

## 📄 Documentation Links

- [PROJECT_BRIEF.md](PROJECT_BRIEF.md) — Product vision, target users, and non-goals.
- [ARCHITECTURE.md](ARCHITECTURE.md) — High-level architecture, layer descriptions, and dual-mode operating model.
- [ROADMAP.md](ROADMAP.md) — Multi-phase implementation roadmap.
- [DECISIONS.md](DECISIONS.md) — Architecture Decision Records (ADRs).
- [DEVELOPMENT_RULES.md](DEVELOPMENT_RULES.md) — Guidelines for human & AI developers.
- [SECURITY_AND_SAFETY.md](SECURITY_AND_SAFETY.md) — Security policies and safety disclaimers.
- [docs/protocols/](docs/protocols/) — Protocol adapter specifications (OPC UA, Modbus TCP, MQTT, DNP3).

---

## 🤝 Contributing

Contributions are welcome! Please review [DEVELOPMENT_RULES.md](DEVELOPMENT_RULES.md) before submitting pull requests.

---

## 📜 License

Dual-licensed under MIT or Apache 2.0.
