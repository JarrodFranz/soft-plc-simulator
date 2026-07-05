# FBD Execution Engine (WS4c) — Design Spec

**Date:** 2026-07-05
**Status:** Approved by delegation (user: "start WS4c, plan then straight into
implementation"; design decisions made per the established parity-first,
usability-optimal approach)
**Author:** Claude (pairing with Jarrod)

Third execution workstream. WS4a (ladder) and WS4b (SFC) are merged; the scan
pipeline is sim inputs → LD → SFC → remaining hardcoded logic. This workstream
executes Function Block Diagrams; the full ST interpreter (WS4d) comes last.

## Problem

FBD programs are editable dataflow graphs (`FbdBlock` nodes + `FbdWire`
edges) but nothing executes them. Two hardcoded blocks remain in
`workspace_shell._evaluateActiveLogic`: the HVAC zone controller
(`proj_fbd_hvac`: `Hvac_Active`, `Fan_Cmd`, `Heat_Cmd`, `Cool_Cmd`) and the
water plant's `Quality_OK` gate (`proj_all_water`).

### Why the shipped graphs can't be executed as-drawn

The `FbdBlock`/`FbdWire` model is deliberately minimal — a block has a `type`
string and a single `tagBinding`; a wire is just `fromBlockId → toBlockId`
with **no port index**. The shipped default diagrams were drawn as *visual
approximations*, not executable logic:

1. **HVAC can't split heat from cool.** As drawn, both `Heat_Cmd` (f_a2) and
   `Cool_Cmd` (f_a3) are `AND(hvacEnable, NOT("Temp In Range"))` off the *same*
   `LIMIT` block — identical formulas. The hardcoded logic distinguishes them
   (`temp < sp-1` vs `temp > sp+1`); the graph structurally cannot.
2. **`LIMIT` is misused as a bound-less comparator.** IEC `LIMIT(MN, IN, MX)`
   is a 3-input numeric clamp; the diagrams use it as "in range?"/"< SP?" with
   two inputs and no bounds — undefined to execute.
3. **`Flow_PV` double-drive.** The water FBD has `AND(Pump_Motor) → TAG_OUTPUT
   Flow_PV`, but `Flow_PV` is a **SimulatedInput** already driven by sim rules
   `sim4`/`sim5` (numeric L/min). Executing that branch would write a bool onto
   the analog flow every scan, fighting the sim engine.

So faithful execution requires the block set to be able to *express* the real
control logic. The design enriches the executable block vocabulary (comparators
+ constant), redraws the two shipped diagrams to be correct **and behaviorally
identical to the hardcoded logic**, and drops the spurious `Flow_PV` branch.

## Approach (chosen)

**Execute a proper dataflow graph with an enriched, well-defined block set,
and migrate the two default diagrams to faithful executable form.** This is
the usability-optimal outcome: the FBD editor's diagrams actually run and
correctly implement the logic, rather than the engine faithfully executing an
under-specified picture. No `FbdBlock`/`FbdWire` model classes change — the
enrichment is new `type` string values the executor and editor palette
understand.

Rejected alternatives: (a) execute-as-drawn — impossible per above, and would
regress HVAC and double-drive `Flow_PV`; (b) change the wire model to carry
port indices — larger churn than needed; deterministic wire-order input
semantics (below) suffice for the shipped graphs and the editor.

## Architecture

### 1. FBD engine (`mobile/lib/models/fbd_exec.dart` — new, pure Dart)

```dart
void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt);

class FbdRuntime {
  // Reserved for stateful blocks (e.g. TON) — empty for the combinational
  // blocks the shipped diagrams use. Cleared on project switch.
  void clear();
}
```

For each `language == 'FunctionBlockDiagram'` program, each scan:

1. **Topological order.** Compute an evaluation order over `fbdBlocks` using
   `fbdWires` as dependency edges (a block evaluates after every block that
   feeds it), via longest-path layering like the LD column assignment. Source
   blocks (`TAG_INPUT`, `CONST`) have no inputs. If a cycle is detected
   (shipped graphs are acyclic), break it deterministically and continue — the
   engine must never hang.
2. **Evaluate each block** to a cached `dynamic` output (bool or num):
   - `TAG_INPUT` → `readPath(p, tagBinding)`.
   - `CONST` → parse `tagBinding` (`"10.0"`→num, `"TRUE"`/`"FALSE"`→bool);
     null if unparseable.
   - `AND` / `OR` → boolean fold of inputs (truthiness: bool, or num≠0);
     `AND` of no inputs = false.
   - `NOT` → boolean invert of the single input.
   - `ADD` / `SUB` / `MUL` / `DIV` → numeric, **input order = the order of the
     matching `fbdWires` entries** (see below); `SUB`/`DIV` are left-fold;
     divide-by-zero → null.
   - `GT` / `LT` / `GE` / `LE` / `EQ` / `NE` → numeric compare of the first two
     inputs (wire order) → bool.
   - `LIMIT` → proper IEC clamp `LIMIT(MN, IN, MX)` (3 inputs, wire order) → num.
   - `TAG_OUTPUT` → write the single input's value to `tagBinding`, **force-aware**
     (skip when the root tag is forced and `path == root.name`, same helper as
     `ld_exec`/`sfc_exec`). Null input → no write.
   - Unknown type / missing input → the block yields null and writes nothing
     (never throws).
3. **Input ordering rule (deterministic):** a block's ordered inputs are the
   cached outputs of `w.fromBlockId` for each `w in fbdWires where
   w.toBlockId == block.id`, in `fbdWires` list order. This is stable, matches
   how the editor appends wires, and is what the migrated diagrams rely on for
   the non-commutative blocks (`SUB`, comparators, `LIMIT`).

Pure Dart; imports only `project_model.dart` and `tag_resolver.dart`.

### 2. Scan pipeline (`workspace_shell.dart`)

`_executeScan`: sim inputs → `executeLdPrograms` → **`executeFbdPrograms`** →
`executeSfcPrograms` → `_evaluateActiveLogic` (now only the ST-domain
leftovers). FBD runs **before** SFC so the water backwash's `Quality_OK`
transition reads this scan's freshly-computed value (tightens the prior
1-scan lag). `_fbdRuntime.clear()` joins the sim/LD/SFC runtime clears on
project switch.

### 3. Migration (replace the hardcoded blocks)

**`proj_fbd_hvac`** — redraw `HvacControl_FBD` so execution reproduces the
hardcoded logic exactly, then delete the hardcoded `proj_fbd_hvac` branch:
- Enable: `NOT(Window_Open)` → `AND(Occupied, …)` = `hvacEnable` →
  `TAG_OUTPUT Fan_Cmd` and `TAG_OUTPUT Hvac_Active`. (Unchanged — already
  faithful: `Fan_Cmd = Hvac_Active = occupied && !windowOpen`.)
- Heat: `CONST 1.0`, `SUB(Setpoint, 1.0)` = spLo, `LT(Room_Temp, spLo)`,
  `AND(hvacEnable, that)` → `TAG_OUTPUT Heat_Cmd` (= `temp < sp-1`).
- Cool: `CONST 1.0`, `ADD(Setpoint, 1.0)` = spHi, `GT(Room_Temp, spHi)`,
  `AND(hvacEnable, that)` → `TAG_OUTPUT Cool_Cmd` (= `temp > sp+1`).
- The misused `LIMIT`/`NOT`-in-range chain (f_l1/f_n2) is replaced by the
  comparator chains above.

**`proj_all_water`** — redraw `WaterQuality_FBD` for `Quality_OK` and drop the
`Flow_PV` branch; delete the hardcoded `Quality_OK` write:
- `LT(Turbidity_PV, Turbidity_SP)` = turbOk; `CONST 10.0`,
  `GT(Level_PV, 10.0)` = lvlOk; `AND(turbOk, lvlOk)` → `TAG_OUTPUT Quality_OK`
  (= `turbidity < turbSP && level > 10.0`).
- **Remove** `wf_i4`/`wf_a2`/`wf_o2` (the `Pump_Motor → AND → Flow_PV` branch)
  and their wires: `Flow_PV` is a simulated analog input owned by `sim4`/`sim5`
  and must not be written by the FBD. This fixes a latent double-drive.

Remaining hardcoded after WS4c: `proj_tank` fill/drain (its own logic —
follow-up), `proj_st_reactor` (ST — WS4d), and `proj_all_water`
`Alarm_Active`/`System_Ready` (ST — WS4d).

### 4. Editor palette (`fbd_editor_screen.dart`)

Add palette entries for the new executable block types so the editor and
executor agree: `CONST`, `GT`, `LT`, `GE`, `LE`, `EQ`, `NE`, `MUL`, `DIV`.
(`AND`/`OR`/`NOT`/`ADD`/`SUB`/`LIMIT`/`TON`/`TAG_INPUT`/`TAG_OUTPUT` already
present.) `CONST`'s value is entered via the existing block `tagBinding`
field (label it "value/const"). Rendering uses the existing generic block
box; no new widget. Keep dark theme, no RenderFlex overflow, zero analyze
issues. `TON` in FBD remains display-only this workstream (no shipped diagram
uses it; stateful-block execution is deferred and documented).

## Behavior parity

No behavior change. The hardcoded HVAC and `Quality_OK` logic were correct;
the migrated diagrams reproduce them bit-for-bit at every scan
(`hvacEnable`, `Fan_Cmd`, `Hvac_Active`, `Heat_Cmd = temp<sp-1`,
`Cool_Cmd = temp>sp+1`, `Quality_OK = turb<SP && level>10`). The only
observable differences are improvements: the on-screen HVAC diagram now
correctly distinguishes heat from cool, `Quality_OK` updates same-scan (was
+1 scan), and `Flow_PV` is no longer at risk of an FBD bool overwrite.

## Testing

- `mobile/test/fbd_exec_test.dart` (pure): TAG_INPUT read; CONST parse
  (num/bool/garbage→null); AND/OR/NOT truthiness incl. numeric inputs and
  empty AND; ADD/SUB/MUL/DIV incl. wire-order for SUB and divide-by-zero→null;
  each comparator GT/LT/GE/LE/EQ/NE on wire-ordered inputs; LIMIT clamp
  (below/within/above); TAG_OUTPUT write + force-aware skip; topological
  ordering across a multi-layer graph; a cycle terminates without hanging;
  non-FBD/empty programs skipped.
- `mobile/test/fbd_exec_integration_test.dart` (pure): scan the real
  `proj_fbd_hvac` through sim→LD→FBD and assert the full truth table
  (occupied/window/temp combinations → `Hvac_Active`/`Fan_Cmd`/`Heat_Cmd`/
  `Cool_Cmd`) matches the old hardcoded formulas; scan the real
  `proj_all_water` and assert `Quality_OK` tracks `turb<SP && level>10` and
  `Flow_PV` is driven only by the sim rules (FBD leaves it untouched).
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints (unchanged)

No third-party/reference-editor branding in any string/label/comment/identifier
· dark theme · `flutter analyze` zero issues · no RenderFlex overflow · parity
with the removed hardcoded logic at the default 500 ms scan · scan-tick clocks
· forcing always wins · engines are pure Dart in `mobile/lib/models`, UI-free.

## Out of scope (deferred)

- Stateful FBD blocks (`TON`/counters) — no shipped diagram uses them; needs a
  per-block state store (WS-later). Documented, palette entry stays but is not
  executed.
- Port-indexed wires / an editor port-reorder UI — deterministic wire-order
  input semantics suffice for now.
- FBD feedback loops (cycles) beyond safe termination.
- `proj_tank` and the ST-domain leftovers (`proj_st_reactor`, water
  `Alarm_Active`/`System_Ready`) — WS4d.
