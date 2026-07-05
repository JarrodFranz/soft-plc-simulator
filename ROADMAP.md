# Multi-Phase Roadmap — Mobile Soft PLC Simulator

> **Warning**: This document outlines planned phases for the Mobile Soft PLC Simulator. All phases prioritize software simulation, SCADA integration, and virtual commissioning rather than hardware safety certification.

---

## Phase 0: Project Scaffold, Shared Types & Documentation
- **Objective**: Establish codebase architecture, core schemas, unit test suite, documentation, and continuous integration baseline.
- **Deliverables**:
  - `README.md`, `PROJECT_BRIEF.md`, `ARCHITECTURE.md`, `DECISIONS.md`, `DEVELOPMENT_RULES.md`, `SECURITY_AND_SAFETY.md`.
  - JSON schemas for project files, tags, runtime configs, and protocol maps in `shared/schemas/`.
  - Example project JSON files in `examples/projects/`.
  - Rust workspace setup with `soft-plc-runtime` crate and companion `gateway`.
  - Flutter workspace scaffold targeting Web, Desktop, Android, and iOS.
- **Status**: ✅ **COMPLETED**

---

## Phase 1: Core Tag Database, Deterministic Scan Engine & Simulated I/O Image
- **Objective**: Build the core memory image, tag database with forced value overrides, scan cycle metric engine, and basic ISA runner.
- **Deliverables**:
  - `TagDatabase` supporting `BOOL`, `INT16/32/64`, `FLOAT32/64`, `STRING`, quality flags, timestamps, and force matrix overrides (`runtime/src/tag.rs`).
  - `ScanEngine` executing deterministic scan cycles with timing metrics (min/max/avg scan time, overrun counts) (`runtime/src/scan_engine.rs`).
  - Ladder Logic Instruction Set Architecture (`XIC`, `XIO`, `OTE`, `OTL`, `OTU`, parallel branch OR frames, `TON`/`TOF` timers) (`runtime/src/instructions.rs`).
  - 43 Rust unit tests verifying tag behavior, forcing, scan metrics, and instruction logic.
- **Status**: ✅ **COMPLETED**

---

## Phase 2: Structured Text (ST) Engine, ST Autocomplete IDE, Memory Manager & Grid HMI Builder
- **Objective**: Full Structured Text (ST) language support with recursive-descent parser, AST interpreter, live autocomplete IDE, Memory Manager (DUT/DB), and custom Grid HMI Dashboard Builder.
- **Deliverables**:
  - ST Lexer, Parser, AST Compiler, and Interpreter (`runtime/src/st/`).
  - **Live Autocomplete ST Editor**: Code completion overlay for global tags, Data Blocks, Structs, built-in function blocks (`TON`, `TOF`, `TP`, `CTU`, `CTD`), math utilities (`LIMIT`, `SEL`, `ABS`, `SQRT`), and keywords.
  - **Memory & Data Storage Manager**: Global Tags, Struct Definitions (DUT / User Defined Types), and Data Blocks (DB).
  - **Custom Grid HMI Dashboard Builder**: Interactive `RUN MODE` vs `EDIT BUILDER` mode with tag-linked input, output, and display components (`PushbuttonSwitch`, `ToggleSwitch`, `NumericSliderInput`, `TextInputField`, `LedIndicatorLight`, `DigitalGaugeDisplay`, `StatusPillDisplay`, `TankGraphicDisplay`) supporting direct Drag-and-Place positioning and grid snap width resizers.
- **Status**: ✅ **COMPLETED**

---

## Phase 3: Complete IEC 61131-3 Language Editors & Autocomplete Suite (ST, LD, FBD, SFC)
- **Objective**: Full graphical and textual IDE support for ALL 4 IEC 61131-3 programming languages with dedicated autocomplete palettes.
- **Deliverables**:
  - **Structured Text (ST)**: Textual IDE with live autocomplete suggestions, templates, and AST verification.
  - **Ladder Logic (LD)**: Node-and-wire graph rung editor with a continuous `L1`/`L2` power-rail frame, contacts (NO/NC/rising/falling), coils (coil/negated/set/reset) pinned terminal against the right rail, parallel (OR) branches over any element span with draggable snap endpoints, and `TON`/`TOF` timer blocks.
  - **Function Block Diagram (FBD)**: Graphical Signal Flow Diagram Editor with drag-and-drop block placement (`AND`, `OR`, `NOT`, `TON`, `LIMIT`, `TAG_INPUT`, `TAG_OUTPUT`), signal wires, and FBD block autocomplete palette.
  - **Sequential Function Chart (SFC)**: State Machine Chart Editor with Initial Steps, Steps, Transitions, ST Actions, and Condition Autocomplete Palette.
- **Status**: ✅ **COMPLETED**

---

## Phase 3.5: Structured Tag System, Simulated I/O & In-App Execution Engines ✅
- **Objective**: Make the in-app simulator real — structured tags resolved by path, data-driven input simulation, and actual execution of the programs built in the editors (in-app Dart engines; see ADR-009). **All four IEC 61131-3 languages now execute; every default project's outputs are driven by real engines, and the previously hardcoded per-project logic is fully retired.**
- **Deliverables**:
  - **Structured tag & type system**: `PlcTag` values as real trees (struct `Map`s, array `List`s); DUT-typed tags replace the retired Data Blocks concept; built-in `TIMER` composite; a pure path resolver (`readPath`/`writePath`/`childrenOf`) for members (`TONTimer.DN`), integer bits (`Word.5`), and array elements (`Recipe[3]`); recursive Memory Manager expansion; path-aware scan accessors and editor tag pickers. ✅
  - **Simulated I/O rules engine**: editable, condition-gated input behaviours (`pulse`, `ramp`, `integrate`, `delayedSet`, `setWhileCondition`) with per-second rates and a dedicated editor screen; the previously hardcoded per-project input physics migrated into visible default rules. ✅
  - **Ladder execution engine**: pure power-flow interpreter over the LD graph (series=AND, parallel=OR, evaluated in topological column order), latch/edge/pulse coil semantics, `TON`/`TOF` timers counting live in their `TIMER` struct tags (scan-tick clock), forcing always wins; hardcoded LD control logic replaced for the motor, conveyor, and water-pump projects; verified by end-to-end scan tests. ✅
  - **SFC execution engine**: pure ST-subset expression/assignment evaluator (`st_expr.dart` — the seed of the ST interpreter) runs step actions and transition conditions with an implicit `STEP_T` step timer; `sfc_exec.dart` drives one active step per program with N-action semantics, first-true-transition switching, and force-aware writes; the bottle filler and water-plant backwash migrated from hardcoded state machines to executed charts. ✅
  - **FBD execution engine**: pure topological dataflow evaluator (`fbd_exec.dart`) over the `FbdBlock`/`FbdWire` graph with a full block set (AND/OR/NOT, ADD/SUB/MUL/DIV, comparators GT/LT/GE/LE/EQ/NE, IEC `LIMIT` clamp, `CONST`, TAG_INPUT/TAG_OUTPUT), input order = wire order, never-throws/never-hangs; the HVAC zone controller and water-quality gate migrated from hardcoded logic to executed diagrams (with editor palette + `CONST` literal editing). ✅
  - **ST interpreter**: pure statement interpreter (`st_exec.dart`) — `IF`/`ELSIF`/`ELSE` (nested) + assignments — built on the `st_expr` expression core; tokenizes with source offsets and evaluates each expression as an exact source substring; force-aware writes; never throws and never hangs (parser progress guaranteed on any input). The reactor deadband controller runs as `ReactorTemp_ST` and water alarms/permissive as a trimmed `Safety_ST`; a single authoritative owner was assigned per tag (`Quality_OK`→FBD, `Treat_Dosing`→LD, tank→FBD) and the last hardcoded logic (`_evaluateActiveLogic`) was retired. ✅
- **Status**: ✅ **COMPLETED — LD, SFC, FBD & ST execution shipped; every default project runs entirely through a real engine (no hardcoded logic remains)**

---

## Phase 4: Industrial OPC UA Server Adapter
- **Objective**: Embed an OPC UA server in the gateway/runtime exposing tag database as standard OPC UA variable nodes.
- **Deliverables**:
  - OPC UA Server namespace (`ns=1;s=Tags/...`).
  - SCADA client interoperability verified with Kepware and UAExpert.
- **Status**: ⏳ Planned

---

## Phase 5: Modbus TCP Server Adapter
- **Objective**: Modbus TCP server mapping tags to Coils, Discrete Inputs, Holding Registers, and Input Registers.
- **Deliverables**:
  - FC01/02/03/04/05/06/15/16 Modbus function code handler.
  - Configurable address mapping JSON.
- **Status**: ⏳ Planned

---

## Phase 6: MQTT Client & Sparkplug B Publisher
- **Objective**: Telemetry publisher broadcasting tag updates to MQTT brokers.
- **Deliverables**:
  - JSON and Sparkplug B Protobuf payload support.
  - Command topic (`/set`) handling for remote writes.
- **Status**: ⏳ Planned

---

## Phase 7: Touch HMI Controls & Mobile UI Polish
- **Objective**: Mobile gesture optimizations, responsive touch HMI controls, and mobile packaging.
- **Deliverables**:
  - Haptic feedback on pushbutton press.
  - Mobile layout adaptations for iOS and Android screen sizes.
- **Status**: ⏳ Planned

---

## Phase 8: DNP3 Outstation Protocol Adapter
- **Objective**: DNP3 outstation exposing Binary Inputs, Binary Outputs, Analog Inputs, and Analog Outputs to DNP3 masters.
- **Status**: ⏳ Planned

---

## Phase 9: Advanced Process Simulation Engine
- **Objective**: Built-in physical process models (PID loops, thermal dynamics, multi-tank flow systems).
- **Status**: ⏳ Planned

---

## Phase 10: Packaging, Multi-Platform Clean Builds & Documentation
- **Objective**: Native installers for Windows (`.msi`), macOS (`.dmg`), Linux (`.AppImage`), Android (`.apk`), and iOS (`.ipa`).
- **Status**: ⏳ Planned
