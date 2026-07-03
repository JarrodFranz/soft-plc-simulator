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

- **Status**: Accepted
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
