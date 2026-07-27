# Non-ST AOI Logic — RLL half + shared scoped-FB infra (L5X sub-project 3) — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-27

## Goal

Make **RLL-bodied Rockwell AOIs execute** their ladder logic when imported,
instead of the current empty-`stSource` no-op — and build the **shared
scoped-FB-execution infrastructure** that FBD-bodied AOI logic will reuse
later. This is L5X sub-project 3, scoped per brainstorming:

- **In scope:** ladder-bodied `FbDefinition`s (model + serialization), a
  **scoped ladder executor** (the ladder analog of `StScope`), dispatch in
  `executeFbInstance`, runtime plumbing through both engine call sites, and
  the AOI import path (RLL `Logic` routine → compiled ladder FB body).
- **Deferred:** FBD-bodied AOI logic — it cannot be built until the L5X FBD
  front-end (sub-project 4) exists to parse the AOI's FBD routine; it will
  slot into this same infrastructure with a scoped FBD executor afterwards.

**Corpus note (recorded honestly):** every AOI in the available Rockwell
corpus is ST-bodied, so this feature is provable only against handcrafted
fixtures. The user chose to build it anyway (completeness for real customer
projects, which use RLL AOIs heavily); the e2e tests are spec-faithful
handcrafted L5X.

## North-star decisions (from brainstorming)

1. **Native ladder FB body, not RLL→ST transpile.** The app's ST subset is
   IF + assignment only — timers, `OTL`/`OTU` latches, and edge instructions
   cannot be expressed in it, so transpiling an AOI's ladder to ST would be
   lossy/wrong. Instead `FbDefinition` carries an optional native ladder body
   executed by a **scoped** ladder executor. This also mirrors exactly what
   FBD-AOI will need (scoped FBD executor on the same dispatch).
2. **Sequencing: RLL-AOI now (+ shared infra), FBD-AOI after sub-project 4.**
3. **Reuse everything shipped:** the RLL compiler (`compileRllRungs`) produces
   the ladder body; `executeRung` (ld_exec) executes it; `executeFbInstance`
   remains the single FB entry point for both engines.

## Why this shape (grounded in the codebase)

- `executeFbInstance` (`models/fb_exec.dart`) is the single FB execution
  entry: writes inputs to `instance.var`, runs `runScopedStBody(p,
  fb.stSource, StScope(instance, varNames))`, reads outputs back. Both
  engines call it (`ld_exec.dart` FB-call block; `fbd_exec.dart` `_evalBlock`
  custom-FB branch). A ladder body slots in as a second dispatch branch.
- `StScope` (`models/st_exec.dart`) is the scoping precedent:
  `rewrite(path)` maps a path whose root segment is one of the FB's var
  names to `instancePath.path`, else leaves it global. The ladder analog
  (`LdScope`) is the same three lines of logic.
- `executeRung` (`models/ld_exec.dart`) resolves every reference via
  `readPath`/`_forceAwareWrite`/`_operandValue` against global paths and
  keeps only edge/pulse prev-state in `LdExecRuntime.prevBool`, keyed
  `"program|rungIndex|nodeId"` (timer/counter state lives in the instance
  tag's own members, e.g. `$base.ACC`). Scoping = rewriting those paths;
  per-instance edge state = an instance-derived program-key.
- `compileRllRungs` (`import/rll_compile.dart`, PR #15) already turns RLL
  neutral text into `LdRung`s — including AOI-call nodes — with
  faithful-or-stub semantics. The AOI import reuses it verbatim.
- `mapImportedFbs` (`import/fb_import.dart`) builds `FbDefinition`s from
  `functionBlock` POUs with a growing registry; it currently accepts only
  `TextBody`. The L5X parser's `_l5xAois` currently inlines an ST `Logic`
  routine and emits `TextBody('')` + a warning for non-ST logic.

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never-throws** — an AOI whose
  ladder cannot compile degrades to the existing empty-body no-op + warning.
- Zero `flutter analyze` warnings (run flutter from `mobile/`).
- **Additive / backward-compatible:** every existing ST-bodied FB, the
  PLCopen import path, and all L5X foundation/RLL behavior are unchanged. A
  project with no ladder-bodied FB behaves byte-identically. `FbDefinition`
  JSON round-trips; old saved projects (no `ladder_rungs` key) load
  unchanged.
- The `xml` package stays confined to the parsers; `rll_compile.dart` and the
  executors stay Flutter-free.

## §1 — Model: `FbDefinition.ladderRungs`

```dart
class FbDefinition {
  String name;
  List<FbVar> vars;
  String stSource;
  List<LdRung> ladderRungs;   // NEW — default const []; non-empty => ladder-bodied
  ...
}
```

- JSON: `'ladder_rungs': [rung.toJson()...]`; `fromJson` defaults to `[]`
  when the key is absent (old projects load unchanged). `LdRung` already
  round-trips (used by `PlcProgram.rungs`).
- **Discriminator:** `ladderRungs.isNotEmpty` → ladder-bodied FB (the
  `stSource` path is skipped); empty → the existing ST path, byte-identical.
- The FB editor UI is NOT extended: a ladder-bodied FB shows its (empty) ST
  source; editing/viewing ladder FB bodies in the editor is a DEFERRED row.

## §2 — Scoped ladder executor (`models/ld_exec.dart`)

```dart
/// Scopes ladder execution to one FB instance: bare references to the FB's
/// own vars resolve/write against `<instancePath>.<var>` instead of a global
/// tag path. Mirrors StScope (st_exec.dart) exactly.
class LdScope {
  final String instancePath;
  final Set<String> localVars;
  LdScope(this.instancePath, this.localVars);
  String rewrite(String path) {
    final root = path.split('.').first.split('[').first;
    return localVars.contains(root) ? '$instancePath.$path' : path;
  }
}
```

`executeRung` gains an optional `LdScope? scope`, applied at **every**
tag-path resolution site in the rung executor: contact/coil `n.variable`
reads/writes, `_operandValue` operand resolution (a numeric literal still
parses first — literals are never rewritten), timer/counter `$base.*` member
paths (rewrite `base` itself, i.e. the instance-local timer tag `T` becomes
`Aoi1.T` so its `.ACC`/`.PRE` members land inside the AOI instance), MOVE/math
destination writes, and FB-call `pinBindings` values (so a nested FB call
inside an AOI binds the AOI's own vars). `scope == null` (every existing
caller) is byte-identical to today.

**Runtime keying:** the AOI body's rungs are executed with the runtime
program-key `'fb:$instanceName'` (instead of a program name). Sanitized
program names cannot contain `:`, so `'fb:'`-prefixed keys can never collide
with real program keys, and two instances of the same AOI get disjoint
edge/pulse state for free.

## §3 — Dispatch + runtime plumbing

`executeFbInstance` (`models/fb_exec.dart`) gains optional parameters:

```dart
Map<String, dynamic> executeFbInstance(
    PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs,
    {int dtMs = 0, LdExecRuntime? ldRt});
```

- Steps 1 (write inputs) and 3 (read outputs) are unchanged.
- Step 2 dispatches: `fb.ladderRungs.isNotEmpty` → run each rung via the
  scoped executor with `LdScope(instanceName, fbVarNames)`, program-key
  `'fb:$instanceName'`, the given `dtMs`, and `ldRt ?? LdExecRuntime()` (an
  ephemeral fallback — both engine call sites always pass a real runtime, so
  the fallback is unreachable in the scan; if ever hit, only edge/pulse
  detection degrades). Placeholder rungs (rails + one wire) execute as
  harmless no-ops. Else → the existing `runScopedStBody` path, unchanged.
- **Call-site threading:**
  - `ld_exec.dart` FB-call block: already holds `dtMs` and its
    `LdExecRuntime rt` → passes both. (Nested AOI-in-AOI recursion reuses the
    same runtime; keys stay disjoint per instance.)
  - `fbd_exec.dart` `_evalBlock` custom-FB branch: holds `dtMs`;
    `executeFbdPrograms` gains an optional `LdExecRuntime? ldRt` threaded
    down to `_evalBlock` → passed to `executeFbInstance`.
  - `scan_tick.dart`: passes the **same** `LdExecRuntime` it already creates
    for LD programs into `executeFbdPrograms` (instance-prefixed keys keep
    AOI-body state disjoint from program-rung state). SFC/ST paths untouched.
- `readOnly` handling matches the ST path (not threaded into FB bodies —
  unchanged parity).

## §4 — AOI import: RLL `Logic` → ladder body

- **Parser** (`l5x_parser.dart` `_l5xAois`): when the AOI's Logic routine is
  `Type="RLL"`, capture its rungs exactly as `_l5xRoutines` does and emit the
  functionBlock POU with `body: NeutralLadderBody(rungs)` (instead of
  `TextBody('')` + warning). FBD/SFC logic keeps the existing
  `TextBody('')` + "logic not yet translated" warning (deferred). ST logic
  unchanged.
  - **EnableIn/EnableOut (RLL-logic AOIs only):** instead of skipping them,
    retain them as **internal** `FbVar`s (`BOOL`, `EnableIn` initialValue
    `true`, `EnableOut` `false`). Rockwell RLL AOI logic commonly references
    `XIC(EnableIn)`; because the body only runs when the call executes,
    `EnableIn = true` during execution is the faithful mapping. Keeping them
    as vars makes those references resolve per-instance via `LdScope` instead
    of silently falling through to absent globals. ST-logic AOIs keep the
    existing skip (backward-compat).
- **Mapper** (`fb_import.dart` `mapImportedFbs`): gains a `NeutralLadderBody`
  branch (alongside the existing `TextBody` branch): compile via
  `compileRllRungs(body, pouName: <AOI name>, fbRegistry: <registry so far>,
  fbRenameMap: <rename map so far>)` and set
  `FbDefinition(ladderRungs: tr.rungs, stSource: '')`.
  - ≥1 rung compiled → the AOI executes (stubbed rungs are inert
    placeholders, warnings surfaced).
  - 0 rungs compiled → `ladderRungs: []` (falls back to today's no-op) + a
    warning naming the AOI.
  - The compile's rung counts / `unsupportedInstructions` / `stubReasons`
    are returned on an extended `FbImportResult` and folded by
    `mapImportedProject` into the **existing RLL report fields**
    (`translatedRllRungCount` etc.) — AOI-body rungs are RLL rungs; no new
    preview UI.
  - **AOI-in-AOI ordering:** the registry grows in document order, so an AOI
    ladder calling an AOI defined *later* in the file has that rung stub as
    an unknown mnemonic (inventoried). Rockwell exports list dependencies
    first, so this is rare; documented as a limitation.
- **PLCopen path:** `parsePlcOpen` never produces a `NeutralLadderBody` FB
  POU, so the `mapImportedFbs` change is inert for PLCopen — byte-identical.

## §5 — Error handling (pure, never-throws)

| Situation | Handling |
|---|---|
| AOI `Logic` is RLL, some/all rungs compile | `ladderRungs` = compiled rungs; AOI executes (placeholders inert) |
| AOI `Logic` is RLL, **no** rung compiles | Empty `ladderRungs` → existing no-op + warning naming the AOI |
| AOI `Logic` is FBD/SFC | Empty body + "logic not yet translated" warning (deferred) |
| `XIC(EnableIn)` etc. in an RLL AOI body | Resolves per-instance (EnableIn internal var, default true) |
| Timer/counter local inside an AOI ladder | Executes scoped (`Aoi1.T.ACC`); inherits the RLL best-effort preset deferral |
| AOI ladder calls an AOI defined later in the file | That rung stubs (unknown mnemonic, inventoried) — ordering limitation |
| Empty instance name | `executeFbInstance` already refuses (returns `{}`) — unchanged |
| Missing/unresolvable scoped path at runtime | Reads 0/false, exactly like a missing global (executeRung is never-throws) |

## §6 — Testing

- **Scoped executor unit** (ld_exec tests): `LdScope.rewrite` maps an FB-var
  root (incl. `x.y` / `x[i]`) to `instance.x...`, leaves globals untouched; a
  rung `XIC(In)OTE(Out)` executed with `LdScope('A1', {In, Out})` reads
  `A1.In` / writes `A1.Out` and does NOT touch same-named globals; a
  scope-null call is byte-identical to today (regression).
- **Dispatch unit** (fb_exec tests): an `FbDefinition` with `ladderRungs`
  (e.g. compare + MOVE ladder implementing a threshold) runs via
  `executeFbInstance` — inputs in, outputs back; **two instances** run
  independently (separate instance members AND separate `'fb:$instance'`
  edge keys — prove with an edge contact that must fire per-instance); a
  ladder FB with a scoped TON accumulates in `inst.T.ACC` across scans with
  `dtMs`.
- **Model round-trip:** `FbDefinition` with `ladderRungs` JSON round-trips;
  an ST-bodied FB serializes/loads byte-identically to before (old JSON
  without the key loads).
- **Import unit** (`fb_import`/`l5x_parser` tests): an RLL-Logic AOI parses
  to a `NeutralLadderBody` functionBlock POU with EnableIn/EnableOut retained
  as internal vars; `mapImportedFbs` compiles it to `ladderRungs`; a
  0-compiled AOI falls back to no-op + warning; PLCopen FB import unchanged.
- **End-to-end** (`import_l5x_aoi_ladder_e2e_test.dart`): a handcrafted L5X
  with an RLL-Logic AOI (`XIC(EnableIn)MOV(In,Out);` or an ADD), an AOI-typed
  controller tag, and a program rung calling it → `parseL5x` →
  `mapImportedProject` → `executeLdPrograms` scan drives the instance's
  ladder and the output member/bound tag is correct; a second instance stays
  independent.
- **Backward-compat:** the whole suite stays green (ST FBs, PLCopen import,
  L5X foundation/RLL, serialization round-trips).

## §7 — Docs

- `docs/iec61131/FUNCTION_BLOCKS.md` — ladder-bodied FBs: what they are, how
  they execute (scoped, per-instance state), that the editor doesn't edit
  them yet.
- `docs/import/L5X.md` — RLL-Logic AOIs now execute; FBD/SFC-Logic AOIs
  remain interface-only; EnableIn/EnableOut semantics note.
- `docs/DEFERRED.md` — strike the "non-ST AOI logic" row for the RLL half
  (note the e2e path); add/keep rows: **FBD-bodied AOI logic** (after L5X FBD
  front-end, sub-project 4, via a scoped FBD executor on this infra); AOI
  `Prescan`/`Postscan`/`EnableInFalse` routines (only `Logic` runs);
  AOI-in-AOI forward-reference ordering; FB editor for ladder-bodied FBs;
  predefined `TIMER`/`COUNTER` type fidelity (shared with the RLL compiler).

## §8 — Deferred (tracked in `docs/DEFERRED.md`)

- **FBD-bodied AOI logic** — blocked on the L5X FBD front-end (sub-project
  4); then a scoped FBD executor reuses §2/§3's infrastructure.
- **AOI auxiliary routines** (`Prescan`/`Postscan`/`EnableInFalse`) — only
  the main `Logic` routine executes.
- **AOI-in-AOI forward references** — callee must precede caller in the file.
- **FB editor support for ladder bodies** — view/edit UI.
- **Predefined `TIMER`/`COUNTER` type mapping** — shared RLL deferral.
