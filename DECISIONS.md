# Architecture Decision Records (ADRs)

## ADR-001: Flutter for Cross-Platform Mobile UI

- **Status**: Accepted
- **Context**: The product vision requires a mobile-capable soft PLC simulator targeting both Android and iOS, while also benefiting from desktop (Windows/macOS/Linux) and web support.
- **Decision**: Use **Flutter (Dart)** for the application UI.
- **Rationale**:
  - Single codebase targeting Android, iOS, Windows, macOS, Linux, and Web.
  - Native performance with Skia/Impeller graphics renderer (critical for fast HMI graphics and ladder logic rendering).
  - Excellent FFI support (`flutter_rust_bridge`) to interface directly with C/Rust libraries.
- **Alternatives Considered**:
  - *React Native*: JS bridge overhead is higher; less consistent desktop rendering.
  - *Native (Swift/Kotlin)*: Requires duplicate UI codebase maintenance.

---

## ADR-002: Rust for PLC Runtime Core

- **Status**: Accepted
- **Context**: The PLC scan cycle engine and protocol stack require high performance, memory safety, deterministic execution without garbage collection pauses, and multi-platform portability.
- **Decision**: Use **Rust** for the runtime core library (`soft-plc-runtime`).
- **Rationale**:
  - Zero-cost abstractions and no garbage collection (prevents unpredictable GC pauses in the scan loop).
  - Memory-safe concurrent state access.
  - Compiles to native shared libraries (`.dll`, `.so`, `.dylib`, `.a`) for Flutter FFI integration on mobile, desktop, and WebAssembly.
  - Rich industrial protocol ecosystem (`opcua`, `tokio-modbus`, `rumqttc`, `dnp3`).
- **Alternatives Considered**:
  - *C/C++*: Risk of memory safety bugs and buffer overflows in protocol parsing.
  - *Go*: Garbage collection pauses interfere with microsecond-level scan loop timing.
  - *TypeScript*: Higher latency, non-portable for native mobile FFI embedding.

---

## ADR-003: Dual Operating Modes (Local Mobile vs. Companion Gateway)

- **Status**: Accepted historically; **Mode B (Companion Gateway) superseded by ADR-010** — the app now hosts all protocols in-process. Mode A is unaffected.
- **Context**: Mobile OS platforms (iOS & Android) enforce strict networking policies (blocking inbound server ports <1024, terminating background TCP servers, aggressive battery sleep).
- **Decision**: Architect the system to support two distinct operating modes:
  - **Mode A (Local Mobile Simulator)**: Runtime embedded directly in the mobile app via FFI for self-contained simulation.
  - **Mode B (Companion Gateway Mode)**: Companion desktop/server process hosts industrial protocol servers (OPC UA, Modbus, DNP3) while synchronizing with the mobile app via WebSockets.
- **Rationale**: Solves mobile operating system networking constraints while retaining full SCADA connectivity for virtual commissioning.
- **Consequences**: Protocol adapters must interact strictly through the Tag Database API, remaining agnostic to whether they run locally or on a companion gateway.

---

## ADR-004: Internal Instruction Model for Multi-Language Support

- **Status**: Accepted
- **Context**: IEC 61131-3 defines 5 control languages (ST, LD, FBD, SFC, IL). Writing separate execution engines for each language leads to duplicated runtime logic.
- **Decision**: All language parsers compile down to a unified **Internal Instruction Set Architecture (ISA)** representation (Contacts, Coils, Branches, Timers, Function Blocks) executed by a single `ScanEngine`.
- **Rationale**: Ensures uniform scan behavior, simplifies testing, and decouples language parsing from scan execution.

---

## ADR-005: JSON File Storage for Projects & Protocol Mappings

- **Status**: Accepted
- **Context**: Need a human-readable, portable, and easily editable project format for saving controller configurations, tag tables, logic programs, and protocol mappings.
- **Decision**: Use standard **JSON** format validated against JSON Schemas (`/shared/schemas`).
- **Rationale**: Easily inspected, edited in text editors, parsed in Rust (`serde_json`) and Dart (`dart:convert`), and versioned in Git.

---

## ADR-006: Node-and-Wire Graph Model for Ladder Diagrams

- **Status**: Accepted
- **Context**: The original LD model stored rungs as flat instruction lists with whole-row "parallel branches," which could not express an OR wrapped around an arbitrary span of contacts.
- **Decision**: Represent each rung as a **graph of nodes** (rails, contacts, coils, blocks) joined by **wires** referencing node ports — series is a wire chain; a parallel (OR) branch is multiple wires converging on one input.
- **Rationale**: Mirrors the PLCopen TC6 `connectionPointIn`/`refLocalId` structure used by standard IEC tooling; branches can span any element range and their endpoints can be re-pointed (draggable re-span); layout is derived (columns via longest-path), not stored.
- **Consequences**: Editor enforces the coil-terminal invariant (nothing after a coil; coils pinned against the right rail); execution evaluates the same graph directly (ADR-009).

---

## ADR-007: Derived Path-Resolved Structured Tags (DUT-Typed Tags Replace Data Blocks)

- **Status**: Accepted
- **Context**: Struct members (`TONTimer.DN`), integer bits, and array elements were faked or hardcoded; "Data Blocks" duplicated the struct-instance concept alongside tags.
- **Decision**: A tag's `value` holds a real tree (struct = `Map`, array = `List`, bit-holder = `int`); members/bits/elements are addressed by path (`.field`, `.N`, `[i]`) and resolved on demand by a pure resolver (`readPath`/`writePath`/`childrenOf`). A struct-typed tag **is** the instance; the separate Data Block concept was removed. Built-in composites (`TIMER`) are implicit DUTs.
- **Rationale**: Single source of truth, no parent/child sync, recursive nesting for free, one addressing scheme shared by logic, HMI bindings, forcing, and UI expansion.
- **Consequences**: Numeric struct-field names are reserved (bit disambiguation); persistence must eventually serialize `structDefs`/`arrayLength` (deferred to the persistence phase).

---

## ADR-008: Data-Driven Simulated I/O Rules Engine

- **Status**: Accepted
- **Context**: How simulated inputs behaved (photo-eye pulses, temperature ramps) was hardcoded per project inside the scan loop — invisible and uneditable.
- **Decision**: A per-project list of **SimRules** (behaviours: `pulse`, `ramp`, `integrate`, `delayedSet`, `setWhileCondition`; AND-combined conditions with literal or tag operands) applied each scan by a pure engine, edited in a dedicated Simulated I/O screen.
- **Rationale**: Rates are **per-second** (scan-speed independent); rules are visible, editable, and per-rule toggleable; manual forcing always overrides; the hardcoded physics migrated into default rules with behavior parity.
- **Consequences**: Only rate/condition behaviours are expressible (no random jitter primitive); OR/grouped conditions deferred.

---

## ADR-009: Direct Graph Interpretation for In-App Execution (vs. Compile-to-ST/C)

- **Status**: Accepted
- **Context**: Reference IEC runtimes compile graphical languages to Structured Text, then to C, executed in a fixed scan cycle with a per-tick PLC clock. The in-app simulator runs in Flutter (incl. web) with no C toolchain and needs an instant edit→run loop plus meaningful pause/step debugging.
- **Decision**: Execute the LD graph **directly** with a pure Dart power-flow interpreter: nodes evaluated in topological (column) order, input power = OR of inbound wires (series therefore ANDs), writes visible to later rungs, `TON`/`TOF` state living in the real `TIMER` struct tags, and **timer time advancing by scan ticks** (dt per scan).
- **Rationale**: Mathematically identical boolean semantics to the compile-to-ST route; interpretation gives live editing and deterministic step debugging (time freezes when paused — matching the reference runtime's per-tick clock advance); performance is ample at simulator scale.
- **Consequences**: Complements ADR-004 — the unified-ISA compilation strategy remains the Rust core's design for native deployments, while the in-app Dart engines interpret; the two must preserve identical observable scan semantics.

---

## ADR-010: In-App Protocol Hosting (Pure Dart) — Companion Gateway Retired

- **Status**: Accepted (supersedes ADR-003's Mode B as the primary architecture)
- **Context**: The product goal was clarified: a **single mobile-first app** (desktop secondary) that itself hosts the outbound industrial protocol servers (OPC UA, Modbus TCP, MQTT, DNP3) — no companion service or second process. The WS16–18 companion gateway (a separate Rust process bridged over WebSocket) works technically but violates "the app is the host." Research confirmed there is **no Dart/Flutter OPC UA library** (client or server); the ecosystem's only answers are gateways or FFI to native stacks — FFI is untestable in this dev environment (native Flutter builds are toolchain-gated) and adds per-platform build complexity.
- **Decision**: Implement the protocol servers **in pure Dart, inside the app**, reading the tag database directly (force-aware writes):
  - **OPC UA**: a hand-rolled minimal server subset over `opc.tcp` — Security Policy `None` + anonymous, Hello/Ack, OpenSecureChannel, Session, GetEndpoints, Browse, Read, Write (v1); Subscriptions/MonitoredItems (v2); encryption later if warranted.
  - **Modbus TCP / MQTT**: pure Dart (`ServerSocket` / MQTT client).
  - **DNP3**: a minimal pure-Dart outstation subset, later.
- **Rationale**: Pure Dart is the only path satisfying all three constraints at once — single app (no companion, no FFI), runs on Android + iOS + desktop from one codebase, and fully machine-testable in this environment (Dart unit tests + the Rust `opcua` **client** retained as a third-party E2E verification harness, run via `cargo`).
- **Consequences**:
  - The companion gateway process is retired; the `gateway/` crate is kept **only** as a dev-time test-client harness (its client E2E proved the harness works, branch `feat/opcua-hardening`).
  - The app's WebSocket `GatewayClient`/tag-sync path is removed once in-app hosting replaces it in the UI; `OpcuaMap`/`ProtocolSettings` (per-project protocol config) carry over unchanged.
  - v1 OPC UA is unencrypted (`None`) — appropriate for LAN commissioning/training and the simulator positioning; a hand-rolled stack targets client compatibility (UAExpert + common SCADA), not OPC Foundation certification.
  - iOS hosts servers only while the app is foregrounded (OS constraint, independent of implementation).
