# PLCopen-XML Program Import (foundation) — Design Spec

**Date:** 2026-07-21. **Status:** user-approved design, pre-plan.
**This is sub-project 1** of a multi-part program-import capability. It builds
the reusable import spine + the first vendor parser (PLCopen TC6 XML) + the
mappers that translate cleanly. The per-language graphical translators
(LD/FBD/SFC → the app's graph models) and additional vendor parsers (Rockwell
L5X, Siemens TIA Openness) are **later sub-projects**, each its own
spec → plan → build, all feeding the same intermediate representation this
spec defines.

## Goal

Let a user import a **PLCopen TC6 XML** program export (the ISO/IEC 61131-10
interchange format that CODESYS, Beckhoff, and Schneider emit) into the soft
PLC — creating a **new project** from it. v1 maps what maps cleanly:
variables → tags, data types (DUTs) → structs, and ST/IL POU bodies →
Structured-Text programs. Graphical POUs (LD/FBD/SFC) are captured **losslessly
into a vendor-neutral intermediate representation (IR)** and imported as
program stubs, so a later sub-project translates them without re-parsing.

## Context (verified on-branch)

- **Target model** — `PlcProject` (`mobile/lib/models/project_model.dart`):
  `tags` (`PlcTag`: name/path/dataType/`arrayLength`/**`defaultValue`**/`ioType`/
  access/…), `structDefs` (`PlcStructDef` + `StructFieldDef`:
  name/dataType/arrayLength/`defaultValue` — the DUT model), `programs`
  (`PlcProgram`: `language` ∈ `StructuredText`/`LadderLogic`/
  `FunctionBlockDiagram`/`SequentialFunctionChart`, `stSource` text, plus the
  graph models `LdRung`/`FbdBlock`/`FbdWire`/`SfcStep`/`SfcTransition`),
  `tasks`, `hmis`.
- **App data types** — `BOOL`, `INT16`, `INT32`, `INT64`, `FLOAT64`, `STRING`,
  `TIMER`, plus composite/struct names. Defaults from
  `defaultValueFor(project, type, arrayLength)` (`tag_resolver.dart`).
- **Import spine to mirror** — `data/project_transfer.dart` is a pure,
  plugin-free `.splc.json` encode/decode with an explicit shape-check that
  ALWAYS throws `FormatException` (never an obscure type) on a non-project
  file. The "Import Project" menu entry + `file_picker`/`share_plus` wrappers
  live in `workspace_shell.dart` (`:2189`), never in the pure core.
- **No `xml` dependency yet** — this spec adds the pure-Dart `xml` package.
- **The mapping reality** — the app's LD/FBD/SFC are its OWN coordinate/graph
  models; PLCopen's graphical bodies are a different coordinate/localId graph.
  Translating them is a hard, per-language effort (a later sub-project). ST
  text maps straight to `stSource`; variables/DUTs map cleanly.

## Decisions taken (user-approved)

1. **First dialect: PLCopen TC6 XML** (one parser, multiple vendors, open
   schema). L5X / Siemens Openness are additive parsers behind the same
   pipeline later.
2. **Reusable-mapper architecture = a vendor-neutral IR.** Every vendor parser
   emits the SAME IR; every language mapper consumes it. The IR represents ALL
   languages losslessly.
3. **Staging: foundation now, graphical translators next.** v1 = pipeline + IR
   + PLCopen parser + vars/DUTs/ST-IL mappers. Graphical POUs → IR (lossless)
   + imported as stubs. LD, FBD, SFC translators are each their own later
   sub-project consuming the IR.
4. **Import target: a NEW project** (named from the file / PLCopen project
   name), added to the project list, leaving the current project untouched.
   No merge / collision-resolution UI in v1.
5. **Autodetect with manual override.** Detection sniffs the root element /
   namespace; a source-format dropdown shows the detected dialect and allows
   override; unimplemented dialects appear disabled ("coming soon"); an
   unrecognized file gets a clear message, never a crash.

## Non-goals / YAGNI (deferred, each its own later sub-project unless noted)

- Graphical body translation (IR-`GraphBody` → `LdRung` / `FbdBlock`+`FbdWire`
  / `SfcStep`+`SfcTransition`) — LD, FBD, SFC each deferred.
- Rockwell `.L5X` and Siemens TIA Openness XML parsers.
- Omron / Mitsubishi exports (partial / CSV — not standardized XML).
- **Merge into the current project** and any collision-resolution UI.
- **Export** (soft PLC → PLCopen XML). Import only.
- Full IEC POU semantics beyond the app's ST subset: functions/FB *calls*
  inside ST are imported as text verbatim (the app's ST evaluator handles what
  it handles); no attempt to synthesize app FB instances from IEC FB types.
- Task/resource execution mapping — POUs import as programs; task assignment is
  left to the user (a warning notes any resource/task associations found).

## Global Constraints

- Pure Dart (no Flutter, no `dart:io`) for the IR, the parser, and the mappers
  (`mobile/lib/import/`); only the file-pick + navigation lives in the shell
  wrapper. `xml` is the sole new dependency (pure Dart, no native).
- **Additive / non-destructive**: importing creates a new project; nothing in
  the current project, existing serialization, or scan behavior changes. The
  lossless round-trip and default-projects suites stay green.
- **Never crash on hostile/partial input**: the parser throws `FormatException`
  (clear message) ONLY on structurally-invalid XML or a non-PLCopen document;
  valid-but-unexpected content becomes an `ImportWarning`, never a throw. The
  mappers never throw.
- Deterministic: no clock/RNG in the parser/mappers (stable IDs, stable
  ordering).
- Dark theme; `withValues(alpha:)` not `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320 / 360 / 1400.
- Identifier hygiene: imported names are sanitized to the app's tag/struct
  identifier rules; every rename is recorded as a warning. The reserved
  `System` name can never be produced (a colliding import name is suffixed).

## Component 1 — The vendor-neutral IR (`import/import_ir.dart`)

Pure data classes, no Flutter, no interpretation of graphical bodies:

- `ImportedProject { String name; List<ImportedType> types; List<ImportedVar>
  globalVars; List<ImportedPou> pous; List<ImportWarning> warnings; }`
- `ImportedType { String name; List<ImportedField> fields; }` (a DUT);
  `ImportedField { String name; String baseType; int arrayLength; dynamic
  initialValue; }`.
- `ImportedVar { String name; String baseType; int arrayLength; dynamic
  initialValue; VarScope scope; bool retain; }` where
  `enum VarScope { global, input, output, inOut, local, temp, external }`.
- `ImportedPou { String name; PouKind kind; PouLanguage lang;
  List<ImportedVar> localVars; PouBody body; }` where
  `enum PouKind { program, functionBlock, function }` and
  `enum PouLanguage { st, il, ld, fbd, sfc }`.
- `sealed class PouBody`:
  - `TextBody extends PouBody { String source; }` (ST/IL).
  - `GraphBody extends PouBody { List<IrGraphNode> nodes; List<IrConnection>
    connections; }` — the lossless capture: `IrGraphNode { int localId; String
    elementType; double x; double y; Map<String,String> attributes; }`
    (elementType e.g. `contact`/`coil`/`block`/`step`/`transition`/`inVariable`;
    attributes preserve negated/edge/typeName/expression/etc.), `IrConnection
    { int toLocalId; int toPort; int fromLocalId; int fromPort; }`. No app-model
    shape is assumed — a later per-language mapper interprets this.
- `ImportWarning { WarningSeverity severity; String message; }` with
  `enum WarningSeverity { info, warning }` (info = something was mapped with a
  caveat, e.g. an IL POU imported as ST; warning = something was NOT mapped,
  e.g. an unknown elementary type fell back to a default).

`GraphBody` is the load-bearing "represents all languages losslessly" piece:
v1's parser populates it fully for LD/FBD/SFC POUs, but v1's mapper does not
consume it (the stub mapper ignores its contents beyond the language tag).
Each later per-language sub-project adds an IR→app-graph mapper to the
pipeline; the user then **re-imports the same file** and the parser produces
the same `GraphBody` for the new mapper to translate. The IR is transient
per-import — nothing about the graph needs persisting into the project, and no
re-architecture is required to add a translator.

## Component 2 — Dialect detection (`import/dialect_detect.dart`)

`ImportDialect? detectDialect(String xml)` — a cheap sniff of the leading
markup (no full parse): PLCopen when the root is `<project>` and a namespace
attribute contains `plcopen` or `iec61131` (TC6 uses
`http://www.plcopen.org/xml/tc6...`). Returns `ImportDialect.plcOpen`, or
`null` when unrecognized. `enum ImportDialect { plcOpen /* future: l5x,
siemensOpenness */ }`. Detection never throws (a malformed head → `null`).

## Component 3 — The PLCopen TC6 parser (`import/plcopen_parser.dart`)

`ImportedProject parsePlcOpen(String xml)` using the `xml` package. Throws
`FormatException` (clear message) on invalid XML or a document that isn't a
PLCopen `<project>`; otherwise walks:

- `<project><types><dataTypes><dataType name="…"><baseType><struct>` → an
  `ImportedType`; each `<variable name><type>` member → `ImportedField`
  (base type normalized via Component 4, array dims from `<array>`,
  `<initialValue>` decoded).
- Global vars from `<instances><configurations><configuration><resource>
  <globalVars>` AND top-level `<types>`-level global var lists → `ImportedVar`
  (scope `global`).
- `<pou name="…" pouType="program|functionBlock|function">` → `ImportedPou`:
  local vars from `<interface><localVars>/<inputVars>/<outputVars>/…` (scope
  from the section), `<body>`'s single language child selects `PouLanguage`
  and body kind: `<ST>`/`<IL>` → `TextBody` (`<xhtml>`/CDATA text extracted);
  `<LD>`/`<FBD>`/`<SFC>` → `GraphBody` (every child element → `IrGraphNode`
  with its `localId`, `<position x y>`, and type-specific attributes;
  `<connectionPointIn><connection refLocalId="…" formalParameter=…>` →
  `IrConnection`). Unknown elements inside a body → captured as a generic
  `IrGraphNode` with its raw attributes + an `info` warning (lossless, never
  dropped).

Deterministic: elements are emitted in document order; localIds are the file's
own. No positional guessing.

## Component 4 — Type normalization (`import/type_normalize.dart`)

`String normalizeType(String iecType, {required List<String> knownDutNames})`
+ the initial-value coercion. Table (IEC/PLCopen → app):

| IEC type | App type |
| --- | --- |
| `BOOL` | `BOOL` |
| `SINT`/`INT`/`UINT`/`USINT`/`BYTE`/`WORD` | `INT16` |
| `DINT`/`UDINT`/`DWORD` | `INT32` |
| `LINT`/`ULINT`/`LWORD` | `INT64` |
| `REAL` | `FLOAT64` |
| `LREAL` | `FLOAT64` |
| `STRING`/`WSTRING`/`CHAR`/`WCHAR` | `STRING` |
| `TIME`/`TON`/`TOF`/`TP` | `TIMER` |
| a name in `knownDutNames` | that name (a struct ref) |
| anything else | `INT16` + a `warning` |

Initial values: `coerceScalarValue(appType, rawText)` (the helper from the tag
value-editing feature) applied to the PLCopen `<initialValue><simpleValue
value="…">`; a structured/array initial value beyond v1 scope → the type
default + an `info` warning. `LREAL→FLOAT64` and any `LINT` beyond 2^53 note a
precision-narrowing `info` warning (the app stores doubles/ints natively;
document the same narrowing story as the protocol layers).

## Component 5 — The mappers (`import/ir_to_project.dart`)

`(PlcProject, ImportReport) mapImportedProject(ImportedProject ir, {required
String projectName})` — pure, never throws, composes small mappers:

- **DUTs → structs**: `ImportedType` → `PlcStructDef`/`StructFieldDef`,
  emitted in dependency order (a struct referencing another comes after it;
  a cycle → break with a warning, mirroring `defaultValueFor`'s cycle guard).
- **Vars → tags**: each global `ImportedVar` → a `PlcTag`: normalized
  `dataType`, `arrayLength`, **`defaultValue` = the IR initialValue** (else the
  type default), `value` seeded to the default, `ioType` from scope
  (`input`→`SimulatedInput`, `output`→`SimulatedOutput`, else `Internal`),
  `retentive` from `retain`, name sanitized (warning on change; `System`
  suffixed). POU-local vars are NOT hoisted to global tags in v1 (an `info`
  warning lists POUs whose locals were not imported — the app's tag model is
  flat/global).
- **ST/IL POUs → programs**: `TextBody` → a `PlcProgram`
  (`language:'StructuredText'`, `stSource` = the text). IL → imported as ST
  text verbatim + an `info` warning "imported from IL — verify against the
  app's ST subset".
- **Graphical POUs → stubs**: an LD/FBD/SFC `GraphBody` → a `PlcProgram` with
  the matching `language`, empty graph, and a `description` note "graphical
  body not yet translated (N elements captured) — re-import once LD/FBD/SFC
  translation ships". A `warning` per graphical POU. (When a later sub-project
  adds the IR→app-graph mapper, this stub branch is replaced by a real
  translation — no persisted graph is needed; see Component 1.)
- **`ImportReport`**: the created project name, counts (tags, structs, ST
  programs, graphical stubs), and the full ordered warning list (from the
  parser + the mappers), for the preview.

## Component 6 — UI (import flow + preview)

Thin wrapper in `workspace_shell.dart` beside the existing "Import Project":

- New menu entry **"Import PLC Program (XML)…"** → `file_picker` (`.xml`) →
  read text → `detectDialect()`.
- **Import dialog**: a **source-format dropdown** (default = detected dialect;
  PLCopen enabled, L5X/Siemens shown disabled "coming soon"); if detection
  returned `null`, a clear "Couldn't recognize this as a supported export —
  pick the format or check the file" line. On confirm, `parsePlcOpen` →
  `mapImportedProject`.
- **Preview** (a screen/dialog, keyed for tests): editable new-project **name**
  (default from the IR), the **counts**, and a scrollable **import report**
  (info + warning lines, colour-coded), then **Create Project** (adds to the
  project list via the existing repository/save path) or **Cancel**. A
  `FormatException` from the parser surfaces as a friendly error, not a crash.

## Data flow

file → `detectDialect` → (dropdown/override) → `parsePlcOpen` → `ImportedProject`
→ `mapImportedProject` → `(PlcProject, ImportReport)` → preview → create new
project (existing save/repository path). The pure core (detect/parse/normalize/
map) is plugin-free and fully unit-tested; only file-pick + navigation touch
Flutter/plugins.

## Error handling / edge cases

- Invalid XML / non-PLCopen document → `FormatException` with a message naming
  what was wrong; surfaced as a dialog, never a crash.
- Unknown elementary type → `INT16` + warning. Unknown DUT reference → treated
  as a struct name (may dangle if that DUT wasn't in the file) + warning.
- Empty/again-imported file, huge file → bounded by the `xml` parser; a POU
  with an empty body → an empty ST program + info warning.
- Name collisions WITHIN the import (two vars same name) → second suffixed +
  warning. `System` → suffixed. Names are sanitized to the app's identifier
  rules.
- Graphical bodies are never dropped — captured to `GraphBody` even when not
  translated.

## Testing

- **Fixtures**: hand-authored valid PLCopen TC6 XML under
  `mobile/test/fixtures/plcopen/` (PLCopen is an open schema — no proprietary
  tool needed): (a) a DUT with a struct + array + initial values; (b) global
  vars of each elementary type with initial values + a retain var; (c) an ST
  POU; (d) an LD (or FBD) POU with a few graphical elements + connections; plus
  a malformed-XML file and a non-PLCopen XML file.
- **Unit**: `detectDialect` (PLCopen vs unknown vs malformed); `normalizeType`
  full table + initial-value coercion + narrowing warnings; `parsePlcOpen`
  against the fixtures (throws on the malformed/non-PLCopen ones; captures the
  graphical body losslessly — assert node/connection counts + a preserved
  attribute); `mapImportedProject` (vars→tags incl. defaultValue + ioType +
  retain + sanitized name; DUTs→structs dependency order; ST→program; graphical
  →stub with retained GraphBody + warning; the report counts/warnings).
- **Widget**: the import dialog (dropdown + disabled future dialects), the
  preview (name edit, counts, report), Create adds a new project and leaves the
  current one untouched; a malformed file shows the friendly error; no overflow
  at 320/360/1400.
- Existing lossless round-trip + default-projects suites stay green (additive).

## Files

- Create: `mobile/lib/import/import_ir.dart`, `dialect_detect.dart`,
  `type_normalize.dart`, `plcopen_parser.dart`, `ir_to_project.dart`;
  `mobile/lib/screens/import_xml_preview.dart` (or a dialog in the shell).
- Modify: `mobile/pubspec.yaml` (`xml`), `mobile/lib/screens/workspace_shell.dart`
  (menu entry + file-pick wrapper + navigation), `docs/` (a short
  `docs/import/plcopen.md`).
- Tests: `mobile/test/import/*` + `mobile/test/fixtures/plcopen/*`.

## Risks

- **Schema variance across vendors**: CODESYS/Beckhoff/Schneider each emit
  slightly different PLCopen (namespaces, extension elements, where globals
  live). Mitigated by: parsing defensively (unknown elements → warnings, not
  throws), the lossless `GraphBody`, and driving the fixtures from more than one
  vendor's element conventions. A real vendor export that the fixtures don't
  cover is the expected first bug — the warning-not-crash contract keeps it
  safe and diagnosable.
- **`GraphBody` shape adequacy for the later translators**: mitigated by
  capturing localIds, positions, ports, AND raw attributes verbatim — the
  translators get everything the file had. If a translator later finds the IR
  lossy, that's an additive IR field, not a re-architecture.
- **New dependency (`xml`)**: standard, pure-Dart, widely used; low risk. The
  parser confines all `xml` API use to `plcopen_parser.dart`.

## Decomposition (plan-time)

Likely five tasks:
1. IR data classes + dialect detection (pure, unit-tested).
2. Type normalization + initial-value coercion (pure, table-tested).
3. PLCopen parser → IR incl. lossless GraphBody (fixtures; throws on
   malformed/non-PLCopen).
4. IR → PlcProject mappers + ImportReport (vars/DUTs/ST/IL/graphical-stub).
5. Import UI (menu + dialect dropdown + preview + create-new-project) + docs +
   whole-feature validation.
