# Importing a PLC Program (PLCopen XML)

The app can import an existing PLC program from a **PLCopen TC6 XML** export
and turn it into a brand-new Soft PLC project — variables, DUTs (structs),
and Structured Text/Instruction List programs. This is an **in-app, pure-Dart
import**: no companion service, no upload to a server, consistent with this
project's in-app-hosting approach to everything else (protocols, the scan
engine, the historian).

```
PLCopen TC6 .xml file  --detect--> parse --> map -->  preview  -->  NEW project
 (CODESYS, Beckhoff,                                  (review        (the
  Schneider, Rockwell,                                 name/counts/    active
  ... any TC6 exporter)                                 warnings)      project
                                                                       is left
                                                                       untouched)
```

## What's supported

- **Global variables → tags.** Every `<globalVars>` variable becomes a
  `PlcTag`, with its elementary IEC type (`BOOL`, `INT`, `REAL`, `LREAL`, …)
  normalized to the app's tag type set, its array dimension, its initial
  value (when present) becoming the tag's default, and its retain state
  mapped to the tag's retentive flag. Per the TC6 schema the `retain`
  qualifier lives on the variable-list container (`<globalVars retain="true">`),
  not on the individual `<variable>`, and it is read from there; a
  `constant`-qualified block is not treated as retentive. `input`/`output`-scoped
  variables map to `SimulatedInput`/`SimulatedOutput`; everything else
  (`local`, `temp`, `external`, plain globals) maps to `Internal`.
- **DUTs (derived data types) → structs.** Each `<dataType>` with a
  `<struct>` body becomes a `PlcStructDef`, including struct-typed and
  array-of-struct fields (nested DUTs resolve in dependency order, so a
  struct referencing another struct gets its real nested default value, not
  a placeholder).
- **ST and IL POUs → Structured Text programs.** A `<pou>` whose body is
  `<ST>` or `<IL>` becomes a `PlcProgram` with `language: 'StructuredText'`.
  IL is imported as-is into the ST source and flagged with an info warning —
  **verify it against the app's ST subset**; this is a straight text carry,
  not an IL-to-ST translation.

## What's captured but not yet translated (LD/FBD/SFC)

A `<pou>` whose body is `<LD>`, `<FBD>`, or `<SFC>` (Ladder Diagram, Function
Block Diagram, Sequential Function Chart) is **not** rendered into the app's
own ladder/FBD/SFC editors yet. Its graphical body (every element's type,
position, and connections) is captured **losslessly** internally, but the
program that lands in the new project is a **stub**: an empty
`LadderLogic`/`FunctionBlockDiagram`/`SequentialFunctionChart` program named
after the original POU, with a description noting how many graphical
elements were captured and that the body isn't translated yet. Each stub
raises a **warning** in the import preview so it's never silently lossy-by
surprise.

Re-importing the same file once a per-language graphical translator ships
will turn these stubs into real, editable diagrams — the capture already
holds everything a translator needs (node types, positions, and the
connection graph, including each wire's **pin identity** — which
`formalParameter` input/output pin of a multi-input block it attaches to),
so no new import work will be required upstream of the translator when it
lands.

## Autodetect (no format picker)

Only one dialect is recognized today — **PLCopen TC6** — so there is no
source/format dropdown to choose from. The importer sniffs the file's
leading markup for a `<project>` root in a PLCopen namespace (`plcopen` or
`tc6` appearing in the document). If that isn't found, you get a friendly
snackbar:

> Couldn't recognize this as a supported PLC export (only PLCopen TC6 XML is
> supported so far)

and nothing else happens — no project is created, nothing is modified. If
the file *is* recognized as PLCopen but isn't well-formed XML (or its root
element genuinely isn't `<project>`), you instead get:

> Couldn't import: not a valid PLCopen document

Both are dead ends by design, not crashes: a bad file never corrupts or
replaces your current project.

## Where it lands: always a new project

A successful import **never modifies the project you currently have open**.
It always creates a **new** project (named from the source file's
`<contentHeader name="...">`, editable in the preview before you commit) and
switches to it, exactly like using **Import Project** for a `.splc.json`
file. If the imported project's id would collide with one already in your
project list, it's renamed deterministically (`..._import`, `..._import_2`,
…) the same way project-file import already handles collisions.

Before the project is created you see a **preview**: the editable project
name, an at-a-glance count line (`N tags · M structs · K programs (J
graphical stubs)`), and every warning collected while mapping (identifier
renames, reserved-name collisions, graphical-body stubs, and anything else
worth a second look) — info-level warnings in white, and the more important
graphical-stub/collision warnings in amber. Nothing is created until you tap
**Create**; **Cancel** discards the import entirely.

## How to run it

1. Open the project ⋮ menu (the same menu **Import Project** lives in).
2. Tap **Import PLC Program (XML)**.
3. Pick a `.xml` file exported from a PLCopen-TC6-capable tool.
4. Review the preview (rename if you like, check the warnings).
5. Tap **Create** to land the new project, or **Cancel** to back out.

## Deferred (not in this release)

- **Graphical translators.** Turning the captured LD/FBD/SFC graph into real
  editable ladder/FBD/SFC bodies (rather than a stub) — a later workstream,
  re-importable against the same file once it ships.
- **Other vendor formats.** Rockwell L5X, Siemens TIA Portal exports, and any
  other non-PLCopen dialect are not recognized yet — only PLCopen TC6 XML is
  autodetected today.
- **Merge-into-existing-project import.** Import always targets a brand-new
  project; there is no "merge these tags/programs into my current project"
  mode.
- **Export to PLCopen XML.** This feature is import-only; there is no
  PLCopen-XML export path out of the app.
