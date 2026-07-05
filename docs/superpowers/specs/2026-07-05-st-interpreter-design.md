# Structured Text Interpreter (WS4d) — Design Spec

**Date:** 2026-07-05
**Status:** Approved by delegation (user: "continue to ws4d"; the one product
fork — proj_tank ownership — resolved by the user: keep FBD, drop the redundant
ST).
**Author:** Claude (pairing with Jarrod)

Final execution workstream. LD (WS4a), SFC (WS4b), and FBD (WS4c) are merged;
the scan pipeline is sim → LD → FBD → SFC → the last hardcoded remainder
(`workspace_shell._evaluateActiveLogic`). This workstream executes Structured
Text programs and **retires `_evaluateActiveLogic` entirely** — every default
project's logic then runs through a real engine.

## Problem

ST programs carry real `stSource` (the `st_editor_screen` shows and edits it)
but nothing executes it. Three ST programs exist, and each currently duplicates
logic owned elsewhere:

- **`ReactorTemp_ST`** (`proj_st_reactor`) — the reactor deadband controller,
  duplicated by the hardcoded `proj_st_reactor` branch in `_evaluateActiveLogic`.
- **`Safety_ST`** (`proj_all_water`) — assigns `Quality_OK` (now owned by
  `WaterQuality_FBD`), `Alarm_Active` + `System_Ready` (hardcoded in
  `_evaluateActiveLogic`), and `Treat_Dosing` (owned by `PumpControl_LD` rung 2).
- **`TankLevelControl_ST`** (`proj_tank`) — duplicates `TankLevel_FBD`, which
  was made the tank's authoritative controller in the prior follow-up.

Executing ST naively would double-drive these tags. The workstream assigns **one
authoritative owner per output tag** and trims/removes ST that overlaps another
engine's domain.

## What the shipped programs dictate (the ST subset to support)

`ReactorTemp_ST` is the demanding case:

```
IF Auto_Mode THEN
    IF Temp_PV < (Temp_SP - 2.0) THEN
        Heat_Cmd := TRUE; Cool_Cmd := FALSE;
    ELSIF Temp_PV > (Temp_SP + 2.0) THEN
        Heat_Cmd := FALSE; Cool_Cmd := TRUE;
    ELSE
        Heat_Cmd := FALSE; Cool_Cmd := FALSE;
    END_IF;
ELSE
    Heat_Cmd := FALSE; Cool_Cmd := FALSE;
END_IF;
Alarm_High := Temp_PV > 95.0;
...
Reactor_Ready := NOT Alarm_High AND NOT Alarm_Low
             AND (Temp_PV >= Temp_SP - 2.0) AND (Temp_PV <= Temp_SP + 2.0);
```

So the interpreter needs: **`IF … THEN … [ELSIF … THEN …]* [ELSE …] END_IF;`
(nested)**, **`path := expr;` assignments**, **`;` terminators**, **`(* *)` and
`//` comments**, and **multi-line boolean/comparison/arithmetic expressions**.
All *expression* semantics (precedence, `AND`/`OR`/`XOR`/`NOT`, comparators,
`+ - * /`, parens, tag paths, `TRUE`/`FALSE`, numeric truthiness, never-throws)
already exist in **`st_expr.dart`** (WS4b). WS4d adds only the **statement
layer** on top and reuses `st_expr` for every expression.

## Architecture

### 1. ST statement interpreter (`mobile/lib/models/st_exec.dart` — new, pure Dart)

```dart
class StRuntime { void clear(); } // reserved for future stateful ST (timers)
void executeStPrograms(PlcProject p, int dtMs, StRuntime rt);
```

Per `language == 'StructuredText'` program with non-empty `stSource`, each scan:

1. **Strip comments** (`(* *)`, `//`) — reuse the same approach as `st_expr`.
2. **Tokenize** into a flat token list. Each token records its `text` and its
   `start`/`end` offsets into the comment-stripped source. Token kinds:
   keywords `IF`/`THEN`/`ELSIF`/`ELSE`/`END_IF` (case-insensitive), `:=`, `;`,
   and everything else is an *expression token* (identifiers incl.
   dotted/indexed paths, numbers, operators, parens). Identifier lexing matches
   `st_expr` so paths stay intact.
3. **Parse** a statement list (recursive for nested `IF`):
   - **assignment** — `pathToken := <expr tokens> ;`. The path is the leading
     identifier token; the RHS is every token up to the terminating `;`.
   - **if** — `IF <cond tokens> THEN <stmts> [ELSIF <cond> THEN <stmts>]*
     [ELSE <stmts>] END_IF ;`. Branch bodies are nested statement lists.
   - Unrecognized/garbage statements are skipped (never throw).
4. **Execute** the statement list top-to-bottom:
   - assignment → `evalExpr(p, source.substring(rhsStart, rhsEnd))`; if the
     result is non-null, **force-aware write** to the path (skip when the root
     tag is forced and `path == root.name`, same helper as `ld/fbd/sfc_exec`).
   - if → evaluate each condition in order via
     `evalStCondition(p, source.substring(condStart, condEnd))`; execute the
     first true branch's statements, else the `ELSE` branch (if any). Nested
     `IF`s recurse.

Because expression regions are passed to `st_expr` as **exact source
substrings** (via offsets, not token rejoin), spacing/paths/multi-line
expressions evaluate identically to how `st_expr` already handles them.
Never throws; never hangs (bounded statement list, no loops in the subset).

Pure Dart; imports only `project_model.dart`, `st_expr.dart`, `tag_resolver.dart`.

### 2. Scan pipeline (`workspace_shell.dart`)

`_executeScan`: sim → `executeLdPrograms` → `executeFbdPrograms` →
`executeSfcPrograms` → **`executeStPrograms`** (last). ST runs last so its
supervisory reads (`System_Ready` needs this-scan `Quality_OK` from FBD and
`Pump_Motor` from LD) see fresh values. `_stRuntime.clear()` joins the other
runtime clears on project switch.

**`_evaluateActiveLogic` is deleted** — after the migration below it has no
remaining body. Its call site is removed. Any `_getTag*`/`_setTag*` helpers or
locals left unused after the deletion are removed (zero analyze issues).

### 3. Migration (one authoritative owner per tag)

**`proj_st_reactor` — ST becomes owner.** `ReactorTemp_ST` executes as-is; delete
the hardcoded `proj_st_reactor` branch from `_evaluateActiveLogic`. It writes
`Heat_Cmd`/`Cool_Cmd`/`Alarm_High`/`Alarm_Low`/`Reactor_Ready` — the same set the
deleted branch wrote.

> Benign refinement (flag, don't fix): `Reactor_Ready` in ST is
> `NOT Alarm_High AND NOT Alarm_Low AND in-deadband`; the old hardcoded used
> `!heat && !cool && in-deadband`. Identical across the reactor's operating
> range (deadband is SP±2 around ~50 °C, never near the 95/5 alarm trips); the
> ST form is the intended, more explicit logic. Same class of "the diagram/text
> is now the source of truth" refinement accepted in WS4c.

**`proj_all_water` — trim `Safety_ST` to its own domain.** Edit its `stSource`
to keep only the genuinely ST-domain supervisory outputs and drop what other
engines own:
- KEEP: `Alarm_Active := (NOT EStop) OR (Level_PV < 5.0) OR (Turbidity_PV > (Turbidity_SP + 5.0));`
  and `System_Ready := Pump_Motor AND Quality_OK AND NOT Alarm_Active;`.
- REMOVE: the `Quality_OK := …` line (owned by `WaterQuality_FBD`) and the
  `IF Pump_Motor AND NOT Quality_OK THEN Treat_Dosing := TRUE; …` block (owned
  by `PumpControl_LD` rung 2).
- Delete the hardcoded `Alarm_Active`/`System_Ready` writes (and the now-unused
  `qualityOk`/`pumpRun`/`estop` locals) from `_evaluateActiveLogic`.

> Note the deliberate parity choice: the old hardcoded `Alarm_Active` used
> `Turbidity_PV > (Turbidity_SP + 8.0)`; the shipped `Safety_ST` text uses
> `+ 5.0`. Executing the ST makes `+5.0` authoritative (a slightly earlier
> turbidity alarm). This is the ST program the editor shows the user, so it is
> the correct source of truth; flag it as a small, intentional behavior change.

**`proj_tank` — remove the redundant ST (user decision: keep FBD).** Delete the
`TankLevelControl_ST` program from `proj_tank.programs` and its entry in the
task `programNames`. `TankLevel_FBD` remains the authoritative controller; no
ST executes for the tank, so no double-drive.

After migration, `_evaluateActiveLogic` is empty → remove the method and its
call.

## Behavior parity

- Reactor: identical outputs in normal operation (the `Reactor_Ready` nuance
  above never diverges in range).
- Water: `Alarm_Active` threshold moves 8.0 → 5.0 (intentional, ST is the source
  of truth); `System_Ready` unchanged in form; `Quality_OK`/`Treat_Dosing`
  keep their existing FBD/LD owners (no change).
- Tank: unchanged (FBD already owns it since the prior follow-up).

## Testing

- `mobile/test/st_exec_test.dart` (pure): assignment lists; single `IF/THEN`;
  `IF/ELSIF/ELSE/END_IF` (each branch selected); **nested IF**; multi-line
  expression assignment (`NOT a AND (x >= y)` across lines); `(* *)` and `//`
  comments; force-aware write (forced tag not overwritten); malformed source
  skipped without throwing; non-ST / empty-source programs skipped.
- `mobile/test/st_exec_integration_test.dart` (pure): scan the real
  `proj_st_reactor` through sim → ST and assert the reactor truth table
  (heat/cool/alarms/ready across auto/manual and cold/hot/in-band/over-temp);
  scan the real `proj_all_water` through sim → LD → FBD → ST and assert
  `Alarm_Active`/`System_Ready` track their formulas, `Quality_OK` is still
  FBD-driven, and `Treat_Dosing` is still LD-driven (ST does not touch either).
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints (unchanged)

No third-party/reference-editor branding · dark theme · `flutter analyze` zero
issues · no RenderFlex overflow · forcing always wins · scan-tick clocks ·
engines are pure Dart in `mobile/lib/models`, UI-free. Behavior parity with the
removed hardcoded logic except the two flagged, intentional refinements
(reactor `Reactor_Ready` form; water `Alarm_Active` 8.0→5.0).

## Out of scope (deferred)

- ST loops (`FOR`/`WHILE`/`REPEAT`), `CASE`, function/FB calls and declarations,
  `VAR` blocks — no shipped program uses them; the subset is IF + assignment.
- Stateful ST (in-body timer/counter instances) — `StRuntime` is reserved but
  unused this release.
- Executing SFC step actions through `st_exec` (they stay on WS4b's
  `runStatements`, which already covers their flat assignment lists).
- The ST editor already exists (autocomplete, syntax) — no editor changes.
