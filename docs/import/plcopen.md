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
- **Ladder Diagram POUs → real `LadderLogic` programs.** A `<pou>` whose body
  is `<LD>` is translated **per rung** into the app's own executable ladder
  format — this is correctness-first, not best-effort: contacts, coils (with
  their set/reset/negated/edge modifiers), series/parallel wiring, and the
  timer/counter/compare/math/MOVE function blocks it supports are turned into
  real, editable `LdRung`s, with backing `TIMER`/`COUNTER` tags created for
  any timer/counter block instance. Any individual rung whose topology or
  block usage falls outside what the translator currently supports (an
  unsupported block type, a non-series-parallel bridge/bypass, an
  unresolvable operand, …) becomes a commented placeholder rung **in that
  same program** instead — it never silently drops or misrepresents logic.
  Every stubbed rung raises a **warning** naming the POU, the rung number, and
  the reason, and the import report's counts (translated vs. stubbed rungs,
  and which block types weren't recognized) surface in the preview so nothing
  is silently lossy. A POU where *every* rung stubs is reported as a
  **graphical stub** (see below) exactly like an untranslated FBD/SFC POU;
  a POU with at least one translated rung is a real program, with any
  remaining stubbed rungs still called out by warning.

## FBD and SFC POUs → real, translated diagrams

A `<pou>` whose body is `<FBD>` or `<SFC>` (Function Block Diagram,
Sequential Function Chart) is translated into the app's own FBD/SFC editors,
the same way LD is — **faithful-or-stub**, at a different granularity per
language:

- **`<FBD>` → per-network translation.** Each weakly-connected component of
  the diagram becomes one native `FbdNetwork` (built-in blocks, `TAG_INPUT`/
  `TAG_OUTPUT`/`CONST` pseudo-blocks, custom-FB call routing, wire pin
  identity). A network that fails to translate (an unsupported element type,
  a negated pin, a compound expression, an unknown block type, an
  unresolved pin) degrades to an empty network with an explanatory comment
  and a warning — but the POU still lands as a real, editable program as
  long as at least one network translated. See
  `docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md`'s "FBD import" section for the
  exact support matrix.
- **`<SFC>` → whole-chart translation.** The entire chart (steps, N-qualified
  actions, linear/selection/simultaneous transitions, jump steps) becomes
  one native `SequentialFunctionChart` program. Unlike FBD, this is
  faithful-or-stub at the **whole-POU** level, not per-element: any
  unsupported topology or condition anywhere in the chart (a wired
  transition condition, a condition/action referencing a graphical body,
  complex/unknown topology, no initial step) falls the entire POU back to a
  stub; an unrepresentable step action alone degrades to a no-op with a
  warning instead of stubbing the chart. See
  `docs/iec61131/SEQUENTIAL_FUNCTION_CHART.md`'s "SFC import" section for
  the exact support matrix.

A POU whose graphical body translates to nothing usable still lands as a
**stub** — an empty `FunctionBlockDiagram`/`SequentialFunctionChart` program
named after the original POU, with a description noting how many graphical
elements were captured. Every stub raises a **warning** in the import
preview so it's never silently lossy-by-surprise, exactly like a fully-
stubbed LD rung.

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

- **FBD negated pins, `inOutVariable`, `connector`/`continuation`, and
  `label`/`jump`.** These specific FBD constructs have no native equivalent
  yet and stub the network they appear in (per-network translation itself
  has shipped; see above and `docs/DEFERRED.md`'s "FBD & SFC graphical
  translators" section for the full, current list of narrower gaps).
- **SFC stored/pulse/timed action qualifiers (S/R/P/L/D/SD/DS/SL), wired
  transition conditions, and graphical (LD/FBD) transition/action bodies.**
  Only the `N` (non-stored) action qualifier and inline/referenced-ST
  conditions translate today (whole-chart translation itself has shipped;
  see above and `docs/DEFERRED.md` for the full list).
- **Other vendor formats.** Rockwell L5X, Siemens TIA Portal exports, and any
  other non-PLCopen dialect are not recognized yet — only PLCopen TC6 XML is
  autodetected today.
- **Merge-into-existing-project import.** Import always targets a brand-new
  project; there is no "merge these tags/programs into my current project"
  mode.
- **Export to PLCopen XML.** This feature is import-only; there is no
  PLCopen-XML export path out of the app.
