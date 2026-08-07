# L5X SFC Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `<Routine Type="SFC">` in a Rockwell L5X export translate into a real, executing native `SequentialFunctionChart` program, closing the last L5X import gap (ST ✔, RLL ✔, FBD ✔, SFC ✘ → ✔), and delete the parser-level SFC warning so the message count matches the PLCopen SFC path exactly.

**Architecture:** The work is a **parser front-end only**. The neutral SFC IR (`SfcBody`/`SfcNode`/`SfcEdge`/`SfcActionAssoc`/`SfcCond*`, `import/import_ir.dart:106-151`), the whole-POU translator (`translateSfcBody`, `import/sfc_translate.dart`) and the mapper arm that consumes it (`import/ir_to_project.dart:386-407`, `body is SfcBody`) already exist, already ship for PLCopen input, and are used **unchanged**. The only new code is one L5X-dialect builder, `_l5xSfcBody`, that turns `<SFCContent>` into that IR — the exact analog of `_l5xFbdBody` for `<FBDContent>`. Its crux is **branch synthesis**: L5X models a branch as one `<Branch>` element with `<Leg>` children plus a flat `<DirectedLink>` list, while the IR models it as a *pair* of connector nodes (divergence + convergence), so the builder synthesizes that pair and derives its wiring from link topology through one unified endpoint classifier. Anything unmappable (an unknown element, a broken branch, a dangling link, an ID collision) sets a routine-level poison flag, which appends a **poison node** — a step carrying a self-edge — that `translateSfcBody`'s unconditional step→step edge scan always converts into a single visible whole-POU stub, with zero translator changes.

**Tech Stack:** Dart 3 / Flutter (package `soft_plc_mobile` in `mobile/`), `flutter_test`, `package:xml` (parsers only). Pure-Dart models, executors and importers.

## Global Constraints

Copied from the spec's binding rules (`docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md`: "North-star decisions (binding)", §2, §3, §4, §7, §8, §13). Every task below must hold all of them.

- **Spec is the single source of requirements:** `docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md`. Every section maps to a task in this plan (see the coverage table below). Trust its code citations, but **re-check any code you write against the live files** before relying on a line number.
- **Faithful-or-stub, at the granularity the translator already enforces.** Structure and transition conditions are **whole-POU**: anything the chart contains that cannot be represented faithfully stubs the entire POU rather than translating a partial chart. Step **actions** degrade per-action to a no-op + warning. This is `translateSfcBody`'s existing contract, inherited verbatim — the builder adds **no new policy**.
- **Zero-change reuse.** `_l5xSfcBody` emits exactly the IR shapes `plcopen_parser.dart`'s `_sfcBody` emits. `translateSfcBody`, `ir_to_project`'s `body is SfcBody` arm, `import_ir.dart`, `models/sfc_exec.dart` and `models/project_model.dart` are **not touched**. `SfcBody.refBodies` and `.graphicalRefs` are always empty for L5X input, and `SfcNodeKind.jump` is **never** emitted.
- **The ONE exception to "zero changes to `sfc_translate.dart`":** a **single comment line** above the step→step edge scan recording that import builders depend on it preceding every warning emission (Task 3). Comment-only — no behaviour, signature, or output change. No other edit to that file is permitted by this plan.
- **Never silent.** Any ID-bearing `<SFCContent>` element the builder cannot map, any structurally broken branch, any dangling link, and any ID collision leads to a **visible whole-POU stub**, never to a dropped node or edge. The mechanism is the poison node of §4.
- **Builder warnings are breadcrumbs, not verdicts.** Every warning `_l5xSfcBody` emits is `WarningSeverity.info` and names the offending element. The single unit-level verdict is the existing `translateSfcBody` + mapper pair.
- **Synthetic ids are routine-wide, negative, and unique.** Malformed, out-of-range, duplicate and absent L5X `ID`s, the synthesized branch connectors and the poison node all draw from **one** descending counter per routine, starting at `-1`. A raw `ID` is only ever accepted when it is **non-negative and ≤ `_kMaxL5xElementId`**, so no synthetic id can collide with a real one, and because there is exactly one counter, no two synthetic ids can collide with each other. **The `parsed < 0` rejection is a correctness gate, not hygiene** — without it a `<Step ID="-1">` collides with the first branch's `divId` and the chart translates cleanly as the *wrong* logic with zero warnings (CL-19's failure mode).
- **Pure, deterministic, never-throws.** The builder returns a body for every input, including malformed XML fragments. Document order (of elements, then of the `<DirectedLink>` list) is the sole tiebreaker everywhere, so two runs over one file produce byte-identical IR. `parseL5x` still throws `FormatException` only for non-well-formed XML or a wrong root element (unchanged).
- **Single-warning path (§7).** The parser's own `WarningSeverity.warning` for SFC routines is **deleted**. The message-count contract, asserted by test, scoped to **messages naming this POU**:

  | Outcome | Messages naming this POU |
  |---|---|
  | SFC routine translates | **zero** warning-severity messages; only builder/translator `info` breadcrumbs, if any |
  | SFC routine stubs | exactly **two** warning-severity messages — `translateSfcBody`'s `SFC POU "…": not translated (<detail>).` and the mapper's `POU "…" (SequentialFunctionChart): graphical body not yet translated (N elements captured) …` |
  | `parseL5x` alone, any SFC routine | **zero** warning-severity messages |

- **Exact severities and assertable substrings.** Every builder-emitted warning is `WarningSeverity.info`, prefixed with `ownerLabel`, and carries these exact fragments (tests assert them verbatim):

  | Situation | Severity | Assertable substring | Consequence |
  |---|---|---|---|
  | `<TextBox>` / `<Attachment>` present | info | `element(s) ignored` | dropped; one warning per routine, kinds deduped |
  | Unknown ID-bearing element (`<Stop>`, `<SbrRet>`, `<JSR>`, top-level `<Leg>`, future) | info | `no representable equivalent` | **poison** |
  | `ID` absent, unparseable, **negative**, or **> `_kMaxL5xElementId`** | info | `malformed ID` | synthetic negative id + **poison** |
  | `ID` reused by a later element | info | `duplicate ID` | later claimant gets a synthetic id (raw id never re-registered) + **poison** |
  | `<DirectedLink>` endpoint names nothing | info | `dangling link` | edge kept against a synthetic id + **poison** |
  | `<DirectedLink>` endpoint names a dropped annotation (matched on the annotation's **accepted** `localId`) | — | (none) | link discarded whole; **no** poison. An annotation whose own `ID` was rejected never registered, so it takes the `duplicate ID` / `malformed ID` row instead — see recorded resolution 12 |
  | `BranchType` absent/unrecognized | info | `branch type` | **poison**; no connectors synthesized |
  | Any branch defect | info | `branch shape not representable (` **+ a cause clause** | **poison** |
  | `BranchFlow` contradicts derived topology | info | `branch flow mismatch` | derived topology wins; **no** stub |
  | Step `Preset` / `LimitHigh` / `LimitLow` meaningful | info | `timing attribute` | dropped; chart still translates |
  | `<Action IsBoolean="true">` | info | `boolean action` | action skipped; chart still translates |
  | `<Action>` with empty/absent body | info | `action has no body` | action skipped; chart still translates |

- **Branch cause clauses** carried inside `branch shape not representable (<cause>)`. Each is asserted by its own test, so no two branch defects share a message:

  `divergence has no inlet` · `divergence has no legs` · `convergence has no inlet` · `convergence has no outlet` · `branch has no links` · `branch is directly adjacent to another branch` · `selection divergence inlet is a <kind>, expected step` · `selection divergence has N inlets, expected 1` · `selection leg head is a <kind>, expected transition` · `selection leg tail is a <kind>, expected transition` · `selection convergence outlet is a <kind>, expected step` · `simultaneous divergence inlet is a <kind>, expected transition` · `simultaneous leg head is a <kind>, expected step` · `simultaneous leg tail is a <kind>, expected step` · `simultaneous convergence outlet is a <kind>, expected transition`

- **Inherited verbatim from `translateSfcBody`** (unchanged, no L5X-specific text): `unsupported — action skipped (N only)` (info) · `action associated with unknown step` (info, unreachable on L5X) · `not resolvable to ST — skipped` (info, unreachable on L5X) · `no initial step marked — first step used` (info) · `not translated (` (**warning**). From the mapper: `graphical body not yet translated` (**warning**).
- **Stub-reason keys** are the existing `sfcStubReasons` keys only (`complex-topology`, `unresolved-condition`, `wired-condition`, `no-initial`). **No new `ImportReport` field, no preview-UI change** — `translatedSfcCount`, `stubbedSfcCount` and `sfcStubReasons` already exist and are already rendered by `screens/import_xml_preview.dart:106-108`.
- **Invariants asserted by test on EVERY fixture** (via the shared `_build` helper, not per-test — an invariant asserted in one named test is an invariant that holds in one named test):
  - `localId` uniqueness across the whole body;
  - the id ranges **partition** the body: every node with a real id is a `step` or `transition`, and every synthesized node (the four connector kinds, the poison node) has a **negative** `localId`;
  - no node of kind `jump`; `refBodies`/`graphicalRefs` empty;
  - a poisoned body (one carrying a `#unrepresentable` node) stubs `complex-topology` with **exactly one** warning-severity message and **zero** translator infos;
  - when a body translates, **no negative `localId` reaches an `SfcStep.id` or `SfcTransition.id`** (no `Main_Seq_s-3`);
  - the four defence-in-depth inlet/outlet **kind** causes never fire (recorded resolution 7).
- **Zero `flutter analyze` warnings.** Flutter is NOT on PATH: use `/c/flutter/bin/flutter`, and run every `flutter` command from `mobile/`.
- **Every task ends green:** the task's own tests, the **full suite** (`/c/flutter/bin/flutter test`) and `/c/flutter/bin/flutter analyze` all pass before the commit step. Every PLCopen SFC test (`sfc_body_test.dart`, `sfc_translate_test.dart` apart from its one *added* invariant test, `import_sfc_e2e_test.dart`), every existing L5X test, and `corpus_import_test.dart` must be byte-identical in outcome.
- **TDD:** write the failing test first, run it and watch it fail for the expected reason, then implement.
- **No em dashes in `knowledge/**` prose** (`.git/sdd/kb-conventions.md:99`: "No em dashes anywhere. Plain hyphens only."). This applies to the knowledge-base files touched in Task 5. It does **not** apply to `docs/**`, which keeps its existing house style, and it does **not** apply to Dart code: the new warning strings follow the codebase's existing em-dash style.

## Recorded resolutions

Twelve points the spec leaves open or where a mechanical reading would be ambiguous. Implement them as written; do not re-litigate them mid-task.

1. **The ID gate registers only ACCEPTED raw ids.** §2's gate snippet writes `assignedByRawId[parsed] = localId` in the `else` arm only, so a malformed / out-of-range / duplicate id is **not** registered. This deliberately differs from `_l5xFbdBody`, which also registers out-of-range ids so a wire still resolves to the real node. On the SFC path the body is already poisoned in every such case, so the only observable difference is *which* synthetic id the edge names — and not registering keeps "a rejected id never resolves" true without exception, which is the simpler invariant to reason about.
2. **Link classification is a total, ordered decision.** Both endpoints are resolved through `assignedByRawId` **first**, and every rule below is keyed off the resolved (accepted) id, never off the raw attribute. Then, in this exact order: (1) either endpoint names a dropped annotation → **discard whole**, no warning, no poison; (2) either endpoint names an element belonging to an **unrecognized-`BranchType` `<Branch>`** → discard whole, no extra warning (that branch already emitted its own breadcrumb + poison); (3) either endpoint resolves to no *mappable* element → `dangling link` + poison + the edge is still emitted, the unresolvable side against a fresh synthetic id and a connector side against the direction fallback (`FromID` → `divId`, `ToID` → `convId`); (4) **both** endpoints are connector-ish (branch or leg) → poison, cause `branch is directly adjacent to another branch`, **no edge emitted** (there is no non-arbitrary connector id to attach it to, and the branch cause message is the loud, named record of the link); (5) exactly one endpoint is connector-ish → §3's unified classifier; (6) neither → ordinary pending edge.
3. **Unmappable elements are registered for duplicate detection but not for resolution.** A `<Stop>`/`<SbrRet>`/unknown tag runs the ID gate (so a later element reusing its `ID` is still a duplicate) but gets **no** `kindById` entry and **no** `SfcNode`. A link naming one therefore takes the `dangling link` path, producing two info breadcrumbs (`no representable equivalent` + `dangling link`) for one defect. Both are info, both poison, and the pair is more informative than either alone.
4. **Branch connector ids are reserved at registration (pass 1), for every branch with a recognized `BranchType`, even when one side is later dropped.** This makes id allocation a pure function of document order, independent of the link list.
5. **At most one `branch shape not representable` warning per branch**, with a fixed precedence: connector-adjacent (recorded in pass 2a) > emission-table cause > shape-validation cause; first recorded wins. Within shape validation the order is: divergence inlet **arity** → divergence inlet **kind** → leg **heads** → leg **tails** → convergence outlet **arity** → convergence outlet **kind**. Warnings are emitted in pass 3 in branch **document order**, never at the moment of recording, so message order is deterministic.
   **A connector-adjacent link is recorded against the `FromID`-side branch only** — one link, one cause, and the `FromID` side is the upstream one (the same "divergence-side cause wins" instinct §3 applies within a branch). The `ToID`-side branch is left to report whatever its own bits say, which for a branch touched by nothing else is `branch has no links`; the connector-adjacent test asserts the `FromID` side's cause specifically, not "the only warning".
6. **The §8 arity cause is a template, instantiated at all four trunk sites.** §8 names only `selection divergence has N inlets, expected 1`; the three mirrors use the identical wording pattern: `selection convergence has N outlets, expected 1`, `simultaneous divergence has N inlets, expected 1`, `simultaneous convergence has N outlets, expected 1`. §9's named case (`selection divergence has 2 inlets, expected 1`) is unchanged; the mirrors get their own cases so all four are reachable.
7. **Four of the eight shape-validation causes are unreachable by construction, and are implemented anyway as defence in depth.** §3's unified classifier derives the *trunk* role **from** the neighbour's kind — a Selection `ToID == B` link whose other endpoint is a transition is classified as a leg tail (`convIn`), never as a mis-kinded `divIn` — so `divIn` and `convOut` can only ever hold correctly-kinded nodes. The four inlet/outlet **kind** causes (`selection divergence inlet is a …`, `selection convergence outlet is a …`, `simultaneous divergence inlet is a …`, `simultaneous convergence outlet is a …`) therefore cannot fire today. They are implemented (a future classifier change would need them) and **asserted absent by test** across the whole branch matrix — the same "kept as defence, asserted absent by test" idiom §1 uses for the translator's dead paths. The four leg head/tail causes and all four arity causes **are** live and each gets its own named test.
8. **A link touching an unrecognized-`BranchType` branch (or its legs) is discarded silently** (resolution 2, rule 2). The alternative — leaving those ids unregistered so every incident link also reports `dangling link` — would bury the one actionable cause (`branch type`) under N breadcrumbs.
9. **`BranchFlow` is checked only against the two recognized values.** `Diverge` with an emitted convergence, or `Converge` with an emitted divergence, is a `branch flow mismatch` info. Absent, empty, or any other value is not checked at all (there is nothing to contradict). The derived topology always wins.
10. **A step timing attribute that is present but non-numeric is treated as meaningful** and warned. §5 says "present and parsing to a non-zero number, or with `*UsesExpr="true"`"; a non-empty unparseable value is neither, and dropping it silently would violate never-silent for the one case most likely to be an expression the exporter inlined.
11. **`IsBoolean="true"` is checked before the empty-body check**, so a boolean action (which typically carries no `<Body>` at all — it names a tag through `Operand`) reports `boolean action` and never also `action has no body`.
12. **`<Action ID>` is not gated; `<TextBox>`/`<Attachment>` `ID` **is**.** The asymmetry is not an oversight, and the test for it is one question: *is the id ever dereferenced?*
    - An `<Action>` is addressed by XML **nesting** and is never a link endpoint, so its id is never looked up. Gating it would buy nothing. A link naming one resolves to nothing and takes the `dangling link` path, which is correct.
    - An **annotation is the one non-node kind whose id IS dereferenced** — rule (1) of resolution 2 discards a link anchored to one. It therefore runs the **same** `gateId` as every other ID-bearing element, and is recorded in `annotationIds` under its **accepted** `localId`. Ungated (recording the raw attribute and skipping the gate), a `<TextBox ID="1"/>` sharing an id with a real element would produce **no** `duplicate ID` warning and **no** poison in either document order, while rule (1) silently discarded every link naming the real element: on this plan's own e2e chart, one extra `<TextBox ID="25"/>` would drop a leg tail out of the simultaneous convergence, `convIn` would become `[27]`, shape validation would still pass, and the `parallelJoin` would degrade to a `single` transition that no longer waits — translated, zero warnings, wrong logic. Exactly the CL-19 shape, and a direct violation of the "any ID collision leads to a visible whole-POU stub" constraint.

**Two task-boundary notes** (mechanics, not policy):

- The **poison node itself lands in Task 1**, not Task 3, because Task 1's ID-gate tests assert that a malformed id makes the chart *stub* — which is only observable once the poison node exists. Task 3 owns the *rest* of the never-silent surface (§5 timing, §6 action degrades), the full §8 conformance suite, the invariant suite, and the `sfc_translate.dart` coupling comment + its dialect-neutral test.
- **`<Branch>`/`<Leg>` fall through Task 1's pass-1 `default` arm** (poison + `no representable equivalent`) until Task 2 adds their case. That intermediate state is visible and safe — a branch-bearing chart stubs loudly — and no Task 1 fixture contains a branch. Task 2 also lands the **branch-flavoured** `ID="-1"` collision regression (§9's named case, which needs a branch connector to collide with); Task 1 lands a malformed-pair version of the same uniqueness invariant.

## Spec coverage

| Spec section | Task |
|---|---|
| §1 `<SFCContent>` schema (steps, transitions, actions, links, annotations, unknown elements) | 1 (elements/links/annotations), 2 (`<Branch>`/`<Leg>`), 3 (`<Stop>`/unknown, actions) |
| §2 The builder: container walk, ID gate, five-pass structure | 1 (passes 1, 2a, 2b, 4), 2 (pass 3) |
| §3 Branch → divergence/convergence synthesis (unified classifier, 4-bit table, shape validation) | 2 |
| §4 Poison-node rule | 1 (mechanism), 3 (invariants + remaining sources) |
| §5 Step timing attributes | 3 |
| §6 Actions and conditions | 1 (conditions, action basics), 3 (boolean / empty-body degrades) |
| §7 Routine arm + double-warning removal | 1 (implementation + guard), 3 (full three-row regression) |
| §8 Error handling, severities, invariants | 1 (gate + link rows), 2 (branch rows + causes), 3 (conformance suite + invariants) |
| §9 Testing | 1, 2, 3 (parser units), 4 (e2e + `sfc_translate_test` invariant lives in 3) |
| §10 Docs | 5 |
| §11 Deferred rows | 5 |
| §12 Risks (coupling comment + dialect-neutral guard) | 3 |
| §13 Execution shape | this plan's task order |

## File structure

| File | Responsibility | Task |
|---|---|---|
| `mobile/lib/import/l5x_parser.dart` | `_kMaxL5xElementId` / `_kL5xAnnotationElements` renames, `_l5xSfcSt`, `_L5xSfcKind`, `_l5xSfcBody` (passes 1/2a/2b/4), `_l5xRoutines` SFC arm + doc comment | 1 |
| `mobile/lib/import/l5x_parser.dart` | `_L5xSfcBranch`, `_l5xSfcKindName`, `_l5xSfcValidateShape`, pass 3 + the unified classifier | 2 |
| `mobile/lib/import/l5x_parser.dart` | `_l5xSfcTiming`, `_l5xSfcActions` degrades | 3 |
| `mobile/lib/import/sfc_translate.dart` | **one comment line** above the step→step edge scan | 3 |
| `mobile/test/import/l5x_parser_sfc_test.dart` | Parser units (new file): happy paths + ID gate | 1 |
| `mobile/test/import/l5x_parser_sfc_test.dart` | Branch synthesis matrix | 2 |
| `mobile/test/import/l5x_parser_sfc_test.dart` | Never-silent conformance + invariants + double-warning regression | 3 |
| `mobile/test/import/l5x_parser_test.dart` | Test rename only (line 227) | 1 |
| `mobile/test/import/sfc_translate_test.dart` | One added dialect-neutral invariant test | 3 |
| `mobile/test/import/import_l5x_sfc_e2e_test.dart` | Composed e2e (new file): parse → map → scan | 4 |
| `docs/import/L5X.md`, `docs/DEFERRED.md`, `docs/iec61131/SEQUENTIAL_FUNCTION_CHART.md` | Feature docs | 5 |
| `knowledge/industry/plc-formats/rockwell-l5x.md`, `knowledge/canonical-manifest.json` | Knowledge base | 5 |

---

### Task 1: `_l5xSfcBody` core — ID gate, elements, links, poison node, routine arm

**Model:** opus · **Effort:** medium

*Rationale (spec §13 assigns opus · medium):* the ID gate is a **correctness gate**, not hygiene — the `parsed < 0` rejection is the one line standing between a `<Step ID="-1">` and a chart that translates cleanly as the wrong logic (CL-19). That reasoning, plus laying down the five-pass skeleton every later task edits, is worth opus. Effort medium: the algorithms are mechanical once the gate's rationale is understood.

Implements spec §1 (steps / transitions / actions / links / annotations), §2 (container walk, ID gate, passes 1 / 2a / 2b / 4), §4 (the poison mechanism), §6 (conditions + action basics), §7 (routine arm + parser-warning deletion).

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` — rename `_kMaxL5xFbdId` (line 182, used at 533) → `_kMaxL5xElementId`; rename `_kL5xFbdAnnotationElements` (line 189, used at 514) → `_kL5xAnnotationElements`; add `_l5xSfcSt`, `_L5xSfcKind`, `_l5xSfcBody`; replace `_l5xRoutines`' `case 'SFC':` (lines 914-921) and rewrite its doc comment (lines 868-873).
- Modify: `mobile/test/import/l5x_parser_test.dart:227` — rename the test only.
- Test: `mobile/test/import/l5x_parser_sfc_test.dart` (new file).

**Interfaces:**
- Consumes: `SfcBody({required List<SfcNode> nodes, required List<SfcEdge> edges, required List<SfcActionAssoc> actions, Map<String,String> refBodies = const {}, Set<String> graphicalRefs = const {}})`, `SfcNode({required int localId, required SfcNodeKind kind, double x = 0, double y = 0, String name = '', bool initial = false, SfcCond? condition})`, `SfcEdge({required int fromLocalId, required int toLocalId})`, `SfcActionAssoc({required int stepLocalId, required String qualifier, required SfcActSource source})`, `SfcActInline(String)`, `SfcCondInline(String)`, `SfcCondNone()`, `SfcNodeKind` (all `import/import_ir.dart:106-151`); `ImportWarning({required WarningSeverity severity, required String message})`; `_children(XmlElement, String) -> Iterable<XmlElement>` (`l5x_parser.dart:78`).
- Produces (all private to `l5x_parser.dart`):
  - `const int _kMaxL5xElementId = 1 << 31;`
  - `const Set<String> _kL5xAnnotationElements = {'TextBox', 'Attachment'};`
  - `enum _L5xSfcKind { step, transition, branch, leg }`
  - `String _l5xSfcSt(XmlElement owner, String wrapper)`
  - `SfcBody _l5xSfcBody(XmlElement routine, List<ImportWarning> warnings, String ownerLabel)`

- [ ] **Step 1: Grep sweep for existing SFC expectations (do this FIRST)**

Verify the blast radius before changing anything:

```
cd mobile && grep -rn "SFC" test/import/ | grep -v sfc_translate_test | grep -v sfc_body_test | grep -v import_sfc_e2e_test
```

Expected: exactly **four** hits, all accounted for — the gate is that there is no *fifth*:

| Hit | Verdict |
|---|---|
| `test/import/l5x_parser_test.dart:227` | the test **name** `routines -> program POUs (ST body; RLL/FBD/SFC stubbed)`; its fixture contains no SFC routine, so only the name is stale (renamed in Step 7) |
| `test/import/ir_to_project_test.dart:482` | group name `mapImportedProject: SFC translation wiring (Task 4)` — **benign** |
| `test/import/ir_to_project_test.dart:483` | test name `SFC POU with a translatable chart becomes a real SFC program` — **benign** |
| `test/import/ir_to_project_test.dart:516` | test name `SFC POU with a wired condition keeps the whole-POU stub` — **benign** |

The three `ir_to_project_test.dart` hits construct `SfcBody`s **directly** and never call `parseL5x`, so deleting the parser's SFC warning cannot move them. Confirm that directly:

```
cd mobile && grep -n "parseL5x" test/import/ir_to_project_test.dart
cd mobile && grep -n "graphical body not yet translated" test/import/corpus_import_test.dart test/import/import_xml_flow_test.dart test/import/ir_to_project_test.dart
```

Expected: **no** `parseL5x` in `ir_to_project_test.dart`, and no `graphical body not yet translated` expectation anywhere that is fed by an L5X SFC routine. If either check surprises you, stop and reconcile before proceeding.

- [ ] **Step 2: Write the failing tests**

Create `mobile/test/import/l5x_parser_sfc_test.dart`:

```dart
// L5X SFC parser units. Fixtures are synthetic and written to the ASSERTED
// <SFCContent> schema of
// docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md §1 — this repo
// contains no SFC-bearing L5X corpus file, so these fixtures ARE the schema
// pin. If a real export disagrees, the fixtures are what changes.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/import/sfc_translate.dart';

/// Wraps `<SFCContent>` children in a minimal L5X document with one
/// `<Routine Name="Seq" Type="SFC">` inside `<Program Name="Main">`.
String _wrap(String sfcChildren) => _wrapRoutine(
    '<Routine Name="Seq" Type="SFC"><SFCContent>$sfcChildren</SFCContent></Routine>');

/// Wraps a whole `<Routine>` element (for fixtures that need two
/// `<SFCContent>` containers, or none at all).
String _wrapRoutine(String routine) => '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Programs><Program Name="Main"><Tags/><Routines>
    $routine
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''';

/// Parses a fixture and returns `(body, allParserWarnings)`.
///
/// EVERY fixture in this file goes through here, because the §8 invariants
/// asserted below must hold for every L5X-built body, not just the malformed
/// ones — an invariant asserted in one named test is an invariant that holds
/// in one named test. It also translates the body, so the poison-mechanism and
/// step-id invariants ride along on every fixture too. Do not bypass it.
(SfcBody, List<ImportWarning>) _build(String xml) {
  final ir = parseL5x(xml);
  final pou = ir.pous.firstWhere((p) => p.name == 'Main_Seq');
  expect(pou.lang, PouLanguage.sfc);
  expect(pou.kind, PouKind.program);
  final body = pou.body as SfcBody;

  // §8 invariant: localId uniqueness across real ids, malformed/duplicate
  // synthetics, branch connectors and the poison node alike. A shared localId
  // makes translateSfcBody's `byId` last-write-wins while stepNodes/succ/pred
  // keep both — a chart that translates cleanly as the WRONG logic.
  expect(body.nodes.map((n) => n.localId).toSet(), hasLength(body.nodes.length),
      reason: 'two SfcNodes share a localId');
  // §8 invariant: the two id ranges PARTITION the body. Every node carrying a
  // REAL id is a step or a transition; every SYNTHESIZED node — the four
  // connector kinds and the poison node — carries a negative id. Stated as a
  // partition rather than as an upper bound, because a bound is satisfied by
  // almost any body and would prove nothing.
  const synthesizedKinds = {
    SfcNodeKind.selDiv,
    SfcNodeKind.selConv,
    SfcNodeKind.simDiv,
    SfcNodeKind.simConv,
  };
  for (final n in body.nodes) {
    if (synthesizedKinds.contains(n.kind) || n.name == '#unrepresentable') {
      expect(n.localId, lessThan(0),
          reason: 'synthesized node (${n.kind}) must never carry a real id');
    } else {
      expect(n.kind == SfcNodeKind.step || n.kind == SfcNodeKind.transition,
          isTrue, reason: 'unexpected node kind ${n.kind}');
      expect(n.localId <= (1 << 31), isTrue,
          reason: 'localId ${n.localId} out of range');
    }
  }
  // §1/§8 invariant: Logix has no jump element, so the builder never emits one.
  expect(body.nodes.any((n) => n.kind == SfcNodeKind.jump), isFalse,
      reason: 'an L5X-built SfcBody must contain no jump node');
  // §1 invariant: Logix has no external action/transition POUs.
  expect(body.refBodies, isEmpty);
  expect(body.graphicalRefs, isEmpty);

  // Recorded resolution 7: the four inlet/outlet KIND causes are unreachable
  // by construction — the classifier derives the trunk role FROM the
  // neighbour's kind. Asserted here rather than in one named test, so EVERY
  // fixture in this file (all 16 emission rows, all 8 shape fixtures, the
  // connector-adjacent and nesting cases) carries the assertion. If this ever
  // fires, the classifier changed and that is the news.
  for (final m in ir.warnings.map((w) => w.message)) {
    expect(m.contains('divergence inlet is a'), isFalse, reason: m);
    expect(m.contains('convergence outlet is a'), isFalse, reason: m);
  }

  final tr = translateSfcBody(body, pouName: 'P');
  if (body.nodes.any((n) => n.name == '#unrepresentable')) {
    // §4 invariant, on EVERY poisoned fixture: the step->step edge scan sits
    // above every warning-emitting statement in `_build`, so a poisoned body
    // yields exactly one message and zero translator infos.
    expect(tr.translated, isFalse, reason: 'a poisoned body must never translate');
    expect(tr.stubReason, 'complex-topology');
    expect(tr.warnings, hasLength(1));
    expect(tr.warnings.single.severity, WarningSeverity.warning);
  }
  if (tr.translated) {
    // §8 invariant: no negative localId ever reaches an SfcStep.id or
    // SfcTransition.id — guards against a program id like `Main_Seq_s-3`.
    // (A poisoned body always stubs, and connector nodes never become steps
    // or transitions, so this holds by construction; it is asserted because
    // "by construction" is exactly the kind of claim that rots.)
    for (final s in tr.steps) {
      expect(s.id.contains('_s-'), isFalse, reason: s.id);
    }
    for (final t in tr.transitions) {
      expect(t.id.contains('_t-'), isFalse, reason: t.id);
    }
  }
  return (body, ir.warnings);
}

/// Convenience: the info-severity messages a fixture produced.
List<String> _infos(List<ImportWarning> ws) => [
      for (final w in ws)
        if (w.severity == WarningSeverity.info) w.message
    ];

/// Convenience: does any info message contain [needle]?
bool _hasInfo(List<ImportWarning> ws, String needle) =>
    _infos(ws).any((m) => m.contains(needle));

SfcNode _nodeAt(SfcBody b, int localId) =>
    b.nodes.firstWhere((n) => n.localId == localId);

void main() {
  group('L5X SFC: happy paths (§1, §6)', () {
    test('a linear chart becomes 2 steps, 1 transition and 2 edges', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" X="10" Y="20" Operand="Idle" InitialStep="true"/>
        <Transition ID="2" X="10" Y="60" Operand="ToRun">
          <Condition><STContent><Line Number="0"><![CDATA[Start]]></Line></STContent></Condition>
        </Transition>
        <Step ID="3" X="10" Y="100" Operand="Run"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      expect(body.nodes.map((n) => n.kind),
          [SfcNodeKind.step, SfcNodeKind.transition, SfcNodeKind.step]);
      expect(body.nodes.map((n) => n.localId), [1, 2, 3]);
      expect(_nodeAt(body, 1).name, 'Idle');
      expect(_nodeAt(body, 1).initial, isTrue);
      expect(_nodeAt(body, 1).x, 10);
      expect(_nodeAt(body, 1).y, 20);
      expect(_nodeAt(body, 3).initial, isFalse);
      expect((_nodeAt(body, 2).condition as SfcCondInline).text, 'Start');
      expect(body.edges.map((e) => '${e.fromLocalId}->${e.toLocalId}'),
          ['1->2', '2->3']);
      expect(ws, isEmpty);

      final tr = translateSfcBody(body, pouName: 'Main_Seq');
      expect(tr.translated, isTrue);
      expect(tr.steps.map((s) => s.name), ['Idle', 'Run']);
      expect(tr.transitions.single.kind, 'single');
      expect(tr.transitions.single.fromStepId, 'Main_Seq_s1');
      expect(tr.transitions.single.toStepId, 'Main_Seq_s3');
    });

    test('a step\'s <Action> children become SfcActionAssocs in document order', () {
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="A1" Qualifier="N">
            <Body><STContent><Line Number="0"><![CDATA[Motor := TRUE;]]></Line></STContent></Body>
          </Action>
          <Action ID="12" Operand="A2" Qualifier="N">
            <Body><STContent><Line Number="0"><![CDATA[Lamp := TRUE;]]></Line></STContent></Body>
          </Action>
        </Step>'''));

      expect(body.actions, hasLength(2));
      expect(body.actions.every((a) => a.stepLocalId == 1), isTrue);
      expect(body.actions.map((a) => a.qualifier), ['N', 'N']);
      expect(body.actions.map((a) => (a.source as SfcActInline).text),
          ['Motor := TRUE;', 'Lamp := TRUE;']);

      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.steps.single.actionSt, 'Motor := TRUE;\nLamp := TRUE;');
    });

    test('a step with a direct <Body> and no <Action> gets one implicit N action', () {
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Body><STContent>
            <Line Number="0"><![CDATA[Motor := TRUE;]]></Line>
            <Line Number="1"><![CDATA[Lamp := TRUE;]]></Line>
          </STContent></Body>
        </Step>'''));

      expect(body.actions, hasLength(1));
      expect(body.actions.single.qualifier, 'N');
      expect((body.actions.single.source as SfcActInline).text,
          'Motor := TRUE;\nLamp := TRUE;');
    });

    test('a missing Qualifier defaults to N', () {
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="A1">
            <Body><STContent><Line Number="0"><![CDATA[Motor := TRUE;]]></Line></STContent></Body>
          </Action>
        </Step>'''));
      expect(body.actions.single.qualifier, 'N');
    });

    test('condition lines join, trim, and lose a single trailing semicolon', () {
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <Transition ID="2">
          <Condition><STContent>
            <Line Number="0"><![CDATA[  Start AND ]]></Line>
            <Line Number="1"><![CDATA[Ready;  ]]></Line>
          </STContent></Condition>
        </Transition>
        <Step ID="3" Operand="Run"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      expect((_nodeAt(body, 2).condition as SfcCondInline).text,
          'Start AND\nReady');
    });

    test('an absent condition becomes SfcCondNone (translator stubs it)', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <Transition ID="2"/>
        <Step ID="3" Operand="Run"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      expect(_nodeAt(body, 2).condition, isA<SfcCondNone>());
      expect(ws, isEmpty); // the verdict belongs to the translator, not the builder
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse);
      expect(tr.stubReason, 'unresolved-condition');
      expect(tr.warnings.single.message, contains('transition has no condition'));
    });

    test('a chart with no InitialStep leans on the translator\'s first-step default', () {
      // The builder does not pre-judge this — `no initial step marked` is the
      // translator's inherited info warning, and it must still be reachable
      // from L5X input (§8's inherited table).
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="A"/>
        <Transition ID="2"><Condition><STContent>
          <Line Number="0"><![CDATA[Go]]></Line></STContent></Condition></Transition>
        <Step ID="3" Operand="B"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      expect(body.nodes.every((n) => !n.initial), isTrue);
      expect(ws, isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.steps.first.isInitial, isTrue);
      expect(
          tr.warnings.any((w) =>
              w.severity == WarningSeverity.info &&
              w.message.contains('no initial step marked — first step used')),
          isTrue);
    });

    test('a missing Operand leaves the name empty (translator synthesizes s<id>)', () {
      final (body, _) = _build(_wrap('<Step ID="7" InitialStep="true"/>'));
      expect(_nodeAt(body, 7).name, '');
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.steps.single.name, 's7');
    });
  });

  group('L5X SFC: the ID gate (§2)', () {
    // The gate's four rejections plus the duplicate rule. Every one of them
    // gets a synthetic NEGATIVE id and poisons the chart, so the POU stubs
    // rather than silently translating with a colliding or missing identity.
    for (final (label, attr, needle) in const [
      ('an absent ID', '', 'malformed ID'),
      ('an unparseable ID', ' ID="abc"', 'malformed ID'),
      ('a negative ID', ' ID="-1"', 'malformed ID'),
      ('an out-of-range ID', ' ID="99999999999"', 'malformed ID'),
    ]) {
      test('$label gets a synthetic negative id and poisons the chart', () {
        final (body, ws) = _build(_wrap('<Step$attr Operand="Idle" InitialStep="true"/>'));
        final step = body.nodes.firstWhere((n) => n.name == 'Idle');
        expect(step.localId, lessThan(0));
        expect(_hasInfo(ws, needle), isTrue, reason: _infos(ws).toString());
        final tr = translateSfcBody(body, pouName: 'P');
        expect(tr.translated, isFalse);
        expect(tr.stubReason, 'complex-topology');
      });
    }

    test('a duplicate ID demotes the LATER claimant and keeps the first\'s links', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="7" Operand="First" InitialStep="true"/>
        <Step ID="7" Operand="Second"/>
        <Transition ID="8">
          <Condition><STContent><Line Number="0"><![CDATA[Go]]></Line></STContent></Condition>
        </Transition>
        <DirectedLink FromID="7" ToID="8"/>'''));

      expect(body.nodes.firstWhere((n) => n.name == 'First').localId, 7);
      expect(body.nodes.firstWhere((n) => n.name == 'Second').localId, lessThan(0));
      expect(body.edges.first.fromLocalId, 7); // the FIRST claimant keeps its links
      expect(_hasInfo(ws, 'duplicate ID'), isTrue, reason: _infos(ws).toString());
      expect(translateSfcBody(body, pouName: 'P').translated, isFalse);
    });

    test('two malformed elements get DISTINCT synthetic ids (uniqueness invariant)', () {
      // The Task 2 fixture adds the branch-connector flavour of this
      // collision; here the point is simply that one descending counter feeds
      // every synthetic id, so two rejects can never share one.
      final (body, _) = _build(_wrap('''
        <Step ID="-1" Operand="Neg" InitialStep="true"/>
        <Step ID="abc" Operand="Bad"/>'''));
      final ids = body.nodes.map((n) => n.localId).toList();
      expect(ids.every((i) => i < 0), isTrue);
      expect(ids.toSet(), hasLength(ids.length)); // also asserted by _build
      expect(translateSfcBody(body, pouName: 'P').translated, isFalse);
    });

    test('an annotation reusing a real element\'s ID is caught, in EITHER order', () {
      // C1. An annotation is not a node, but its id IS dereferenced by pass
      // 2a's annotation-anchor rule — it is the one non-node kind that is.
      // Ungated, a <TextBox ID="1"/> would claim id 1 with no duplicate-ID
      // warning and no poison, and every link naming the real element 1 would
      // then be silently discarded: with the e2e chart's join, `convIn` loses
      // a leg tail, shape validation still passes, and the parallelJoin
      // degrades to a `single` transition that no longer waits — translated,
      // zero warnings, wrong logic.
      const step = '<Step ID="1" Operand="Idle" InitialStep="true"/>';
      const box = '<TextBox ID="1" X="0" Y="0"/>';
      const rest = '''
        <Transition ID="2"><Condition><STContent>
          <Line Number="0"><![CDATA[Go]]></Line></STContent></Condition></Transition>
        <DirectedLink FromID="1" ToID="2"/>''';

      for (final (label, fixture) in [
        ('element first', '$step$box$rest'),
        ('annotation first', '$box$step$rest'),
      ]) {
        final (body, ws) = _build(_wrap(fixture));
        expect(_hasInfo(ws, 'duplicate ID'), isTrue,
            reason: '$label: ${_infos(ws)}');
        expect(body.nodes.any((n) => n.name == '#unrepresentable'), isTrue,
            reason: label);
        final tr = translateSfcBody(body, pouName: 'P');
        expect(tr.translated, isFalse, reason: label);
        expect(tr.stubReason, 'complex-topology', reason: label);
      }

      // Element-first: the annotation is the one demoted, so the real element
      // keeps its id AND its inbound link — nothing was swallowed.
      final (body, _) = _build(_wrap('$step$box$rest'));
      expect(body.edges.any((e) => e.fromLocalId == 1 && e.toLocalId == 2),
          isTrue);
    });

    test('two <SFCContent> containers merge, and a cross-container duplicate is caught', () {
      final (body, ws) = _build(_wrapRoutine('''
        <Routine Name="Seq" Type="SFC">
          <SFCContent><Step ID="1" Operand="A" InitialStep="true"/></SFCContent>
          <SFCContent><Step ID="2" Operand="B"/><Step ID="1" Operand="Dup"/></SFCContent>
        </Routine>'''));

      expect(body.nodes.map((n) => n.name), ['A', 'B', 'Dup', '#unrepresentable']);
      expect(_nodeAt(body, 1).name, 'A');
      expect(_nodeAt(body, 2).name, 'B');
      expect(body.nodes.firstWhere((n) => n.name == 'Dup').localId, lessThan(0));
      expect(_hasInfo(ws, 'duplicate ID'), isTrue);
    });
  });

  group('L5X SFC: links, annotations and the poison node (§2, §4)', () {
    test('a dangling link keeps its edge against a synthetic id and poisons', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <DirectedLink FromID="1" ToID="999"/>'''));

      expect(_hasInfo(ws, 'dangling link'), isTrue, reason: _infos(ws).toString());
      // The edge is KEPT — never silently dropped.
      final e = body.edges.firstWhere((e) => e.fromLocalId == 1);
      expect(e.toLocalId, lessThan(0));
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse);
      expect(tr.stubReason, 'complex-topology');
    });

    test('<TextBox>/<Attachment> are dropped and counted, kinds deduped', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <TextBox ID="50" X="0" Y="0"/>
        <TextBox ID="51" X="0" Y="0"/>
        <Attachment ID="52" X="0" Y="0"/>'''));

      expect(body.nodes.map((n) => n.localId), [1]);
      expect(_infos(ws).where((m) => m.contains('element(s) ignored')), hasLength(1));
      expect(_infos(ws).single,
          'Routine "Main_Seq": 3 element(s) ignored (TextBox, Attachment).');
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('exactly one poison node is appended no matter how many defects', () {
      final (body, _) = _build(_wrap('''
        <Step ID="abc" Operand="A" InitialStep="true"/>
        <Step ID="xyz" Operand="B"/>
        <DirectedLink FromID="1" ToID="999"/>'''));

      final poison = body.nodes.where((n) => n.name == '#unrepresentable').toList();
      expect(poison, hasLength(1));
      expect(poison.single.kind, SfcNodeKind.step);
      expect(poison.single.localId, lessThan(0));
      expect(
          body.edges.where((e) =>
              e.fromLocalId == poison.single.localId &&
              e.toLocalId == poison.single.localId),
          hasLength(1));
    });
  });

  group('L5X SFC: the routine arm (§7)', () {
    test('parseL5x emits ZERO warning-severity messages for an SFC routine', () {
      // The parser-level `graphical body not yet translated` warning is GONE:
      // the whole-POU verdict belongs to translateSfcBody + the mapper.
      for (final fixture in [
        _wrap('<Step ID="1" Operand="Idle" InitialStep="true"/>'), // translates
        _wrap('<Step ID="abc" Operand="Idle" InitialStep="true"/>'), // stubs
      ]) {
        final ir = parseL5x(fixture);
        expect(ir.warnings.where((w) => w.severity == WarningSeverity.warning),
            isEmpty,
            reason: 'parseL5x must not pre-judge an SFC routine');
      }
    });

    test('a routine with no <SFCContent> yields an EMPTY body, not a poisoned one', () {
      final (body, ws) = _build(
          _wrapRoutine('<Routine Name="Seq" Type="SFC"/>'));
      expect(body.nodes, isEmpty);
      expect(body.edges, isEmpty);
      expect(body.actions, isEmpty);
      expect(ws, isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse);
      expect(tr.stubReason, 'no-initial'); // NOT complex-topology
      expect(tr.warnings.single.message, contains('chart has no steps'));
    });
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

From `mobile/`:

```
/c/flutter/bin/flutter test test/import/l5x_parser_sfc_test.dart
```

Expected: FAIL. The fixtures parse, but `pou.body` is today's empty `SfcBody`, so the first assertion to blow is `expect(body.nodes.map((n) => n.kind), [...])` — `Expected: [<SfcNodeKind.step>, ...] Actual: []`. The routine-arm group fails on `parseL5x must not pre-judge an SFC routine` (today's parser emits its own warning-severity message).

- [ ] **Step 4: Rename the two shared constants**

In `mobile/lib/import/l5x_parser.dart`, line 176-189, replace the two declarations (pure rename plus a widened doc comment — no member change):

```dart
/// Upper bound on a usable L5X element `ID`, shared by the FBD and SFC
/// builders. Anything above it (or absent, unparseable, or negative) is
/// treated as malformed and gets a unique negative synthetic id instead,
/// reproducing `plcopen_parser.dart`'s `_graphBody` contract: distinct
/// negative ids keep `weaklyConnectedComponents` from merging two unrelated
/// malformed nodes, and the FBD translator's `localId < 0` gate still stubs
/// their component. On the SFC path the same rejection keeps a raw `ID` out
/// of the synthetic-id namespace that branch connectors and the poison node
/// draw from — see `_l5xSfcBody`.
const int _kMaxL5xElementId = 1 << 31;

/// L5X graphical elements that are pure annotations: they carry an `ID` (or
/// link to one) but never participate in dataflow or control flow, so they are
/// dropped entirely rather than kept as opaque stub nodes. Shared by the FBD
/// and SFC builders. Everything else unrecognized IS surfaced (see
/// `_l5xFbdBody` and `_l5xSfcBody`), so a `<JSR>`/`<SBR>`/`<Ret>` network or a
/// `<Stop>` element stubs visibly instead of silently disappearing.
const Set<String> _kL5xAnnotationElements = {'TextBox', 'Attachment'};
```

Then update the two use sites:
- line 514: `if (_kL5xFbdAnnotationElements.contains(tag)) {` → `if (_kL5xAnnotationElements.contains(tag)) {`
- line 533: `parsed > _kMaxL5xFbdId ||` → `parsed > _kMaxL5xElementId ||`

Confirm no other references remain:

```
cd mobile && grep -rn "_kMaxL5xFbdId\|_kL5xFbdAnnotationElements" lib/ test/
```

Expected: no output.

- [ ] **Step 5: Add the SFC builder**

In `mobile/lib/import/l5x_parser.dart`, insert immediately **after** `_l5xFbdBody` (i.e. after line 748, before `VarScope _usageScope`):

```dart
/// Joined `<STContent><Line>` text under [owner]'s direct [wrapper] child
/// (`'Body'` for a `<Step>`/`<Action>`, `'Condition'` for a `<Transition>`),
/// each line trimmed, joined with `\n`, then trimmed as a whole. Returns `''`
/// when absent, empty or whitespace-only. Never throws.
String _l5xSfcSt(XmlElement owner, String wrapper) {
  final lines = <String>[];
  for (final w in _children(owner, wrapper)) {
    for (final st in _children(w, 'STContent')) {
      for (final ln in _children(st, 'Line')) {
        lines.add(ln.innerText.trim());
      }
    }
  }
  return lines.join('\n').trim();
}

/// Element kinds `_l5xSfcBody`'s link classifier can resolve an endpoint to.
/// Unmappable elements (`<Stop>`, `<SbrRet>`, an unknown tag) are deliberately
/// NOT registered here: they poison the chart, and a link naming one must take
/// the `dangling link` path rather than resolve to a node that does not exist.
enum _L5xSfcKind { step, transition, branch, leg }

/// Parses one `<Routine Type="SFC">`'s `<SFCContent>` into the neutral
/// [SfcBody] the shared `translateSfcBody` consumes — the SFC analog of
/// [_l5xFbdBody]. [ownerLabel] is the human label used in warnings, e.g.
/// `'Routine "Main_Seq"'`.
///
/// Pure, deterministic, NEVER THROWS: every attribute read is null-tolerant,
/// document order (of elements, then of the `<DirectedLink>` list) is the sole
/// tiebreaker, and an absent/empty `<SFCContent>` yields an empty body.
///
/// Emits exactly the IR shapes `plcopen_parser.dart`'s `_sfcBody` emits, so
/// `translateSfcBody` and `ir_to_project`'s `body is SfcBody` arm need ZERO
/// changes. `refBodies`/`graphicalRefs` are always empty (Logix has no external
/// action/transition POUs) and `SfcNodeKind.jump` is never emitted (Logix
/// expresses a loop-back as an ordinary `<DirectedLink>` to an earlier
/// element, not as a distinct jump element).
///
/// MULTI-CONTAINER: every `<SFCContent>` of the routine merges into ONE body,
/// in document order, with NO id or y offsetting — an SFC routine is a single
/// chart with routine-unique `ID`s, and offsetting would break the absolute
/// `<DirectedLink>` ids. A duplicate `ID` across containers is therefore a
/// defect handled by the ID gate, not papered over.
///
/// NEVER SILENT: any element this builder cannot map, any structurally broken
/// branch, any dangling link and any ID collision sets the routine-level
/// `unrepresentable` flag, which appends a POISON NODE (a step carrying a
/// self-edge) in pass 4. `translateSfcBody`'s step->step edge scan is
/// unconditional over `body.edges` and precedes every warning it emits, so a
/// poisoned body always stubs `complex-topology` with EXACTLY ONE warning —
/// the same two-message shape the PLCopen SFC path produces for any stub. See
/// `docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md` §4.
SfcBody _l5xSfcBody(
    XmlElement routine, List<ImportWarning> warnings, String ownerLabel) {
  final nodes = <SfcNode>[];
  final edges = <SfcEdge>[];
  final actions = <SfcActionAssoc>[];
  // The ONE routine-wide synthetic-id counter: malformed/duplicate ids, the
  // branch connectors and the poison node all draw from it, so no two
  // synthetic ids can collide. The gate's `parsed < 0` rejection below is what
  // stops a RAW id from colliding with them.
  var malformedId = -1;
  var unrepresentable = false;
  final ignoredKinds = <String>[];
  var ignoredCount = 0;
  // Assigned localIds of dropped <TextBox>/<Attachment>. Logix anchors an
  // annotation to the element it comments on; that anchor is a documentation
  // relationship, not control flow, so a link touching one is discarded
  // WITHOUT poisoning.
  //
  // Keyed by the ACCEPTED localId, never by the raw attribute: an annotation
  // is the one non-node kind whose id IS dereferenced, so it runs the same ID
  // gate as everything else (see pass 1).
  final annotationIds = <int>{};
  // Raw `ID` -> assigned localId. Only ACCEPTED ids are registered: a rejected
  // one must never resolve, or a link naming it would silently retarget onto
  // the element that was demoted.
  final assignedByRawId = <int, int>{};
  // Assigned localId -> kind, read by the link classifier.
  final kindById = <int, _L5xSfcKind>{};

  /// The ID gate: absent / unparseable / negative / out-of-range / duplicate
  /// all get a unique synthetic negative id, an info breadcrumb and the poison
  /// flag. Duplicate severity stays `info` (unlike the FBD builder's
  /// `warning`) because here the stub is whole-POU and the loud message
  /// already exists twice — translator + mapper.
  int gateId(XmlElement el) {
    final raw = el.getAttribute('ID');
    final parsed = int.tryParse(raw ?? '');
    final duplicate =
        parsed != null && parsed >= 0 && assignedByRawId.containsKey(parsed);
    if (parsed == null ||
        parsed < 0 ||
        parsed > _kMaxL5xElementId ||
        duplicate) {
      unrepresentable = true;
      warnings.add(ImportWarning(
          severity: WarningSeverity.info,
          message: duplicate
              ? '$ownerLabel: <${el.name.local}> reuses a duplicate ID '
                  '($parsed) — it was given a synthetic id and the chart is '
                  'not translated.'
              : '$ownerLabel: <${el.name.local}> has a malformed ID '
                  '(${raw == null ? 'absent' : '"$raw"'}) — the chart is not '
                  'translated.'));
      return malformedId--;
    }
    assignedByRawId[parsed] = parsed; // no offsetting: localId IS the raw id
    return parsed;
  }

  // ---- Pass 1 — register elements, in document order.
  for (final content in _children(routine, 'SFCContent')) {
    for (final el in content.childElements) {
      final tag = el.name.local;
      if (tag == 'DirectedLink') {
        continue; // pass 2a
      }
      if (_kL5xAnnotationElements.contains(tag)) {
        ignoredCount++;
        if (!ignoredKinds.contains(tag)) ignoredKinds.add(tag);
        // An annotation is not a node, but its id IS dereferenced (pass 2a
        // discards a link anchored to one), so it MUST run the same ID gate as
        // every other ID-bearing element. Ungated, a <TextBox> reusing a real
        // element's `ID` would claim that id in `annotationIds` without a
        // duplicate-ID warning and without poisoning, and pass 2a would then
        // silently discard every link naming the REAL element — a chart that
        // translates cleanly as the wrong logic, the exact CL-19 shape. Gated,
        // the collision is an ordinary duplicate in either document order.
        annotationIds.add(gateId(el));
        continue;
      }
      final localId = gateId(el);
      final x = double.tryParse(el.getAttribute('X') ?? '') ?? 0;
      final y = double.tryParse(el.getAttribute('Y') ?? '') ?? 0;
      final name =
          (el.getAttribute('Operand') ?? el.getAttribute('Name') ?? '').trim();
      switch (tag) {
        case 'Step':
          {
            nodes.add(SfcNode(
              localId: localId,
              kind: SfcNodeKind.step,
              name: name,
              initial: el.getAttribute('InitialStep') == 'true',
              x: x,
              y: y,
            ));
            kindById[localId] = _L5xSfcKind.step;
            // Actions come from XML NESTING, not from a link (contrast
            // PLCopen's <actionBlock> + connectionPointIn), so stepLocalId is
            // always a real step id here.
            final actionEls = _children(el, 'Action').toList();
            if (actionEls.isEmpty) {
              final inline = _l5xSfcSt(el, 'Body');
              if (inline.isNotEmpty) {
                actions.add(SfcActionAssoc(
                    stepLocalId: localId,
                    qualifier: 'N',
                    source: SfcActInline(inline)));
              }
            } else {
              for (final a in actionEls) {
                final q = (a.getAttribute('Qualifier') ?? '').trim();
                actions.add(SfcActionAssoc(
                  stepLocalId: localId,
                  qualifier: q.isEmpty ? 'N' : q,
                  source: SfcActInline(_l5xSfcSt(a, 'Body')),
                ));
              }
            }
            break;
          }
        case 'Transition':
          {
            var cond = _l5xSfcSt(el, 'Condition');
            // `conditionSt` is evaluated as a boolean EXPRESSION by sfc_exec,
            // so a single trailing statement terminator would fail to parse.
            if (cond.endsWith(';')) {
              cond = cond.substring(0, cond.length - 1).trimRight();
            }
            nodes.add(SfcNode(
              localId: localId,
              kind: SfcNodeKind.transition,
              name: name,
              x: x,
              y: y,
              condition: cond.isEmpty ? SfcCondNone() : SfcCondInline(cond),
            ));
            kindById[localId] = _L5xSfcKind.transition;
            break;
          }
        default:
          {
            // <Stop>, <SbrRet>, <JSR>, a top-level <Leg>, any future tag: no
            // representable equivalent. Deliberately NOT registered in
            // `kindById` and NOT emitted as a node, so nothing downstream can
            // mistake it for a mappable element — the poison flag is what
            // makes it visible.
            unrepresentable = true;
            warnings.add(ImportWarning(
                severity: WarningSeverity.info,
                message: '$ownerLabel: <$tag ID="${el.getAttribute('ID') ?? ''}"> '
                    'has no representable equivalent — the chart is not '
                    'translated.'));
            break;
          }
      }
    }
  }

  // ---- Pass 2a — collect and classify links, in document order.
  final pending = <SfcEdge>[];
  for (final content in _children(routine, 'SFCContent')) {
    for (final el in _children(content, 'DirectedLink')) {
      final fromAttr = el.getAttribute('FromID');
      final toAttr = el.getAttribute('ToID');
      final fromRaw = int.tryParse(fromAttr ?? '');
      final toRaw = int.tryParse(toAttr ?? '');
      final fromId = fromRaw == null ? null : assignedByRawId[fromRaw];
      final toId = toRaw == null ? null : assignedByRawId[toRaw];
      // (1) An annotation anchor is documentation, not control flow. Keyed off
      // the ACCEPTED id: an annotation whose raw `ID` was rejected (malformed,
      // out of range, or a duplicate) never registered in `assignedByRawId`,
      // so it can never swallow another element's links — it poisoned the
      // chart instead.
      if ((fromId != null && annotationIds.contains(fromId)) ||
          (toId != null && annotationIds.contains(toId))) {
        continue;
      }
      final fromKind = fromId == null ? null : kindById[fromId];
      final toKind = toId == null ? null : kindById[toId];
      // (3) An endpoint naming no MAPPABLE element. The edge is still emitted
      // against a fresh synthetic id: dropping it would silently delete a
      // control path.
      if (fromKind == null || toKind == null) {
        unrepresentable = true;
        warnings.add(ImportWarning(
            severity: WarningSeverity.info,
            message: '$ownerLabel: <DirectedLink FromID="${fromAttr ?? ''}" '
                'ToID="${toAttr ?? ''}"> is a dangling link (endpoint names no '
                'element) — the chart is not translated.'));
        pending.add(SfcEdge(
          fromLocalId: fromKind == null ? malformedId-- : fromId!,
          toLocalId: toKind == null ? malformedId-- : toId!,
        ));
        continue;
      }
      // (6) An ordinary edge. (Task 2 inserts rules 2, 4 and 5 — the
      // connector-endpoint cases — ahead of this.)
      pending.add(SfcEdge(fromLocalId: fromId!, toLocalId: toId!));
    }
  }

  // ---- Pass 2b — the remaining edges, in their original document order.
  // (Task 2's pass 3 appends the connector nodes and their edges BEFORE this,
  // so connector edges lead the list. Nothing in translateSfcBody depends on
  // edge order; this is determinism and presentation, not semantics.)
  edges.addAll(pending);

  // ---- Pass 4 — finalize.
  if (ignoredCount > 0) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: $ignoredCount element(s) ignored '
            '(${ignoredKinds.join(', ')}).'));
  }
  if (unrepresentable) {
    // The poison node. `_build`'s step->step edge scan is unconditional over
    // `body.edges` and runs before the succ/pred maps, before actions are
    // grouped, and before any warning-emitting statement, so this ALWAYS
    // throws `_SfcStub('complex-topology', 'step directly wired to step
    // (missing transition)')` — position-independent, edge-order-independent,
    // deterministic, and with no stray translator infos.
    final pid = malformedId--;
    nodes.add(SfcNode(
        localId: pid, kind: SfcNodeKind.step, name: '#unrepresentable'));
    edges.add(SfcEdge(fromLocalId: pid, toLocalId: pid));
  }
  return SfcBody(
      nodes: nodes,
      edges: edges,
      actions: actions,
      refBodies: const {},
      graphicalRefs: const {});
}
```

- [ ] **Step 6: Swap the routine arm and delete the parser warning**

In `mobile/lib/import/l5x_parser.dart`, replace the `case 'SFC':` block (lines 914-921) with:

```dart
            case 'SFC':
              // <SFCContent> parses into a real SfcBody; ir_to_project's
              // existing `body is SfcBody` arm translates it whole-POU
              // (faithful-or-stub) via the shared translateSfcBody. A chart
              // that does not translate keeps that arm's stub — no
              // parser-level warning, so the message count matches the
              // PLCopen SFC path exactly.
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.sfc, localVars: const [],
                  body: _l5xSfcBody(r, warnings, 'Routine "$name"')));
              break;
```

and rewrite `_l5xRoutines`' doc comment (lines 868-873) so its SFC sentence matches the FBD one next to it:

```dart
/// Maps each `<Routine>` in each `<Program>` to a program POU named
/// `Program_Routine`. ST inlines its lines; RLL captures each rung's neutral
/// text + comment into a `NeutralLadderBody`; FBD parses its structured
/// `<FBDContent>` into a `GraphBody` (translated per network by
/// `ir_to_project`); SFC parses its structured `<SFCContent>` into an
/// `SfcBody` (translated whole-POU by `ir_to_project`).
```

- [ ] **Step 7: Rename the stale test name**

In `mobile/test/import/l5x_parser_test.dart:227`, rename the test (its fixture contains no SFC or FBD routine, so the body is untouched):

```dart
  test('routines -> program POUs (ST body; RLL captured)', () {
```

- [ ] **Step 8: Run the tests**

From `mobile/`:

```
/c/flutter/bin/flutter test test/import/l5x_parser_sfc_test.dart test/import/l5x_parser_test.dart
```

Expected: PASS — `All tests passed!`

- [ ] **Step 9: Full suite + analyze**

From `mobile/`:

```
/c/flutter/bin/flutter test
/c/flutter/bin/flutter analyze
```

Expected: `All tests passed!` and `No issues found!`. If `corpus_import_test.dart` moves, an SFC-bearing corpus file exists that the spec did not anticipate — stop and reconcile §1 against it before continuing.

- [ ] **Step 10: Commit**

```
git add -A && git commit -m "feat(l5x): parse SFC routine bodies into the neutral SfcBody"
```

---

### Task 2: Branch → divergence/convergence synthesis (the crux)

**Model:** opus · **Effort:** high

*Rationale (binding, per spec §13):* this is the design's crux and the one place where a plausible-looking shortcut produces a chart that translates cleanly as the *wrong* logic. The unified classifier's "leg endpoints by direction, branch endpoints by the other endpoint's kind" rule, the 16-row emission table, and the ordering rules between emission-table causes and shape-validation causes all have to be held in one head at once.

Implements spec §3 in full, plus §1's `<Branch>`/`<Leg>` rows and §2's pass 3.

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` — add `_L5xSfcBranch`, `_l5xSfcKindName`, `_l5xSfcValidateShape`; extend `_l5xSfcBody`'s state block, pass 1 (`case 'Branch':`), pass 2a (link-classification rules 2, 4, 5) and add pass 3.
- Test: `mobile/test/import/l5x_parser_sfc_test.dart` (existing file, append groups).

**Interfaces:**
- Consumes: everything Task 1 produced, plus `SfcNodeKind.selDiv`, `.selConv`, `.simDiv`, `.simConv`.
- Produces (all private to `l5x_parser.dart`):
  - `class _L5xSfcBranch` with `_L5xSfcBranch({required String rawId, required int divId, required int convId, required SfcNodeKind divKind, required SfcNodeKind convKind, required String? flow})`, fields `final List<int> divIn, divOut, convIn, convOut`, getters `bool get emitDiv`, `bool get emitConv`, `bool get isSelection`.
  - `String _l5xSfcKindName(_L5xSfcKind? k)`
  - `void _l5xSfcValidateShape(_L5xSfcBranch br, Map<int, _L5xSfcKind> kindById, void Function(_L5xSfcBranch, String) defect)`
- `_l5xSfcBody`'s signature is **unchanged**.

- [ ] **Step 1: Write the failing tests**

Append these groups to `mobile/test/import/l5x_parser_sfc_test.dart`, inside `void main() {`, after Task 1's last group. Also add these two helpers at file scope (next to `_nodeAt`):

```dart
/// Projects a body's edges onto `(kindOf(from), kindOf(to))` pairs, sorted.
/// Connector `localId`s are allocation-order dependent and the two `<Branch>`
/// encodings differ in element count, so THIS — not literal IR equality — is
/// what "the two encodings agree" means (§9).
List<String> _edgeKindMultiset(SfcBody b) {
  final kinds = {for (final n in b.nodes) n.localId: n.kind};
  return [
    for (final e in b.edges)
      '${kinds[e.fromLocalId]?.name ?? 'missing'}'
          '->${kinds[e.toLocalId]?.name ?? 'missing'}'
  ]..sort();
}

/// A one-line `<Transition>` with an inline ST condition.
String _t(int id, String name, String cond) =>
    '<Transition ID="$id" Operand="$name"><Condition><STContent>'
    '<Line Number="0"><![CDATA[$cond]]></Line></STContent></Condition></Transition>';
```

```dart
  group('L5X SFC: branch synthesis — the happy shapes (§3)', () {
    // S0 -> B(legs 11,12) -> legs open with T1/T2, close with T3/T4 -> S5.
    // Trunk links name the BRANCH id, leg links name LEG ids — i.e. the
    // paired encoding's natural shape, in which every branch mixes both forms
    // by construction. (This fixture is also the "both forms in one branch"
    // case of §9: the deleted mixed-convention rule would have poisoned it.)
    const selectionChart = '''
      <Step ID="1" Operand="S0" InitialStep="true"/>
      <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
      <Transition ID="2" Operand="T1"><Condition><STContent><Line Number="0"><![CDATA[A]]></Line></STContent></Condition></Transition>
      <Step ID="3" Operand="S1"/>
      <Transition ID="4" Operand="T3"><Condition><STContent><Line Number="0"><![CDATA[C]]></Line></STContent></Condition></Transition>
      <Transition ID="5" Operand="T2"><Condition><STContent><Line Number="0"><![CDATA[B]]></Line></STContent></Condition></Transition>
      <Step ID="6" Operand="S2"/>
      <Transition ID="7" Operand="T4"><Condition><STContent><Line Number="0"><![CDATA[D]]></Line></STContent></Condition></Transition>
      <Step ID="8" Operand="S5"/>
      <DirectedLink FromID="1" ToID="10"/>
      <DirectedLink FromID="11" ToID="2"/>
      <DirectedLink FromID="12" ToID="5"/>
      <DirectedLink FromID="2" ToID="3"/>
      <DirectedLink FromID="3" ToID="4"/>
      <DirectedLink FromID="4" ToID="11"/>
      <DirectedLink FromID="5" ToID="6"/>
      <DirectedLink FromID="6" ToID="7"/>
      <DirectedLink FromID="7" ToID="12"/>
      <DirectedLink FromID="10" ToID="8"/>''';

    // The same chart with EVERY branch-incident link routed through the
    // <Branch> id — no <Leg> id appears as an endpoint anywhere, and the
    // branch declares no <Leg> children at all.
    const selectionChartBranchIdForm = '''
      <Step ID="1" Operand="S0" InitialStep="true"/>
      <Branch ID="10" BranchType="Selection"/>
      <Transition ID="2" Operand="T1"><Condition><STContent><Line Number="0"><![CDATA[A]]></Line></STContent></Condition></Transition>
      <Step ID="3" Operand="S1"/>
      <Transition ID="4" Operand="T3"><Condition><STContent><Line Number="0"><![CDATA[C]]></Line></STContent></Condition></Transition>
      <Transition ID="5" Operand="T2"><Condition><STContent><Line Number="0"><![CDATA[B]]></Line></STContent></Condition></Transition>
      <Step ID="6" Operand="S2"/>
      <Transition ID="7" Operand="T4"><Condition><STContent><Line Number="0"><![CDATA[D]]></Line></STContent></Condition></Transition>
      <Step ID="8" Operand="S5"/>
      <DirectedLink FromID="1" ToID="10"/>
      <DirectedLink FromID="10" ToID="2"/>
      <DirectedLink FromID="10" ToID="5"/>
      <DirectedLink FromID="2" ToID="3"/>
      <DirectedLink FromID="3" ToID="4"/>
      <DirectedLink FromID="4" ToID="10"/>
      <DirectedLink FromID="5" ToID="6"/>
      <DirectedLink FromID="6" ToID="7"/>
      <DirectedLink FromID="7" ToID="10"/>
      <DirectedLink FromID="10" ToID="8"/>''';

    // S0 -> T0 -> B(legs 11,12) -> legs open with S1/S2, close with S3/S4
    // -> T5 -> S6. Selection diverges into TRANSITIONS; simultaneous is the
    // mirror and diverges into STEPS — the one fact synthesis must get right.
    const simultaneousChart = '''
      <Step ID="1" Operand="S0" InitialStep="true"/>
      <Transition ID="2" Operand="T0"><Condition><STContent><Line Number="0"><![CDATA[G]]></Line></STContent></Condition></Transition>
      <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/><Leg ID="12"/></Branch>
      <Step ID="3" Operand="S1"/>
      <Transition ID="4" Operand="Ta"><Condition><STContent><Line Number="0"><![CDATA[A]]></Line></STContent></Condition></Transition>
      <Step ID="5" Operand="S3"/>
      <Step ID="6" Operand="S2"/>
      <Transition ID="7" Operand="Tb"><Condition><STContent><Line Number="0"><![CDATA[B]]></Line></STContent></Condition></Transition>
      <Step ID="8" Operand="S4"/>
      <Transition ID="9" Operand="T5"><Condition><STContent><Line Number="0"><![CDATA[D]]></Line></STContent></Condition></Transition>
      <Step ID="13" Operand="S6"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="10"/>
      <DirectedLink FromID="11" ToID="3"/>
      <DirectedLink FromID="12" ToID="6"/>
      <DirectedLink FromID="3" ToID="4"/>
      <DirectedLink FromID="4" ToID="5"/>
      <DirectedLink FromID="6" ToID="7"/>
      <DirectedLink FromID="7" ToID="8"/>
      <DirectedLink FromID="5" ToID="11"/>
      <DirectedLink FromID="8" ToID="12"/>
      <DirectedLink FromID="10" ToID="9"/>
      <DirectedLink FromID="9" ToID="13"/>''';

    test('a paired selection branch emits selDiv+selConv and exactly 6 branch edges', () {
      final (body, ws) = _build(_wrap(selectionChart));

      final div = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.selDiv);
      final conv = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.selConv);
      expect(div.localId, lessThan(0));
      expect(conv.localId, lessThan(0));
      expect(div.localId == conv.localId, isFalse);

      // Connector edges LEAD the list (pass 3 before pass 2b), in
      // divIn / divOut / convIn / convOut order.
      expect(body.edges.take(6).map((e) => '${e.fromLocalId}->${e.toLocalId}'), [
        '1->${div.localId}',
        '${div.localId}->2',
        '${div.localId}->5',
        '4->${conv.localId}',
        '7->${conv.localId}',
        '${conv.localId}->8',
      ]);
      expect(body.edges, hasLength(10)); // 6 branch + 4 intra-leg
      expect(ws, isEmpty);

      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.transitions.map((t) => t.kind).toSet(), {'single'});
      expect(
          tr.transitions.map((t) => '${t.fromStepId}->${t.toStepId}').toSet(),
          {'P_s1->P_s3', 'P_s3->P_s8', 'P_s1->P_s6', 'P_s6->P_s8'});
    });

    test('a paired simultaneous branch emits simDiv+simConv, a fork and a join', () {
      final (body, ws) = _build(_wrap(simultaneousChart));

      final div = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.simDiv);
      final conv = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.simConv);
      expect(body.edges.take(6).map((e) => '${e.fromLocalId}->${e.toLocalId}'), [
        '2->${div.localId}',
        '${div.localId}->3',
        '${div.localId}->6',
        '5->${conv.localId}',
        '8->${conv.localId}',
        '${conv.localId}->9',
      ]);
      expect(body.edges, hasLength(12)); // 6 branch + 6 ordinary
      expect(ws, isEmpty);

      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      final fork = tr.transitions.firstWhere((t) => t.kind == 'parallelFork');
      expect(fork.fromStepId, 'P_s1');
      expect(fork.toStepIds.toSet(), {'P_s3', 'P_s6'});
      final join = tr.transitions.firstWhere((t) => t.kind == 'parallelJoin');
      expect(join.fromStepIds.toSet(), {'P_s5', 'P_s8'});
      expect(join.toStepId, 'P_s13');
      expect(tr.transitions.where((t) => t.kind == 'parallelFork'), hasLength(1));
      expect(tr.transitions.where((t) => t.kind == 'parallelJoin'), hasLength(1));
    });

    test('the leg-id and branch-id encodings produce the same chart', () {
      // NOT literal IR equality: connector ids are allocation-order dependent
      // and the fixtures differ in element count.
      final (legForm, legWs) = _build(_wrap(selectionChart));
      final (branchForm, branchWs) = _build(_wrap(selectionChartBranchIdForm));

      expect(_edgeKindMultiset(branchForm), _edgeKindMultiset(legForm));
      expect(legWs, isEmpty);
      expect(branchWs, isEmpty);

      final a = translateSfcBody(legForm, pouName: 'P');
      final b = translateSfcBody(branchForm, pouName: 'P');
      expect(b.translated, a.translated);
      expect(b.steps.map((s) => '${s.id}|${s.name}|${s.isInitial}'),
          a.steps.map((s) => '${s.id}|${s.name}|${s.isInitial}'));
      expect(
          b.transitions.map((t) =>
              '${t.id}|${t.kind}|${t.fromStepId}|${t.toStepId}|'
              '${t.fromStepIds.join(',')}|${t.toStepIds.join(',')}|${t.conditionSt}'),
          a.transitions.map((t) =>
              '${t.id}|${t.kind}|${t.fromStepId}|${t.toStepId}|'
              '${t.fromStepIds.join(',')}|${t.toStepIds.join(',')}|${t.conditionSt}'));
    });

    test('a <Branch> with no <Leg> children at all translates (there is no mode switch)', () {
      // Directly pins the deletion of the "no Leg id => fallback mode" gate.
      final (body, ws) = _build(_wrap(selectionChartBranchIdForm));
      expect(ws, isEmpty);
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('BOTH link forms in one branch translate (the mixed-convention regression)', () {
      // In the paired encoding a branch's TRUNK links must name the <Branch>
      // id while its LEG links name <Leg> ids, so EVERY paired branch mixes
      // both forms by construction. The deleted "mixed convention => poison"
      // rule would have stubbed this — the common case, and the headline
      // fixture of the spec itself. This test exists so that rule can never be
      // reintroduced silently.
      final (body, ws) = _build(_wrap(selectionChart));
      expect(_hasInfo(ws, 'branch shape not representable'), isFalse,
          reason: _infos(ws).toString());
      expect(body.nodes.where((n) => n.name == '#unrepresentable'), isEmpty);
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a diverge-only branch emits the divergence and drops the convergence', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S1"/>
        ${_t(4, 'T2', 'B')}
        <Step ID="5" Operand="S2"/>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="2"/>
        <DirectedLink FromID="12" ToID="4"/>
        <DirectedLink FromID="2" ToID="3"/>
        <DirectedLink FromID="4" ToID="5"/>'''));

      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), hasLength(1));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), isEmpty);
      expect(ws, isEmpty);
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a converge-only branch emits the convergence and drops the divergence', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S1" InitialStep="true"/>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S2"/>
        ${_t(4, 'T2', 'B')}
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
        <Step ID="5" Operand="S5"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="11"/>
        <DirectedLink FromID="3" ToID="4"/>
        <DirectedLink FromID="4" ToID="12"/>
        <DirectedLink FromID="10" ToID="5"/>'''));

      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), hasLength(1));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), isEmpty);
      expect(ws, isEmpty);
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('loop-back legs are not a special case (ordinary edges + row 2)', () {
      // A leg tail wired to an upstream step instead of back into the branch
      // never touches a branch or leg id, so it is an ordinary edge and the
      // branch's own bits land on the diverge-only row.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S1"/>
        ${_t(4, 'T2', 'B')}
        <Step ID="5" Operand="S2"/>
        ${_t(6, 'BackA', 'C')}
        ${_t(7, 'BackB', 'D')}
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="2"/>
        <DirectedLink FromID="12" ToID="4"/>
        <DirectedLink FromID="2" ToID="3"/>
        <DirectedLink FromID="4" ToID="5"/>
        <DirectedLink FromID="3" ToID="6"/>
        <DirectedLink FromID="6" ToID="1"/>
        <DirectedLink FromID="5" ToID="7"/>
        <DirectedLink FromID="7" ToID="1"/>'''));

      expect(ws, isEmpty, reason: _infos(ws).toString());
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), hasLength(1));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.transitions.map((t) => t.kind).toSet(), {'single'});
      // Both loop-backs land on the initial step.
      expect(
          tr.transitions
              .where((t) => t.toStepId == 'P_s1')
              .map((t) => t.fromStepId)
              .toSet(),
          {'P_s3', 'P_s5'});
    });

    test('a single-leg branch translates as an ordinary linear path', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S1"/>
        ${_t(4, 'T2', 'B')}
        <Step ID="5" Operand="S2"/>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>
        <DirectedLink FromID="3" ToID="4"/>
        <DirectedLink FromID="4" ToID="11"/>
        <DirectedLink FromID="10" ToID="5"/>'''));

      expect(ws, isEmpty); // faithful, if pointless — no warning, no stub
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.transitions.map((t) => t.kind).toSet(), {'single'});
    });

    test('STEP-SEPARATED nested branches TRANSLATE (nesting per se is supported)', () {
      // The intuitive-but-false claim is "nested branches stub". An inner
      // branch whose inlet is the intervening step is an ordinary selDiv with
      // a single step inflow; upstream/downstreamSteps resolve each transition
      // through exactly ONE connector to exactly one step.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="30" BranchType="Selection"><Leg ID="31"/><Leg ID="32"/></Branch>
        ${_t(20, 'T1', 'A')}
        <Step ID="2" Operand="S1"/>
        <Branch ID="40" BranchType="Selection"><Leg ID="41"/><Leg ID="42"/></Branch>
        ${_t(23, 'T5', 'C')}
        <Step ID="4" Operand="S5"/>
        ${_t(25, 'T7', 'E')}
        ${_t(24, 'T6', 'D')}
        <Step ID="5" Operand="S6"/>
        ${_t(26, 'T8', 'F')}
        <Step ID="6" Operand="S7"/>
        ${_t(27, 'T9', 'G')}
        ${_t(21, 'T2', 'B')}
        <Step ID="3" Operand="S2"/>
        ${_t(22, 'T4', 'H')}
        <Step ID="7" Operand="S9"/>
        <DirectedLink FromID="1" ToID="30"/>
        <DirectedLink FromID="31" ToID="20"/>
        <DirectedLink FromID="32" ToID="21"/>
        <DirectedLink FromID="20" ToID="2"/>
        <DirectedLink FromID="2" ToID="40"/>
        <DirectedLink FromID="41" ToID="23"/>
        <DirectedLink FromID="42" ToID="24"/>
        <DirectedLink FromID="23" ToID="4"/>
        <DirectedLink FromID="24" ToID="5"/>
        <DirectedLink FromID="4" ToID="25"/>
        <DirectedLink FromID="5" ToID="26"/>
        <DirectedLink FromID="25" ToID="41"/>
        <DirectedLink FromID="26" ToID="42"/>
        <DirectedLink FromID="40" ToID="6"/>
        <DirectedLink FromID="6" ToID="27"/>
        <DirectedLink FromID="27" ToID="31"/>
        <DirectedLink FromID="21" ToID="3"/>
        <DirectedLink FromID="3" ToID="22"/>
        <DirectedLink FromID="22" ToID="32"/>
        <DirectedLink FromID="30" ToID="7"/>'''));

      expect(ws, isEmpty);
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), hasLength(2));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), hasLength(2));
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.transitions, hasLength(8));
      expect(tr.transitions.map((t) => t.kind).toSet(), {'single'});
      expect(
          tr.transitions.every((t) =>
              t.fromStepId.isNotEmpty && t.toStepId.isNotEmpty),
          isTrue);
    });

    test('BranchFlow is read but not trusted: a mismatch warns, the links win', () {
      final (body, ws) = _build(_wrap(
          selectionChart.replaceFirst('BranchType="Selection"',
              'BranchType="Selection" BranchFlow="Diverge"')));

      expect(_hasInfo(ws, 'branch flow mismatch'), isTrue, reason: _infos(ws).toString());
      expect(_hasInfo(ws, 'branch shape not representable'), isFalse);
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), hasLength(1));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), hasLength(1));
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a raw ID="-1" can never collide with a branch connector (Critical 2)', () {
      // Without §2's `parsed < 0` gate the step would keep localId -1, which
      // is exactly divId of the first branch: byId is last-write-wins while
      // stepNodes/succ/pred keep BOTH, so the chart would translate cleanly
      // with zero warnings AS THE WRONG LOGIC.
      final (body, ws) = _build(_wrap('''
        <Step ID="-1" Operand="Neg" InitialStep="true"/>
        <Step ID="1" Operand="S0"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S1"/>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      final neg = body.nodes.firstWhere((n) => n.name == 'Neg');
      final div = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.selDiv);
      expect(neg.localId, lessThan(0));
      expect(neg.localId == div.localId, isFalse);
      expect(_hasInfo(ws, 'malformed ID'), isTrue);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse, reason: 'the gate must make this LOUD');
      expect(tr.stubReason, 'complex-topology');
    });
  });

  group('L5X SFC: the 4-bit emission decision table (§3)', () {
    /// A selection-branch fixture in which each of the four buckets is set
    /// independently, through the BRANCH id — the only form in which every
    /// bit is independently settable.
    String bits(bool divIn, bool divOut, bool convIn, bool convOut) => _wrap('''
      <Step ID="1" Operand="S1" InitialStep="true"/>
      ${_t(2, 'T1', 'A')}
      ${_t(3, 'T2', 'B')}
      <Step ID="4" Operand="S2"/>
      <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
      ${divIn ? '<DirectedLink FromID="1" ToID="10"/>' : ''}
      ${divOut ? '<DirectedLink FromID="10" ToID="2"/>' : ''}
      ${convIn ? '<DirectedLink FromID="3" ToID="10"/>' : ''}
      ${convOut ? '<DirectedLink FromID="10" ToID="4"/>' : ''}''');

    // Every one of the 16 combinations is named: 3 well-formed shapes and the
    // 13 defect rows, each with its own cause clause.
    const rows = <(bool, bool, bool, bool, bool, bool, String?)>[
      //div in, div out, conv in, conv out, emit div, emit conv, cause
      (true, true, true, true, true, true, null),
      (true, true, false, false, true, false, null),
      (false, false, true, true, false, true, null),
      (true, true, true, false, true, true, 'convergence has no outlet'),
      (true, true, false, true, true, true, 'convergence has no inlet'),
      (true, false, true, true, true, true, 'divergence has no legs'),
      (false, true, true, true, true, true, 'divergence has no inlet'),
      (true, false, false, false, true, false, 'divergence has no legs'),
      (false, true, false, false, true, false, 'divergence has no inlet'),
      (false, false, true, false, false, true, 'convergence has no outlet'),
      (false, false, false, true, false, true, 'convergence has no inlet'),
      (true, false, true, false, true, true, 'divergence has no legs'),
      (true, false, false, true, true, true, 'divergence has no legs'),
      (false, true, true, false, true, true, 'divergence has no inlet'),
      (false, true, false, true, true, true, 'divergence has no inlet'),
      (false, false, false, false, false, false, 'branch has no links'),
    ];

    for (final r in rows) {
      final (dIn, dOut, cIn, cOut, emitDiv, emitConv, cause) = r;
      test('bits $dIn/$dOut/$cIn/$cOut -> '
          '${cause ?? 'no defect'}', () {
        final (body, ws) = _build(bits(dIn, dOut, cIn, cOut));

        expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv),
            hasLength(emitDiv ? 1 : 0));
        expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv),
            hasLength(emitConv ? 1 : 0));

        final shape = _infos(ws)
            .where((m) => m.contains('branch shape not representable ('))
            .toList();
        if (cause == null) {
          expect(shape, isEmpty, reason: shape.toString());
        } else {
          // A poisoned branch still emits its connectors, so the element
          // count stays honest — but exactly ONE cause is reported.
          expect(shape, hasLength(1));
          expect(shape.single,
              contains('branch shape not representable ($cause)'));
          final tr = translateSfcBody(body, pouName: 'P');
          expect(tr.translated, isFalse);
          expect(tr.stubReason, 'complex-topology');
        }
      });
    }
  });

  group('L5X SFC: branch shape validation and its cause clauses (§3, §8)', () {
    test('a selection leg headed by a step', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Step ID="4" Operand="S2"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="4"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(selection leg head is a step, expected transition)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('a selection leg tailed by a step', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Step ID="4" Operand="S2"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <DirectedLink FromID="1" ToID="11"/>
        <DirectedLink FromID="10" ToID="4"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(selection leg tail is a step, expected transition)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('a simultaneous leg headed by a transition', () {
      final (_, ws) = _build(_wrap('''
        ${_t(2, 'T0', 'A')}
        ${_t(3, 'T1', 'B')}
        <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
        <DirectedLink FromID="2" ToID="10"/>
        <DirectedLink FromID="11" ToID="3"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(simultaneous leg head is a transition, expected step)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('a simultaneous leg tailed by a transition', () {
      final (_, ws) = _build(_wrap('''
        ${_t(2, 'T0', 'A')}
        ${_t(3, 'T1', 'B')}
        <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
        <DirectedLink FromID="2" ToID="11"/>
        <DirectedLink FromID="10" ToID="3"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(simultaneous leg tail is a transition, expected step)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('two trunk-ins on a selection divergence', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Step ID="5" Operand="S0b"/>
        ${_t(2, 'T1', 'A')}
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="5" ToID="10"/>
        <DirectedLink FromID="10" ToID="2"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(selection divergence has 2 inlets, expected 1)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('two trunk-outs on a selection convergence', () {
      final (_, ws) = _build(_wrap('''
        ${_t(2, 'T1', 'A')}
        <Step ID="4" Operand="S2"/>
        <Step ID="5" Operand="S3"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <DirectedLink FromID="2" ToID="10"/>
        <DirectedLink FromID="10" ToID="4"/>
        <DirectedLink FromID="10" ToID="5"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(selection convergence has 2 outlets, expected 1)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('two trunk-ins on a simultaneous divergence', () {
      final (_, ws) = _build(_wrap('''
        ${_t(2, 'T0', 'A')}
        ${_t(3, 'T0b', 'B')}
        <Step ID="4" Operand="S1"/>
        <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
        <DirectedLink FromID="2" ToID="10"/>
        <DirectedLink FromID="3" ToID="10"/>
        <DirectedLink FromID="10" ToID="4"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(simultaneous divergence has 2 inlets, expected 1)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('two trunk-outs on a simultaneous convergence', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S1" InitialStep="true"/>
        ${_t(2, 'T5', 'A')}
        ${_t(3, 'T5b', 'B')}
        <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="10" ToID="2"/>
        <DirectedLink FromID="10" ToID="3"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(simultaneous convergence has 2 outlets, expected 1)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('connector-adjacent nesting poisons with its own cause', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <Branch ID="20" BranchType="Selection"><Leg ID="21"/></Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="20"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(branch is directly adjacent to another branch)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('a <Branch> nested inside a <Leg> is unregistered -> dangling link', () {
      // Pins the §2 recursion policy: pass 1 walks the DIRECT children of each
      // <SFCContent>, plus a <Branch>'s direct <Leg> children, and no further.
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        ${_t(2, 'T1', 'A')}
        <Branch ID="10" BranchType="Selection">
          <Leg ID="11"><Branch ID="20" BranchType="Selection"><Leg ID="21"/></Branch></Leg>
          <Leg ID="12"/>
        </Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="20" ToID="2"/>'''));
      expect(_hasInfo(ws, 'dangling link'), isTrue, reason: _infos(ws).toString());
    });

    test('an unrecognized BranchType poisons and synthesizes nothing', () {
      for (final (attr, shown) in const [
        ('', ''),
        (' BranchType="Parallel"', 'Parallel'),
      ]) {
        final (body, ws) = _build(_wrap('''
          <Step ID="1" Operand="S0" InitialStep="true"/>
          ${_t(2, 'T1', 'A')}
          <Branch ID="10"$attr><Leg ID="11"/></Branch>
          <DirectedLink FromID="1" ToID="10"/>
          <DirectedLink FromID="11" ToID="2"/>'''));

        expect(_hasInfo(ws, 'branch type "$shown"'), isTrue,
            reason: _infos(ws).toString());
        expect(
            body.nodes.any((n) => const [
                  SfcNodeKind.selDiv,
                  SfcNodeKind.selConv,
                  SfcNodeKind.simDiv,
                  SfcNodeKind.simConv
                ].contains(n.kind)),
            isFalse);
        // Links touching it are discarded, NOT reported as dangling: the
        // branch-type breadcrumb is the one actionable cause.
        expect(_hasInfo(ws, 'dangling link'), isFalse);
        expect(translateSfcBody(body, pouName: 'P').translated, isFalse);
      }
    });

    test('the four inlet/outlet KIND causes are unreachable by construction', () {
      // §3's classifier derives the trunk role FROM the neighbour's kind, so
      // divIn/convOut can only ever hold correctly-kinded nodes. The checks
      // exist as defence in depth against a future classifier change.
      //
      // DOCUMENTATION ONLY — the enforcing assertion lives in `_build`, so it
      // rides on every fixture in this file including all 16 emission rows and
      // all 8 shape fixtures. A version of this test that only walked
      // well-formed charts would pass with the kind checks deleted outright,
      // which is why it must not be the only home for the claim.
      final fixtures = <String>[
        _wrap('''
          <Step ID="1" Operand="S0" InitialStep="true"/>
          <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
          ${_t(2, 'T1', 'A')}
          <Step ID="3" Operand="S1"/>
          ${_t(4, 'T2', 'B')}
          <Step ID="5" Operand="S2"/>
          <DirectedLink FromID="1" ToID="10"/>
          <DirectedLink FromID="11" ToID="2"/>
          <DirectedLink FromID="2" ToID="3"/>
          <DirectedLink FromID="3" ToID="4"/>
          <DirectedLink FromID="4" ToID="11"/>
          <DirectedLink FromID="10" ToID="5"/>'''),
        _wrap('''
          ${_t(2, 'T0', 'A')}
          <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
          <Step ID="3" Operand="S1"/>
          ${_t(4, 'T5', 'B')}
          <DirectedLink FromID="2" ToID="10"/>
          <DirectedLink FromID="11" ToID="3"/>
          <DirectedLink FromID="3" ToID="11"/>
          <DirectedLink FromID="10" ToID="4"/>'''),
      ];
      for (final f in fixtures) {
        final (_, ws) = _build(f);
        expect(_infos(ws).any((m) => m.contains('divergence inlet is a')), isFalse);
        expect(_infos(ws).any((m) => m.contains('convergence outlet is a')), isFalse);
      }
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

From `mobile/`:

```
/c/flutter/bin/flutter test test/import/l5x_parser_sfc_test.dart
```

Expected: FAIL. Task 1's `default:` arm treats `<Branch>` as unmappable, so every new test dies on a missing connector node — e.g. `Bad state: No element` from `firstWhere((n) => n.kind == SfcNodeKind.selDiv)`, and the emission-table rows report `no representable equivalent` instead of the expected cause clauses. Task 1's groups must still pass.

- [ ] **Step 3: Add the branch state class and helpers**

In `mobile/lib/import/l5x_parser.dart`, insert immediately **after** the `_L5xSfcKind` enum:

```dart
/// Per-`<Branch>` synthesis state. L5X models a branch as ONE element with
/// `<Leg>` children plus a flat `<DirectedLink>` list; the neutral IR (and
/// IEC 61131-3, and `sfc_exec`) models it as TWO connector nodes, an opening
/// divergence and a closing convergence, with ordinary edges between them and
/// the elements on each leg. This class holds the synthesized pair's reserved
/// ids and the four link buckets §3's decision table reads.
///
/// Leg MEMBERSHIP is never computed: only each leg's head and tail matter, and
/// both fall straight out of the endpoint classifier.
class _L5xSfcBranch {
  _L5xSfcBranch({
    required this.rawId,
    required this.divId,
    required this.convId,
    required this.divKind,
    required this.convKind,
    required this.flow,
  });

  /// The raw `ID` attribute text, used verbatim in warnings.
  final String rawId;

  /// Reserved at REGISTRATION (pass 1), from the routine-wide synthetic-id
  /// counter, for every branch with a recognized `BranchType` — even when one
  /// side is later dropped. That makes id allocation a pure function of
  /// document order, independent of the link list.
  final int divId, convId;
  final SfcNodeKind divKind, convKind;

  /// `BranchFlow`, READ BUT NOT TRUSTED: emission is derived from link
  /// topology, so an export that splits a branch into separate `Diverge` and
  /// `Converge` elements and one that emits a single paired element both work
  /// without a mode switch.
  final String? flow;

  /// Node ids feeding / fed by each synthesized connector.
  final List<int> divIn = [], divOut = [], convIn = [], convOut = [];

  /// §3's emission rule, in full: a side is emitted whenever EITHER of its
  /// bits is set, and dropped when both are clear. (All 16 rows of the
  /// decision table satisfy this; a side with exactly one bit set is emitted
  /// AND recorded as a defect, so the element count stays honest.)
  bool get emitDiv => divIn.isNotEmpty || divOut.isNotEmpty;
  bool get emitConv => convIn.isNotEmpty || convOut.isNotEmpty;

  bool get isSelection => divKind == SfcNodeKind.selDiv;
}

/// Human name for a resolved endpoint kind, used inside branch cause clauses.
String _l5xSfcKindName(_L5xSfcKind? k) => switch (k) {
      _L5xSfcKind.step => 'step',
      _L5xSfcKind.transition => 'transition',
      _L5xSfcKind.branch => 'branch',
      _L5xSfcKind.leg => 'leg',
      null => 'unknown element',
    };

/// §3's shape validation for one branch, run only on EMITTED connectors and
/// only when the emission table found no defect, so one defect can never be
/// reported twice. Asserts the neighbour kinds `translateSfcBody`'s
/// `upstreamSteps`/`downstreamSteps` require:
///
///   selDiv  <- exactly one step;  -> transitions
///   selConv <- transitions;       -> exactly one step
///   simDiv  <- exactly one transition; -> steps
///   simConv <- steps;             -> exactly one transition
///
/// Why validate here rather than letting `translateSfcBody` catch it: the
/// translator's gates are reached ONLY from a transition's pred/succ walk, so
/// a malformed connector that is on no transition's walk would be IGNORED and
/// the steps behind it would become unreachable islands that vanish without a
/// word. The translator's own gates remain as a backstop.
///
/// The four inlet/outlet KIND checks are DEFENCE IN DEPTH: §3's unified
/// classifier derives the trunk role FROM the neighbour's kind, so `divIn` and
/// `convOut` can only ever hold correctly-kinded nodes today. They are kept
/// against a future classifier change and asserted absent by test.
void _l5xSfcValidateShape(_L5xSfcBranch br, Map<int, _L5xSfcKind> kindById,
    void Function(_L5xSfcBranch, String) defect) {
  final side = br.isSelection ? 'selection' : 'simultaneous';
  // Selection diverges into TRANSITIONS and converges out to a STEP;
  // simultaneous is the mirror. That asymmetry is the single fact synthesis
  // must get right.
  final trunkKind =
      br.isSelection ? _L5xSfcKind.step : _L5xSfcKind.transition;
  final legKind =
      br.isSelection ? _L5xSfcKind.transition : _L5xSfcKind.step;

  if (br.emitDiv) {
    if (br.divIn.length != 1) {
      defect(br, '$side divergence has ${br.divIn.length} inlets, expected 1');
      return;
    }
    final inletKind = kindById[br.divIn.single];
    if (inletKind != trunkKind) {
      defect(
          br,
          '$side divergence inlet is a ${_l5xSfcKindName(inletKind)}, '
          'expected ${_l5xSfcKindName(trunkKind)}');
      return;
    }
    for (final n in br.divOut) {
      final k = kindById[n];
      if (k != legKind) {
        defect(
            br,
            '$side leg head is a ${_l5xSfcKindName(k)}, '
            'expected ${_l5xSfcKindName(legKind)}');
        return;
      }
    }
  }
  if (br.emitConv) {
    for (final n in br.convIn) {
      final k = kindById[n];
      if (k != legKind) {
        defect(
            br,
            '$side leg tail is a ${_l5xSfcKindName(k)}, '
            'expected ${_l5xSfcKindName(legKind)}');
        return;
      }
    }
    if (br.convOut.length != 1) {
      defect(br, '$side convergence has ${br.convOut.length} outlets, expected 1');
      return;
    }
    final outletKind = kindById[br.convOut.single];
    if (outletKind != trunkKind) {
      defect(
          br,
          '$side convergence outlet is a ${_l5xSfcKindName(outletKind)}, '
          'expected ${_l5xSfcKindName(trunkKind)}');
      return;
    }
  }
}
```

- [ ] **Step 4: Extend `_l5xSfcBody`'s state block**

Immediately after the `final kindById = <int, _L5xSfcKind>{};` declaration, add:

```dart
  // Branch bookkeeping. `branches` is document order — the order every branch
  // warning and every connector node/edge is emitted in.
  final branches = <_L5xSfcBranch>[];
  final branchByLocalId = <int, _L5xSfcBranch>{};
  final legToBranch = <int, _L5xSfcBranch>{};
  // localIds belonging to a branch (or leg) whose `BranchType` was not
  // recognized. A link touching one is discarded whole: that branch already
  // emitted the one actionable breadcrumb, and N `dangling link` messages
  // would bury it.
  final unrecognizedIds = <int>{};
  // At most ONE `branch shape not representable` cause per branch. Precedence:
  // connector-adjacent (pass 2a) > emission-table cause > shape-validation
  // cause; first recorded wins. Emission happens in pass 3, in branch document
  // order, so message order is deterministic.
  final branchDefect = <_L5xSfcBranch, String>{};
  void defect(_L5xSfcBranch br, String cause) {
    branchDefect.putIfAbsent(br, () => cause);
    unrepresentable = true;
  }
```

- [ ] **Step 5: Add the `<Branch>` case to pass 1**

In `_l5xSfcBody`'s pass-1 `switch (tag)`, insert between `case 'Transition':` and `default:`:

```dart
        case 'Branch':
          {
            // No 1:1 IR node — a <Branch> is synthesized into a PAIR of
            // connector nodes in pass 3, wired from link topology.
            final rawId = el.getAttribute('ID') ?? '';
            final type = (el.getAttribute('BranchType') ?? '').trim();
            final divKind = switch (type) {
              'Selection' => SfcNodeKind.selDiv,
              'Simultaneous' => SfcNodeKind.simDiv,
              _ => null,
            };
            if (divKind == null) {
              unrepresentable = true;
              warnings.add(ImportWarning(
                  severity: WarningSeverity.info,
                  message: '$ownerLabel: <Branch ID="$rawId"> branch type '
                      '"$type" not recognized — the chart is not translated.'));
              // The branch AND its legs are registered as unrecognized (the
              // legs still run the ID gate, so duplicate detection stays
              // honest), which makes every incident link a silent discard
              // rather than N `dangling link` breadcrumbs burying the one
              // actionable cause.
              unrecognizedIds.add(localId);
              for (final leg in _children(el, 'Leg')) {
                unrecognizedIds.add(gateId(leg));
              }
              break; // no connectors synthesized
            }
            final convKind = divKind == SfcNodeKind.selDiv
                ? SfcNodeKind.selConv
                : SfcNodeKind.simConv;
            // Two ids from the ONE routine-wide counter, reserved in
            // document order.
            final divId = malformedId--;
            final convId = malformedId--;
            final br = _L5xSfcBranch(
              rawId: rawId,
              divId: divId,
              convId: convId,
              divKind: divKind,
              convKind: convKind,
              flow: el.getAttribute('BranchFlow')?.trim(),
            );
            branches.add(br);
            branchByLocalId[localId] = br;
            kindById[localId] = _L5xSfcKind.branch;
            // A <Leg>'s `ID` is a LINK ENDPOINT, not a node. The walk stops
            // here: a <Branch> nested as a child of a <Leg> is never
            // registered, so any link naming it dangles -> visible stub.
            for (final leg in _children(el, 'Leg')) {
              final legId = gateId(leg);
              legToBranch[legId] = br;
              kindById[legId] = _L5xSfcKind.leg;
            }
            break;
          }
```

- [ ] **Step 6: Add the connector rules to pass 2a**

In `_l5xSfcBody`'s pass 2a, insert rule (2) immediately after the annotation check (rule 1) and before `final fromKind = ...` (`fromId`/`toId` are already resolved above rule 1, so nothing needs renaming):

```dart
      // (2) A link touching an unrecognized-BranchType branch (or its legs).
      // That branch already emitted the one actionable breadcrumb plus the
      // poison flag; N `dangling link` messages would bury it.
      if ((fromId != null && unrecognizedIds.contains(fromId)) ||
          (toId != null && unrecognizedIds.contains(toId))) {
        continue;
      }
```

then replace the dangling arm's edge construction plus the trailing ordinary-edge line with:

```dart
      // (3) An endpoint naming no MAPPABLE element. The edge is still emitted
      // against a fresh synthetic id: dropping it would silently delete a
      // control path. A resolvable connector side uses the DIRECTION fallback
      // purely so the edge has an endpoint — the body is already poisoned, so
      // no reading of that edge can matter.
      if (fromKind == null || toKind == null) {
        unrepresentable = true;
        warnings.add(ImportWarning(
            severity: WarningSeverity.info,
            message: '$ownerLabel: <DirectedLink FromID="${fromAttr ?? ''}" '
                'ToID="${toAttr ?? ''}"> is a dangling link (endpoint names no '
                'element) — the chart is not translated.'));
        int side(int? id, _L5xSfcKind? kind, bool isFrom) {
          if (kind == null) return malformedId--;
          if (kind == _L5xSfcKind.leg) {
            final b = legToBranch[id]!;
            return isFrom ? b.divId : b.convId;
          }
          if (kind == _L5xSfcKind.branch) {
            final b = branchByLocalId[id]!;
            return isFrom ? b.divId : b.convId;
          }
          return id!;
        }

        pending.add(SfcEdge(
            fromLocalId: side(fromId, fromKind, true),
            toLocalId: side(toId, toKind, false)));
        continue;
      }
      final fromConn =
          fromKind == _L5xSfcKind.branch || fromKind == _L5xSfcKind.leg;
      final toConn = toKind == _L5xSfcKind.branch || toKind == _L5xSfcKind.leg;
      // (4) CONNECTOR-ADJACENT: a leg head or tail that is ITSELF a branch,
      // giving a div->div / conv->conv / div->conv edge with no step or
      // transition between. upstream/downstreamSteps see through only ONE
      // connector, so a connector chain has no representable resolution. No
      // edge is emitted (there is no non-arbitrary connector id to attach it
      // to); the cause clause is the loud, named record of the link.
      if (fromConn && toConn) {
        final br = fromKind == _L5xSfcKind.leg
            ? legToBranch[fromId]!
            : branchByLocalId[fromId]!;
        defect(br, 'branch is directly adjacent to another branch');
        continue;
      }
      // (5) Exactly one connector endpoint: §3's unified endpoint classifier.
      // There is deliberately NO mode switch and no mixed-convention rule — in
      // the paired encoding a branch's TRUNK links must name the <Branch> id
      // while its LEG links name <Leg> ids, so every paired branch mixes both
      // forms by construction.
      if (fromConn || toConn) {
        final connKind = fromConn ? fromKind : toKind;
        final connId = fromConn ? fromId! : toId!;
        final otherKind = fromConn ? toKind : fromKind;
        final otherId = fromConn ? toId! : fromId!;
        final br = connKind == _L5xSfcKind.leg
            ? legToBranch[connId]!
            : branchByLocalId[connId]!;
        if (connKind == _L5xSfcKind.leg) {
          // LEG endpoints resolve BY DIRECTION. Unambiguous: a leg id can only
          // ever mean "the branch-side end of this leg", and which end is
          // fixed by the arrow.
          if (fromConn) {
            br.divOut.add(otherId);
          } else {
            br.convIn.add(otherId);
          }
        } else {
          // BRANCH endpoints resolve BY THE OTHER ENDPOINT'S KIND. The naive
          // direction rule agrees on every trunk link but is strictly worse on
          // a leg-role link expressed through the branch id: it would read
          // `FromID == B -> T1` as a convergence outlet and wire conv -> T1, a
          // silently wrong chart that still passes every shape check.
          final legKind = br.isSelection
              ? _L5xSfcKind.transition // selection legs open/close on transitions
              : _L5xSfcKind.step; // simultaneous legs open/close on steps
          final isLegRole = otherKind == legKind;
          if (fromConn) {
            (isLegRole ? br.divOut : br.convOut).add(otherId);
          } else {
            (isLegRole ? br.convIn : br.divIn).add(otherId);
          }
        }
        continue;
      }
      // (6) An ordinary edge.
      pending.add(SfcEdge(fromLocalId: fromId!, toLocalId: toId!));
```

- [ ] **Step 7: Add pass 3**

In `_l5xSfcBody`, insert between the end of pass 2a's loop and the `// ---- Pass 2b` comment:

```dart
  // ---- Pass 3 — synthesize branch connectors (§3), in branch document order.
  // Connector nodes and their edges are appended BEFORE the ordinary edges, so
  // a single ordered edge list falls out.
  for (final br in branches) {
    final emitDiv = br.emitDiv;
    final emitConv = br.emitConv;
    // The 4-bit emission decision table, in full. Every one of the 16
    // combinations is covered: a side with exactly one bit set is a defect, a
    // branch no link touches is a defect, and where two causes could apply the
    // DIVERGENCE-side cause wins (deterministic, and it is the upstream defect
    // — the one a user fixes first).
    if (!emitDiv && !emitConv) {
      defect(br, 'branch has no links');
    } else if (emitDiv && (br.divIn.isEmpty || br.divOut.isEmpty)) {
      defect(
          br,
          br.divIn.isNotEmpty
              ? 'divergence has no legs'
              : 'divergence has no inlet');
    } else if (emitConv && (br.convIn.isEmpty || br.convOut.isEmpty)) {
      defect(
          br,
          br.convIn.isNotEmpty
              ? 'convergence has no outlet'
              : 'convergence has no inlet');
    }
    if (!branchDefect.containsKey(br)) {
      _l5xSfcValidateShape(br, kindById, defect);
    }
    // BranchFlow contradicting the derived topology is a breadcrumb, not a
    // defect: the links are what the chart actually says.
    if ((br.flow == 'Diverge' && emitConv) ||
        (br.flow == 'Converge' && emitDiv)) {
      warnings.add(ImportWarning(
          severity: WarningSeverity.info,
          message: '$ownerLabel: <Branch ID="${br.rawId}"> branch flow '
              'mismatch: BranchFlow="${br.flow}" but the links describe '
              '${emitDiv && emitConv ? 'both a divergence and a convergence' : emitDiv ? 'a divergence' : 'a convergence'}'
              ' — the links win.'));
    }
    if (emitDiv) {
      nodes.add(SfcNode(localId: br.divId, kind: br.divKind));
    }
    if (emitConv) {
      nodes.add(SfcNode(localId: br.convId, kind: br.convKind));
    }
    if (emitDiv) {
      for (final n in br.divIn) {
        edges.add(SfcEdge(fromLocalId: n, toLocalId: br.divId));
      }
      for (final n in br.divOut) {
        edges.add(SfcEdge(fromLocalId: br.divId, toLocalId: n));
      }
    }
    if (emitConv) {
      for (final n in br.convIn) {
        edges.add(SfcEdge(fromLocalId: n, toLocalId: br.convId));
      }
      for (final n in br.convOut) {
        edges.add(SfcEdge(fromLocalId: br.convId, toLocalId: n));
      }
    }
    final cause = branchDefect[br];
    if (cause != null) {
      warnings.add(ImportWarning(
          severity: WarningSeverity.info,
          message: '$ownerLabel: <Branch ID="${br.rawId}"> branch shape not '
              'representable ($cause) — the chart is not translated.'));
    }
  }
```

- [ ] **Step 8: Run the tests**

From `mobile/`:

```
/c/flutter/bin/flutter test test/import/l5x_parser_sfc_test.dart
```

Expected: PASS — `All tests passed!`

- [ ] **Step 9: Full suite + analyze**

From `mobile/`:

```
/c/flutter/bin/flutter test
/c/flutter/bin/flutter analyze
```

Expected: `All tests passed!` and `No issues found!`

- [ ] **Step 10: Commit**

```
git add -A && git commit -m "feat(l5x): synthesize SFC branch divergence/convergence connectors"
```

---

### Task 3: The never-silent surface — timing, action degrades, conformance, invariants, coupling guard

**Model:** sonnet · **Effort:** medium

*Rationale (matches spec §13):* the remaining behaviours are small, local and fully specified (two helper functions and a set of warning strings); the bulk of the task is writing the conformance and invariant suites, where completeness matters more than novel reasoning. The one subtle piece — the `sfc_translate.dart` statement-ordering dependency — is spelled out verbatim in §4 and §12.2 and comes with its own test.

Implements spec §4 (poison invariants), §5 (step timing), §6 (action degrades), §7 (full message-count regression), §8 (the conformance table), §12.2 (the coupling comment + its dialect-neutral guard).

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` — add `_l5xSfcTiming` and `_l5xSfcActions`; replace the inline action block in `_l5xSfcBody`'s `case 'Step':`.
- Modify: `mobile/lib/import/sfc_translate.dart` — **one comment line** above the step→step edge scan (line 47-49's comment block). No other change.
- Test: `mobile/test/import/l5x_parser_sfc_test.dart` (append groups).
- Test: `mobile/test/import/sfc_translate_test.dart` (append one test).

**Interfaces:**
- Produces (private to `l5x_parser.dart`):
  - `void _l5xSfcTiming(XmlElement step, String stepLabel, List<ImportWarning> warnings, String ownerLabel)`
  - `void _l5xSfcActions(XmlElement step, int stepLocalId, String stepLabel, List<SfcActionAssoc> out, List<ImportWarning> warnings, String ownerLabel)`
- `_l5xSfcBody`'s signature is **unchanged**. `translateSfcBody`'s signature, behaviour and output are **unchanged**.

- [ ] **Step 1: Write the failing tests (parser)**

Append to `mobile/test/import/l5x_parser_sfc_test.dart`, inside `void main() {`. Add this import at the top of the file:

```dart
import 'package:soft_plc_mobile/import/ir_to_project.dart';
```

```dart
  group('L5X SFC: step timing attributes (§5)', () {
    test('a zero or absent Preset is silent — Logix writes Preset="0" everywhere', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true" Preset="0"
              LimitHigh="0" LimitLow="0"/>
        <Step ID="2" Operand="Run"/>'''));
      expect(_hasInfo(ws, 'timing attribute'), isFalse, reason: _infos(ws).toString());
    });

    test('a meaningful Preset/LimitHigh/LimitLow each warn once, naming the step', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Step_003" InitialStep="true"
              Preset="5000" LimitHigh="9000" LimitLow="10"/>'''));

      final timing = _infos(ws).where((m) => m.contains('timing attribute')).toList();
      expect(timing, hasLength(3));
      expect(timing[0],
          'Routine "Main_Seq": SFC step "Step_003" timing attribute Preset '
          'dropped — no native step timer (use STEP_T in a transition condition).');
      expect(timing[1], contains('timing attribute LimitHigh'));
      expect(timing[2], contains('timing attribute LimitLow'));
      // Dropping timing NEVER stubs the chart.
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a *UsesExpr="true" companion makes the attribute meaningful even at 0', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S" InitialStep="true" Preset="0" PresetUsesExpr="true"/>'''));
      expect(_infos(ws).where((m) => m.contains('timing attribute')), hasLength(1));
    });
  });

  group('L5X SFC: action degrades (§6)', () {
    test('IsBoolean="true" skips the action with a `boolean action` breadcrumb', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="Motor" Qualifier="N" IsBoolean="true"/>
        </Step>'''));

      expect(body.actions, isEmpty);
      expect(_hasInfo(ws, 'boolean action'), isTrue, reason: _infos(ws).toString());
      expect(_hasInfo(ws, 'action has no body'), isFalse); // boolean check wins
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('an action with an absent or whitespace-only body is skipped, loudly', () {
      // Without this the assoc reaches _actionSt, whose `if (s.text.isNotEmpty)`
      // guard drops it WITHOUT a warning — the one silent-loss hole in the
      // action path, and one only the builder can close.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="Empty1" Qualifier="N"/>
          <Action ID="12" Operand="Empty2" Qualifier="N">
            <Body><STContent><Line Number="0"><![CDATA[   ]]></Line></STContent></Body>
          </Action>
        </Step>'''));

      expect(body.actions, isEmpty);
      final noBody = _infos(ws).where((m) => m.contains('action has no body')).toList();
      expect(noBody, hasLength(2));
      expect(noBody[0], contains('"Empty1"'));
      expect(noBody[1], contains('"Empty2"'));
      // A per-action degrade, NOT a poison: an empty action is a
      // documentation stub, not a structural defect.
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a non-N qualifier is NOT pre-filtered — the translator degrades it', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="A1" Qualifier="S">
            <Body><STContent><Line Number="0"><![CDATA[Motor := TRUE;]]></Line></STContent></Body>
          </Action>
        </Step>'''));

      expect(body.actions.single.qualifier, 'S'); // reaches the translator untouched
      expect(ws, isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.steps.single.actionSt, '');
      expect(
          tr.warnings.any((w) =>
              w.severity == WarningSeverity.info &&
              w.message.contains('unsupported — action skipped (N only)')),
          isTrue);
    });
  });

  group('L5X SFC: unmappable elements and the poison mechanism (§4)', () {
    for (final tag in const ['Stop', 'SbrRet', 'JSR', 'Frobnicate', 'Leg']) {
      test('<$tag> has no representable equivalent', () {
        final (body, ws) = _build(_wrap('''
          <Step ID="1" Operand="Idle" InitialStep="true"/>
          <$tag ID="9" X="0" Y="0"/>'''));

        expect(
            _infos(ws).any((m) =>
                m.contains('no representable equivalent') &&
                m.contains('<$tag ID="9">')),
            isTrue,
            reason: _infos(ws).toString());
        // Not emitted as a node — the poison flag is what makes it visible.
        expect(body.nodes.where((n) => n.name == '#unrepresentable'), hasLength(1));
        // Poison fires even though the element is on NO path at all.
        final tr = translateSfcBody(body, pouName: 'P');
        expect(tr.translated, isFalse);
        expect(tr.stubReason, 'complex-topology');
      });
    }

    test('a poisoned body produces exactly ONE warning and ZERO translator infos', () {
      // The mechanism's whole guarantee: _build's step->step edge scan sits
      // above every warning-emitting statement, so nothing else gets a word in.
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Idle"/>
        <Step ID="2" Operand="Run">
          <Action ID="21" Operand="A" Qualifier="S">
            <Body><STContent><Line Number="0"><![CDATA[X := 1;]]></Line></STContent></Body>
          </Action>
        </Step>
        <Stop ID="9"/>'''));

      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse);
      expect(tr.stubReason, 'complex-topology');
      expect(tr.warnings, hasLength(1));
      expect(tr.warnings.single.severity, WarningSeverity.warning);
      expect(tr.warnings.single.message,
          contains('step directly wired to step (missing transition)'));
    });

    test('many defects still produce exactly one poison node', () {
      final (body, _) = _build(_wrap('''
        <Stop ID="9"/>
        <SbrRet ID="8"/>
        <Step ID="abc" Operand="Bad"/>
        <Step ID="1" Operand="A" InitialStep="true"/>
        <Step ID="1" Operand="Dup"/>
        <DirectedLink FromID="1" ToID="777"/>'''));
      expect(body.nodes.where((n) => n.name == '#unrepresentable'), hasLength(1));
    });

    test('the L5X path never reaches the translator\'s PLCopen-only degrades', () {
      // §1: Logix has no external action/transition POUs and no graphically
      // wired condition, so these translator paths are dead for L5X input.
      // Kept in the translator (PLCopen needs them), asserted unreachable here.
      for (final fixture in [
        _wrap('''
          <Step ID="1" Operand="Idle" InitialStep="true">
            <Action ID="11" Operand="A" Qualifier="N">
              <Body><STContent><Line Number="0"><![CDATA[X := 1;]]></Line></STContent></Body>
            </Action>
          </Step>
          ${_t(2, 'T1', 'Go')}
          <Step ID="3" Operand="Run"/>
          <DirectedLink FromID="1" ToID="2"/>
          <DirectedLink FromID="2" ToID="3"/>'''),
      ]) {
        final (body, _) = _build(fixture);
        // Actions are associated by XML NESTING, so stepLocalId is always a
        // real step id — the "unknown step" degrade is structurally
        // unreachable.
        final stepIds = {
          for (final n in body.nodes)
            if (n.kind == SfcNodeKind.step) n.localId
        };
        expect(body.actions.every((a) => stepIds.contains(a.stepLocalId)), isTrue);
        final tr = translateSfcBody(body, pouName: 'P');
        for (final needle in const [
          'action associated with unknown step',
          'not resolvable to ST — skipped',
          'transition references',
          'graphical transition condition',
        ]) {
          expect(tr.warnings.any((w) => w.message.contains(needle)), isFalse,
              reason: needle);
        }
      }
    });
  });

  group('L5X SFC: annotations and empty content (§2, §8)', () {
    test('a link anchored to a <TextBox> is discarded — no warning, no poison', () {
      // Poisoning a chart because it is well commented would be absurd.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        ${_t(2, 'T1', 'Go')}
        <Step ID="3" Operand="Run"/>
        <TextBox ID="50" X="0" Y="0"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>
        <DirectedLink FromID="50" ToID="1"/>'''));

      expect(_hasInfo(ws, 'dangling link'), isFalse, reason: _infos(ws).toString());
      expect(body.nodes.where((n) => n.name == '#unrepresentable'), isEmpty);
      expect(body.edges, hasLength(2));
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('an EMPTY <SFCContent/> yields no-initial, not a topology defect', () {
      // Guards against a "when in doubt, poison" drift that would mislabel an
      // empty routine.
      final (body, ws) = _build(_wrap(''));
      expect(body.nodes, isEmpty);
      expect(ws, isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.stubReason, 'no-initial');
      expect(tr.warnings.single.message, contains('chart has no steps'));
    });
  });

  group('L5X SFC: §8 warning conformance', () {
    // Every builder-emitted row of §8's table, with its exact assertable
    // substring, reachable from a named fixture. Severity is `info` on ALL of
    // them: builder warnings are breadcrumbs, the verdict belongs to
    // translateSfcBody + the mapper.
    final cases = <(String, String, String)>[
      (
        'annotations',
        '<Step ID="1" Operand="A" InitialStep="true"/><TextBox ID="9"/>',
        'element(s) ignored'
      ),
      (
        'unknown element',
        '<Step ID="1" Operand="A" InitialStep="true"/><Stop ID="9"/>',
        'no representable equivalent'
      ),
      ('malformed id', '<Step ID="abc" Operand="A"/>', 'malformed ID'),
      (
        'duplicate id',
        '<Step ID="1" Operand="A"/><Step ID="1" Operand="B"/>',
        'duplicate ID'
      ),
      (
        'dangling link',
        '<Step ID="1" Operand="A"/><DirectedLink FromID="1" ToID="99"/>',
        'dangling link'
      ),
      (
        'branch type',
        '<Branch ID="10" BranchType="Parallel"><Leg ID="11"/></Branch>',
        'branch type'
      ),
      (
        'branch shape',
        '<Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>',
        'branch shape not representable ('
      ),
      (
        'timing attribute',
        '<Step ID="1" Operand="A" InitialStep="true" Preset="5000"/>',
        'timing attribute'
      ),
      (
        'boolean action',
        '<Step ID="1" Operand="A" InitialStep="true">'
            '<Action ID="11" Operand="M" IsBoolean="true"/></Step>',
        'boolean action'
      ),
      (
        'action has no body',
        '<Step ID="1" Operand="A" InitialStep="true">'
            '<Action ID="11" Operand="M"/></Step>',
        'action has no body'
      ),
    ];

    for (final (label, fixture, needle) in cases) {
      test('$label -> info "$needle", prefixed with the owner label', () {
        final (_, ws) = _build(_wrap(fixture));
        final hits = ws
            .where((w) => w.message.contains(needle))
            .toList();
        expect(hits, isNotEmpty, reason: _infos(ws).toString());
        expect(hits.every((w) => w.severity == WarningSeverity.info), isTrue);
        expect(hits.every((w) => w.message.startsWith('Routine "Main_Seq": ')),
            isTrue, reason: hits.map((w) => w.message).toString());
      });
    }
  });

  group('L5X SFC: the double-warning regression (§7)', () {
    // The bug this sub-project fixes: the old parser arm emitted its own
    // warning-severity message on TOP of the translator's and the mapper's —
    // three messages where the PLCopen path emits two.
    const translating = '''
      <Step ID="1" Operand="Idle" InitialStep="true"/>
      <Transition ID="2"><Condition><STContent>
        <Line Number="0"><![CDATA[Start]]></Line></STContent></Condition></Transition>
      <Step ID="3" Operand="Run"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="3"/>''';
    const stubbing = '''
      <Step ID="1" Operand="Idle" InitialStep="true"/>
      <Stop ID="9"/>''';

    List<ImportWarning> mapAndCollect(String sfcChildren) {
      final ir = parseL5x(_wrap(sfcChildren));
      final res =
          mapImportedProject(ir, projectName: ir.name, projectId: 'sfc_msg');
      return res.report.warnings
          .where((w) => w.message.contains('Main_Seq'))
          .toList();
    }

    test('parseL5x alone emits zero warning-severity messages for the POU', () {
      for (final f in [translating, stubbing]) {
        final ir = parseL5x(_wrap(f));
        expect(
            ir.warnings.where((w) =>
                w.severity == WarningSeverity.warning &&
                w.message.contains('Main_Seq')),
            isEmpty);
      }
    });

    test('a translating SFC routine produces zero warning-severity messages', () {
      expect(
          mapAndCollect(translating)
              .where((w) => w.severity == WarningSeverity.warning),
          isEmpty);
    });

    test('a stubbing SFC routine produces exactly two — translator + mapper', () {
      final loud = mapAndCollect(stubbing)
          .where((w) => w.severity == WarningSeverity.warning)
          .toList();
      expect(loud, hasLength(2), reason: loud.map((w) => w.message).toString());
      expect(loud.any((w) => w.message.contains('not translated (')), isTrue);
      expect(
          loud.any((w) => w.message.contains('graphical body not yet translated')),
          isTrue);
    });
  });
```

- [ ] **Step 2: Write the failing test (dialect-neutral translator invariant)**

Append to `mobile/test/import/sfc_translate_test.dart`, inside `void main() {`, after the last test:

```dart
  test('a step self-edge stubs complex-topology with exactly ONE warning and '
      'zero infos', () {
    // DIALECT-NEUTRAL INVARIANT, deliberately living here rather than in an
    // L5X test file: the property belongs to the translator. Import builders
    // (l5x_parser's SFC poison node) depend on the step->step edge scan
    // preceding every warning emission in _build — reorder _build and this
    // test fails in the file the reordering happened in.
    //
    // The body below WOULD emit two info warnings if the scan did not pre-empt
    // them: a non-N action (per-action degrade) and no step marked initial.
    final body = SfcBody(nodes: [
      _step(1, 'Idle'), // deliberately NOT initial
      _trans(2, SfcCondInline('Go')),
      _step(3, 'Run'),
      _step(-9, '#unrepresentable'), // the poison node's shape
    ], edges: [
      _e(1, 2), _e(2, 3), _e(-9, -9),
    ], actions: [
      SfcActionAssoc(
          stepLocalId: 1, qualifier: 'S', source: SfcActInline('Motor := TRUE;')),
    ]);

    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isFalse);
    expect(tr.stubReason, 'complex-topology');
    expect(tr.warnings, hasLength(1));
    expect(tr.warnings.single.severity, WarningSeverity.warning);
    expect(tr.warnings.single.message,
        contains('step directly wired to step (missing transition)'));
  });
```

- [ ] **Step 3: Run both test files to verify they fail**

From `mobile/`:

```
/c/flutter/bin/flutter test test/import/l5x_parser_sfc_test.dart test/import/sfc_translate_test.dart
```

Expected: FAIL on the parser file — no `timing attribute`, `boolean action` or `action has no body` warning exists yet, and the empty-body action still reaches `body.actions`. The **`sfc_translate_test.dart` addition should PASS immediately** — it is a guard on behaviour that already holds, and its value is that it fails loudly if `_build` is ever reordered. If it fails now, `_build`'s ordering is not what §4 assumes: stop and re-read `sfc_translate.dart:40-60` before writing any implementation.

- [ ] **Step 4: Add the two step helpers**

In `mobile/lib/import/l5x_parser.dart`, insert immediately **before** `_l5xSfcBody`:

```dart
/// §5 — one info breadcrumb per MEANINGFUL step timing attribute.
///
/// Logix steps carry `Preset`, `LimitHigh` and `LimitLow` (each with a
/// `*UsesExpr` companion): a step timer plus high/low residence limits.
/// `SfcStep` is `{id, name, isInitial, actionSt}` and `sfc_exec` has no
/// per-step timer, so these are not structurally representable and v1 drops
/// them — but never silently. The post-import recovery is `STEP_T` (elapsed
/// time in the active step), which `sfc_exec` injects as an ST variable usable
/// in a transition condition, so a dropped `Preset="5000"` is hand-recoverable
/// as `STEP_T >= 5000` on the step's outgoing transition.
///
/// The MEANINGFUL gate matters: Logix writes `Preset="0"` on every step in a
/// typical export, and warning on those would bury the real ones. A present
/// but non-numeric value counts as meaningful (it is most likely an inlined
/// expression, and dropping it silently would be the worst case).
void _l5xSfcTiming(XmlElement step, String stepLabel,
    List<ImportWarning> warnings, String ownerLabel) {
  for (final attr in const ['Preset', 'LimitHigh', 'LimitLow']) {
    final raw = (step.getAttribute(attr) ?? '').trim();
    final usesExpr = step.getAttribute('${attr}UsesExpr') == 'true';
    final n = num.tryParse(raw);
    final meaningful = usesExpr || (raw.isNotEmpty && (n == null || n != 0));
    if (!meaningful) continue;
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: SFC step "$stepLabel" timing attribute $attr '
            'dropped — no native step timer (use STEP_T in a transition '
            'condition).'));
  }
}

/// §6 — the [SfcActionAssoc]s for one `<Step>`.
///
/// Association comes from XML NESTING, not from a link (contrast PLCopen's
/// `<actionBlock>` + `connectionPointIn`), so `stepLocalId` is always a real
/// step id and the translator's "action associated with unknown step" degrade
/// is structurally unreachable on this path.
///
/// A `<Step>` with `<Action>` children emits one assoc each, in document order
/// (the order the translator concatenates them into `actionSt`); a `<Step>`
/// with none but a direct `<Body><STContent>` emits one implicit `N` action.
///
/// TWO PER-ACTION DEGRADES, both info + skip, never a poison — an unsupported
/// action must not cost the whole chart (north-star 1's action granularity):
///  * `IsBoolean="true"` names a BOOL Logix holds true while the step is
///    active and CLEARS on deactivation. `actionSt` runs only while the step
///    is active but nothing runs on deactivation, so `Op := TRUE;` would leave
///    the bit latched forever — wrong logic, not a degrade. Checked FIRST,
///    because a boolean action typically carries no `<Body>` at all.
///  * An empty/absent body would otherwise reach `_actionSt`, whose
///    `if (s.text.isNotEmpty)` guard drops it WITHOUT a warning — the one
///    silent-loss hole in the action path, and one only this builder can close
///    because only it knows the action existed.
///
/// Non-`N` qualifiers are deliberately NOT pre-filtered: they reach the
/// translator untouched and hit its existing per-action degrade, so the policy
/// and the message live in exactly one place.
void _l5xSfcActions(XmlElement step, int stepLocalId, String stepLabel,
    List<SfcActionAssoc> out, List<ImportWarning> warnings, String ownerLabel) {
  final actionEls = _children(step, 'Action').toList();
  if (actionEls.isEmpty) {
    final inline = _l5xSfcSt(step, 'Body');
    if (inline.isNotEmpty) {
      out.add(SfcActionAssoc(
          stepLocalId: stepLocalId,
          qualifier: 'N',
          source: SfcActInline(inline)));
    }
    return;
  }
  for (final a in actionEls) {
    final operand =
        (a.getAttribute('Operand') ?? a.getAttribute('Name') ?? '').trim();
    final label = operand.isEmpty ? '(unnamed)' : operand;
    if (a.getAttribute('IsBoolean') == 'true') {
      warnings.add(ImportWarning(
          severity: WarningSeverity.info,
          message: '$ownerLabel: SFC step "$stepLabel" boolean action "$label" '
              'skipped — a BOOL held true for the step\'s duration and cleared '
              'on deactivation has no native equivalent.'));
      continue;
    }
    final text = _l5xSfcSt(a, 'Body');
    if (text.isEmpty) {
      warnings.add(ImportWarning(
          severity: WarningSeverity.info,
          // Worded so the assertable substring `action has no body` appears
          // LITERALLY: the action name follows in parentheses rather than
          // splitting the phrase.
          message: '$ownerLabel: SFC step "$stepLabel": action has no body '
              '("$label") — skipped.'));
      continue;
    }
    final q = (a.getAttribute('Qualifier') ?? '').trim();
    out.add(SfcActionAssoc(
      stepLocalId: stepLocalId,
      qualifier: q.isEmpty ? 'N' : q,
      source: SfcActInline(text),
    ));
  }
}
```

- [ ] **Step 5: Wire them into the `<Step>` case**

In `_l5xSfcBody`'s `case 'Step':`, replace everything from `// Actions come from XML NESTING…` through the closing of the `else` block with:

```dart
            final stepLabel = name.isEmpty ? 's$localId' : name;
            _l5xSfcTiming(el, stepLabel, warnings, ownerLabel);
            _l5xSfcActions(el, localId, stepLabel, actions, warnings, ownerLabel);
```

so the case reads: build the `SfcNode`, record `kindById`, then the two helper calls, then `break;`.

- [ ] **Step 6: Add the coupling comment to `sfc_translate.dart`**

In `mobile/lib/import/sfc_translate.dart`, extend the comment block above the step→step edge scan (currently lines 47-49) to:

```dart
  // A direct step->step edge means a transition is missing from the source
  // — a structural error, not something we can represent faithfully as a
  // partial chart. Whole-POU stub rather than silently drop the path.
  //
  // Import builders (l5x_parser's SFC poison node) depend on this scan
  // preceding every warning emission below — see
  // docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md §4.
  for (final e in body.edges) {
```

**Nothing else in this file changes.** No statement moves, no signature changes, no output changes.

- [ ] **Step 7: Run the tests**

From `mobile/`:

```
/c/flutter/bin/flutter test test/import/l5x_parser_sfc_test.dart test/import/sfc_translate_test.dart
```

Expected: PASS — `All tests passed!`

- [ ] **Step 8: Full suite + analyze**

From `mobile/`:

```
/c/flutter/bin/flutter test
/c/flutter/bin/flutter analyze
```

Expected: `All tests passed!` and `No issues found!`. Confirm `git diff --stat mobile/lib/import/sfc_translate.dart` shows **only** added comment lines.

- [ ] **Step 9: Commit**

```
git add -A && git commit -m "feat(l5x): SFC timing/action degrades, poison invariants, single-warning path"
```

---

### Task 4: End-to-end proof and the backward-compatibility sweep

**Model:** sonnet · **Effort:** medium

*Rationale (deviates from spec §13's opus · medium, deliberately):* by this point the mechanism is built and unit-proven; the remaining work is composing one realistic document, reading the scan semantics off `sfc_exec.dart` (which the plan quotes below), and running the sweep. That is careful assembly, not novel reasoning. Escalate to opus only if the chart does not advance as traced and the cause is not obvious from the trace in Step 1.

Implements spec §9's e2e section and the backward-compatibility sweep.

**Files:**
- Test: `mobile/test/import/import_l5x_sfc_e2e_test.dart` (new file).

**Interfaces:**
- Consumes: `ImportedProject parseL5x(String xml)`; `mapImportedProject(ImportedProject ir, {required String projectName, required String projectId})` returning a result with `.project` (a `PlcProject`) and `.report` (`translatedSfcCount`, `stubbedSfcCount`, `sfcStubReasons`, `warnings`); `void executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt)`; `SfcRuntime()` with `active` (`Map<String, Set<String>>`); `writePath(PlcProject, String, dynamic)` / `readPath(PlcProject, String)` (`models/tag_resolver.dart`).
- Produces: no library code.

**Scan semantics this test relies on** (read off `models/sfc_exec.dart:44-125`, quoted so the assertions are not guesswork): each scan runs every active step's action first, then evaluates transitions against a **start-of-scan snapshot** of the active set; a step activated in scan N is therefore only eligible to leave in scan N+1. Alternative branches are **first-true-wins** in `prog.sfcTransitions` order (which is IR node order, i.e. document order). A `parallelFork` needs its single source active; a `parallelJoin` needs **every** source active.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/import/import_l5x_sfc_e2e_test.dart`:

```dart
// End-to-end proof: a handcrafted L5X SFC routine imports as a real, executing
// SequentialFunctionChart program. Exercises an initial step with an N action,
// a linear transition, a SELECTION branch whose legs select on a tag, and a
// SIMULTANEOUS fork/join. Pipeline: parseL5x -> mapImportedProject ->
// executeSfcPrograms. A second document proves the stub path and §7's message
// counts.
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

String _t(int id, String name, String cond) =>
    '<Transition ID="$id" Operand="$name"><Condition><STContent>'
    '<Line Number="0"><![CDATA[$cond]]></Line></STContent></Condition></Transition>';

String _act(int id, String name, String st) =>
    '<Action ID="$id" Operand="$name" Qualifier="N"><Body><STContent>'
    '<Line Number="0"><![CDATA[$st]]></Line></STContent></Body></Action>';

/// Idle -T2(Start)-> Charge -selection(ModeA | ModeB)-> PathA | PathB
///   -> Prep -T14(Go, fork)-> {Mix1, Mix2} -> {MixADone, MixBDone}
///   -T28(Go, join)-> Done
final String _kChartXml = '''
<?xml version="1.0" encoding="utf-8"?>
<RSLogix5000Content TargetType="Controller"><Controller Name="SfcE2E">
  <Tags>
    <Tag Name="Start" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="ModeA" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="ModeB" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Go" DataType="BOOL"><Data Format="Decorated"><DataValue Value="1"/></Data></Tag>
    <Tag Name="Ready" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Charging" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="A_On" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="B_On" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="M1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="M2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main"><Tags/><Routines>
    <Routine Name="Seq" Type="SFC"><SFCContent>
      <Step ID="1" X="0" Y="0" Operand="Idle" InitialStep="true" Preset="0">
        ${_act(101, 'SetReady', 'Ready := TRUE;')}
      </Step>
      ${_t(2, 'ToCharge', 'Start')}
      <Step ID="3" X="0" Y="80" Operand="Charge">
        ${_act(103, 'DoCharge', 'Charging := TRUE;')}
      </Step>
      <Branch ID="10" X="0" Y="120" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
      ${_t(4, 'PickA', 'ModeA')}
      <Step ID="5" X="-60" Y="200" Operand="PathA">
        ${_act(105, 'DoA', 'A_On := TRUE;')}
      </Step>
      ${_t(6, 'LegADone', 'Go')}
      ${_t(7, 'PickB', 'ModeB')}
      <Step ID="8" X="60" Y="200" Operand="PathB">
        ${_act(108, 'DoB', 'B_On := TRUE;')}
      </Step>
      ${_t(9, 'LegBDone', 'Go')}
      <Step ID="13" X="0" Y="320" Operand="Prep"/>
      ${_t(14, 'Fork', 'Go')}
      <Branch ID="20" X="0" Y="380" BranchType="Simultaneous"><Leg ID="21"/><Leg ID="22"/></Branch>
      <Step ID="22001" X="-60" Y="440" Operand="Mix1">
        ${_act(1220, 'DoM1', 'M1 := TRUE;')}
      </Step>
      ${_t(24, 'M1Done', 'Go')}
      <Step ID="25" X="-60" Y="520" Operand="MixADone"/>
      <Step ID="23001" X="60" Y="440" Operand="Mix2">
        ${_act(1230, 'DoM2', 'M2 := TRUE;')}
      </Step>
      ${_t(26, 'M2Done', 'Go')}
      <Step ID="27" X="60" Y="520" Operand="MixBDone"/>
      ${_t(28, 'Join', 'Go')}
      <Step ID="29" X="0" Y="600" Operand="Done"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="3"/>
      <DirectedLink FromID="3" ToID="10"/>
      <DirectedLink FromID="11" ToID="4"/>
      <DirectedLink FromID="4" ToID="5"/>
      <DirectedLink FromID="5" ToID="6"/>
      <DirectedLink FromID="6" ToID="11"/>
      <DirectedLink FromID="12" ToID="7"/>
      <DirectedLink FromID="7" ToID="8"/>
      <DirectedLink FromID="8" ToID="9"/>
      <DirectedLink FromID="9" ToID="12"/>
      <DirectedLink FromID="10" ToID="13"/>
      <DirectedLink FromID="13" ToID="14"/>
      <DirectedLink FromID="14" ToID="20"/>
      <DirectedLink FromID="21" ToID="22001"/>
      <DirectedLink FromID="22" ToID="23001"/>
      <DirectedLink FromID="22001" ToID="24"/>
      <DirectedLink FromID="24" ToID="25"/>
      <DirectedLink FromID="23001" ToID="26"/>
      <DirectedLink FromID="26" ToID="27"/>
      <DirectedLink FromID="25" ToID="21"/>
      <DirectedLink FromID="27" ToID="22"/>
      <DirectedLink FromID="20" ToID="28"/>
      <DirectedLink FromID="28" ToID="29"/>
    </SFCContent></Routine>
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''';

/// The same shape, cut down, with one `<Stop>` — the whole POU must stub.
const String _kStopXml = '''
<?xml version="1.0" encoding="utf-8"?>
<RSLogix5000Content TargetType="Controller"><Controller Name="SfcStop">
  <Tags><Tag Name="Start" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag></Tags>
  <Programs><Program Name="Main"><Tags/><Routines>
    <Routine Name="Seq" Type="SFC"><SFCContent>
      <Step ID="1" Operand="Idle" InitialStep="true"/>
      <Transition ID="2"><Condition><STContent>
        <Line Number="0"><![CDATA[Start]]></Line></STContent></Condition></Transition>
      <Step ID="3" Operand="Run"/>
      <Stop ID="4" X="0" Y="200" Operand="Halt"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="3"/>
      <DirectedLink FromID="3" ToID="4"/>
    </SFCContent></Routine>
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''';

void main() {
  test('an L5X SFC routine imports as an executing chart (selection + fork/join)', () {
    final ir = parseL5x(_kChartXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_sfc_e2e');
    final p = res.project;

    final chart = p.programs.firstWhere((pr) => pr.name == 'Main_Seq');
    expect(chart.language, 'SequentialFunctionChart');
    expect(
        chart.sfcSteps.map((s) => s.name),
        containsAll(<String>[
          'Idle', 'Charge', 'PathA', 'PathB', 'Prep',
          'Mix1', 'Mix2', 'MixADone', 'MixBDone', 'Done',
        ]));
    expect(chart.sfcSteps.firstWhere((s) => s.name == 'Idle').isInitial, isTrue);
    expect(chart.sfcTransitions.where((t) => t.kind == 'parallelFork'), hasLength(1));
    expect(chart.sfcTransitions.where((t) => t.kind == 'parallelJoin'), hasLength(1));
    expect(res.report.translatedSfcCount, 1);
    expect(res.report.stubbedSfcCount, 0);
    expect(res.report.sfcStubReasons, isEmpty);
    expect(
        res.report.warnings.where((w) =>
            w.severity == WarningSeverity.warning &&
            w.message.contains('Main_Seq')),
        isEmpty);

    String idOf(String name) =>
        chart.sfcSteps.firstWhere((s) => s.name == name).id;
    final rt = SfcRuntime();
    void tick() => executeSfcPrograms(p, 100, rt);
    Set<String> active() => rt.active['Main_Seq'] ?? <String>{};

    // `Go` is the always-true guard on the leg-closing / fork / join
    // transitions. Written explicitly rather than leaned on the imported
    // literal, so this test proves the CHART, not BOOL literal coercion.
    writePath(p, 'Go', true);

    // Scan 1: Idle is active, its action runs; Start is false -> no move.
    tick();
    expect(active(), {idOf('Idle')});
    expect(readPath(p, 'Ready'), true);

    // Scan 2: Start fires the linear transition.
    writePath(p, 'Start', true);
    tick();
    expect(active(), {idOf('Charge')});

    // Scan 3: Charge acts; the selection picks the leg whose condition is
    // true (first-true-wins over ModeA then ModeB).
    writePath(p, 'ModeA', true);
    tick();
    expect(readPath(p, 'Charging'), true);
    expect(active(), {idOf('PathA')});

    // Scan 4: PathA acts, then its leg-closing transition merges to Prep.
    tick();
    expect(readPath(p, 'A_On'), true);
    expect(readPath(p, 'B_On') == true, isFalse,
        reason: 'the unselected leg never ran');
    expect(active(), {idOf('Prep')});

    // Scan 5: the fork activates BOTH parallel steps at once.
    tick();
    expect(active(), {idOf('Mix1'), idOf('Mix2')});

    // Scan 6: both parallel actions run, both legs advance.
    tick();
    expect(readPath(p, 'M1'), true);
    expect(readPath(p, 'M2'), true);
    expect(active(), {idOf('MixADone'), idOf('MixBDone')});

    // Scan 7: the join waits for BOTH, then fires.
    tick();
    expect(active(), {idOf('Done')});
  });

  test('an SFC routine containing a <Stop> stubs the whole POU, with two messages', () {
    final ir = parseL5x(_kStopXml);
    expect(
        ir.warnings.where((w) => w.severity == WarningSeverity.warning),
        isEmpty,
        reason: 'the parser no longer pre-judges an SFC routine');

    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_sfc_stop');
    expect(res.report.translatedSfcCount, 0);
    expect(res.report.stubbedSfcCount, 1);
    expect(res.report.sfcStubReasons['complex-topology'], 1);

    final loud = res.report.warnings
        .where((w) =>
            w.severity == WarningSeverity.warning &&
            w.message.contains('Main_Seq'))
        .toList();
    expect(loud, hasLength(2), reason: loud.map((w) => w.message).toString());
    expect(loud.any((w) => w.message.contains('not translated (')), isTrue);
    expect(loud.any((w) => w.message.contains('graphical body not yet translated')),
        isTrue);

    final prog = res.project.programs.firstWhere((pr) => pr.name == 'Main_Seq');
    expect(prog.language, 'SequentialFunctionChart');
    expect(prog.sfcSteps, isEmpty);
  });
}
```

- [ ] **Step 2: Run the test**

From `mobile/`:

```
/c/flutter/bin/flutter test test/import/import_l5x_sfc_e2e_test.dart
```

Expected: PASS — `All tests passed!` (Tasks 1-3 have already built everything this exercises; this test is the composed proof, so it should go green on the first run. If a scan assertion fails, print `active()` per tick and compare against the trace in the "Scan semantics" note above before changing any fixture.)

- [ ] **Step 3: Backward-compatibility sweep**

From `mobile/`:

```
/c/flutter/bin/flutter test
/c/flutter/bin/flutter analyze
```

Expected: `All tests passed!` and `No issues found!`. Then confirm the source blast radius is exactly what the spec promised:

```
git diff --stat main -- mobile/lib/
```

Expected: `mobile/lib/import/l5x_parser.dart` (all behaviour) and `mobile/lib/import/sfc_translate.dart` (comment lines only). Nothing else under `mobile/lib/` may appear.

- [ ] **Step 4: Commit**

```
git add -A && git commit -m "test(l5x): end-to-end executing SFC chart from an L5X routine"
```

---

### Task 5: Docs and the knowledge base

**Model:** sonnet · **Effort:** medium

*Rationale (raised from spec §13's sonnet · low):* four files carry stale, load-bearing claims that this sub-project falsifies — including an explicit "verify SFC support against source before assuming otherwise" note in the knowledge base and a manifest `summary` that asserts the still-unshipped state. Getting every one of them, plus the AOI-restriction correction, is careful editing across files rather than boilerplate. Medium effort; no novel design.

Implements spec §10 and §11.

**Files:**
- Modify: `docs/import/L5X.md`
- Modify: `docs/DEFERRED.md`
- Modify: `docs/iec61131/SEQUENTIAL_FUNCTION_CHART.md`
- Modify: `knowledge/industry/plc-formats/rockwell-l5x.md`
- Modify: `knowledge/canonical-manifest.json`

**Interfaces:** none (documentation only). No Dart changes; the suite must stay green by construction.

- [ ] **Step 1: `docs/import/L5X.md` — the new "SFC routines translate" section**

Replace the **SFC routines** bullet under `## What's captured but not yet translated` (line 128-131) — the bullet is deleted from that section — and insert this new section immediately **before** `## What's captured but not yet translated`:

```markdown
## SFC routines translate

A `<Routine Type="SFC">`'s `<SFCContent>` parses into the neutral SFC IR and
runs through the **same** whole-POU translator PLCopen SFC input goes through
(`translateSfcBody`), producing a real, executing `SequentialFunctionChart`
program. Translation is **faithful-or-stub for the whole chart**: structure and
transition conditions either all resolve or the entire POU stays a stub (a
half-translated sequence executes wrong logic, which is worse than not
executing). Step **actions** degrade individually, so one unsupported action
never costs the chart.

| L5X source | Native mapping |
| --- | --- |
| `<Step Operand InitialStep X Y>` | `SfcStep` (name, `isInitial`, position) |
| `<Action Qualifier="N">` inside a `<Step>` | that step's `actionSt`, in document order |
| a `<Step>` with a direct `<Body><STContent>` and no `<Action>` | one implicit `N` action |
| `<Transition><Condition><STContent>` | `conditionSt` (a single trailing `;` is stripped) |
| `<Branch BranchType="Selection">` + `<Leg>`s | a divergence/convergence connector pair → multiple `single` transitions from one step (first-true-wins) |
| `<Branch BranchType="Simultaneous">` + `<Leg>`s | a divergence/convergence connector pair → `parallelFork` / `parallelJoin` |
| `<DirectedLink FromID ToID>` | a chart edge; a link naming a `<Leg>` resolves to that branch's divergence or convergence by direction |
| a loop-back link to an earlier element | an ordinary edge (Logix has no jump element) |
| `<TextBox>` / `<Attachment>` | dropped, counted, one info warning per routine |

**Nesting.** A branch whose leg contains a step which then opens a second
branch — the ordinary way real charts nest — translates. Only
*connector-adjacent* branches (a leg head or tail that is itself a `<Branch>`,
with no step or transition between the two connectors) are unrepresentable.

**Stubbed (whole POU)**, with the `sfcStubReasons` key: an unmappable element
(`<Stop>`, `<SbrRet>`, `<JSR>`, an unknown tag), a structurally broken branch
(unrecognized `BranchType`, a leg head or tail of the wrong kind, more than one
trunk in or out, a branch no link touches, connector-adjacent nesting), a
dangling `<DirectedLink>`, a malformed or duplicate element `ID`, or a
step wired directly to a step (`complex-topology`); a transition with no
condition (`unresolved-condition`); a chart with no steps (`no-initial`).
Every one of these also emits an info breadcrumb naming the offending element,
so the stub is never a mystery.

**Degraded (chart still translates)**, each with an info warning:
- **non-`N` action qualifiers** (`S`, `R`, `P`, `L`, `D`, `SD`, `DS`, `SL`) —
  the action is skipped.
- **`IsBoolean="true"` actions** — skipped. Logix holds the named BOOL true
  while the step is active and clears it on deactivation; the native action
  model has no deactivation hook, so assigning `TRUE` would leave the bit
  latched forever.
- **`<Action>` with an empty or absent body** — skipped.
- **step timing** (`Preset`, `LimitHigh`, `LimitLow`, and their `*UsesExpr`
  companions) — dropped, because `SfcStep` has no timer. Recover a dropped
  `Preset="5000"` by hand as `STEP_T >= 5000` on the step's outgoing
  transition; `STEP_T` (elapsed time in the active step, ms) is available in
  every transition condition. A `Preset="0"` — which Logix writes on nearly
  every step — is dropped silently, so the warnings you do see are the real
  ones.

Proven end-to-end (parse → map → translate → execute), including a selection
branch and a simultaneous fork/join, in
`mobile/test/import/import_l5x_sfc_e2e_test.dart`.
```

- [ ] **Step 2: `docs/import/L5X.md` — correct the SFC AOI bullet**

Replace the **SFC AOI logic** bullet (line 132-135) with:

```markdown
- **SFC AOI logic.** Studio 5000 does not permit SFC as an Add-On Instruction
  `Logic` language — AOIs accept Ladder, FBD or Structured Text only — so
  there is nothing to translate. The importer keeps a defensive
  interface-only path (parameters + local tags become a real `FbDefinition`,
  with an info warning naming the AOI) should such a file ever appear.
  (RLL and FBD AOI logic execute — see above.)
```

- [ ] **Step 3: `docs/import/L5X.md` — the Deferred list**

In `## Deferred (not in this release)`, delete the `- **L5X SFC routine translation** — sub-project 5. …` bullet (line 166-167) and add these bullets in its place:

```markdown
- **Real-corpus SFC validation** — the `<SFCContent>` schema this importer
  targets is asserted from Rockwell-format domain knowledge and pinned only by
  synthetic fixtures; no SFC-bearing `.L5X` exists in the local corpus. The
  highest-value follow-up.
- **`<Stop>` elements** — stub the POU today. Mapping one onto a terminal step
  needs a real export showing how Logix wires and resets it.
- **Step `Preset`/`LimitHigh`/`LimitLow`** — dropped with a warning;
  auto-synthesizing `STEP_T >= <preset>` would silently rewrite a transition
  the user did not author.
- **`IsBoolean` actions** — skipped; they need a set-on-activate /
  reset-on-deactivate action model `SfcStep` does not have.
- **Connector-adjacent / chained branches** — a leg head or tail that is itself
  a `<Branch>` stubs. (Step-separated nesting already translates.)
- **Recursive `<SFCContent>` walk** — a `<Branch>` nested *inside* a `<Leg>`
  element is unregistered, so a link naming it stubs the POU visibly.
```

- [ ] **Step 4: `docs/DEFERRED.md` — strike the shipped row, add the new ones**

In the `## L5X import (Rockwell Logix → app)` section, replace the row at line 126:

```markdown
| ~~L5X SFC routine translation~~ | ~~later~~ | **Shipped** (2026-08-07, L5X sub-project 5): a `<Routine Type="SFC">`'s `<SFCContent>` parses into the neutral `SfcBody` (`_l5xSfcBody` in `l5x_parser.dart`) — steps, nested `<Action>`s, inline transition conditions, annotations, and `<Branch>`/`<Leg>` synthesized into the IR's divergence/convergence connector pair from link topology — and translates through the existing shared `translateSfcBody` into a real, executing `SequentialFunctionChart` program, whole-POU faithful-or-stub. The parser's own "graphical body not yet translated" warning is **gone**: an L5X SFC routine now produces exactly the same message count as the PLCopen SFC path (zero when it translates, two when it stubs). Anything unmappable — `<Stop>`, an unknown element, a broken branch, a dangling link, a malformed/duplicate `ID` — routes through a poison node to a visible whole-POU stub rather than a silent drop, with no change to `sfc_translate.dart` beyond one coupling comment. Proven end-to-end in `mobile/test/import/import_l5x_sfc_e2e_test.dart`. **The L5X import program (ST, RLL, FBD, SFC) is now complete.** See `docs/import/L5X.md`'s "SFC routines translate". |
```

and append these rows to the same section's table:

```markdown
| **Real-corpus SFC validation** | **near-term** | The `<SFCContent>` schema `_l5xSfcBody` targets is asserted from Rockwell-format domain knowledge and pinned only by synthetic fixtures in `mobile/test/import/l5x_parser_sfc_test.dart` — this repo contains no SFC-bearing `.L5X` (no corpus file, no vendored schema manual). Acquire one Studio 5000 SFC export, add it to the local corpus, run `corpus_import_test.dart`, and reconcile the schema and the branch-synthesis rules against it. The single highest-value follow-up of this sub-project. |
| `<Stop>` element semantics (L5X SFC) | near-term | v1 poisons the POU (visible whole-POU stub + a `no representable equivalent` breadcrumb). A `<Stop>` maps plausibly onto a terminal step with no outgoing transition, which `sfc_exec` already parks on, but "plausibly" is not enough without a real export showing how Logix wires and resets it. If the corpus follow-up shows `<Stop>` is ubiquitous, this becomes urgent rather than a nicety. |
| Step `Preset`/`LimitHigh`/`LimitLow` (L5X SFC) | later | Dropped with an info warning naming the step and the attribute; `SfcStep` has no timer and `sfc_exec` no per-step preset. Hand-recoverable as `STEP_T >= <preset>` on the outgoing transition. Auto-synthesizing that condition would silently rewrite a transition the user did not author, and has no defined composition with an existing condition (`AND`? replace?), which needs a real corpus to decide. |
| `IsBoolean` SFC actions (L5X) | later | Skipped with an info warning. Logix holds the named BOOL true while the step is active and clears it on deactivation; `actionSt` runs only while the step is active and nothing runs on deactivation, so `Op := TRUE;` would leave the bit latched forever — wrong logic, not a degrade. Needs a set-on-activate / reset-on-deactivate action model `SfcStep` does not have. |
| Non-`N` SFC action qualifiers, L5X side | later | Rides the existing cross-dialect row in "FBD & SFC graphical translators": the builder deliberately does not pre-filter `S`/`R`/`P`/`L`/`D`/`SD`/`DS`/`SL`, so they reach `translateSfcBody`'s existing per-action degrade (skipped + one info warning). Listed here so the L5X matrix is self-contained. |
| SFC-bodied AOIs | later | Studio 5000 does not permit SFC as an AOI `Logic` language (Ladder / FBD / ST only), so there is nothing to translate. `_l5xAois`' `else` arm keeps a defensive interface-only path with an info warning should such a file ever appear. Revisit only if a real export contradicts the restriction. |
| Connector-adjacent / chained SFC branches (L5X) | later | Only *connector-adjacent* branches stub — a leg head or tail that is itself a `<Branch>`, giving a `div→div` / `conv→conv` / `div→conv` edge with nothing between. **Step-separated nesting already translates** and needs nothing. Chaining would need `upstreamSteps`/`downstreamSteps` to see through more than one connector, which is a `translateSfcBody` change and out of scope for a parser sub-project. |
| Recursive `<SFCContent>` walk | later | Pass 1 is flat: the direct children of each `<SFCContent>`, plus a `<Branch>`'s direct `<Leg>` children, and no further. A `<Branch>` nested *inside* a `<Leg>` element is therefore unregistered, so any link naming it becomes a `dangling link` and the POU stubs visibly. Make the walk recursive if a real export shows Logix nests that way. |
```

- [ ] **Step 5: `docs/iec61131/SEQUENTIAL_FUNCTION_CHART.md` — cover both dialects**

Retitle the import section and append an L5X subsection. Change the heading

```markdown
## SFC import (PLCopen → native SequentialFunctionChart)
```

to

```markdown
## SFC import (PLCopen and Rockwell L5X → native SequentialFunctionChart)
```

and change its first sentence's opening to name the shared translator:

```markdown
An imported SFC POU — from PLCopen TC6 **or** from a Rockwell L5X
`<Routine Type="SFC">` — translates as a whole through one shared translator:
the entire chart (steps, transitions, conditions, topology) becomes a native
chart, or the whole POU stays a stub (faithful-or-stub). An unrepresentable
step **action** degrades to a no-op with a warning (chart flow is preserved).
```

Then append at the end of the file:

```markdown
### L5X (`<SFCContent>`) specifics

The L5X dialect reaches the same translator through its own parser front-end
(`_l5xSfcBody` in `mobile/lib/import/l5x_parser.dart`). Two structural
contrasts with PLCopen drive everything else:

- **Actions nest inside their step** (`<Step><Action Qualifier="N">`), where
  PLCopen wires a sibling `<actionBlock>` to the step.
- **Links are a flat `<DirectedLink FromID ToID>` list**, where PLCopen carries
  each edge on the target element's `connectionPointIn`.

| L5X source | Native mapping |
| --- | --- |
| `<Step Operand InitialStep>` | `SfcStep` |
| `<Action Qualifier="N">` (nested) | that step's `actionSt`, in document order |
| `<Step>` with a direct `<Body><STContent>` and no `<Action>` | one implicit `N` action |
| `<Transition><Condition><STContent>` | `conditionSt` (one trailing `;` stripped) |
| `<Branch BranchType="Selection">` | `selDiv` + `selConv` pair → `single` transitions (first-true-wins) |
| `<Branch BranchType="Simultaneous">` | `simDiv` + `simConv` pair → `parallelFork` / `parallelJoin` |
| `<DirectedLink>` | a chart edge |
| loop-back link | an ordinary edge (Logix has no jump element) |

**Branch-pair synthesis.** L5X models a branch as one `<Branch>` element with
`<Leg>` children; the native model wants a *pair* of connector nodes. The
importer synthesizes that pair and derives its wiring from the links alone:
a link naming a `<Leg>` resolves by direction (out of a leg = the divergence
feeds that leg's head; into a leg = that leg's tail feeds the convergence),
and a link naming the `<Branch>` resolves by the other endpoint's kind
(selection diverges into transitions and converges out to a step; simultaneous
is the mirror). `BranchFlow` is read but not trusted — the links win, and a
contradiction is reported as an info warning. Step-separated nested branches
translate; only connector-adjacent ones (a leg head or tail that is itself a
branch) are unrepresentable.

**Step timing has no native equivalent.** Logix steps carry `Preset`,
`LimitHigh` and `LimitLow` (each with a `*UsesExpr` companion) — a step timer
plus high/low residence limits. `SfcStep` is `{id, name, isInitial, actionSt}`
and has no timer, so these are dropped with one info warning per meaningful
attribute (a `Preset="0"`, which Logix writes on nearly every step, is silent).

> **Recovering a dropped preset by hand.** `STEP_T` — elapsed time in the
> currently active step, in milliseconds — is injected into every transition
> condition. A step that carried `Preset="5000"` becomes faithful again by
> writing `STEP_T >= 5000` on its outgoing transition (or `AND`-ing it into an
> existing condition). The importer deliberately does not synthesize this: it
> would rewrite logic the user did not author.

**L5X-specific degrades**, each an info warning with the chart still
translating: `IsBoolean="true"` actions (no deactivation hook, so assigning
`TRUE` would latch the bit forever), `<Action>`s with an empty or absent body,
and non-`N` qualifiers (which ride the shared cross-dialect degrade).

Proven end-to-end for L5X in
`mobile/test/import/import_l5x_sfc_e2e_test.dart`.
```

- [ ] **Step 6: `knowledge/industry/plc-formats/rockwell-l5x.md` — front matter and the reader note**

**Plain hyphens only in this file — no em dashes** (`.git/sdd/kb-conventions.md:99`).

Replace the front-matter `summary:` value with:

```yaml
summary: Documents the Rockwell L5X (RSLogix5000Content) project-exchange schema's structure alongside this app's exact import support matrix - the RLL compile instruction set, real shipped AOI/RLL-Logic-AOI execution, real shipped FBD routine and FBD-Logic-AOI execution, real shipped SFC routine translation with its asserted-and-fixture-pinned <SFCContent> schema and branch-pair synthesis rule, a sheet-merge identity-collision import pitfall, and Rockwell FBD interop specifics (Operand/Function elements, SEL/CTUD name collisions, connector name reuse, OSRI/OSFI mapping).
```

and replace the **Read this before** note's last clause (which currently tells the reader SFC support has not shipped and to verify against source):

```markdown
> **Read this before:** importing a Studio 5000 L5X export, extending RLL, FBD or SFC
> translation, or checking which L5X body kinds execute for real (all four - ST, RLL, FBD and
> SFC - do, as of this version; §5's `<SFCContent>` structure is asserted from format knowledge
> and pinned by synthetic fixtures rather than by a real corpus export, so treat the SCHEMA, not
> the support status, as the thing to verify against a real file).
```

- [ ] **Step 7: `knowledge/industry/plc-formats/rockwell-l5x.md` — rewrite §5**

Retitle §5 and rewrite its headline plus the SFC paragraph and matrix. Replace the heading and the first paragraph:

```markdown
## 5. FBD and SFC both ship

**FBD routine, FBD-Logic AOI and SFC routine translation are all real and shipped, each reusing
the same translator PLCopen input goes through (see [plcopen-tc6-xml.md](./plcopen-tc6-xml.md)
§7). Every L5X body kind - ST, RLL, FBD, SFC - now produces real executing logic.**
```

Leave the FBD paragraphs, the CL-19 sheet-merge note and the CL-22 interop list unchanged. Replace the paragraph beginning "SFC stays unshipped, unchanged from before:" with:

```markdown
A `<Routine Type="SFC">`'s `<SFCContent>` parses into the neutral `SfcBody` IR (`_l5xSfcBody` in
`l5x_parser.dart`) and runs through the same `translateSfcBody` the PLCopen path uses, whole-POU
faithful-or-stub. Steps carry their nested `<Action Qualifier="N">` children (association is by XML
NESTING, not by a link - the opposite of PLCopen's sibling `<actionBlock>`), transitions carry an
inline ST `<Condition>`, and `<DirectedLink FromID ToID>` is a flat routine-wide edge list rather
than PLCopen's per-target `connectionPointIn`.

**Branch-pair synthesis is the crux.** L5X models a branch as ONE `<Branch BranchType>` element
carrying `<Leg>` children; the neutral IR, IEC 61131-3 and `sfc_exec` all model it as TWO connector
nodes, an opening divergence and a closing convergence. The importer therefore synthesizes the pair
and derives its wiring from link topology alone, through one unified endpoint rule with no mode
switch:

- a link naming a `<Leg>` resolves BY DIRECTION - out of a leg means the divergence feeds that
  leg's head, into a leg means that leg's tail feeds the convergence;
- a link naming the `<Branch>` resolves BY THE OTHER ENDPOINT'S KIND - selection diverges into
  TRANSITIONS and converges out to a STEP, simultaneous is the mirror, so the neighbour's kind
  alone says whether the link is a trunk role or a leg role.

The kind rule matters: the naive direction rule agrees on every trunk link but reads a leg-head
link expressed through the branch id as a convergence outlet, wiring conv -> T1, a silently wrong
chart that still passes every shape check. Emission is then a total function of four booleans (is
each of divIn/divOut/convIn/convOut non-empty): a side is emitted whenever either of its bits is
set, dropped when both are clear, and a side with exactly one bit set is a defect with its own
named cause. Every paired branch legitimately MIXES both link forms - trunk links must name the
`<Branch>` id while leg links name `<Leg>` ids - so a "mixed convention" rule would stub the common
case, which is why there is no such rule.

**Never silent.** Any unmappable element (`<Stop>`, `<SbrRet>`, `<JSR>`, an unknown tag), any
structurally broken branch, any dangling link and any malformed/duplicate `ID` sets a routine-level
flag that appends a POISON NODE - a step carrying a self-edge. `translateSfcBody`'s step-to-step
edge scan is unconditional over the edge list and sits above every warning-emitting statement, so a
poisoned body always stubs `complex-topology` with exactly one warning and no stray infos, with
ZERO changes to the translator (it carries one coupling comment naming the dependency, and a
dialect-neutral test in `sfc_translate_test.dart` fails if `_build` is ever reordered). A raw
`ID` is accepted only when non-negative and within range, which is what keeps a `<Step ID="-1">`
out of the same namespace as the synthetic negative ids branch connectors and the poison node draw
from - without that gate the step's id collides with the first branch's divergence and the chart
translates cleanly AS THE WRONG LOGIC with zero warnings, the same failure shape as CL-19 above.

> **ASSERTED, NOT CORPUS-VERIFIED.** The `<SFCContent>` element set and attribute names above are
> stated from Rockwell-format domain knowledge; this repo contains no SFC-bearing L5X (no corpus
> file, no vendored schema manual). They are pinned by synthetic, schema-faithful fixtures in
> `mobile/test/import/l5x_parser_sfc_test.dart`, exactly the precedent the FBD sub-project set for
> `<FBDContent>`. The branch rules above are written to absorb BOTH plausible encodings of
> `<Branch>` (paired element, or separate Diverge/Converge elements) without a mode switch, but a
> THIRD encoding would invalidate them. Acquiring one real SFC export and running it through
> `corpus_import_test.dart` is the tracked near-term follow-up (`docs/DEFERRED.md`).
```

and replace the support matrix's two SFC rows:

```markdown
| `SFC` routine | Real, whole-POU translate via the shared `translateSfcBody` (this section) |
| `SFC`-Logic AOI | Not possible in Studio 5000 (AOIs accept Ladder/FBD/ST only); defensive interface-only path kept |
```

Finally, update the closing line of §5 so it names both e2e proofs:

```markdown
Proven end-to-end (parse -> map -> translate -> execute) in
`mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart` (FBD routine + FBD-Logic AOI) and
`mobile/test/import/import_l5x_sfc_e2e_test.dart` (SFC routine, selection branch and
simultaneous fork/join).
```

- [ ] **Step 8: `knowledge/industry/plc-formats/rockwell-l5x.md` — the practical Q&A**

Replace the `### "My AOI's RLL logic runs, and now its FBD logic runs too - what about SFC?"` entry with:

```markdown
### "My AOI's RLL logic runs, and now its FBD logic runs too - what about SFC?"
SFC ROUTINES translate for real as of this version (§5) - the whole chart, including selection and
simultaneous branches, becomes an executing `SequentialFunctionChart` program, or the whole POU
stubs with a named reason. SFC-Logic AOIs are a different question and the answer is that they do
not exist: Studio 5000 does not permit SFC as an AOI `Logic` language (Ladder, FBD or ST only), so
the importer keeps only a defensive interface-only path for one.

### "My SFC routine imported as a stub - what did I do wrong?"
Probably nothing. SFC is whole-POU faithful-or-stub, so ONE unmappable thing takes down the chart:
a `<Stop>` element, a structurally broken branch, a dangling `<DirectedLink>`, a duplicate or
malformed element `ID`, or a transition with no condition. Every one of them also emits an
info-severity breadcrumb naming the offending element and id, so read the info warnings, not just
the two loud ones (§5).
```

- [ ] **Step 9: `knowledge/canonical-manifest.json` — sync the summary**

Update the `knowledge:industry/plc-formats/rockwell-l5x` entry's `"summary"` to the exact string written in Step 6 (the manifest summary must match the file's front-matter summary verbatim). Leave `topics`, `related`, `learnings` and `priority` unchanged unless the run produced a new learning id; the FBD run's `CL-17`/`CL-19`/`CL-22` still apply.

Then verify the manifest is still valid JSON and the two summaries agree:

```
cd "D:/Documents/Claude/Projects/Mobile Soft PLC" && node -e "const m=require('./knowledge/canonical-manifest.json');const e=m.entries.find(x=>x.id==='knowledge:industry/plc-formats/rockwell-l5x');console.log(e.summary)"
```

Expected: prints the new summary. (If `entries` is not the array key, read the file's top-level shape first and adjust the expression — the check is the point, not the exact accessor.)

- [ ] **Step 10: Sweep for other stale SFC claims**

```
cd "D:/Documents/Claude/Projects/Mobile Soft PLC" && grep -rn -i "sfc" knowledge/industry/plc-formats/index.md knowledge/industry/iec61131/sequential-function-chart.md docs/import/plcopen.md
```

Any sentence asserting L5X SFC is unshipped must be corrected in the same commit. If `knowledge/industry/iec61131/sequential-function-chart.md` describes SFC import as PLCopen-only, widen it to name both dialects and cross-link `rockwell-l5x.md` §5 (plain hyphens, no em dashes).

- [ ] **Step 11: Verify nothing else moved**

From `mobile/`:

```
/c/flutter/bin/flutter test
/c/flutter/bin/flutter analyze
```

Expected: `All tests passed!` and `No issues found!` (documentation-only task, so this is a regression check on the previous four commits).

- [ ] **Step 12: Commit**

```
git add -A && git commit -m "docs: L5X SFC routine translation ships"
```

---

## Done means

- `<Routine Type="SFC">` translates into an executing `SequentialFunctionChart` program, proven by `mobile/test/import/import_l5x_sfc_e2e_test.dart` running scan ticks through a selection branch and a simultaneous fork/join.
- Anything unmappable stubs the whole POU **visibly** — never a dropped node or edge — through the poison node, with `sfcStubReasons['complex-topology']` and an info breadcrumb naming the element.
- An L5X SFC routine produces exactly the PLCopen path's message count: zero warning-severity messages when it translates, two when it stubs.
- `mobile/lib/` changes are confined to `l5x_parser.dart` plus one comment block in `sfc_translate.dart`.
- Every §8 severity/substring, all 15 §8 branch cause clauses (11 live, 4 asserted-absent as defence in depth), and every §9 test case has a named test.
- `flutter test` and `flutter analyze` are green, and every pre-existing PLCopen SFC, L5X and corpus test is byte-identical in outcome.
