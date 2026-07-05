# SFC Execution Engine (WS4b) — Design Spec

**Date:** 2026-07-05
**Status:** Approved by delegation (user: "continue with WS4b"; decisions made
per the established parity-first approach)
**Author:** Claude (pairing with Jarrod)

Second execution workstream. WS4a (ladder execution) is merged; the scan
pipeline is sim inputs → LD programs → remaining hardcoded logic. FBD (WS4c)
and full ST (WS4d) come later.

## Problem

SFC programs are editable charts (steps with ST action snippets, transitions
with ST condition strings) but nothing executes them. Two hardcoded state
machines remain in `workspace_shell._evaluateActiveLogic`: the bottle filler
(`proj_sfc_filling`, driven off `Sfc_Step`/`Step_Delay` tags) and the water
plant's backwash valve/pump sequencing — plus the WS4a leftover: a deliberate
`Backwash_Active` shadow-write kept "until SFC execution (WS4b)".

## What the shipped data dictates

The default SFC programs' strings define the required language subset:

- Conditions: `Start_Cmd`, `Bottle_Present`, `Fill_Level >= 95.0`,
  `NOT Backwash_Active`, `Quality_OK  (* turbidity clearing *)`,
  `TRUE  (* 1s cap press timer *)`.
- Actions: `Fill_Valve := TRUE;`, `Filled_Count := Filled_Count + 1;`,
  multi-line statement lists with `//` comments.

So: identifiers are **tag paths** (dotted/indexed, via the WS2 resolver),
literals `TRUE`/`FALSE`/numbers, boolean ops `AND`/`OR`/`NOT` (and `XOR`),
comparators `=` `<>` `<` `>` `<=` `>=`, arithmetic `+ - * /`, parentheses,
assignments `path := expr;`, and **comments `(* ... *)` and `// ...`
stripped**. Timed transitions currently carry their intent only in comments
(`TRUE (* 5s timer *)`) — execution introduces the IEC-style implicit
**`STEP_T`** (elapsed ms in the active step, advanced by scan ticks like every
other clock in the app) and the defaults are migrated to real conditions
(`STEP_T >= 3000`).

## Architecture

### 1. ST-subset evaluator (`mobile/lib/models/st_expr.dart` — new, pure Dart)

The deliberate seed of WS4d's full interpreter. Public API:

```dart
/// Evaluates an ST expression against the project's tags (plus [extraVars],
/// e.g. {'STEP_T': 1200}). Returns bool/num/String, or null on any parse or
/// resolution error (never throws).
dynamic evalExpr(PlcProject p, String source, {Map<String, dynamic> extraVars});

/// True if [source] evaluates truthy (true, or non-zero number).
bool evalCondition(PlcProject p, String source, {Map<String, dynamic> extraVars});

/// Executes a statement list of `path := expr;` assignments through [write].
/// Comments and blank lines are skipped; a malformed statement is skipped
/// (never throws).
void runStatements(PlcProject p, String source,
    void Function(String path, dynamic value) write,
    {Map<String, dynamic> extraVars});
```

Implementation: hand-rolled lexer (strips `(* *)` block and `//` line
comments; case-insensitive keywords/operators) + recursive-descent parser with
precedence `OR` < `XOR` < `AND` < `NOT` < comparison < additive <
multiplicative < unary minus < primary. Identifiers resolve via `extraVars`
first, then `readPath`. Numeric comparison coerces `num`; `=`/`<>` also
compare bools. Division by zero → null.

### 2. SFC engine (`mobile/lib/models/sfc_exec.dart` — new, pure Dart)

```dart
class SfcRuntime {
  Map<String, String> activeStepId; // keyed by program name
  Map<String, int> stepElapsedMs;
  void clear();
}

void executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt);
```

Per `language == 'SequentialFunctionChart'` program, each scan:

1. If no active step (first scan / after `clear()`), activate the step with
   `isInitial == true` (else the first step); elapsed = 0.
2. **Run the active step's `actionSt`** via `runStatements` (IEC "N" action
   semantics — every scan while active), with force-aware writes (a forced
   root tag is never overwritten; same helper pattern as `ld_exec`).
3. `elapsed += dtMs`; evaluate the active step's outgoing transitions in list
   order via `evalCondition` with `extraVars: {'STEP_T': elapsed}`. The first
   true transition deactivates the current step and activates its target
   (elapsed resets to 0). The new step's action runs from the next scan.

Unknown `toStepId` → transition is ignored (no throw). Programs with no steps
are skipped.

### 3. Scan pipeline (`workspace_shell.dart`)

`_executeScan`: sim inputs → `executeLdPrograms` → **`executeSfcPrograms`** →
`_evaluateActiveLogic` (now only FBD/ST-domain leftovers). `_sfcRuntime`
cleared on project switch alongside the sim/LD runtimes.

### 4. Migration (replace the hardcoded state machines)

**`proj_sfc_filling`** — delete the whole hardcoded block. Update the default
`BottleFill_SFC` steps/transitions for full parity at the default scan speed:

- Every step action gains `Sfc_Step := N;` (0-4) so the existing HMI/tag
  display stays live, data-driven (no engine special-casing). `Step_Delay`
  keeps existing but is no longer written (superseded by `STEP_T`).
- `WAIT_BOTTLE` action gains `Fill_Level := 0.0;` — reproduces the
  per-bottle reset on the WAIT→FILLING edge (safe as an N-action: the fill
  valve is closed in that step, so the sim rule isn't raising the level).
- `CAPPING → EJECTING` condition becomes `STEP_T >= 3000` (was 6 scans at the
  500 ms default); `EJECTING → COUNT` becomes `STEP_T >= 2000` (4 scans).
- **One-shot increments use the one-scan-step pattern.** N-actions repeat
  every scan, so `Filled_Count := Filled_Count + 1;` cannot live in a dwell
  step's action. A dedicated **`COUNT` step** is inserted between EJECTING and
  WAIT_BOTTLE: its action is
  `Filled_Count := Filled_Count + 1;\nEject_Cyl := FALSE;\nSfc_Step := 5;` and
  its outgoing transition is `TRUE` — the engine runs the action once, then
  the step switches on the same scan's transition evaluation (taking effect
  next scan), so the step is active for exactly one scan and the increment
  executes exactly once per bottle. (This is the standard SFC idiom for
  pulse actions given N-only qualifiers.)

**`proj_all_water`** — delete the hardcoded `Backwash_Active`,
`Backwash_Valve`, `Backwash_Pump` writes (and the WS4a shadow-write comment).
Rung 4 (`BackwashTimer.DN → OTE Backwash_Active`) now genuinely drives
`Backwash_Active`; `FilterBackwash_SFC` sequences the valve/pump: its timed
placeholders become `STEP_T >= 5000` (valve open) and `STEP_T >= 10000`
(rinse). Keep the hardcoded `Quality_OK` (FBD, WS4c) and
`Alarm_Active`/`System_Ready` (ST, WS4d) writes.

**Deliberate behavior change (flagged):** backwash now starts only after the
ladder's 30 s `BackwashTimer` persistence delay instead of instantly on bad
quality — transient turbidity spikes no longer trigger a backwash. This is the
fully-executed end-state the WS4a code comment explicitly deferred to WS4b.

## Testing

- `mobile/test/st_expr_test.dart` (pure): literals/identifiers/extraVars;
  comparator set; AND/OR/NOT precedence with parens; arithmetic incl.
  `Filled_Count + 1`; comment stripping (`(* *)`, `//`); malformed input →
  null/false, never throws; `runStatements` multi-line assignment lists with
  comments; truthiness.
- `mobile/test/sfc_exec_test.dart` (pure): initial-step activation; N-action
  runs each scan; transition on condition; `STEP_T` timing fires at the
  threshold and resets on entry; first-true-transition-wins ordering; forced
  target not overwritten; step switch takes effect next scan (one-scan COUNT
  step pattern executes its action exactly once).
- Integration (`ld_exec_integration_test.dart` or a new sfc integration file):
  full bottle cycle on the real `proj_sfc_filling` — start, bottle arrives,
  fills to 95 via the sim rule, caps 3 s, ejects 2 s, `Filled_Count`
  increments exactly 1 per bottle across two consecutive cycles, `Sfc_Step`
  tag tracks the active step; water-plant backwash end-to-end: bad quality →
  30 s ladder timer → `Backwash_Active` → SFC opens valve, pumps, rinses,
  closes when quality recovers.
- Full suite green; analyze zero; web build.

## Global constraints (unchanged)

No third-party/reference-editor branding · dark theme · `flutter analyze`
zero issues · no RenderFlex overflow · parity with removed hardcoded logic at
the default scan speed (except the flagged backwash-start delay) · scan-tick
clocks · forcing wins.

## Out of scope (deferred)

- Parallel/simultaneous SFC branches (single active step per program — matches
  the editor's linear chart model).
- `IF`/loops/function calls in the ST subset (WS4d).
- FBD execution (WS4c) — `Quality_OK` stays hardcoded until then.
- Stored/set/reset SFC action qualifiers (N-only, matching the editor's label).
