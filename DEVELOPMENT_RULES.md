# Development Rules for Human & AI Developers

These rules are mandatory for all human developers and LLM AI agents contributing code or documentation to the `soft-plc-simulator` repository.

---

## 📜 Core Guidelines

1. **Read Core Documentation First**:
   - Always read `PROJECT_BRIEF.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `DECISIONS.md`, and `SECURITY_AND_SAFETY.md` before initiating major refactors or new features.

2. **Strict Decoupling of Architecture**:
   - **UI Layer (`/mobile` widgets/screens)**: Must NOT contain protocol handling or simulation/execution logic. The standalone simulator's engines live in **`/mobile/lib/models`** as **pure Dart modules** (tag path resolver, simulated-I/O rules engine, ladder execution engine — see ADR-009): they must stay free of Flutter imports, be unit-testable in isolation, and preserve the same observable scan semantics as the Rust core so they remain replaceable by it.
   - **Runtime Core (`/runtime`)**: Must remain independent of Flutter/Dart UI imports. Communication must happen strictly through clean APIs or FFI boundaries.
   - **Protocol Adapters (`/gateway` & `/docs/protocols`)**: Must read and write tag values ONLY through the `TagDatabase` API. Never inject protocol-specific logic into the scan engine.

3. **No Safety Certification Claims**:
   - NEVER present or describe this application as a production safety-certified PLC (SIL/IEC 61508). Always maintain simulator warnings in UI, logs, and documentation.

4. **Zero Secret Hardcoding**:
   - Do NOT commit credentials, tokens, private keys, certificates, or passwords to Git.
   - Use environment variables or external configuration files for protocol auth.

5. **Buildability & Test Passing**:
   - All generated code MUST compile cleanly without warnings.
   - Before committing, execute `cargo test` in `/runtime` and `flutter test` in `/mobile`. All unit and integration tests must pass.

6. **Deterministic Scan Cycle Hygiene**:
   - In the runtime core, avoid blocking I/O, synchronous network calls, or allocation inside the scan loop.
   - Scan cycle logic must be fast, deterministic, and non-blocking.

7. **Consistent Terminology**:
   - Use standard terminology throughout code, comments, and documentation:
     - `Soft PLC`, `Runtime Core`, `Scan Cycle`, `Tag Database`, `I/O Image`, `Simulated Input`, `Simulated Output`, `Force`, `Companion Gateway`, `Ladder Logic`, `Structured Text`.

8. **Incremental Commits & Documentation Updates**:
   - Keep commits small, focused, and well-described.
   - Update `ARCHITECTURE.md`, `ROADMAP.md`, and relevant protocol docs whenever structural changes are made.
