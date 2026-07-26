# L5X Import — Foundation (sub-project 1) — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-26

## Goal

Add a **Rockwell L5X** (Studio 5000 / Logix Designer export) front-end to the
importer. The importer's IR is vendor-neutral, so this sub-project is a **new
parser only** — `parseL5x(xml) -> ImportedProject` — with `mapImportedProject`
and every downstream mapper/translator reused unchanged.

Foundation scope: map the **controller skeleton** — UDTs → structs, AOIs → custom
function blocks, controller + program tags → tags (with real scalar values), and
**ST routines → executable ST programs**. Ladder (RLL), FBD, and SFC routines,
and non-ST AOI logic, are stubbed for later sub-projects. This ships a real,
useful Rockwell import (the full tag database + type/AOI definitions + ST logic,
executable) and locks in the front-end seam — mirroring how the PLCopen skeleton
shipped before its graphical translators.

## L5X program decomposition (context)

L5X import is multiple sub-projects (the languages don't share PLCopen's
shapes). Ordered:

1. **Foundation** *(this spec)* — skeleton: UDTs, AOIs, tags, ST routines.
2. **RLL ladder compiler** — neutral-text instruction mnemonics → native LD.
3. **Non-ST AOI logic** — RLL/FBD-bodied AOI logic (rides on 2/4).
4. **L5X FBD** translator.
5. **L5X SFC** translator.

## North-star decisions (from brainstorming)

1. **New front-end only; IR + mappers reused.** `parseL5x` emits the same
   `ImportedProject` IR the PLCopen parser does. `mapImportedProject` is
   unchanged.
2. **AOIs → `FbDefinition` via the existing FB-import path.** Each AOI is emitted
   as an `ImportedPou(kind: functionBlock, lang: st, localVars: <params>,
   body: TextBody(<logic>))`, so the already-shipped `mapImportedFbs` maps it to
   an `FbDefinition` with **zero mapper changes**. Because `lookupComposite`
   resolves FB names as composite types, **AOI-typed tags resolve
   automatically**. ST-bodied AOI logic is inlined (executable now); RLL/FBD-
   bodied AOI logic → empty body + warning (interface still resolves).
3. **Flat namespace, program-prefixed program names.** A Routine → a program
   named `Program_Routine` (display-only, collision-free). Controller + program
   tags → the flat tag namespace by their own name; a genuine cross-program name
   collision gets a `_N` suffix + warning (the mapper's existing dedup).
   Unqualified routine references resolve best-effort against the flat namespace
   — correct for the common case (controller-scoped tags), collisions are the
   documented edge, matching how LD/FBD import already treat global references.
4. **Values: hydrate type defaults + scalar tag values.** UDT member defaults and
   AOI parameter `<DefaultData>` hydrate the type, so composite tags get correct
   *type-default* values. Scalar tags hydrate from Decorated `<DataValue>` (all
   radices incl. Hex). Per-instance composite value *overrides* are deferred.

## Why this shape (grounded in the codebase + real samples)

- The import seam is proven: `detectDialect(text)` (`dialect_detect.dart`)
  selects a front-end; `workspace_shell.dart` (`_handleImportedXmlText`,
  `debugImportXml`) calls `parsePlcOpen` → `mapImportedProject` →
  `ImportXmlPreview`. Adding L5X = a detect case + `parseL5x` + a routing
  branch; `mapImportedProject` is untouched.
- The IR already fits: `ImportedProject{name, types, globalVars, pous,
  warnings}`; `ImportedType`/`ImportedField{name, baseType, arrayLength,
  initialValue}`; `ImportedVar{name, baseType, arrayLength, initialValue,
  scope, retain}`; `ImportedPou{name, kind, lang, localVars, body}` with
  `PouKind.functionBlock` + `TextBody` — exactly what `mapImportedFbs`
  (`fb_import.dart`) consumes to build `FbDefinition`s.
- `normalizeType(iecType, {knownDutNames})` (`type_normalize.dart`) **already
  handles every L5X elementary type** (BOOL, SINT, INT, DINT, LINT, USINT, UINT,
  UDINT, ULINT, REAL, LREAL, STRING, WORD, DWORD) — so type mapping is free;
  `coerceInitialValue(p, appType, arrayLength, text, warnings)` coerces value
  literals.
- Real samples in `Resources/Project Exports/Rockwell-L5X/` confirm the schema
  (see §1) and are used as end-to-end corpus fixtures (§7).

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic. `parseL5x` throws `FormatException`
  ONLY for non-well-formed XML or a root that is not `<RSLogix5000Content>`;
  every valid-but-unsupported element becomes an `ImportWarning` (never a throw)
  — the exact contract `parsePlcOpen` follows.
- The `xml` package is confined to `l5x_parser.dart` (as it is to
  `plcopen_parser.dart`).
- Zero `flutter analyze` warnings (run flutter from `mobile/`).
- **Additive / backward-compatible:** the PLCopen import path is untouched; a
  PLCopen file still detects and imports identically. No new dependency.
- No new protocol → protocol-logging rule N/A.

## §1 — L5X schema (grounded in the samples)

```
<RSLogix5000Content SchemaRevision= TargetType="Controller|Program|AddOnInstruction|DataType">
  <Controller Name= Use=>
    <DataTypes>
      <DataType Name= Class="User">
        <Members><Member Name= DataType= Dimension= Radix= [Target= BitNumber=]/></Members>
    <Tags>                                  <!-- controller-scoped -->
      <Tag Name= DataType= Dimensions= Constant=>
        <Data Format="L5K"><![CDATA[[…]]]></Data>          <!-- ignored -->
        <Data Format="Decorated">
          <DataValue Value= Radix=/>                        <!-- scalar -->
          | <Structure DataType=><DataValueMember Name= Radix= Value=/>…</Structure>  <!-- composite -->
    <Programs>
      <Program Name=>
        <Tags>…</Tags>                       <!-- program-scoped -->
        <Routines>
          <Routine Name= Type="ST"><STContent><Line Number=><![CDATA[…]]></Line></STContent>
          <Routine Name= Type="RLL"><RLLContent><Rung Number=><Text><![CDATA[XIC(A)OTE(B);]]></Text></Rung>
          <Routine Name= Type="FBD|SFC">…
    <AddOnInstructionDefinitions>
      <AddOnInstructionDefinition Name= Revision=>
        <Parameters><Parameter Name= DataType= Usage="Input|Output|InOut" Visible=>
          <DefaultData Format="Decorated"><DataValue Value=/></DefaultData></Parameter></Parameters>
        <LocalTags>…</LocalTags>
        <Routines>…</Routines>               <!-- AOI logic -->
```

## §2 — New unit: `lib/import/l5x_parser.dart`

`ImportedProject parseL5x(String xml)`. Structure mirrors `plcopen_parser.dart`.

- **Root check:** parse with `xml`; `on XmlException` → `FormatException('Not
  well-formed XML: …')`. If `root.name.local != 'RSLogix5000Content'` →
  `FormatException('Not an L5X document: root is <…>, expected
  <RSLogix5000Content>.')`.
- **Project name:** the `<Controller name>` attribute (fallback
  `TargetName`, else `'Imported L5X Project'`).
- **DataTypes → `ImportedType`** (§3).
- **AOIs → `ImportedPou(kind: functionBlock)`** (§4).
- **Tags → `ImportedVar`** (§5), from `<Controller><Tags>` and every
  `<Program><Tags>`.
- **Routines → `ImportedPou(kind: program)`** (§6).
- Assemble `ImportedProject(name, types, globalVars, pous, warnings)`.

## §3 — DataTypes → structs

For each `<DataType Class="User">` (skip `Class` other than `User`):
`ImportedType(name, fields)`. For each `<Member>`:
- `name` = `@Name`; `baseType` = `@DataType`; `arrayLength` = `int.tryParse(@Dimension) ?? 0` (0 = scalar).
- `initialValue` from the member's `<DefaultData>` `<DataValue Value>` if present
  (radix-aware, §5.1), else null.
- **BIT-overlay member** (`@Target` + `@BitNumber` present): import as a plain
  `BOOL` field + an `ImportWarning(info, 'Member "X" is a bit overlay of "<Target>.<BitNumber>" — imported as a plain BOOL (no bit aliasing).')`.
  (The app has no bit-aliasing; the parent word and the BOOL field become
  independent fields.)

Member base types normalize via `normalizeType(baseType, knownDutNames:
dutNames)` in the mapper (unchanged). A member referencing a type not present in
the file (predefined AB/CIP type) resolves through the mapper's existing
unknown-type fallback (default value + the mapper's own warning).

## §4 — AOIs → function-block POUs

For each `<AddOnInstructionDefinition Name=>` →
`ImportedPou(name: <Name>, kind: PouKind.functionBlock, lang: st,
localVars: <vars>, body: <TextBody>)`:

- **Vars:** each `<Parameter>` (in document order) →
  `ImportedVar(name: @Name, baseType: @DataType, arrayLength: 0, scope: <scope>,
  initialValue: <DefaultData scalar>)`, where scope is `Usage=Input→input`,
  `Output→output`, `InOut→inOut` (the FB mapper already maps `inOut`→input +
  warning). **Skip** the system parameters `EnableIn`/`EnableOut` (identified by
  name; both are `Visible="false"` BOOLs). `<LocalTags>` → `ImportedVar(scope:
  local)` (become FB internal vars).
- **Body:** find the AOI's Logic routine (a `<Routine>` under the AOI's
  `<Routines>`; conventionally named `Logic`, else the first). If it is `Type="ST"`
  → `TextBody(<Lines concatenated>)`. If it is RLL/FBD/SFC → `TextBody('')` +
  `ImportWarning(info, 'AOI "<Name>" logic is <lang> — interface imported, logic
  not yet translated.')`.

`mapImportedFbs` (unchanged) turns these into `FbDefinition`s; `lookupComposite`
resolves AOI-typed tags.

## §5 — Tags → `ImportedVar`

For each `<Tag>` in `<Controller><Tags>` and in every `<Program><Tags>`:
`ImportedVar(name: @Name, baseType: @DataType, arrayLength: <dims>, scope:
global, initialValue: <value>, retain: <retain>)`.

- `arrayLength` from `@Dimensions` (first dimension; multi-dim → first + a
  "multi-dimensional array flattened to <n>" info warning).
- `retain` = false (L5X tags carry no IEC-style retain qualifier; retentiveness
  is not modeled in foundation).
- Program-scoped tags go into the same flat `globalVars` list; the mapper's
  existing sanitize+dedup handles cross-program name collisions (`_N` + warning).

### §5.1 — Value hydration

- **Scalar tag** (`<Data Format="Decorated"><DataValue Value= Radix=/>`):
  `initialValue` = the parsed literal. Radix handling: `Decimal` → as-is;
  `Hex`/`16#…` (with optional `_` separators, e.g. `16#ffff_0000`) → parsed int;
  `Binary`/`2#…`, `Octal`/`8#…` likewise; a `Float`/exponent → double. A value
  that fails to parse → null + info warning (the mapper defaults it).
- **Composite / array tag** (`<Structure>` / `<ArrayMember>`): foundation does
  **not** parse the tag's own member values; `initialValue` = null, so the mapper
  uses the **type default** (correct, since §3/§4 hydrated the member/parameter
  defaults). Per-instance value overrides are a deferred limitation (§12), not a
  per-tag warning (avoids noise on every composite tag).
- The `<Data Format="L5K">` twin is ignored (Decorated is authoritative).

## §6 — Routines → program POUs

For each `<Routine Name= Type=>` inside a `<Program Name=>`:
`ImportedPou(name: '<Program>_<Routine>', kind: PouKind.program, lang: <lang>,
localVars: const [], body: <body>)`:

- **`Type="ST"`** → `lang: st`, `TextBody(<all <Line> CDATA concatenated with
  '\n'>)`. Executable via the app's ST subset (best-effort, like PLCopen ST/IL
  import).
- **`Type="RLL"`** → `lang: ld`, `GraphBody(nodes: const [], connections: const
  [])` (an empty graphical body → the mapper's existing whole-POU LD stub) +
  `ImportWarning(warning, 'Routine "<Program>_<Routine>" (Ladder): <n> rungs not
  yet translated — neutral-text ladder import ships in a later update.')`.
- **`Type="FBD"`/`Type="SFC"`** → `lang: fbd`/`sfc`, empty `GraphBody` (FBD) or
  empty `SfcBody` (SFC) → the existing stub, + a count-carrying warning.

(No IR changes: RLL/FBD/SFC neutral text / graphics are not captured in
foundation; the future compilers extend `l5x_parser.dart` to capture them.)

## §7 — Dialect detection + routing

- `dialect_detect.dart`: add `ImportDialect.l5x`. `detectDialect` head-sniffs
  for `<rslogix5000content` (case-insensitive) in the leading markup → returns
  `ImportDialect.l5x`; the existing PLCopen branch is unchanged; unknown → null.
- `import_ir.dart`: extend `enum ImportDialect { plcOpen, l5x }`.
- `workspace_shell.dart`: `_handleImportedXmlText` (and `debugImportXml`) switch
  on the detected dialect: `l5x` → `parseL5x`, `plcOpen` → `parsePlcOpen`; both
  → `mapImportedProject`. Broaden the "unrecognized" snackbar to name both
  formats; keep the `on FormatException` friendly-error path.

## §8 — Reporting

Reuse the existing `ImportReport` fields — `tagCount`, `structCount`,
`stProgramCount`, `graphicalStubCount`, `importedFbCount` (AOIs surface here),
`warnings`. The preview screen already renders these; only the dialect messaging
broadens. No new report fields required for foundation (RLL/FBD/SFC counts land
with their sub-projects).

## §9 — Error handling (pure; only `parseL5x` throws `FormatException`)

| Situation | Handling |
|---|---|
| Malformed XML / non-`<RSLogix5000Content>` root | `FormatException` (friendly snackbar) |
| BIT-overlay member (`Target`/`BitNumber`) | Plain BOOL field + info warning |
| Member/tag references an unresolved (predefined AB) type | Mapper default + warning |
| AOI Logic is RLL/FBD/SFC | FB interface imported, empty body + info warning |
| RLL/FBD/SFC routine | Graphical stub + warning (rung/line count captured) |
| Program-scoped tag name collision | `_N` suffix + warning (existing dedup) |
| Hex/binary/octal scalar value | Parsed to the app's numeric value |
| Unparseable scalar value | null + info warning (mapper defaults it) |
| Per-instance composite value override | Type default used + note (deferred) |
| Multi-dimensional array | First dimension used + info warning |
| Unknown element/attribute | Ignored, no throw |

## §10 — Testing

- **Dialect detect** (`dialect_detect_test.dart`): `<RSLogix5000Content>` →
  `ImportDialect.l5x`; a PLCopen doc still → `plcOpen`; junk → null.
- **Parser unit** (`l5x_parser_test.dart`): a small hand-authored L5X →
  `ImportedProject` asserting: a UDT with an array member + a BIT-overlay member
  (→ BOOL field + warning); an AOI → a `functionBlock` POU whose `localVars` are
  the parameters in order, EnableIn/EnableOut skipped, `InOut`→inOut, ST logic in
  the body; a controller scalar tag with a **Hex** value parsed correctly; an
  AOI-typed tag; an ST routine → `Program_Routine` ST POU; an RLL routine →
  an empty LD `GraphBody` + a rung-count warning.
- **Mapping integration** (`ir_to_project` via `parseL5x`): the AOI-typed tag
  resolves to a composite whose default values come from the AOI parameter
  defaults; the AOI is an `FbDefinition`; `importedFbCount` counts it.
- **End-to-end corpus** (`import_l5x_e2e_test.dart`): parse a **real sample**
  (`Resources/Project Exports/Rockwell-L5X/logixlibraries_Numeric_Program.L5X`)
  → `mapImportedProject`; assert it produces a project (no throw), the UDTs/AOIs/
  tags import, an AOI-typed controller tag resolves with correct default values,
  and an ST-bodied AOI executes when its instance is scanned. A second sample
  (`logixlibraries_Op_PID_AOI.L5X`, ST-heavy AOIs) round-trips without throwing.
  (Load the file via the test harness the PLCopen corpus test uses.)
- **Backward-compat:** PLCopen import path and its whole test suite stay green;
  detecting/importing a PLCopen document is byte-identical to today.

## §11 — Docs

- `docs/import/` (or `docs/iec61131/`) — an L5X import support matrix (supported:
  UDTs, AOIs→FBs, tags + scalar values, ST routines; stubbed/degraded: RLL/FBD/
  SFC routines, non-ST AOI logic, BIT overlays, per-instance composite values,
  predefined AB types).
- `docs/DEFERRED.md` — record the **L5X import sub-program**: foundation
  delivered; queued 2–5 (RLL ladder compiler, non-ST AOI logic, FBD, SFC); plus
  within-foundation deferrals (BIT-overlay aliasing, per-instance composite value
  overrides, predefined AB module types, multi-dimensional arrays).

## §12 — Deferred (tracked in `docs/DEFERRED.md`)

- **RLL ladder compiler** — neutral-text instructions → native LD (sub-project 2).
- **Non-ST AOI logic** (RLL/FBD-bodied) — rides on 2/4 (sub-project 3).
- **L5X FBD / SFC** translators (sub-projects 4/5).
- **BIT-overlay member aliasing** — no bit-aliasing in the app model.
- **Per-instance composite tag value overrides** — type defaults used for now.
- **Predefined AB/CIP module datatypes** — only user UDTs/AOIs resolve.
- **Multi-dimensional arrays** — flattened to the first dimension.
