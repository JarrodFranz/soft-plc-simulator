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

## Phase 3.6: Project Persistence & Portability ✅
- **Objective**: Make projects survive restarts and move between devices — one cross-platform storage path for the single app targeting the iOS/Android stores and desktop.
- **Deliverables**:
  - **Lossless serialization** of the whole `PlcProject` graph (LD rungs, FBD blocks/wires, SFC steps/transitions, struct defs, and the structured tag value tree + forcing were previously dropped on save) — proven by a 20-scan scan-equivalence round-trip per default project. ✅
  - **`ProjectRepository`** over `shared_preferences` (universal backend — Android/iOS/desktop/web, one code path): catalog + defensive reads, seed-defaults-on-first-run, and full project CRUD. ✅
  - **Shell integration**: boot from the repository with the last active project restored; debounced autosave with a Saving/Saved/Save-failed (and a visible "not saved — storage unavailable") indicator; New/Duplicate/Rename/Delete/Reset in the project switcher. Boot uses try/catch channel detection (no timeout race), so a slow-but-working device always persists. ✅
  - **Export/Import** of `.splc.json` files (`share_plus`/`file_picker`) for cross-device transfer with no cloud; crash-proof import (malformed files raise a typed error, never crash) and id-collision reassignment. ✅
- **Status**: ✅ **COMPLETED**

---

## Phase 4: Industrial OPC UA Server Adapter 🔄
- **Objective**: The **single app itself hosts** an OPC UA server exposing the user-chosen tags as standard OPC UA variable nodes to SCADA/any OPC UA client (**ADR-010** — no companion service; pure-Dart in-app server; mobile-first, desktop secondary).
- **Direction change (ADR-010)**: the earlier companion-gateway route (WS16–18: a separate Rust process bridged over WebSocket — built, machine-tested, and client-verified) was **retired** when the goal was clarified to "one app hosts everything." Its lasting artifacts: the per-project **Outbound Protocols configuration** ✅ (`ProtocolSettings` with per-protocol enable + config, additive persistence) which carries over unchanged, and the **Rust `opcua` client E2E harness** ✅ (proven against the gateway; branch `feat/opcua-hardening`) which becomes the third-party verifier for the in-app server.
- **Deliverables**:
  - **In-app pure-Dart OPC UA server v1** ✅ — a hand-rolled `opc.tcp` binary server implemented in Dart *inside the app* (no FFI, no companion process): Security `None` + anonymous, Hello/Ack, secure channel (incl. token renewal), sessions, GetEndpoints, and Browse/Read/Write over the per-project exposed-tag map — reading the live tag DB in-process and writing force-aware (an external write to a *forced* tag is refused with `Bad_UserAccessDenied`). `dart:io` is confined to the socket host (`services/opcua_host.dart`); hosting is opt-in via the Outbound Protocols section (Start/Stop, configurable port, default 4840) and is stopped on every project switch. Every wire encoding / service NodeId / status code was verified byte-for-byte against the vendored Rust `opcua` 0.12 reference; the codec is dart2js-compile-safe. **Machine-verified end-to-end** by `tool/opcua_e2e.sh`: a real Rust `opcua` client connects to the in-app Dart server and completes GetEndpoints → Browse → Read → Write → read-back (exact value). Runs on Android / desktop / iOS (iOS serves while the app is foreground; web compiles but cannot host inbound sockets).
  - **Subscriptions/MonitoredItems (live SCADA monitoring) — v2** ✅ — all nine subscription services (`CreateSubscription`/`ModifySubscription`/`DeleteSubscriptions`/`SetPublishingMode`, `CreateMonitoredItems`/`ModifyMonitoredItems`/`DeleteMonitoredItems`, `Publish`/`Republish`; `SetMonitoringMode` deliberately not implemented — mode is set at item create/modify): data-change monitored items on the Value attribute with absolute-deadband change detection, per-subscription keep-alive/lifetime timing driven off a host clock tick, `Republish` retransmission of missed notifications, and fixed caps (10 subscriptions/session, 500 monitored items/subscription, 10 parked publishes/session, 20 retransmission messages/subscription). The Outbound Protocols card surfaces `Subscriptions: N · Monitored items: M` once a client subscribes. **Machine-verified end-to-end** by the extended `tool/opcua_e2e.sh`: after the v1 GetEndpoints/Browse/Read/Write/read-back proof, the real Rust `opcua` client creates a subscription + monitored item and receives a genuine pushed `DataChangeNotification` triggered by a server-side mutation on an independent timer — proof a third-party client is receiving *pushed* data changes, not just polling. See `docs/protocols/opcua.md`'s "Subscriptions (v2)" section for the documented v2 simplifications (Sampling≈Reporting, `TimestampsToReturn` ignored, keep-alives continue while publishing is disabled).
  - Encryption (`Basic256Sha256`) + user tokens — later, if warranted. ⏳
  - SCADA client interoperability verified with Kepware/UAExpert (manual confirmation on top of the automated client probe). ⏳
- **Status**: 🔄 **ACTIVE — in-app pure-Dart OPC UA server v1 + v2 subscriptions shipped (ADR-010; single app hosts, real-client E2E-proven incl. pushed data-change notifications); encryption + external-SCADA-client confirmation remain**

---

## Phase 5: Modbus TCP Server Adapter ✅
- **Objective**: The **single app itself hosts** a Modbus TCP server mapping tags to Coils, Discrete Inputs, Holding Registers, and Input Registers (same "one app hosts everything" model as Phase 4's OPC UA server, ADR-010).
- **Deliverables**:
  - **`ModbusMap`/`ModbusProtocolConfig`** ✅ — a per-project, additive `protocols.modbus` config (enable flag, port, default `502`) with a tag<->address map across the four classic Modbus data tables, editable in the Outbound Protocols section's Modbus TCP card or auto-generated from the project's scalar tags (**Regenerate** — read/write `ioType`s default `ReadWrite`, `SimulatedOutput` defaults `ReadOnly`).
  - **Pure-Dart MBAP/PDU codec + register-file handler** ✅ (`mobile/lib/protocols/modbus/modbus_pdu.dart`, zero Flutter dependency, dart2js-safe): all 8 classic function codes (`01`/`02`/`03`/`04`/`05`/`06`/`0F`/`10`), big-endian wire encoding with high-word-first `INT32`/`FLOAT64` packing, LSB-first coil bit packing, reads that never fail on unmapped gaps (0-fill), force-aware writes (a write to a forced tag is silently discarded but still answers success — deliberately different from OPC UA's visible `Bad_UserAccessDenied` refusal, since the classic Modbus wire has no equivalent rich status), and proper exception responses (`01`/`02`/`03`) on illegal function/address/value.
  - **In-app `dart:io` socket host** ✅ (`mobile/lib/services/modbus_host.dart`, the only file in the project allowed to import `dart:io` for Modbus) — MBAP-length-prefixed frame reassembly over a real `ServerSocket`, hostile/malformed-frame connection isolation (never takes the whole host down), opt-in Start/Stop lifecycle wired into the Outbound Protocols Modbus TCP card (status, mapped-tag count, connected-client count, endpoint display).
  - **Machine-verified end-to-end** by `tool/modbus_e2e.sh`: a real Rust `tokio-modbus` crate client connects to the in-app Dart server and completes a poll-for-server-side-mutation (`read_holding_registers`, proving live reads not a frozen snapshot) → `write_single_register` + independent read-back → `write_single_coil` + independent read-back (`read_coils`). Runs on Android / desktop / iOS (iOS serves while the app is foreground; web compiles but cannot host inbound sockets).
  - Configurable address mapping, persisted per-project (additive `protocols.modbus.map`). ✅
- **Status**: ✅ **SHIPPED — in-app pure-Dart Modbus TCP server v1, machine-verified by a real Rust `tokio-modbus` client (see `docs/protocols/modbus.md`)**

**Interop hardening (post-ship)** ✅ — a live third-party SCADA client and a live Modbus master both surfaced real interoperability bugs the automated probes hadn't caught: the OPC UA server's forced-write refusal didn't cover the general read path (fixed: forcing now flows through the shared `readPath` resolver everywhere, including reads), the address space didn't answer the standard `NamespaceArray`/browse-from-Root discovery sequence strict clients use before addressing anything (fixed — see `docs/protocols/opcua.md`), and the Modbus register map only supported top-level scalar tags with no way to hand-edit entries or address struct members (fixed — the map editor is now user-editable and a map entry's `tag` may be a dotted struct-member path, force-gated to scalar roots only). All three fixes are machine-proven end-to-end: the extended `tool/opcua_e2e.sh` asserts `NamespaceArray[1]` equals the project namespace and that a top-down Root→Objects browse reaches every tag, and the extended `tool/modbus_e2e.sh` asserts a forced coil reads back forced and a dotted struct-member holding-register entry decodes correctly.

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
  - **Responsive & adaptive layout** (width-based, not platform-based; shared `mobile/lib/ui/responsive.dart` with breakpoints 640/840, `context.isCompact`/`isExpanded`, viewport-clamped dialogs, 44px touch targets): the desktop 3-pane IDE is preserved at ≥840 px, and on a phone/narrow window the project tree becomes a `Drawer`, the Tag Inspector an end-drawer, editor palettes on-demand bottom sheets, graphical canvases pan/zoom viewers with tap-to-configure, and the Memory Manager a card list — verified by widget tests at fixed surface sizes plus a whole-app overflow smoke test (155 tests). ✅
  - **Editor polish** ✅ — the FBD workspace pans/zooms on every platform (was desktop-fixed) with an "Auto-arrange" action that lays blocks into tidy dependency-ordered columns (pure, tested layout); the HMI component dialog's dropdown overflow was fixed.
  - **Project-wide undo/redo** ✅ — a snapshot history (reusing the WS6 lossless serialization) captures on the debounced autosave tick (coalescing a drag/burst into one step), works across every editor with no per-editor plumbing, resets on project swap, and restores via `fromJson` with an editor-revision key that rebuilds the editor cleanly. Toolbar buttons + Ctrl/⌘+Z / +Y / +Shift+Z shortcuts; depth-capped, in-memory.
  - Haptic feedback on pushbutton press. ⏳
  - Native mobile packaging (iOS/Android). ⏳ (see Phase 10)
- **Status**: 🔄 **ACTIVE — responsive/adaptive layout, editor polish (pannable FBD + auto-arrange), and project-wide undo/redo shipped; haptics & native packaging remain**

---

## Phase 8: DNP3 Outstation Protocol Adapter
- **Objective**: DNP3 outstation exposing Binary Inputs, Binary Outputs, Analog Inputs, and Analog Outputs to DNP3 masters.
- **Status**: ⏳ Planned

---

## Phase 9: Advanced Process Simulation Engine ✅
- **Objective**: Built-in physical process models (PID loops, thermal dynamics, multi-tank flow systems).
- **Deliverables**:
  - **Analog-scaled rates** ✅ — an optional actuator tag (`sourcePath` + `refValue`) proportionally drives an `integrate`/`ramp` rate, so a PLC's analog output modulates the process (real closed-loop control); off/byte-identical when unset.
  - **First-order lag dynamics** ✅ — a `firstOrderLag` behaviour moves a value toward a target (fixed or tag-driven) with a time constant τ (realistic thermal/level/pressure response). Both are configurable in the Simulated I/O editor.
  - **Showcase** ✅ — the reactor temperature is a first-order thermal process (ambient pull + heat/cool) that the executed ST deadband controller regulates: reaches and holds setpoint, decays to ambient with control off (verified by a falsifiable closed-loop test).
  - **PID control function block** ✅ — a stateful FBD block (`SP,PV,KP,KI,KD → CV`) computing positional PID per scan (`error = SP−PV`, integral with conditional anti-windup, derivative, `CV` clamped 0–100), with per-block state in `FbdRuntime` (cleared on project switch, mirroring `TON`/`TOF`) and a palette entry. A "Tank Level PID Control" demo closes a real loop — the PID's `CV` drives an analog-scaled valve inflow against a constant outflow disturbance to hold level at setpoint (verified by a falsifiable closed-loop settling test; engine stays pure/never-throws even for pathological gain constants via the output clamp).
  - **IEC 61131-3 counter function blocks** ✅ — edge-triggered `CTU`/`CTD`/`CTUD` FBD blocks (`CU/R/PV→Q/CV`, `CD/LD/PV→Q/CV`, `CU/CD/R/LD/PV→QU/QD/CV`) with per-block state in `FbdRuntime` (cleared on project switch), reset/load priority, `CV` floored at 0, and palette entries. A "Batch Counter" demo counts pulsed part arrivals to a preset, raises `Batch_Done`, and self-resets via one-scan-delayed tag feedback (cycle-free) — verified by a falsifiable closed-loop counting test plus mutation-checked edge-trigger coverage.
  - **IEC 61131-3 edge detectors + pulse timer** ✅ — `R_TRIG`/`F_TRIG` (`CLK→Q` one-scan edge pulse) and the non-retriggerable `TP` pulse timer (`IN/PT→Q/ET`, fixed-width pulse using the scan clock), with per-block state in `FbdRuntime` (cleared on project switch) and palette entries. A "Pulse Output" demo gates a fixed 3000 ms `TP` pulse from a simulated button's rising edge (`R_TRIG`), so the output pulse width is independent of how long the button is held — verified by a falsifiable closed-loop test plus a mutation-locked non-retrigger/ET-hold test. This completes the standard IEC 61131-3 FBD function-block library (timers, PID, counters, edge/pulse).
  - **Transport dead-time + coupled tanks** ✅ — a `deadTime` Simulated-I/O behaviour outputs a source signal delayed by a dead time (`τ` seconds) via a bounded per-rule FIFO buffer (pass-through at `τ≤0`, clamped, force-aware, cleared on project switch), reusing existing rule fields (no serialization change) and configurable in the editor. A "Cascade Tanks with Transport Delay" demo couples two tanks through a 3 s transport line so the downstream tank visibly lags the upstream one — verified by pure engine step/ramp delay tests plus a direct `Transfer_Line == Tank_A[n scans ago]` assertion (mutation-checked to fail at `τ=0`).
  - **Measurement noise** ✅ — a `noise` Simulated-I/O behaviour reads a clean source tag and writes `measured = clean + bounded uniform noise (±amplitude)` to a *separate* tag, so it is non-accumulating (no random-walk drift). The noise is deterministic — a per-rule xorshift PRNG seeded from a stable FNV-1a hash of `rule.id` (no `Math.random`/clock) — so a project and its serialized round-trip produce the identical sequence and the 20-scan scan-equivalence guard stays green. Reuses existing rule fields (no serialization change), configurable in the editor. A "Noisy Level Measurement" demo shows a smooth true level, a jittery bounded measurement, and a first-order-lag-filtered reading — verified by bounded/varies/no-drift/determinism engine tests plus a filter-attenuation integration test.
  - Auto-tune, multi-variable (MIMO) coupled plant models, nonlinear valve curves, and Gaussian/pink noise & per-sensor drift. ⏳ Planned
- **Status**: ✅ **COMPLETED — analog rates, first-order lag, PID, the full IEC FBD function-block library (timers/counters/edge/pulse), transport dead-time + coupled tanks, and deterministic measurement noise all shipped with showcase demos; MIMO/auto-tune/nonlinear/richer-noise models remain as future enhancements**

---

## Phase 10: Packaging, Multi-Platform Clean Builds & Documentation
- **Objective**: Native installers for Windows (`.msi`), macOS (`.dmg`), Linux (`.AppImage`), Android (`.apk`/`.aab`), and iOS (`.ipa`).
- **Deliverables**:
  - **Native app readiness** ✅ — the single Flutter codebase now has all five platform targets scaffolded (android/ios/windows/macos/linux + web), consistent app identity (**Soft PLC Simulator**, `com.jarrodfranz.softplcsimulator`, `0.1.0+1`), a brand-free ladder-logic launcher icon + dark splash generated for every platform, and a [SHIPPING.md](../../SHIPPING.md) guide covering the build commands and the user-owned steps (developer accounts, signing keys, store uploads) plus the local toolchain gaps. Web builds today.
  - Signed store binaries + installers, and completing the local/CI build toolchains. ⏳ (user-owned: accounts, certificates, uploads; iOS/macOS need a Mac).
- **Status**: 🔄 **ACTIVE — native scaffolding/identity/icons/splash + shipping docs done; signed store builds remain (user-owned toolchain + accounts)**
