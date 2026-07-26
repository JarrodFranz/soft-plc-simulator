# SFC Import Translator — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-26

## Goal

Convert imported PLCopen **SFC** (Sequential Function Chart) POUs — today captured
in the IR but emitted as a whole-POU stub — into real, executable native
`SequentialFunctionChart` program bodies. This is sub-project 3 of 3 in the
graphical-translators program (LD shipped `2026-07-22`; FBD shipped `2026-07-26`,
PR #12); shipping it **completes** the program.

Policy (from brainstorming): **whole-POU faithful-or-stub** for structure and
transition conditions — an SFC chart is one connected state machine, so it
translates in full or the whole POU stays a stub (a stubbed/empty transition
condition evaluates to `false` forever and would deadlock the chart). An
individual step **action** that cannot be represented degrades to a no-op +
warning (a missing action omits side effects but does not break chart flow).

## North-star decisions

1. **Whole-POU faithful-or-stub (structure + conditions); actions degrade.**
   The entire chart translates or the whole POU stays a stub. Unrepresentable
   step actions (non-N qualifier, graphical/unresolved body) become no-ops with
   a warning; the chart still translates.
2. **Inline + referenced ST conditions/actions resolved.** A transition's
   condition or a step's action written inline is used directly; a `<reference
   name="X"/>` to a transition/action defined in the POU's `<transitions>` /
   `<actions>` sections is resolved to that ST body and inlined. A referenced
   **graphical** (LD/FBD) body cannot be inlined → whole-POU stub (condition) /
   no-op action (action) + warning. This is what makes SFC import usable on real
   exports, mirroring how `<expression>` support did for FBD.
3. **N action qualifier only.** Only N (non-stored) actions map to the native
   `SfcStep.actionSt` (run-while-active semantics). Stored/pulse/timed
   qualifiers (S/R/P/L/D/SD/DS/SL) degrade to no-op + warning — approximating
   them as N would be silently-wrong. Multiple N actions on one step concatenate
   in declaration order.
4. **Typed SFC IR, not the generic `GraphBody`.** SFC elements carry payloads
   `GraphBody` cannot hold (a transition owns a condition; a step owns actions
   with qualifiers; both may be named sub-POUs). The parser extracts SFC bodies
   into a dedicated typed `SfcBody`; the translator maps typed IR → native.

## Why this shape (grounded in the codebase)

- The native model already provides the full target:
  `SfcStep{id, name, isInitial, actionSt}` and
  `SfcTransition{id, fromStepId, toStepId, conditionSt, kind, toStepIds,
  fromStepIds}` (`models/project_model.dart`), executed by
  `executeSfcPrograms` (`models/sfc_exec.dart`): the initial step (else the
  first) activates; each scan every active step's `actionSt` runs as ST with
  `STEP_T` available; transitions fire against a start-of-scan snapshot —
  `kind:'single'` alternatives are first-true-wins in transition-list order,
  `kind:'parallelFork'` (`fromStepId`→`toStepIds`) activates all branch heads,
  `kind:'parallelJoin'` (`fromStepIds`→`toStepId`) waits until every source is
  active. An **empty/unparseable `conditionSt` evaluates to `false`**
  (`evalStCondition` → `evalExpr` null → false), which is exactly why a stubbed
  condition would deadlock — hence whole-POU stub for conditions.
- The importer is a pure IR→project mapper (`lib/import/ir_to_project.dart`).
  Its SFC POUs currently route through `_graphBody` → `GraphBody` and hit the
  `else if (body is GraphBody)` whole-POU stub arm (lines ~308-321). This spec
  routes SFC POUs to a new `SfcBody` and a new `body is SfcBody` arm; the
  `GraphBody` fallback arm stays for any other graphical language.
- The PLCopen parser (`plcopen_parser.dart`) already isolates the `xml`
  package, resolves the POU body language (`_pou` → `SFC` case), and has helper
  patterns (`_findElement`, `_descendants`, attribute copy) the SFC body builder
  reuses.

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never-throws** — an
  untranslatable chart degrades to the whole-POU stub; the pipeline continues.
- Zero `flutter analyze` warnings (run flutter from `mobile/`).
- **Additive / backward-compatible:** a project with no SFC POUs imports
  byte-identically. The SFC arm fires only on `pou.lang == PouLanguage.sfc`.
  Existing PLCopen corpus/round-trip tests and the app's own SFC round-trip
  tests stay green.
- Follows the importer's name discipline where it applies (step names sanitized
  for display; step **ids** are deterministic synthetic ids, not user names).
- No new protocol → protocol-logging rule N/A. No new dependency.

## §1 — Typed SFC IR (`import_ir.dart`)

```dart
enum SfcNodeKind { step, transition, selDiv, selConv, simDiv, simConv, jump }

/// A transition's condition source.
sealed class SfcCond {}
class SfcCondInline extends SfcCond { final String text; SfcCondInline(this.text); }
class SfcCondRef    extends SfcCond { final String name; SfcCondRef(this.name); }
class SfcCondWired  extends SfcCond {}            // a graphical/FBD-driven signal
class SfcCondNone   extends SfcCond {}            // no condition found

/// An action associated with a step.
sealed class SfcActSource {}
class SfcActInline extends SfcActSource { final String text; SfcActInline(this.text); }
class SfcActRef    extends SfcActSource { final String name; SfcActRef(this.name); }

class SfcActionAssoc {
  final int stepLocalId;
  final String qualifier;        // 'N','S','R','P','L','D','SD','DS','SL', ...
  final SfcActSource source;
  SfcActionAssoc({required this.stepLocalId, required this.qualifier, required this.source});
}

class SfcNode {
  final int localId;
  final SfcNodeKind kind;
  final double x, y;
  final String name;             // step name / jump targetName / '' otherwise
  final bool initial;            // step only
  final SfcCond? condition;      // transition only
  SfcNode({required this.localId, required this.kind, this.x = 0, this.y = 0,
      this.name = '', this.initial = false, this.condition});
}

class SfcEdge { final int fromLocalId, toLocalId; SfcEdge({required this.fromLocalId, required this.toLocalId}); }

class SfcBody extends PouBody {
  final List<SfcNode> nodes;
  final List<SfcEdge> edges;
  final List<SfcActionAssoc> actions;
  final Map<String, String> refBodies;   // name -> ST source (ST-bodied local transitions/actions)
  final Set<String> graphicalRefs;       // names of referenced local bodies that are graphical (can't inline)
  SfcBody({required this.nodes, required this.edges, required this.actions,
      this.refBodies = const {}, this.graphicalRefs = const {}});
}
```

## §2 — Parser: build `SfcBody` (`plcopen_parser.dart`)

Route an SFC POU to a new `_sfcBody(langEl, pouEl, warnings, pouName)` instead of
`_graphBody` (the `resolvedLang == PouLanguage.sfc` branch). It:

- **Steps:** for each `<step>` → `SfcNode(kind: step, name: @name,
  initial: @initialStep == 'true')`.
- **Transitions:** for each `<transition>` → `SfcNode(kind: transition,
  condition: <parsed>)`. Parse the `<condition>` child:
  - `<condition><inline><ST>…` (or an `<ST>`/`xhtml` text child) → `SfcCondInline(text)`.
  - `<condition><reference name="X"/>` → `SfcCondRef('X')`.
  - `<condition>` containing a `connectionPointIn` (wired boolean) or an FBD/LD
    sub-body → `SfcCondWired()`.
  - no `<condition>` → `SfcCondNone()`.
- **Action blocks:** each `<actionBlock>` is associated with a step via a
  `connectionPointIn`/`connectionPointOut` to that step's local id. For each
  `<action>` child → `SfcActionAssoc(stepLocalId, qualifier: @qualifier ?? 'N',
  source: <inline ST text | SfcActRef(@reference name)>)`.
- **Divergence/convergence/jump:** `<selectionDivergence>`→selDiv,
  `<selectionConvergence>`→selConv, `<simultaneousDivergence>`→simDiv,
  `<simultaneousConvergence>`→simConv, `<jumpStep>`/`<jump>`→jump
  (`name: @targetName`).
- **Edges:** every `<connectionPointIn><connection refLocalId=…/>` → an
  `SfcEdge(fromLocalId: ref, toLocalId: thisNode)` (same walk `_graphBody` uses).
- **Referenced local bodies:** read the POU's sibling `<transitions>` /
  `<actions>` sections (children of `<pou>`, not `<body>`): each
  `<transition name="X"><body><ST>…` / `<action name="Y"><body><ST>…` →
  `refBodies['X'|'Y'] = <ST text>`; a section body in `<LD>`/`<FBD>`/`<SFC>` →
  add the name to `graphicalRefs` (referenced-but-not-inlinable). (`_pou` passes
  the `<pou>` element down so these siblings are reachable.)

The parser routes ST-condition/action text through the existing text extraction
(handles `<ST>`/`xhtml`/`<inline>`), trimming it.

## §3 — Translator (`lib/import/sfc_translate.dart`)

Pure, deterministic, never-throws.

```dart
class SfcTranslation {
  final List<SfcStep> steps;
  final List<SfcTransition> transitions;
  final bool translated;         // false => caller keeps the whole-POU stub
  final String? stubReason;      // sfcStubReasons key when !translated
  final List<ImportWarning> warnings;
  SfcTranslation({required this.steps, required this.transitions,
      required this.translated, required this.stubReason, required this.warnings});
}

SfcTranslation translateSfcBody(SfcBody body, {required String pouName});
```

Internally uses a private `_SfcStub(reason, detail)` for whole-POU bail-out,
caught at the top of `translateSfcBody` (never escapes → `translated: false`).

**Ids.** Native `SfcStep`/`SfcTransition` require string `id`s. Use deterministic
synthetic ids from the source local ids: steps `'${pouName}_s${localId}'`,
transitions `'${pouName}_t${localId}'`. A selection divergence emits several
`single` transitions from one step; each gets a distinct id derived from the
branch transition's own local id (they are separate `<transition>` elements in
the source, so their local ids differ).

**Step build.** Each step node → `SfcStep(id: '${pouName}_s${localId}',
name: <sanitized @name or 's$localId'>, isInitial: node.initial)`. `actionSt` =
the step's N-qualified actions resolved to ST and joined with `\n`:
- `SfcActInline(text)` → `text`.
- `SfcActRef(name)` → `refBodies[name]` if present; if `name ∈ graphicalRefs` or
  absent → skip + warning (no-op action).
- non-N qualifier → skip + info warning.
If no step is marked initial → info warning, mark the topologically-first step
initial (the engine already falls back to the first step, so this only makes the
import explicit). Zero steps → `_SfcStub('no-initial', 'chart has no steps')`.

**Transition build** (walk the topology from `edges`):
- **simple** `step →(edge) transition →(edge) step` → `SfcTransition(kind:
  'single', fromStepId, toStepId, conditionSt: <resolved>)`.
- **selection divergence** `step → selDiv → [transition → …stepPath]×n` → one
  `kind:'single'` transition from the step per branch (native first-true-wins;
  branch order = edge order out of selDiv). `selConv` merges the branch tails'
  transitions onto the single after-step.
- **simultaneous divergence** `step →(edge) transition →(edge) simDiv →
  [step]×n` → `kind:'parallelFork'` (`fromStepId`=step, `toStepIds`=branch head
  steps, `conditionSt`=the transition's). `simConv` `[step]×n → simConv →
  transition → step` → `kind:'parallelJoin'` (`fromStepIds`=branch tail steps,
  `toStepId`=after step, `conditionSt`=the transition's).
- **jump** `transition → jump(targetName)` → resolve `targetName` to a step by
  name; emit a `kind:'single'` transition to it. An unresolvable jump target →
  `_SfcStub('complex-topology', 'jump to unknown step "…"')`.

**Condition resolution** (`conditionSt` for each transition):
- `SfcCondInline(text)` → `text`.
- `SfcCondRef(name)` → `refBodies[name]`; if `name ∈ graphicalRefs` or absent →
  `_SfcStub('unresolved-condition', 'transition references …')`.
- `SfcCondWired()` → `_SfcStub('wired-condition', 'graphical transition condition')`.
- `SfcCondNone()` → `_SfcStub('unresolved-condition', 'transition has no condition')`.

**Topology guards (→ `_SfcStub('complex-topology', …)`):** a dangling edge
endpoint, an unmatched fork/join, a divergence nesting the walker can't classify,
or a transition with zero or multiple step-successors that isn't a recognized
divergence shape. Faithful-or-stub: if the walker cannot produce a complete,
unambiguous native chart, the whole POU stubs.

## §4 — Mapper integration (`ir_to_project.dart`)

Add a `body is SfcBody` arm (before the `GraphBody` fallback):

```dart
} else if (body is SfcBody) {
  final tr = translateSfcBody(body, pouName: pou.name);
  warnings.addAll(tr.warnings);
  if (tr.translated) {
    programs.add(PlcProgram(name: pou.name, language: 'SequentialFunctionChart',
        sfcSteps: tr.steps, sfcTransitions: tr.transitions));
    translatedSfcCount++;
  } else {
    // today's whole-POU SFC stub (unchanged wording), + reason inventory
    sfcStubReasons[tr.stubReason ?? 'complex-topology'] =
        (sfcStubReasons[tr.stubReason ?? 'complex-topology'] ?? 0) + 1;
    warnings.add(ImportWarning(severity: WarningSeverity.warning,
        message: 'POU "${pou.name}" (SequentialFunctionChart): graphical body not '
            'yet translated — re-import once graphical translation ships.'));
    programs.add(PlcProgram(name: pou.name, language: 'SequentialFunctionChart',
        description: 'Graphical body not translated on import.'));
    stubbedSfcCount++;
    stubCount++; // also feeds graphicalStubCount, preserving that total
  }
} else if (body is GraphBody) {
  // any other graphical language: unchanged whole-POU stub (SFC no longer here)
  ...
}
```

`ImportReport` gains `translatedSfcCount` (int, default 0), `stubbedSfcCount`
(int, default 0 — the SFC portion of `graphicalStubCount`), and `sfcStubReasons`
(`Map<String,int>`, default `{}`), threaded into the returned report. (`stubCount`
still feeds `graphicalStubCount` for the SFC-stub case, preserving that total.)

## §5 — Preview (`import_xml_preview.dart`)

Surface the SFC counts beside the LD/FBD ones: `translatedSfcCount` translated /
`stubbedSfcCount` stubbed SFC charts, plus the `sfcStubReasons` keys when a chart
stubbed — same treatment as the existing LD/FBD count lines.

## §6 — Error handling (pure, never-throws)

| Situation | Handling |
|---|---|
| Transition condition is `wired` (graphical/FBD signal) | Whole-POU stub; `sfcStubReasons['wired-condition']` |
| Condition `ref` → graphical body / missing, or `SfcCondNone` | Whole-POU stub; `sfcStubReasons['unresolved-condition']` |
| Unsupported/malformed topology (nested divergence, dangling edge, unmatched fork/join, unknown jump target) | Whole-POU stub; `sfcStubReasons['complex-topology']` |
| Zero steps | Whole-POU stub; `sfcStubReasons['no-initial']` |
| Steps present but none marked initial | Warn (info) + mark first step initial; chart translates |
| Non-N action qualifier (S/R/P/L/D/…) | Action skipped → no-op + info warning; chart translates |
| Action `ref` → graphical body / missing | Action skipped → no-op + warning; chart translates |
| No SFC POUs in the project | Byte-identical import (SFC arm fires only on `pou.lang == sfc`) |

## §7 — Testing

- **Parser unit** (`plcopen_parser_test.dart`): an SFC POU builds an `SfcBody` —
  steps (name/initial), a transition's inline vs `ref` vs `wired` condition, an
  `actionBlock`'s qualifier + inline/ref source, edges from `connectionPointIn`,
  and `refBodies`/`graphicalRefs` from the `<transitions>`/`<actions>` sections;
  existing fixtures stay green.
- **Translate unit (pure)** (`sfc_translate_test.dart`): a linear 3-step chart →
  3 steps + 2 `single` transitions with correct `conditionSt`/`actionSt`; a
  selection divergence → N `single` transitions from one step; a simultaneous
  divergence + convergence → `parallelFork` + `parallelJoin`; a jump → a
  `single` transition to the named step; a referenced ST condition/action
  resolved and inlined; a non-N action → skipped + warning (chart still
  translates); a `wired`/graphical-ref/none condition → `translated == false`
  with the right `stubReason`.
- **End-to-end fixture** (`import_sfc_e2e_test.dart`): a handcrafted PLCopen SFC
  POU (initial `Idle` → transition `Start` (a global BOOL) → `Run` step whose
  action sets an output → transition `Done` → back to `Idle`), including one
  **referenced** ST transition or action, → `mapImportedProject` →
  `executeSfcPrograms` scans: with `Start` false the active step stays `Idle`;
  set `Start` true, tick → active step becomes `Run` and its action ran; the
  referenced condition/action resolved and executed.
- **Backward-compat:** the existing PLCopen corpus/round-trip tests stay green; a
  no-SFC project imports identically; the app's own SFC round-trip/exec tests are
  untouched (they don't go through the importer).

## §8 — Docs

- `docs/iec61131/` — add an SFC import support matrix (supported: steps,
  single/selection/parallel transitions, jumps, inline + referenced-ST
  conditions/actions, N actions; stubbed/degraded: wired conditions, graphical
  referenced bodies, non-N qualifiers, complex topology), paralleling the LD/FBD
  import notes.
- Import doc — note SFC POUs now translate (whole-POU faithful-or-stub caveat).
- `docs/DEFERRED.md` — strike the "SFC import translator" row (delivered here;
  the graphical-translators program is now **complete**); record residual SFC
  gaps: stored/pulse/timed action qualifiers (S/R/P/L/D/SD/DS/SL), graphical
  (LD/FBD) transition/action bodies, wired transition conditions, action/
  transition definitions as standalone external POUs.

## §9 — Deferred (tracked in `docs/DEFERRED.md`)

- **Stored/pulse/timed action qualifiers** (S/R/P/L/D/SD/DS/SL) — native model is
  N-only; these degrade to no-op today.
- **Graphical (LD/FBD) transition/action bodies** — not inlinable to ST.
- **Wired transition conditions** — a condition driven by a graphical signal.
- **Action/transition definitions as standalone external POUs** (not in the SFC
  POU's `<transitions>`/`<actions>` sections) — only in-POU references resolve.
