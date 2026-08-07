# IEC 61131-3 Specification: Sequential Function Chart (SFC)

Sequential Function Chart partitions control logic into steps, transitions, and actions for sequential state machine execution.

## SFC import (PLCopen and Rockwell L5X → native SequentialFunctionChart)

An imported SFC POU — from PLCopen TC6 **or** from a Rockwell L5X
`<Routine Type="SFC">` — translates as a whole through one shared translator:
the entire chart (steps, transitions, conditions, topology) becomes a native
chart, or the whole POU stays a stub (faithful-or-stub). An unrepresentable
step **action** degrades to a no-op with a warning (chart flow is preserved).

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

### L5X (`<SFCContent>`) specifics

The L5X dialect reaches the same translator through its own parser front-end
(`_l5xSfcBody` in `mobile/lib/import/l5x_parser.dart`). Two structural
contrasts with PLCopen drive everything else:

- **Actions nest inside their step** (`<Step><Action Qualifier="N">`), where
  PLCopen wires a sibling `<actionBlock>` to the step.
- **Links are a flat `<DirectedLink FromID ToID>` list**, where PLCopen carries
  each edge on the target element's `connectionPointIn`.

| L5X source | Native mapping |
| --- | --- |
| `<Step Operand InitialStep>` | `SfcStep` |
| `<Action Qualifier="N">` (nested) | that step's `actionSt`, in document order |
| `<Step>` with a direct `<Body><STContent>` and no `<Action>` | one implicit `N` action |
| `<Transition><Condition><STContent>` | `conditionSt` (one trailing `;` stripped) |
| `<Branch BranchType="Selection">` | `selDiv` + `selConv` pair → `single` transitions (first-true-wins) |
| `<Branch BranchType="Simultaneous">` | `simDiv` + `simConv` pair → `parallelFork` / `parallelJoin` |
| `<DirectedLink>` | a chart edge |
| loop-back link | an ordinary edge (Logix has no jump element) |

**Branch-pair synthesis.** L5X models a branch as one `<Branch>` element with
`<Leg>` children; the native model wants a *pair* of connector nodes. The
importer synthesizes that pair and derives its wiring from the links alone:
a link naming a `<Leg>` resolves by direction (out of a leg = the divergence
feeds that leg's head; into a leg = that leg's tail feeds the convergence),
and a link naming the `<Branch>` resolves by the other endpoint's kind
(selection diverges into transitions and converges out to a step; simultaneous
is the mirror). `BranchFlow` is read but not trusted — the links win, and a
contradiction is reported as an info warning. Step-separated nested branches
translate; only connector-adjacent ones (a leg head or tail that is itself a
branch) are unrepresentable.

**Step timing has no native equivalent.** Logix steps carry `Preset`,
`LimitHigh` and `LimitLow` (each with a `*UsesExpr` companion) — a step timer
plus high/low residence limits. `SfcStep` is `{id, name, isInitial, actionSt}`
and has no timer, so these are dropped with one info warning per meaningful
attribute (a `Preset="0"`, which Logix writes on nearly every step, is silent).

> **Recovering a dropped preset by hand.** `STEP_T` — elapsed time in the
> currently active step, in milliseconds — is injected into every transition
> condition. A step that carried `Preset="5000"` becomes faithful again by
> writing `STEP_T >= 5000` on its outgoing transition (or `AND`-ing it into an
> existing condition). The importer deliberately does not synthesize this: it
> would rewrite logic the user did not author.

**L5X-specific degrades**, each an info warning with the chart still
translating: `IsBoolean="true"` actions (no deactivation hook, so assigning
`TRUE` would latch the bit forever), `<Action>`s with an empty or absent body,
and non-`N` qualifiers (which ride the shared cross-dialect degrade).

Proven end-to-end for L5X in
`mobile/test/import/import_l5x_sfc_e2e_test.dart`.
