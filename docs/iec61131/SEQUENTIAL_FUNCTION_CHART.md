# IEC 61131-3 Specification: Sequential Function Chart (SFC)

Sequential Function Chart partitions control logic into steps, transitions, and actions for sequential state machine execution.

## SFC import (PLCopen → native SequentialFunctionChart)

An imported SFC POU translates as a whole: the entire chart (steps, transitions,
conditions, topology) becomes a native chart, or the whole POU stays a stub
(faithful-or-stub). An unrepresentable step **action** degrades to a no-op with a
warning (chart flow is preserved).

| Source | Native mapping |
| --- | --- |
| `<step>` (name, initialStep) | `SfcStep`; N-qualified actions → `actionSt` |
| linear `step→transition→step` | `SfcTransition(kind:'single')` |
| `<selectionDivergence>` | multiple `single` transitions from one step (first-true-wins) |
| `<simultaneousDivergence>` / `<simultaneousConvergence>` | `parallelFork` / `parallelJoin` |
| `<jumpStep targetName>` | `single` transition to the named step |
| transition condition — inline ST / `<reference>` to an ST transition | `conditionSt` |
| step action — inline ST / `<reference>` to an ST action, qualifier N | `actionSt` |

Stubbed (whole POU) — with the `sfcStubReasons` key: a wired transition condition
(`wired-condition`); a condition referencing a graphical/missing body
(`unresolved-condition`); complex/unsupported topology, unknown jump target
(`complex-topology`); a chart with no steps (`no-initial`). Degraded (no-op +
warning): non-N action qualifiers (S/R/P/L/D/…); actions referencing a
graphical/missing body.

Proven end-to-end (parse → map → translate → execute), including a
referenced-ST transition condition and a referenced-ST step action, in
`mobile/test/import/import_sfc_e2e_test.dart`.
