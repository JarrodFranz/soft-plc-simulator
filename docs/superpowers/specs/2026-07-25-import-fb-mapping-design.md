# Import Mapping — Custom Function Blocks (sub-project 2) — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-25

## Goal

Wire the just-shipped native custom-function-block capability into the PLCopen
importer so real exports that use user function blocks translate instead of
stubbing. Two coupled halves:

1. **FB-definition mapping:** an imported PLCopen `functionBlock` POU with a
   Structured-Text body becomes a native `FbDefinition` (typed interface + ST
   body) on the project — not a standalone program.
2. **LD call routing:** a rung block whose `typeName` names an imported FB
   translates to an FB-call node (`blockType = FB name`, `variable = instance`,
   wired `pinBindings`) with a struct-typed instance tag — instead of the
   current `unsupported-block` stub.

This is the "import payoff" that follows the native FB capability
(`docs/superpowers/specs/2026-07-23-custom-function-blocks-design.md`).

## North-star decisions (from brainstorming)

1. **ST-bodied FBs only.** A `functionBlock` POU with an ST body maps to a real,
   executable `FbDefinition`. A `functionBlock` POU with a **graphical** body
   (LD/FBD/SFC) is **not** imported as an FB — a warning is emitted and its body
   remains captured in the IR only. (Graphical FB bodies are a separately
   deferred item; native FBs execute ST only.)
2. **Registry-passing.** The mapper builds the `FbDefinition`s first, then passes
   a `name → FbDefinition` registry into the LD translator so a call block
   resolves to an instance. `ld_translate` stays pure; no post-processing pass.
3. **LD routing only, this sub-project.** The FBD import translator does not
   exist yet (FBD POUs fully stub), so FBD calls to FBs still stub — deferred.

## Why this shape (grounded in the codebase)

- The importer is a pure IR→project mapper (`lib/import/ir_to_project.dart`);
  the vendor-neutral IR (`import_ir.dart`) already captures `functionBlock`
  POUs with `kind == PouKind.functionBlock`, their typed `localVars`
  (`VarScope.input/output/inOut/local/temp`), and their `PouBody`
  (`TextBody` for ST). Today the POU→program loop ignores `pou.kind`, so a
  functionBlock POU wrongly becomes a program and its interface is discarded.
- The native model already provides everything the target needs: `FbDefinition`
  / `FbVar` / `FbVarDir { input, output, internal }`
  (`models/project_model.dart`), `createFbInstanceTag` + `uniqueFbInstanceName`
  (`models/fb_instance.dart`), the reserved-name guard
  `fbNameValidationError(p, name, {excluding})` (`models/fb_name_validation.dart`,
  keyed on `kFbdBuiltinBlockTypes` / `kLdBuiltinBlockTypes`), and the LD FB-call
  execution path (`LdNode.blockType`/`variable`/`pinBindings`, `ld_exec.dart`).
- The LD translator already stubs unknown blocks: `_kSupportedBlocks` gates the
  `typeName`; a miss adds to `unsupportedBlockTypes` and throws `_StubException`.
  The parser captures every `<block>` attribute generically (so `typeName` and
  `instanceName` are present) and carries pin identity on each `IrConnection`
  (`toPin`/`fromPin` = PLCopen `formalParameter`).

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never throws** — every
  untranslatable POU/rung/pin degrades to a stub + warning, exactly like today.
- Zero `flutter analyze` warnings. Run flutter from `mobile/`.
- **Additive / backward-compatible:** a project with no function blocks imports
  byte-identically to today. The new FB pass and the LD registry fire only when
  `functionBlock` POUs / FB-call blocks are present. Existing import tests stay
  green.
- Follows the importer's established name discipline: sanitize identifiers,
  dedup, avoid `System`, warn on every rename — and propagate a rename to every
  reference.

## §1 — FB-definition mapping (`ir_to_project.dart`)

A new pass runs after structs + global vars and **before** the POU→program
loop, producing (a) the project's `fbDefinitions` and (b) an `fbRegistry`
(`Map<String, FbDefinition>`, keyed by final FB name) for the LD translator.

For each `pou` with `pou.kind == PouKind.functionBlock`:

- **Graphical body** (`GraphBody`): emit
  `ImportWarning(warning, 'Function block "<name>" has a graphical body (<lang>) — not imported (ST-bodied FBs only). <n> elements captured.')`
  and skip. Do **not** emit it as a program.
- **ST body** (`TextBody`): build an `FbDefinition`:
  - `name`: sanitized + collision-resolved (below).
  - `vars`: one `FbVar` per `localVar`, in declaration order:
    - `VarScope.input` → `FbVarDir.input`
    - `VarScope.output` → `FbVarDir.output`
    - `VarScope.local` / `VarScope.temp` / `VarScope.external` / `VarScope.global`
      → `FbVarDir.internal`
    - `VarScope.inOut` → `FbVarDir.input` **plus** an info warning
      (`'VAR_IN_OUT "<var>" on FB "<name>" imported as an input (by-reference semantics unsupported).'`)
    - `dataType`: `normalizeType(baseType, knownDutNames)` (reuses the existing
      DUT-aware normaliser — an FB var typed as an imported struct resolves).
    - `initialValue`: `coerceInitialValue(...)` against the structs-known scratch
      project (same call the struct/var passes use).
  - `stSource`: the POU's `TextBody.source`, verbatim. If the POU's `lang` is
    IL, add the existing "imported from IL as ST — verify" info warning. (An ST
    body beyond the app's ST subset is imported as-is; it runs partially exactly
    as ST programs do today — no new handling.)

**FB name sanitize + collision.** Compute the final name against a scratch
project holding the structs + the FB defs built so far:
`_sanitizeIdentifier(raw)`, then while `!fbNameIsValid(scratch, candidate)`
(collides with a builtin block type, a builtin composite, a struct, or an
already-built FB) or `candidate == kSystemTagName`, suffix `_1/_2/…`. Warn on any
rename. Record `oldName → finalName` in a rename map so §2 can retarget LD call
blocks whose `typeName` referenced the old name. `fbDefinitions` is emitted in
POU order.

## §2 — LD call routing (`ld_translate.dart`)

`translateLdBody` gains a parameter — the FB registry (`Map<String,
FbDefinition>`, keyed by final FB name) and the old→final rename map — threaded
from the mapper. `_kSupportedBlocks` gating is unchanged; the FB path is an
**additive branch before the unsupported-block throw**:

For a `<block>` node whose `typeName` (after applying the rename map) is a key in
the registry:

- **Instance:** `variable = ` the block's `instanceName` attribute, sanitized;
  if empty/absent, synthesize `uniqueFbInstanceName`-style from the FB name.
  Dedup instance names within the POU (a `usedInstanceNames` set already exists).
- **Pin bindings** (`LdNode.pinBindings`, varName → tag/operand):
  - **Inputs:** for each incoming `IrConnection` into this block, its `toPin`
    (the PLCopen `formalParameter`) is the FB input-var name; resolve the source
    (`byId[fromLocalId].attributes['variable']`, same literal/tag resolution the
    data-fold path uses) and bind `pinBindings[toPin] = source`. An input pin
    whose source can't be resolved → **stub the rung** (`_StubException
    'unresolved-operand'`), consistent with existing policy.
  - **Outputs:** for each outgoing `IrConnection` from this block, its `fromPin`
    is the FB output-var name; the consumer's operand/target tag is the binding:
    `pinBindings[fromPin] = target`. An unbound output is allowed (the FB may
    have outputs no one reads) — no stub.
- **Power flow:** the FB block is a **data block** — power passes straight
  through (`LdNode` transparent to power), exactly like native LD FB execution.
  It participates in the rung's series flow like the existing math/compare data
  blocks.
- **Instance tag:** create a struct-typed tag via `createFbInstanceTag(project,
  fb, name: variable)` semantics (dataType = FB name, value =
  `defaultValueFor(fbName)`), and add it to the translation's `instanceTags`
  list so the mapper merges it with the same sanitize/dedup used for
  timer/counter instances. (The mapper's existing instance-rename propagation
  must also retarget FB-call nodes: extend `isInstanceBackedLdBlock` — or the
  mapper's retarget guard — to treat an FB-name blockType as instance-backed so a
  renamed instance tag updates the node's `variable`.)

A translated FB-call block is **not** reported in `unsupportedLdBlockTypes` (it
is now supported). A rung that stubs for another reason still reports normally.

## §3 — Orchestration, report, data flow

`mapImportedProject` order:

1. Structs (unchanged).
2. Global vars → tags (unchanged).
3. **NEW: FB defs** (§1) → `fbDefinitions` + `fbRegistry` + rename map.
4. POUs → programs. `functionBlock` POUs are **skipped** here (handled in §1).
   LD POUs call `translateLdBody(..., fbRegistry, renameMap)`; FB-call blocks
   route (§2). FB instance tags merge into `tags` (existing merge loop, now also
   retargeting FB-call node `variable`s on rename).
5. Assemble `PlcProject(..., fbDefinitions: fbDefinitions, ...)`.

`ImportReport` gains `importedFbCount` (int, default 0). The preview/UI surface
(`import` screen) shows it alongside the existing counts. `stProgramCount`
excludes FB POUs (they are FBs, not programs).

## §4 — Error handling (pure, never-throws)

- Graphical-bodied FB → warning, skipped (no def, no program).
- FB name collision/reserved → rename + propagate to LD `typeName` refs + warning.
- `VAR_IN_OUT` → mapped to input + info warning.
- Unresolved FB **input** pin in LD → stub that rung (existing policy); other
  rungs/POUs unaffected.
- FB ST body beyond the app's ST subset → imported verbatim, runs partially like
  ST programs today (info only if it was IL-sourced).
- An LD block whose `typeName` names a **graphical** (thus un-imported) FB → not
  in the registry → stubs as `unsupported-block` (correct — its behaviour can't
  be reproduced).

## §5 — Testing

- *FB mapping (pure):* an ST `functionBlock` POU → `FbDefinition` with vars in
  order, correct `FbVarDir` per scope (incl. inOut→input + warning), normalized
  DUT-typed var, ST body verbatim; a graphical `functionBlock` POU → no def +
  warning + not emitted as a program; a name collision (FB named `AND` / a
  struct name) → renamed + warning.
- *LD routing (pure):* an LD rung with a custom-FB call block → an
  `LdNode(blockType = FB name, variable = instance)` with `pinBindings` mapping
  each `formalParameter` to the wired operand/tag, plus a struct-typed instance
  tag; an unresolved input pin → the rung stubs; the FB name is absent from
  `unsupportedLdBlockTypes`.
- *End-to-end fixture:* a handcrafted PLCopen XML (spec-faithful, not written to
  the importer) with one ST function block (e.g. `Scaler: Out := In * Gain;`) and
  one LD POU that instantiates + calls it wired to real tags → `mapImportedProject`
  produces a project whose `executeLdPrograms` scan drives the FB and yields the
  expected output. A rename case (FB or instance) round-trips runnably.
- *Backward-compat:* the existing PLCopen corpus/round-trip tests stay green; a
  no-FB project imports identically.

## Deferred — tracked in `docs/DEFERRED.md`

- **FBD FB-call routing** — waits on the FBD import translator (FBD POUs fully
  stub today). Once that ships, route FBD custom-FB calls to instances the same
  way.
- Graphical-bodied FB bodies (LD/FBD/SFC) — an imported FB with a graphical body
  is not executable natively (already deferred under custom FBs).
- IEC `VAR_IN_OUT` by-reference semantics (mapped to input for now).
- Import of stateless IEC `function` POUs (v1 is function *blocks*).
