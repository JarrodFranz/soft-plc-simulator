# IEC 61131-3 Language Support Specifications

The Soft PLC Simulator provides support for IEC 61131-3 programmable controller languages:

1. **Structured Text (ST)**: Pascal-like textual programming language ([STRUCTURED_TEXT.md](STRUCTURED_TEXT.md)).
2. **Ladder Diagram (LD)**: Relay-logic graphic representation ([LADDER_LOGIC.md](LADDER_LOGIC.md)).
3. **Function Block Diagram (FBD)**: Graphic signal-flow diagrams ([FUNCTION_BLOCK_DIAGRAM.md](FUNCTION_BLOCK_DIAGRAM.md)).
4. **Sequential Function Chart (SFC)**: State-machine sequential flow ([SEQUENTIAL_FUNCTION_CHART.md](SEQUENTIAL_FUNCTION_CHART.md)).

All four are **edited and executed in-app**. Each language has its own pure-Dart
executor — `ld_exec.dart`, `fbd_exec.dart`, `st_exec.dart`, and `sfc_exec.dart`
— which the scan tick runs against the shared tag database once per scan, in
task-priority order (see [`../task-scheduling.md`](../task-scheduling.md)). The
executors are deterministic (no wall clock, no randomness) and force-aware.

The pages here describe each *language*; for the shipped **editor** behaviour
see [`../ld-editor.md`](../ld-editor.md) (ladder canvas, branches, Go-Online
monitoring) and [`../sfc-branching.md`](../sfc-branching.md) (2D SFC charts,
alternative and parallel fork/join branching, the multi-token engine, and
Go-Online step highlighting).

> Historical note: the original Phase-0 design compiled every language into a
> single instruction model executed by a Rust `ScanEngine`. That was superseded
> by ADR-010 — the Rust runtime remains in `runtime/` but the app executes all
> logic in-process in Dart.
