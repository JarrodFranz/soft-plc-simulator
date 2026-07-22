# LD Graphical Translator — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-22
**Depends on:** the PLCopen import foundation (`mobile/lib/import/*`), including the
captured graphical `GraphBody` IR and connection **pin identity**
(`IrConnection.toPin`/`fromPin`).

## Goal

Turn an imported PLCopen **Ladder Diagram** POU — currently mapped to an empty
**stub** program — into a real, editable *and executable* `LadderLogic`
program in the app's native LD model, so an imported ladder both renders in the
editor and runs correctly in the scan engine.

This is **sub-project 1 of 3** graphical translators (LD now; FBD and SFC are
separate later specs). It is the first consumer of the pin-identity capture.

## North-star decisions (from brainstorming)

1. **Per-rung correctness-first.** Each rung is translated *fully faithfully or
   not at all*. A rung containing any element/topology the app can't represent
   exactly becomes a **commented placeholder rung + a warning**; every rung that
   IS translated is trustworthy and runs correctly. Nothing is silently wrong.
2. **Full app-LD-capability coverage.** Translate everything the app's LD engine
   already executes: contacts (normal/negated/rising/falling), coils
   (normal/negated/set/reset), power rails, single-level parallel branches, and
   function blocks `TON/TOF/TP`, `CTU/CTD/CTUD`, `GT/LT/GE/LE/EQ/NE`,
   `ADD/SUB/MUL/DIV/MOVE`. Rungs using anything outside this set stub.

## Global constraints

- **Pure Dart, in-app** (ADR-010). The translator is a pure, deterministic,
  never-throws graph→graph function — no Flutter, no I/O, no clock, no RNG.
- **Additive / backward-compatible.** Only the LD branch of the import mapping
  changes; FBD/SFC keep stubbing untouched. The `GraphBody`/`IrConnection` IR is
  unchanged.
- **Never crashes on untrusted input.** A rung the translator can't handle
  becomes a placeholder, never an exception.
- **Zero `flutter analyze` warnings.**
- **Behavioral fidelity is the bar:** a translated rung, run by the existing
  `ld_exec`, must produce the same logic as the source rung.

## Architecture & hook-in (§1)

- **New pure module** `mobile/lib/import/ld_translate.dart`:
  ```dart
  class LdTranslation {
    final List<LdRung> rungs;            // every rung, translated or placeholder
    final List<ImportWarning> warnings;  // one per stubbed rung + any element notes
    final int translatedRungCount;       // rungs faithfully translated
    final int stubbedRungCount;          // rungs that became placeholders
  }
  LdTranslation translateLdBody(GraphBody body, {required String pouName});
  ```
  It returns the rung list + warnings + counts; it does **not** build the
  `PlcProgram` (that stays in the mapper), keeping it a pure body translator.
  `rungs` includes placeholder rungs so the program's rung numbering matches the
  source; `translatedRungCount > 0` is the mapper's "real program vs whole-POU
  stub" decision.
- **Hook point:** `mobile/lib/import/ir_to_project.dart`, the POU loop's
  `GraphBody` branch (which today always stubs — `ir_to_project.dart` lines
  ~135-148). For `pou.lang == PouLanguage.ld`, call `translateLdBody`. If it
  yields ≥1 real rung, emit a **real** `PlcProgram(language: 'LadderLogic',
  rungs: …)`; fold its warnings into the report. If it yields zero real rungs,
  keep the existing whole-POU stub. FBD/SFC POUs are unchanged (still stub).
- **Contract preserved:** pure, deterministic, never throws.

## Rung segmentation (§2)

**Rungs = connected components once the power rails are removed.**

1. Index nodes by `localId`; classify `leftPowerRail`/`rightPowerRail` as rails.
   Before removing them, record each non-rail node's rail attachment (touches
   left rail = rung start; touches right rail = rung end).
2. Remove rail nodes; compute **connected components** over the remaining nodes
   (edges undirected for this step). Each component = one candidate rung.

This handles the canonical cases automatically:
- `[A]-(C)` and `[B]-(D)`, no shared elements → two components → two rungs.
- `[A]‖[B] → (C)` (parallel contacts, one coil) → one component → one rung with
  a parallel branch.
- `[A]-[B]` splitting to `(C)` and `(D)` → one component → **one rung with
  stacked coils**, shared series path kept once.

**Ordering:** rungs emitted top-to-bottom by each component's minimum element
`y` (ties: `x`, then `localId`). PLCopen `x`/`y` are used *only* for ordering;
the app re-derives geometry.

**Component stub triggers (correctness-first):** no coil/output (the app
requires coil-terminated rungs); not connected to the left rail (floating);
branch structure nested/complex beyond single-level parallel (the row-lane model
can't express it). A stubbed component becomes a commented placeholder rung + a
warning naming the reason; the POU's other rungs still translate.

## Per-element mapping (§3)

The connection **`toPin`** distinguishes a **power** connection (→ `LdWire`)
from a **data** connection into a block operand pin (→ folds into
`operandA`/`operandB`/preset, *not* a wire). This is what makes blocks
translatable.

| PLCopen element | → App | Detail |
|---|---|---|
| `leftPowerRail` / `rightPowerRail` | rail nodes `L` / `R` | fixed ids, one pair per rung |
| `contact` | `LdKind.contact` | `variable` = bound tag; `modifier` from `negated`/`edge` → `normal`/`negated`/`rising`/`falling` |
| `coil` | `LdKind.coil` | `variable` = bound tag; `modifier` from `negated`/`storage`(set/reset)/`edge` |
| `block` (`typeName` ∈ supported set) | `LdKind.block` | `blockType` = mapped `typeName`; `variable` = instance name; operands/preset per below |
| `inVariable` | *folded* | its literal/tag becomes the consuming block's `operandA`/`operandB` or preset — never its own node |
| `outVariable` | *folded* | the tag it captures becomes the producing block's destination `variable` |
| connection into a power/boolean pin | `LdWire` | rung series/parallel path (rail→contact→…→coil; block `EN`/`IN`/`Q`) |
| connection into a data pin (`IN1`,`IN2`,`PT`,`PV`) | operand fold | resolved via `toPin`, not a wire |

**Blocks:**
- Timers `TON/TOF/TP`: `PT` literal (`T#5s`) parsed to `presetMs` via a small
  IEC-duration parser; `IN` is the power wire; `Q` drives downstream.
- Counters `CTU/CTD/CTUD`: preset from `PV`; `CU/CD/R/LD` from wired inputs.
- Compares `GT/LT/GE/LE/EQ/NE`: `operandA`/`operandB` from `IN1`/`IN2`; power =
  `inP && result`.
- Math/`MOVE` `ADD/SUB/MUL/DIV/MOVE`: operands from inputs; destination
  `variable` from the `outVariable`/output tag.

**Node IDs:** derived from PLCopen `localId` (`n<localId>`) so wires reference
stable ids; rails use `L`/`R`. Deterministic.

**Element-level stub triggers (add to §2's list):** `typeName` outside the
supported set; a contact/coil carrying an unsupported modifier *combination*
(e.g. negated **and** edge — the app stores a single modifier); a data pin fed
by something that isn't a resolvable literal/tag; an unparseable duration/preset.
Any of these stubs the whole rung.

## Execution correctness, reporting & testing (§4)

**Faithfulness reduces to** correct element mapping, correct power-vs-data wire
classification, and correct branch/row assignment (sequential on one lane = AND;
alternative paths on separate lanes = OR — exactly `ld_exec`'s power model).
Layout (columns) and execution reuse the app's existing, tested helpers
(`ld_graph.dart` `buildRung`/`colAssignment`, `ld_exec.dart`).

**Timer/counter instance backing (a real requirement).** A translated
`TON`/`CTU`/… block references an instance variable whose structured members
(`.ACC`,`.DN`,`.CV`,…) the engine reads/writes. In PLCopen those instances are
the POU's local vars, which the mapper currently drops. The translator must
**ensure each timer/counter instance it emits is backed by a tag of the app's
`TIMER`/`COUNTER` type, creating it if absent** — scoped to the instances the LD
translator actually uses, not general local-var surfacing.

**Warnings & report.** Each stubbed rung emits a `warning`-level `ImportWarning`
naming the POU, rung ordinal, and reason (unsupported `typeName` / complex
topology / no coil / unresolved operand). `ImportReport` gains `stubbedRungCount`
(total across POUs). A POU with ≥1 real rung is a translated program, not a
whole-POU stub; `graphicalStubCount` continues to count whole-POU stubs
(all-rungs-stubbed LD POUs, and all FBD/SFC POUs).

**Existing tests that will change:** any that assert an LD POU imports as a stub
(e.g. `basic.xml`'s `Rung1`, the import-flow test's `graphicalStubCount`) are
updated to the new reality (a translatable LD rung becomes a real program).

**Testing strategy.**
- **Pure unit tests** on `translateLdBody`, using small PLCopen LD fixtures
  parsed via `parsePlcOpen`, each asserting *both* the produced
  `LdRung`/`LdNode`/`LdWire` structure *and* correct behavior when run through
  `ld_exec` (behavioral fidelity): series-AND, parallel-OR, stacked coils, every
  contact/coil modifier, a `TON` with `T#5s`, a counter, a compare, a `MOVE`.
- **Stub-path tests:** unsupported block `typeName`; nested/complex branching;
  no-coil component; a POU mixing translatable + stubbed rungs → partial
  translation + correct `stubbedRungCount` + warnings.
- **Determinism test:** same input → identical output.
- **Integration:** `mapImportedProject` over a PLCopen LD fixture → a real
  `LadderLogic` program that renders and runs.
- **Real corpus:** after shipping, run the local corpus LD samples
  (`twincat_kamil_LD_Evolution_4.xml`, Beremiz LD POUs) through and record the
  translate-vs-stub rate — exploratory validation, not hard assertions.

## Out of scope / deferred

- **FBD and SFC translators** — separate later sub-projects.
- **Unknown/user function blocks** in ladder — stub-the-rung for now; a future
  block-support expansion + re-import picks them up.
- **Honoring PLCopen pixel coordinates** for layout — the app re-derives
  geometry; coordinates are used only for rung ordering.
- **Nested/complex branch topology** beyond single-level parallel — stubbed.
- **General POU local-variable surfacing** — only timer/counter instance tags
  needed by translated rungs are created here.
