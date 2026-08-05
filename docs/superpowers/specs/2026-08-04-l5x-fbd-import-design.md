# L5X FBD: front-end + FBD-bodied AOIs (L5X sub-projects 4+5, combined) — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-08-04

## Goal

Make Rockwell **L5X FBD content executable** in the app, end to end, in one
program:

- **Front-end half:** a `<Routine Type="FBD">`'s structured
  `<FBDContent><Sheet>` XML (NOT neutral text — unlike RLL) parses into the
  vendor-neutral IR `GraphBody` and translates through the **existing**
  `translateFbdBody` into a native, executing `FunctionBlockDiagram` program.
- **AOI half:** an AOI whose `Logic` routine is FBD compiles at import into an
  **FBD-bodied `FbDefinition`** and executes per instance via a new **scoped
  FBD executor**, slotting onto the infrastructure L5X sub-project 3 built
  (`FbDefinition` body discriminator + `executeFbInstance` dispatch + engine
  runtime threading).

The two halves ship together because they share one parser: the same
`GraphBody` builder feeds `_l5xRoutines`' FBD arm and `_l5xAois`' FBD arm.

**Corpus note (recorded honestly):** the local corpus
(`Resources/Project Exports/Rockwell-L5X/`, 5 files) contains **zero** FBD
content — `grep -rl 'FBDContent'` and `grep -rl 'Type="FBD"'` over the whole
repo (corpus included) return nothing. Every fixture in this feature is
therefore **handcrafted schema-faithful L5X**, the same precedent as the
PLCopen FBD e2e (`import_fbd_e2e_test.dart`) and all of sub-project 3. The
corpus test (`corpus_import_test.dart`) keeps proving only "imports without
throwing" for the real files.

## North-star decisions (from brainstorming — binding)

1. **One parser, two consumers.** `_l5xFbdBody` emits exactly the IR attribute
   keys `plcopen_parser.dart`'s `_graphBody` emits (`variable`, `typeName`,
   `instanceName`, `hasNegatedPin`, negative synthetic ids for malformed
   `localId`s), so **`translateFbdBody` needs zero changes**.
2. **Compile-at-import, never at execution.** An FBD AOI's `Logic` routine is
   translated by `translateFbdBody` **during import** (against the FB registry
   built so far) into native `FbdBlock`/`FbdWire`/`FbdNetwork` lists stored on
   `FbDefinition`. There is no FBD→ST transpile and no import-time work at
   scan time.
3. **Native FBD FB body + scoped FBD executor** — the exact analog of
   sub-project 3's ladder body + `runScopedLdBody`, reusing `LdScope` for the
   tag-path rewriting (identical root-segment rule).
4. **Multi-sheet merges into ONE `GraphBody`** with per-sheet localId
   offsetting; `ICon`/`OCon` connector pairs are resolved **at parse time**
   into direct wires.
5. **AB mnemonic aliasing at parse time** (rewriting `typeName`, and — see
   Resolution R1 — the wire pin names), best-effort for `TONR`/`TOFR` with a
   prominent "verify" warning; everything unmapped passes through and the
   translator stubs + inventories it (`unsupportedFbdBlockTypes`).
6. **Faithful-or-stub, never-throws** everywhere — inherited from
   `translateFbdBody`, unchanged.

## Why this shape (grounded in the codebase)

- `translateFbdBody` (`import/fbd_translate.dart`) already does everything the
  L5X front-end needs: weakly-connected components → one `FbdNetwork` each,
  `inVariable` → `CONST`/`TAG_INPUT` (`_isLiteral`/`_isIdentifier`),
  `outVariable` → `TAG_OUTPUT`, `block` → built-in (`kFbdBuiltinBlockTypes`)
  or custom-FB routing via `fbRegistry`/`fbRenameMap`, the `_assertPin`
  pin-faithfulness gate, and per-network faithful-or-stub with
  `FbdTranslation.{translatedNetworkCount, stubbedNetworkCount,
  unsupportedBlockTypes, stubReasons, warnings, instanceTags}`. Reusing it
  verbatim is why this sub-project is a parser + an executor, not a translator.
- `ir_to_project.dart`'s FBD arm (`body is GraphBody && pou.lang ==
  PouLanguage.fbd`, ~line 286) already turns a translated `GraphBody` into a
  real `PlcProgram(language: 'FunctionBlockDiagram', fbdBlocks:, fbdWires:,
  fbdNetworks:)` with instance-tag sanitize/dedup/retarget. The L5X front-end
  needs **no change there at all** — only the parser stops emitting an empty
  `GraphBody` (l5x_parser.dart ~line 315).
- `executeFbInstance` (`models/fb_exec.dart`) is the single FB entry point,
  already dispatching `fb.ladderRungs.isNotEmpty ? runScopedLdBody :
  runScopedStBody`, already threading `dtMs`/`ldRt`/`readOnly`, already
  depth-guarded (`_kMaxFbCallDepth = 16`). A third branch is additive.
- `FbdRuntime` (`models/fbd_exec.dart`) keys **every** stateful block's state
  by `b.id` (`_elapsedMs`, `_pid`, `_counters`, `_prevClk`, `_pulse`). Block
  ids are unique per project *program*, but every instance of an FBD-bodied
  AOI shares one set of body block ids — so the scoped executor must prefix
  the state key per instance (§3).
- `LdScope` (`models/ld_exec.dart`) is `rewrite(path)` = "root segment in
  `localVars` → `<instancePath>.<path>`, else untouched". FBD needs exactly
  that for `FbdBlock.tagBinding`; a second identical class would be drift.
- `mapImportedFbs` (`import/fb_import.dart`) already has the shape to mirror:
  a `NeutralLadderBody` arm that compiles against the **registry so far**,
  builds a bodied `FbDefinition` when ≥1 unit translated, falls back to
  interface-only + a warning naming the AOI otherwise, and returns extra
  counters on `FbImportResult` that `mapImportedProject` folds into existing
  report fields.

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never-throws** — an FBD AOI
  whose body cannot translate degrades to the existing interface-only no-op +
  warning; an FBD routine that cannot translate keeps today's whole-POU stub.
- Zero `flutter analyze` warnings (run flutter from `mobile/`).
- **Additive / backward-compatible:** every ST- and ladder-bodied FB, the whole
  PLCopen import path (including PLCopen FBD programs), and all existing L5X
  behavior are byte-identical. `FbDefinition` JSON round-trips; old projects
  (no `fbd_blocks` key) load unchanged.
- The `xml` package stays confined to the parsers. `fbd_exec.dart`,
  `fb_exec.dart`, `ld_exec.dart` stay Flutter-free.
- **PLCopen `functionBlock` FBD POUs keep today's "graphical body — not
  imported" warning.** Only L5X-parser-produced FBD AOIs enter the new
  `mapImportedFbs` arm (see §6 and Resolution R2).

---

## §1 — Model: FBD body on `FbDefinition` (`models/project_model.dart`)

```dart
class FbDefinition {
  String name;
  List<FbVar> vars;
  String stSource;
  List<LdRung> ladderRungs;      // shipped (sub-project 3)
  List<FbdBlock> fbdBlocks;      // NEW — default []; non-empty => FBD-bodied
  List<FbdWire> fbdWires;        // NEW
  List<FbdNetwork> fbdNetworks;  // NEW (headers/comments; execution reads only block.network)
  ...
}
```

- JSON keys `fbd_blocks` / `fbd_wires` / `fbd_networks` — the **same key names
  `PlcProgram` already uses**, so the element serializers are reused as-is.
  Each is emitted **only when non-empty** (mirrors `ladder_rungs`), so an
  ST- or ladder-bodied FB's JSON is byte-identical to today. `fromJson`
  defaults each to `[]` (old projects load unchanged).
- **Body precedence discriminator** (single source of truth, `executeFbInstance`):
  `ladderRungs.isNotEmpty` → ladder; else `fbdBlocks.isNotEmpty` → FBD; else
  ST. Documented on the class next to the existing `ladderRungs` note.
- `PlcProgram`'s constructor-level `_normalizeFbdNetworks` is **not** mirrored
  onto `FbDefinition`: the executor never indexes `fbdNetworks` (it partitions
  on `FbdBlock.network` and sorts the distinct indices), and
  `translateFbdBody` appends exactly one network per component, so the lists
  are consistent by construction. Recorded as a deferred note, not a gap.
- **Third `FbdBlock` root:** like `ladderRungs`, these blocks are a *second*
  `FbdBlock` root in the project graph (`PlcProgram.fbdBlocks` is the first).
  `renameFbDefinition` (`models/tag_resolver.dart`, which already walks
  `FbdBlock.type` in programs and `def.ladderRungs`) gains a loop over
  `def.fbdBlocks` renaming `b.type == oldName`. Class doc-comment updated to
  name all three roots.

## §2 — Scoped FBD executor (`models/fbd_exec.dart`)

Extract the per-program body of `executeFbdPrograms` into a private helper and
call it from both the program path and the new scoped path:

```dart
void _runFbdBody(PlcProject p, List<FbdBlock> blocks, List<FbdWire> wires,
    int dtMs, FbdRuntime rt,
    {Set<String>? readOnly, LdExecRuntime? ldRt, FbdMonitor? monitor,
     String monitorProgName = '', LdScope? scope, String stateKeyPrefix = ''});

/// Executes one FBD FB body scoped to a single instance. The FBD analog of
/// `runScopedLdBody` (ld_exec.dart). Never throws.
void runScopedFbdBody(PlcProject p, List<FbdBlock> blocks, List<FbdWire> wires,
    LdScope scope, int dtMs, FbdRuntime rt,
    {Set<String>? readOnly, LdExecRuntime? ldRt});
```

- `executeFbdPrograms(...)` keeps its exact public signature and, per program,
  calls `_runFbdBody(p, prog.fbdBlocks, prog.fbdWires, dtMs, rt, readOnly:
  readOnly, ldRt: ldRt, monitor: monitor, monitorProgName: prog.name)` — no
  scope, empty state-key prefix ⇒ **byte-identical** network partitioning,
  topological worklist, cycle fallback, monitor keys, and runtime keys.
- `runScopedFbdBody` calls `_runFbdBody(..., scope: scope, stateKeyPrefix:
  'fb:${scope.instancePath}|', monitor: null)`.

**Tag-path scoping.** `_evalBlock` gains `LdScope? scope` and applies
`sp(path) = scope == null ? path : scope.rewrite(path)` at exactly three
sites — the only places a block reaches a tag path:

| Branch | Today | Scoped |
|---|---|---|
| `TAG_INPUT` | `readPath(p, b.tagBinding)` | `readPath(p, sp(b.tagBinding))` |
| `TAG_OUTPUT` | `readOnly` gate + `_forceAwareWrite(p, b.tagBinding, v)` | gate + write on `sp(b.tagBinding)` |
| custom FB (`fbDefinitionFor`) | `executeFbInstance(p, fb, b.tagBinding, …)` | `… , sp(b.tagBinding), …` |

`CONST` is deliberately **not** rewritten (`b.tagBinding` there is a literal,
not a path). The `readOnly` gate is applied to the **rewritten** path, so an
instance member (`Inst.Out`) is never gated while a global coil target still
is — matching the `readOnly` semantics sub-project 3's F4 fix established for
ladder bodies.

**Per-instance stateful-block state.** `_evalBlock` takes a precomputed
`String stateKey` and every `rt._elapsedMs/_pid/_counters/_prevClk/_pulse`
lookup uses it instead of `b.id`. The caller computes:

```dart
final stateKey = '$stateKeyPrefix${b.id}';   // programs: '' + b.id  (unchanged)
                                             // FB body: 'fb:<instancePath>|<blockId>'
```

e.g. two instances of an FBD AOI named `Pump` whose body has a `TON` at block
`AOI Ramp_n7` key `fb:Pump1|AOI Ramp_n7` and `fb:Pump2|AOI Ramp_n7` — disjoint
by construction. Sanitized tag/instance names cannot contain `:` or `|`, so an
`'fb:'`-prefixed key can never collide with a program block id (the same
argument `runScopedLdBody`'s `'fb:<instance>'` program-key uses). Nested
instances get `instancePath` = `Outer.Inner`, still unique.

**Monitoring:** scoped bodies pass `monitor: null` (FB-body online values are a
deferred row, as they are for ladder bodies).

## §3 — Dispatch + runtime plumbing

`models/fb_exec.dart`:

```dart
Map<String, dynamic> executeFbInstance(
    PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs,
    {int dtMs = 0, LdExecRuntime? ldRt, FbdRuntime? fbdRt, Set<String>? readOnly});
```

- Steps 1 (write inputs) and 3 (read outputs) unchanged.
- Step 2 becomes three-way (§1 precedence). The existing EnableIn re-assert
  block is factored into a private `_reassertEnableIn(p, fb, instanceName)`
  (data-driven on `name == 'EnableIn' && direction == internal && dataType ==
  'BOOL'`) and called from **both** graphical branches — ladder behaviour is
  unchanged; FBD gets the same semantics (§7).
- FBD branch:
  `runScopedFbdBody(p, fb.fbdBlocks, fb.fbdWires, LdScope(instanceName, varNames),
  dtMs, fbdRt ?? FbdRuntime(), readOnly: readOnly, ldRt: ldRt)`.
  The `fbdRt ?? FbdRuntime()` **ephemeral fallback** degrades *only* stateful
  blocks (a TON in the body restarts each call); it is unreachable from the
  scan because both engines thread a real runtime (below). Same contract the
  ladder branch's `ldRt ?? LdExecRuntime()` documents.
- **Cyclic definitions** (an FBD FB whose body calls itself, reachable only
  from hand-edited/legacy JSON) are already covered: every nested call goes
  through `executeFbInstance`'s `_kMaxFbCallDepth` guard.

**Runtime threading (symmetric to sub-project 3's Task 4, in the other
direction):**

| Call site | Change |
|---|---|
| `fbd_exec.dart` `_evalBlock` custom-FB branch | already has `rt` (the `FbdRuntime`) → `executeFbInstance(…, ldRt: ldRt, fbdRt: rt)` |
| `ld_exec.dart` `executeLdPrograms` | gains `FbdRuntime? fbdRt`, threaded to `executeRung` |
| `ld_exec.dart` `executeRung` | gains `FbdRuntime? fbdRt`, passed at its FB-call block: `executeFbInstance(…, ldRt: rt, fbdRt: fbdRt, readOnly: readOnly)` |
| `ld_exec.dart` `runScopedLdBody` | gains `FbdRuntime? fbdRt` and forwards it (a ladder AOI calling an FBD AOI) |
| `screens/scan_tick.dart` | `executeLdPrograms(p, dtMs, rt.ld, …, fbdRt: rt.fbd)` — the same `rt.fbd` already passed to `executeFbdPrograms` |

`ld_exec.dart` importing `fbd_exec.dart` for `FbdRuntime` closes a library
cycle with `fbd_exec.dart`'s existing `import 'ld_exec.dart'` — the same
already-shipped shape as `fb_exec.dart` ↔ `ld_exec.dart`. Dart permits it (no
top-level circular initialization is introduced).

## §4 — L5X FBD parser (`import/l5x_parser.dart`)

One private builder, used by both arms:

```dart
GraphBody _l5xFbdBody(XmlElement routine, List<ImportWarning> warnings,
    String ownerLabel);   // ownerLabel: 'Routine "Prog_Main"' | 'AOI "Foo"'
```

**Element mapping** (whitelist — anything else is ignored, see below):

| L5X element | IR `elementType` | Attributes emitted |
|---|---|---|
| `<IRef Operand=… X= Y= ID=>` | `inVariable` | `variable` = `Operand` (trimmed) |
| `<ORef Operand=… >` | `outVariable` | `variable` = `Operand` |
| `<Block Type=… Operand=… >` | `block` | `typeName` = aliased `Type`; `instanceName` = `Operand` |
| `<Function Type=… >` | `block` | `typeName` = aliased `Type` |
| `<AddOnInstruction Name=… Operand=… >` | `block` | `typeName` = `Name` (never aliased); `instanceName` = `Operand` |
| `<ICon Name=…>` / `<OCon Name=…>` | resolved away (§5); **unmatched ones kept** as `ICon`/`OCon` | `connectorName` |
| `<Wire FromID FromParam ToID ToParam>` | → `IrConnection` | — |
| `<TextBox>`, `<Attachment>`, anything else | **ignored** | — |

- The whitelist (rather than plcopen's "every child with a `localId`") is
  required: `<TextBox>` carries an `ID` and `<Attachment>` links it to a real
  element, so a generic loop would drag an annotation into a real component
  and stub it as `unsupported-element`. One info warning per routine when any
  element kind was ignored (count + kinds), no per-element noise.
- `IrConnection(toLocalId: ToID, toPin: ToParam, fromLocalId: FromID,
  fromPin: FromParam)` — `null` when the attribute is absent (implicit single
  pin), exactly like `_graphBody`.
- **Ids:** `ID` parsed with `int.tryParse`; absent/unparseable/negative/absurd
  (`> 1 << 31`) ids get a **unique negative synthetic id** (`malformedId--`),
  reproducing `_graphBody`'s contract so `weaklyConnectedComponents` can't
  merge two malformed nodes and the translator's `localId < 0` gate still
  stubs their component.
- `hasNegatedPin` is never emitted (Logix FBD has no pin inversion; `BNOT` is
  an explicit element). Documented, not implemented.
- **Two passes per sheet:** nodes first (so every element's aliased type is
  known), then wires (pin aliasing needs the endpoint node's type — §6).
- Never throws: every attribute read is null-tolerant; an empty/absent
  `FBDContent` yields `GraphBody(nodes: [], connections: [])`.

### `_l5xRoutines` FBD arm (front-end)

Replace the "graphical body not yet translated" warning + empty `GraphBody`
(~line 315) with `body: _l5xFbdBody(r, warnings, 'Routine "$name"')`, keeping
`lang: PouLanguage.fbd`, `kind: PouKind.program`. `ir_to_project`'s existing
FBD arm then translates it — **no change in `ir_to_project.dart` for the
front-end half.** An FBD routine that translates nothing keeps today's
whole-POU stub + warning (that arm's existing `else`).

## §5 — Multi-sheet merge + connector resolution

**Sheet merge.** All `<Sheet>`s of a routine merge into ONE `GraphBody`:

- Per-sheet **localId offsetting**: sheet 0 uses raw ids; before each later
  sheet, `offset = maxAssignedIdSoFar + 1`. Wires live inside their own
  `<Sheet>`, so every reference is sheet-local and offsetting is
  self-consistent and collision-free. Synthetic negative ids are never
  offset.
- Per-sheet **y offsetting**: `y = rawY + yBase`, where `yBase` advances to
  `maxYSeenSoFar + 200` before each later sheet (Resolution R5). Without it,
  `weaklyConnectedComponents`' layout ordering (min-y, min-x, min-localId)
  would interleave sheet 2's networks with sheet 1's; with it, network
  numbering reads sheet-by-sheet, top-to-bottom. Offsets stay small enough
  that block coordinates remain plausible for a future editor.

**Connectors (`ICon`/`OCon`) resolved at parse time**, routine-wide (Logix
connector names link across sheets):

1. Collect, over the merged routine: `oconIn[name]` = the wires whose `ToID`
   is an `OCon` with that `Name`; `iconOut[name]` = the wires whose `FromID`
   is an `ICon` with that `Name`.
2. For each name present in both, emit the cross-product of direct wires:
   `IrConnection(from: producer.fromLocalId, fromPin: producer.fromParam,
   to: consumer.toLocalId, toPin: consumer.toParam)`. Then drop those
   connector nodes and their wires.
3. **Unmatched** connector (`ICon` with no same-named `OCon`, or vice versa):
   the node and its wires are **kept** with `elementType` `ICon`/`OCon`, so
   the affected component stubs through the translator's faithful-or-stub gate
   (`unsupported-element`) rather than silently losing a data path. An info
   warning names the routine/AOI and the connector name. Never throws.
   (Resolution R4 — decision 4 called this "the pin gate"; the gate that
   actually fires is the element-kind gate in the same `_translateComponent`
   pre-flight.)

## §6 — Rockwell mnemonic + pin aliasing (at parse)

Applied in `_l5xFbdBody` **before** the IR is emitted, so `fbd_translate.dart`
sees only IEC names.

**Type aliases** (`Block`/`Function` `Type` only — `AddOnInstruction` `Name`
is never aliased):

`EQU→EQ`, `NEQ→NE`, `GEQ→GE`, `LEQ→LE`, `GRT→GT`, `LES→LT`, `BAND→AND`,
`BOR→OR`, `BNOT→NOT`; best-effort `TONR→TON`, `TOFR→TOF`.

`TONR`/`TOFR` additionally get `attributes['abOriginal'] = 'TONR'|'TOFR'` and a
**prominent verify warning** naming the routine/AOI:
*"Rockwell TONR mapped best-effort to the IEC TON block — retentive/reset
behaviour differs; verify."* (`abOriginal` is IR-only: `translateFbdBody`
ignores unknown attributes and there is no native field to carry it. Recorded
as a deferred nicety.) A **wired `Reset` pin** then stubs that network
naturally via `_assertPin` (`unresolved-pin`) — no special case, per decision 5.

**Pin aliases** (Resolution R1 — mandatory, see below), keyed by the AB source
type, applied to `ToParam` using the destination node's type and to `FromParam`
using the source node's type:

| AB type(s) | Pin map |
|---|---|
| `ADD`,`SUB`,`MUL`,`DIV` (type identity) | `SourceA→IN1`, `SourceB→IN2`, `Dest→OUT` |
| `EQU`,`NEQ`,`GEQ`,`LEQ`,`GRT`,`LES` | `SourceA→IN1`, `SourceB→IN2`, `Dest→OUT` |
| `BAND`,`BOR` | `In<k>→IN<k>` (regex), `Out→OUT` |
| `BNOT` | `In→IN`, `Out→OUT` |
| `TONR`,`TOFR` | `TimerEnable→IN`, `PRE`/`Preset→PT`, `DN→Q`, `ACC→ET` |

Any pin not in the map passes through **verbatim** and, if it isn't a real
IEC pin, `_assertPin` stubs that network (`unresolved-pin`) — faithful-or-stub
preserved.

**Everything else unmapped:** `SCL`, `PIDE`, `MOV`, `MOD`, `ESEL`, … keep their
Rockwell type name, fail `kFbdBuiltinBlockTypes`, and stub with
`unsupported-block` while being inventoried into
`ImportReport.unsupportedFbdBlockTypes` (no new report field).

## §7 — AOI FBD logic → FBD-bodied `FbDefinition`

**Parser (`_l5xAois`).** Generalize the existing `isRll` flag to
`keepsEnableParams = isRll || isFbd` (`logicType == 'FBD'`):

- `EnableIn`/`EnableOut` are retained as **internal** `BOOL` vars (EnableIn
  `initialValue: true`, EnableOut `false`) for FBD-logic AOIs too, exactly as
  for RLL. In an FBD body they appear as an `IRef Operand="EnableIn"` →
  `TAG_INPUT` whose `tagBinding` is rewritten by `LdScope` to
  `<instance>.EnableIn` (reads `true`), and an `ORef Operand="EnableOut"` →
  `TAG_OUTPUT` writing `<instance>.EnableOut`. ST/SFC-logic AOIs keep the
  historic skip.
- Body: `body = _l5xFbdBody(logic, warnings, 'AOI "$name"')`,
  `lang = PouLanguage.fbd`. SFC logic keeps today's
  "logic not yet translated" warning.
- The `_reassertEnableIn` call in `executeFbInstance` (§3) makes an
  `EnableOut`-clearing body non-self-disabling across calls, same as ladder.

**Mapper (`mapImportedFbs`).** New arm mirroring the `NeutralLadderBody` arm:

```dart
FbImportResult mapImportedFbs(List<ImportedPou> pous, {
  required List<PlcStructDef> structs,
  required Set<String> dutNames,
  required List<ImportWarning> warnings,
  ImportDialect dialect = ImportDialect.plcOpen,   // NEW (R2)
});
```

- Entry gate: `final isFbdAoiBody = body is GraphBody && pou.lang ==
  PouLanguage.fbd && dialect == ImportDialect.l5x;` — the existing
  reject-and-warn guard becomes
  `if (body is! TextBody && body is! NeutralLadderBody && !isFbdAoiBody) { …warn; continue; }`.
  **PLCopen `functionBlock` FBD POUs keep today's warning byte-for-byte.**
- Translation: `translateFbdBody(body, pouName: 'AOI $name', fbRegistry:
  registry, fbRenameMap: renameMap)` — **registry so far**, so an AOI whose
  sheet calls an AOI defined *earlier* routes to a real FB-instance block and
  one defined *later* stubs (`unsupported-block`, inventoried) — the same
  documented forward-reference limit the ladder arm has.
- `tr.translatedNetworkCount > 0` → `FbDefinition(name:, vars:, fbdBlocks:
  tr.blocks, fbdWires: tr.wires, fbdNetworks: tr.networks)`; `== 0` →
  interface-only `FbDefinition(name:, vars:)` + a warning naming the AOI —
  **suppressed when the body had zero nodes** (nothing to fail at), mirroring
  the ladder arm's `body.rungs.isNotEmpty` guard.
- **Nested-FB instance tags (Resolution R3).** `tr.instanceTags` are
  project-level `PlcTag`s that `mapImportedFbs` cannot add to the project and
  that would be *shared* by every AOI instance. They are therefore **never
  emitted**; instead, for each instance tag:
  - an `FbVar` with that name already exists (the AOI's `LocalTag` typed as the
    nested AOI — already resolved to the nested FB by the existing
    `renameMap`/`normalizeType` var loop) → nothing to do; `LdScope` rewrites
    the block's `tagBinding` to `<instance>.<localTag>`, giving true
    per-instance nested state. An info warning if the existing var's
    `dataType` differs from the block's type.
  - otherwise → **synthesize** an internal `FbVar(name: it.name, dataType:
    it.dataType, direction: internal, initialValue: it.value)` from the tag
    `translateFbdBody` already built (its `value` came from `defaultValueFor`),
    so the nested instance lives inside the AOI struct as well.
- Counters: `FbImportResult` gains `translatedFbdNetworkCount`,
  `stubbedFbdNetworkCount`, `unsupportedFbdBlockTypes`, `fbdStubReasons`
  (all default-safe), folded by `mapImportedProject` into its **existing**
  FBD accumulators (`translatedFbdNetworkCount` … declared at
  `ir_to_project.dart` ~189) exactly as the RLL counters are seeded at ~199.
  No new `ImportReport` field, no preview-UI change.
- `mapImportedProject` passes `dialect: ir.dialect`; `ImportedProject` gains
  `final ImportDialect dialect` defaulted to `ImportDialect.plcOpen`, set to
  `ImportDialect.l5x` by `parseL5x` (R2). Every existing construction site and
  test compiles unchanged.

## §8 — Error handling (pure, never-throws)

| Situation | Handling |
|---|---|
| FBD routine, some networks translate | Real `FunctionBlockDiagram` program; untranslatable networks are empty commented networks (existing behaviour) |
| FBD routine, nothing translates | Today's whole-POU stub + warning (existing `else` arm) |
| AOI FBD `Logic`, ≥1 network translates | FBD-bodied `FbDefinition`; stubbed networks inert, reasons warned as `POU "AOI <name>" network N: …` |
| AOI FBD `Logic`, 0 networks translate (body had nodes) | Interface-only `FbDefinition` + warning naming the AOI |
| AOI FBD `Logic` with empty/absent `FBDContent` | Interface-only, **no** warning |
| Unmatched `ICon`/`OCon` | Node kept → component stubs (`unsupported-element`) + info warning naming the connector |
| `TONR`/`TOFR` | Mapped best-effort to `TON`/`TOF` + prominent verify warning; a wired `Reset` stubs that network (`unresolved-pin`) |
| Unmapped AB block (`SCL`, `PIDE`, `MOV`, …) | Network stubs (`unsupported-block`), type inventoried in `unsupportedFbdBlockTypes` |
| Unmapped pin name (`SourceC`, `EN`, …) | Network stubs (`unresolved-pin`) |
| Dotted operand (`Timer1.DN`) on an `IRef`/`ORef` | Stubs (`complex-expression`) — pre-existing `_isIdentifier` limit shared with the PLCopen FBD translator (deferred row) |
| `<TextBox>` / `<Attachment>` / unknown element | Ignored at parse; one info warning per routine |
| Malformed/absent `ID` | Unique negative synthetic id → that component stubs (`unsupported-element`) |
| Multiple wires into one input pin | Existing `claimedInputSlots` gate → `unresolved-pin` |
| Dataflow cycle inside an FB body | `_runFbdBody`'s existing cycle fallback evaluates once with cached values; scan always terminates |
| FBD FB that (cyclically) calls itself | `_kMaxFbCallDepth` returns `{}` beyond depth 16 |
| Empty instance name | `executeFbInstance` already refuses (returns `{}`) |
| Missing/unresolvable scoped path at runtime | Reads `null` / writes no-op, exactly like a missing global |
| PLCopen `functionBlock` with an FBD body | Unchanged "graphical body (fbd) — not imported" warning |

## §9 — Testing

**Parser units** (`test/import/l5x_parser_fbd_test.dart`):
- each element kind (`IRef`/`ORef`/`Block`/`Function`/`AddOnInstruction`)
  produces the expected `elementType` + attribute keys (`variable`/`typeName`/
  `instanceName`);
- `Wire` → `IrConnection` with `toPin`/`fromPin` (and `null` when absent);
- type aliasing (`EQU`→`EQ`, `BAND`→`AND`) **and** pin aliasing
  (`SourceA`→`IN1`, `Dest`→`OUT`, `In1`→`IN1`);
- `TONR` → `TON` + `abOriginal` + verify warning;
- multi-sheet: two sheets with **overlapping raw ids** merge with disjoint
  localIds and sheet-ordered y;
- connectors: matched `OCon`/`ICon` pair becomes a direct wire (producer→
  consumer, pins preserved) and the connector nodes disappear; unmatched
  connector keeps its node + warns;
- malformed: missing `ID`, non-numeric `ID`, absent `FBDContent`, `<TextBox>`/
  `<Attachment>` present → never throws, ignored-element warning.

**Model round-trip** (`test/models/fb_model_test.dart`): an FBD-bodied
`FbDefinition` round-trips (`fbd_blocks`/`fbd_wires`/`fbd_networks`); an
ST-bodied and a ladder-bodied FB serialize byte-identically to before (keys
absent); old JSON without the keys loads.

**Scoped executor units** (`test/models/fb_fbd_body_exec_test.dart`):
- `TAG_INPUT`/`TAG_OUTPUT` bind to `<instance>.<var>` and do **not** touch
  same-named globals; a non-var binding still resolves global;
- `CONST` is not rewritten;
- **two-instance stateful isolation:** an FBD body with a `TON` (and an
  `R_TRIG`) accumulates independently for `Inst1`/`Inst2` across scans with
  `dtMs`, proving the `'fb:<instance>|<blockId>'` state key;
- `readOnly` drops a body `TAG_OUTPUT` writing a read-only global but never an
  instance member;
- **ephemeral degrade:** calling `executeFbInstance` with no `fbdRt` still
  produces correct combinational outputs and only loses timer accumulation;
- **regression:** `executeFbdPrograms` on a normal program is unchanged
  (existing `fbd_exec_test.dart` / `fbd_networks_exec_test.dart` stay green).

**Dispatch/threading units** (extend `test/models/fb_exec_test.dart`,
`test/fb_fbd_exec_test.dart`): precedence (ladder wins over fbd wins over ST);
an FBD-bodied FB called from a **ladder** program keeps its state across scans
(`fbdRt` threading through `executeLdPrograms`); a ladder-bodied FB called from
an **FBD** program still works (no regression); EnableIn is re-asserted true
each call for an FBD body.

**Mapper units** (`test/import/fb_import_fbd_test.dart`): registry-so-far
routing (AOI-in-AOI, earlier vs later definition), zero-translated fallback +
warning naming the AOI, zero-node body → no warning, nested-instance var
synthesis/reuse (R3), counters land on `FbImportResult`, and a **PLCopen**
`functionBlock` FBD POU still hits the unchanged warning path.

**Composed e2e** (`test/import/import_l5x_aoi_fbd_e2e_test.dart`): one
handcrafted L5X containing (a) a program `<Routine Type="FBD">` with two
sheets, an aliased compare and a connector pair, (b) an AOI with FBD `Logic`
(EnableIn-gated, containing a `TON`), (c) two AOI-typed controller tags, and
(d) a program rung calling both instances → `parseL5x` → `mapImportedProject`
→ scan: the FBD program computes, both AOI instances execute, their timer
state accumulates **independently** across scans, and outputs land on the
bound tags.

**Backward-compat:** the whole suite green — PLCopen import (incl.
`import_fbd_e2e_test.dart`), L5X foundation/RLL/AOI-ladder e2e,
serialization round-trips, corpus test.

## §10 — Docs

- `docs/iec61131/FUNCTION_BLOCKS.md` — FBD-bodied FBs: what they are, the
  three-way body precedence, per-instance scoping and stateful-block state
  keys, and that the FB editor doesn't view/edit them yet.
- `docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md` — extend the "FBD import" section
  with the **L5X** support matrix (element kinds, alias tables, connectors,
  multi-sheet, what stubs).
- `docs/import/L5X.md` — new "FBD routines translate" + "FBD-Logic AOIs
  execute" sections; move FBD out of "What's captured but not yet translated"
  (SFC stays); EnableIn/EnableOut note.
- `docs/DEFERRED.md` — **strike** the "FBD-bodied AOI logic" row (~110) and the
  "L5X FBD routine translation" row (~115), replacing both with shipped rows
  citing the e2e test; keep/add the rows in §11.

## §11 — Deferred (tracked in `docs/DEFERRED.md`)

- **AB block synthesis** — `SCL`, `PIDE`, `MOV`, `MOD`, `ESEL` and other
  unmapped Rockwell FBD blocks stub and are inventoried; no synthesis onto
  native equivalents (e.g. `MOV` as a pass-through wire, `PIDE`→`PID`).
- **`TONR`/`TOFR` fidelity** — mapped best-effort to `TON`/`TOF`; retentive
  accumulation and the `Reset` pin are not modeled (`abOriginal` survives only
  in the IR + warning; there is no native field to carry it).
- **AOI auxiliary routines** (`Prescan`/`Postscan`/`EnableInFalse`) — only
  `Logic` is imported/executed (shared with sub-project 3).
- **`<TextBox>` / `<Attachment>` elements** — annotations are ignored (counted
  in one info warning), not imported as documentation.
- **FB editor for graphical bodies** — an FBD-bodied `FbDefinition` shows its
  (empty) ST source; no view/edit UI for `fbdBlocks` (extends the existing
  ladder-body row, including the same "renaming/deleting an FB var silently
  reroutes body references" consequence).
- **FB-body online monitoring** — scoped bodies pass `monitor: null`; imported
  AOI bodies have no live pin values.
- **PLCopen FBD-bodied `functionBlock` POUs** — the executor supports them;
  only the `dialect` gate withholds them, pending PLCopen-specific validation.
- **Dotted/member operands in FBD refs** (`Timer1.DN`) — stub
  (`complex-expression`), shared with the PLCopen FBD translator.
- **Backing-tag fidelity for FBD `Block` elements** — a `<Block Type="TON"
  Operand="T1">`'s state lives in the translator-managed `FbdRuntime`, not in
  the `T1` TIMER tag.
- **AOI-in-AOI forward references** — callee must precede caller in the file
  (shared with sub-project 3).
- **L5X SFC routine translation** — the remaining L5X sub-project.

## §12 — Deviations & resolutions (conflicts found against live code)

- **R1 — the alias table must map PIN names, not just type names.**
  `translateFbdBody`'s `_assertPin` compares a wire's `toPin`/`fromPin`
  literally against `fbd_pins.dart`'s IEC registry. Rockwell FBD wires carry
  `SourceA`/`SourceB`/`Dest` (math + compares) and `In1`/`Out` (bit functions)
  — none of which are `IN1`/`IN2`/`OUT` (case included). A type-only alias
  would make **every** aliased and math/compare network stub with
  `unresolved-pin`, i.e. the feature would translate almost nothing. Resolved
  minimally by extending the same parse-time alias table with a per-type pin
  map (§6); unmapped pins still pass through and still stub.
- **R2 — a dialect marker is required to keep PLCopen byte-identical.** The IR
  carries no dialect (`ImportDialect` lives only in `dialect_detect.dart`), and
  a PLCopen `functionBlock` FBD POU is indistinguishable from an L5X FBD AOI
  by `kind`/`lang`/body type alone. Resolved by adding
  `ImportedProject.dialect` (default `ImportDialect.plcOpen`, set by
  `parseL5x`) and a defaulted `dialect` param on `mapImportedFbs` — the
  smallest change that implements decision 8's "safe rule". Rejected
  alternative: gating on `lang == fbd` alone, which would silently change the
  PLCopen path.
- **R3 — nested-FB instance tags inside an AOI body have no home.**
  `translateFbdBody` emits `instanceTags` (project `PlcTag`s) for custom-FB
  call blocks, but `mapImportedFbs` cannot add project tags, and a shared
  global instance would make two AOI instances share nested state. Resolved
  **without touching `fbd_translate.dart`**: the arm consumes `tr.instanceTags`
  locally — reusing a same-named `FbVar` when present, else synthesizing an
  internal `FbVar` from the tag — so the nested instance always lives inside
  the AOI struct and `LdScope` gives it per-instance state (§7).
- **R4 — unmatched connectors stub via the element gate, not the pin gate.**
  Decision 4 says the translator's pin gate stubs a dangling connection; the
  gate that actually fires is `_translateComponent`'s element-kind pre-flight
  (`unsupported-element`) because the retained node's `elementType` is
  `ICon`/`OCon`. Same faithful-or-stub outcome, different `stubReasons` key —
  recorded so tests assert the right key.
- **R5 — per-sheet y offsetting added.** Not in the binding decisions, but
  `weaklyConnectedComponents` orders components by layout (min-y, min-x,
  min-localId); merging sheets by localId alone would interleave sheet 2's
  networks with sheet 1's in the network numbering. A running
  `maxY + 200` per-sheet y base makes network order read sheet-by-sheet (§5).
- **No conflict found** for decisions 2, 6, 7, 9, 10: `translateFbdBody`
  consumes the plcopen attribute keys as specified, `FbDefinition`'s JSON
  conventions mirror `ladder_rungs` exactly, `LdScope` reuse is a literal fit,
  and `executeFbInstance`'s EnableIn re-assert generalizes by extracting the
  existing block into a helper.

## §13 — Implementation shape (for the plan)

Nine tasks, one plan. Tasks 1–3 (model + executor + plumbing) and tasks 4–6
(parser) are independent and parallelizable; 7 joins them.

1. Model: `FbDefinition` FBD fields, JSON, precedence doc, `renameFbDefinition`
   third root (+ round-trip tests).
2. `_runFbdBody` extraction + `runScopedFbdBody` + `LdScope` rewriting +
   state-key prefix (+ scoped-executor tests).
3. `executeFbInstance` third branch + `fbdRt` + `_reassertEnableIn`; `ld_exec`
   / `scan_tick` threading (+ dispatch tests).
4. `_l5xFbdBody` core (elements, wires, ids, whitelist) + `_l5xRoutines` FBD
   arm (+ parser tests).
5. Multi-sheet merge + connector resolution (+ tests).
6. Alias tables (types + pins) + `TONR`/`TOFR` warnings (+ tests).
7. `_l5xAois` FBD arm (EnableIn/EnableOut) + `ImportedProject.dialect` +
   `mapImportedFbs` FBD arm + R3 instance-var handling + `FbImportResult`
   counters + `ir_to_project` folding (+ mapper tests).
8. Composed e2e + full-suite backward-compat sweep.
9. Docs (§10).
