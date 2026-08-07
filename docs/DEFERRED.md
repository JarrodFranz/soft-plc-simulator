# Deferred Work Registry

The single, canonical list of work that was **consciously deferred** — scoped
out of a shipped feature on purpose, not forgotten and not a bug. Every spec and
plan that defers something records it here (and links back here from its own
"Deferred / out of scope" section) so nothing is silently lost.

**How to use this file**
- When a design/spec/plan defers an item, add a row to the relevant section
  below with a one-line description and its source (PR / spec / ledger).
- Reference this file from the spec/plan's own deferred section instead of
  re-listing items in prose ("Deferred items are tracked in `docs/DEFERRED.md`").
- When a deferred item is picked up and shipped, **strike it through** and note
  the PR that closed it (keep it for history), or move it to the "Shipped
  follow-ups" section at the bottom.
- `near-term` = the intended next expansion; `later` = someday/maybe.

---

## FBD editor overhaul (spec 2026-07-23)

| Item | Priority | Notes |
|---|---|---|
| EN/ENO chaining | later | Enable/enable-out gating on blocks (IEC execution-control) — not needed for network ordering. |
| Jumps / returns / labels | later | The PDF's execution-control elements; networks already deliver the ordering the user asked for. |
| ~~Custom / user function blocks in FBD~~ | ~~later~~ | **Shipped** (2026-07-23, custom-function-blocks feature): FB definitions appear in the FBD palette and execute via the `fbDefinitionFor` registry fallback in `fbd_pins.dart`/`fbd_exec.dart`. See `docs/iec61131/FUNCTION_BLOCKS.md` and the "Custom (user-defined) function blocks" section below (import mapping from PLCopen remains deferred there). |
| Cross-network wiring | later | By design wires are intra-network; cross-network data flows through tags. |

**Minor code-quality follow-ups (from the whole-branch review, non-blocking):**
- Add direct unit tests for the constructor-level `fbdNetworks` normalization + the no-over-extension invariant (currently only indirectly covered).
- `executeFbdPrograms` re-scans blocks/wires per network (O(networks×wires)) — could pre-bucket once; negligible today.
- The desktop palette dock / phone add-block FAB add blocks into network 0 (no "active lane" cue); per-lane add-block is the primary path.
- `_resolvedWireFromPin` in the editor hand-mirrors `fbd_exec`'s private `_resolvedFromPin` — promote the exec helpers to public and share, to remove drift risk.

## Custom (user-defined) function blocks (spec 2026-07-23)

| Item | Priority | Notes |
|---|---|---|
| ~~Import mapping → FB defs/instances~~ | ~~near-term~~ | **Shipped** (2026-07-25, `feat/import-fb-mapping`): PLCopen `functionBlock` POUs (ST body only) now map to `FbDefinition`s; LD custom-FB call blocks route to FB instances (pin bindings + backing instance tag), proven end-to-end (parse → map → translate → execute) in `mobile/test/import/import_fb_e2e_test.dart`. FBD custom-FB call routing remains deferred (row below) until the FBD import translator exists. |
| FB call gated by a preceding series contact | later | The LD custom-FB call translator (`_buildFbCallNode`) only handles a bare FB block wired directly off a rail (or as the sole element on its rung) — a call preceded by a series contact on the same rung has not been proven and may stub or mistranslate the power-gating. Power-gating of imported FB calls is unverified/deferred. |
| ~~FBD custom-FB call routing~~ | ~~near-term~~ | **Shipped** (2026-07-26, FBD import translator feature): an FBD `<block>` whose `typeName` is a registered custom FB routes to a real instance (pin bindings + struct-typed instance tag) the same way the LD translator does, proven end-to-end in `mobile/test/import/import_fbd_e2e_test.dart`. |
| ~~Graphical-bodied FBs (LD/FBD body)~~ | ~~later~~ | **Shipped** (LD 2026-08-04, L5X sub-project 3; FBD 2026-08-07, L5X sub-project 4): an imported AOI's ladder or FBD `Logic` routine compiles into `FbDefinition.ladderRungs` / `fbdBlocks`+`fbdWires`+`fbdNetworks` and executes per instance via the scoped ladder/FBD executors (`executeFbInstance`'s three-way precedence). Proven end-to-end in `mobile/test/import/import_l5x_aoi_ladder_e2e_test.dart` and `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart`. Still true: a **PLCopen** FBD `functionBlock` POU is still skipped with the "graphical body — not imported" warning (`mapImportedFbs`'s deliberate `ImportDialect.l5x` gate, pending PLCopen-specific validation — see the row below in "L5X import"). |
| FB calling another FB (nesting/recursion) | later | The app's ST subset has no FB-call syntax, so v1 FB bodies can't instantiate other FBs. |
| FB body ST beyond the app's ST subset | later | An imported FB whose ST exceeds IF/ELSIF/ELSE + assignments is handled as ST programs are today (partial). |
| IEC *functions* (stateless POUs) | later | v1 is function *blocks* (stateful instances); stateless FUNs are a separate POU kind. |
| Imported `VAR_IN_OUT` mapped to input | later | `mapImportedFbs` maps an FB's `VAR_IN_OUT` vars to `FbVarDir.input` (by-reference IEC semantics aren't representable in the app's by-value FB model) and emits an info warning naming the var; the FB still imports rather than being skipped. |
| Boolean-literal FB input pin binding | later | `ld_exec.dart`'s custom-FB block resolves a literal `pinBindings` value via `num.tryParse` only (tag lookup first, else numeric literal). A BOOL-typed FB input bound to a literal `TRUE`/`FALSE` (e.g. from imported LD) resolves to null and leaves the instance field at its prior value. Consistent with `_operandValue`'s pre-existing numeric-only literal handling; add boolean-literal parsing when a case appears. (IMPORT-FB Task 4 review.) |
| Imported FB output wired directly to a coil | later | The LD import translator folds an FB output only when it feeds an `<outVariable>`; an FB boolean output wired DIRECTLY to a coil leaves the FB→coil edge as a power wire AND binds the coil tag in `pinBindings`. At scan the coil is then driven by rung power (FB is power-transparent) while the pinBinding write sets it to `FB.Out` — same tag, possibly different value (last-write-wins). Rare wiring; not in any corpus. Fold FB→coil the same as FB→outVariable when a case appears. (IMPORT-FB whole-branch review.) |
| ~~`<expression>`-dialect FB call operands~~ | ~~later~~ | **Shipped** (2026-07-26, FBD import translator feature): `plcopen_parser` now reads a graph node's operand from a descendant `<expression>` element as a fallback when no `<variable>` element is present (identifier or literal only), so an `<inVariable>`/`<outVariable>` bound via `<expression>` resolves instead of stubbing. Proven in `mobile/test/import/import_fbd_e2e_test.dart`. (IMPORT-FB whole-branch review.) |
| Dotted read into a struct-typed local FB var | later | `StScope.readVars` only keys bare top-level var names, and `st_expr` lexes `SubVar.Field` as one dotted identifier → a body read of `SubVar.Field` (SubVar a local struct-typed var) misses the scope and falls through to a global. No current FB has struct-typed locals; revisit if Tasks 4-5 introduce them. (CFBX Task 3 review.) |
| FB interface-var rename does not propagate to pin refs | later | Renaming an `FbVar` (interface var) in the FB editor does not propagate to already-set `LdNode.pinBindings` keys or FBD wire pin references for placed instances of that FB — the FB continues to resolve (name-keyed), but existing pin bindings keyed to the old var name go stale. Consistent with the existing (also non-propagating) behavior of struct-field renames in `memory_manager_screen.dart`'s `_showEditStructDialog`, which likewise never updates any binding/reference that named the old field. `renameFbDefinition` (Task 6 fix pass, `tag_resolver.dart`) DOES propagate an FB *definition* rename (name itself) everywhere, since that mirrors `renameStructDef`'s existing propagation contract — only the var-level rename is deferred. |
| `executeFbInstance`'s "fallback unreachable in the scan" guarantee has no structural guard test | later | `fb_exec.dart`'s doc comment asserts the ephemeral `LdExecRuntime()` fallback (used when a caller omits `ldRt`) never actually fires during a real scan, because `runScanTick` is the sole `lib/` caller of `executeFbdPrograms`, which always supplies its real `LdExecRuntime`. That invariant is not enforced by any test — a future direct/ad-hoc caller of `executeFbdPrograms` (or a second `runScanTick`-like entry point) could silently reintroduce the fallback path with degraded edge detection and nothing would fail. (L5X AOI ladder sub-project, Task 4 review.) |

## LD graphical translator (PR #4)

| Item | Priority | Notes |
|---|---|---|
| Custom / user function blocks | **near-term** | Rungs with unsupported/custom block `typeName`s stub; the translator records them in `ImportReport.unsupportedLdBlockTypes` as a data-driven backlog. The intended next unlock so real exports translate. |
| Branch topology beyond single-level parallel | near-term | Bridge/nested/non-series-parallel rungs faithfully stub today; richer topology support would raise the translate rate. |
| Full counter power pins (CD / R / LD) | near-term | The app's LD block model has one power input; a counter wiring CD/R/LD stubs rather than mistranslating. |
| Global-var rename → LD reference propagation (F2) | later | If a global var is renamed on import (sanitize collision or reserved `System`), contact/coil/operand refs in translated rungs keep the old name. Uncommon trigger. |
| Rail-fed-both-primary-and-reset counter residual | later | `segmentRungs` drops rail-edge `toPin`; a counter rail-wired to both its primary and reset pin (pathological, not in any corpus) slips the power-pin guard. |
| Coil modifier-combo vs storage precedence (T3) | later | A coil with negated+edge+storage stubs rather than mapping to set/reset. Safe (stub, not wrong-logic). |
| `parseIecDuration` float ms-accumulation (T1) | later | Cosmetic; `.round()` absorbs any epsilon. |

## FBD & SFC graphical translators (graphical-translators program)

| Item | Priority | Notes |
|---|---|---|
| ~~FBD import translator~~ | ~~near-term~~ | **Shipped** (2026-07-26, FBD import translator feature): sub-project 2 of 3; imported FBD POUs translate per-network (weakly-connected component, faithful-or-stub) into real, executing `FunctionBlockDiagram` programs, including custom-FB call routing. Proven end-to-end in `mobile/test/import/import_fbd_e2e_test.dart`. See `docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md`'s "FBD import" section for the support matrix. |
| ~~SFC import translator~~ | ~~later~~ | **Shipped** (2026-07-26, SFC import translator feature): sub-project 3 of 3; imported SFC POUs translate as a whole chart (steps, transitions, conditions, topology — including selection/simultaneous divergence-convergence and jump steps) into real, executing `SequentialFunctionChart` programs (faithful-or-stub). Proven end-to-end in `mobile/test/import/import_sfc_e2e_test.dart`. See `docs/iec61131/SEQUENTIAL_FUNCTION_CHART.md`'s "SFC import" section for the support matrix. **The graphical-translators program (LD/FBD/SFC) is now complete.** |
| SFC action qualifiers S/R/P/L/D/SD/DS/SL | later | Only the `N` (non-stored) action qualifier translates to `actionSt`; stored/pulse/timed qualifiers (S, R, P, L, D, SD, DS, SL) have no native equivalent in the app's action model and degrade to a no-op with a warning. |
| Graphical (LD/FBD) SFC transition/action bodies | later | A transition condition or step action whose body is an LD or FBD network (rather than ST) has no translation path; conditions referencing one stub the POU (`unresolved-condition`), actions referencing one degrade to a no-op. |
| Wired SFC transition conditions | later | A transition condition wired from a boolean signal on the diagram (rather than inline/referenced ST) stubs the whole POU (`wired-condition`); no native equivalent for a graphically-wired condition input. |
| SFC action/transition definitions as standalone external POUs | later | Only actions/transitions declared in-POU (`<actions>`/`<transitions>`) and referenced via `<reference name=".."/>` resolve; a reference to an action or transition defined as its own separate top-level POU is not resolved. |
| Negated FBD pins (NOT-block insertion) | later | A negated input/output pin on an FBD wire has no native equivalent block-side; the translator flags it (`negated-pin`) and stubs the whole network rather than synthesizing an inserted `NOT` block. |
| `inOutVariable` | later | FBD's by-reference in/out pin variable has no native equivalent in the app's by-value block model; a network containing one stubs (`unsupported-element`). |
| `connector`/`continuation` cross-references | later | Off-page/off-network wire continuations (PLCopen `connector`/`continuation` elements) have no native model; a network containing one stubs (`unsupported-element`). |
| `label`/`jump` execution control | later | FBD is dataflow-only in the app (no jump/label execution control); a network containing one stubs (`unsupported-element`). |
| Compound-expression operands | later | The parser's `<expression>` fallback only resolves a bare identifier or literal; a compound expression (e.g. `A+B`, `NOT X`) stubs the network (`complex-expression`). A small expression→block compiler would translate these instead of stubbing. |

## PLCopen-XML import (PRs #2 / #3)

| Item | Priority | Notes |
|---|---|---|
| Import-fidelity warnings | near-term | Bundle: unknown type → `INT16` silently (N2); multidimensional arrays collapse to first dimension (N3); case-insensitive DUT-name match (T2a); duplicate DUT names collapse silently (T4b); a DUT named `TIMER`/`COUNTER`/`SYSTEM` shadows a builtin (T4c). |
| POU local variables not surfaced | later | `ImportedPou.localVars` are captured in the IR but the mapper only creates timer/counter instance tags, not general locals. |
| ~~Other vendor dialects (Rockwell L5X, Siemens TIA)~~ | ~~later~~ | **Rockwell L5X shipped** (2026-07-26, L5X import foundation — see "L5X import" section below); Siemens TIA (and Beckhoff TwinCAT, CODESYS native) remain unsupported — only PLCopen TC6 and Rockwell L5X are autodetected today. |
| Merge-into-existing-project import | later | Import always creates a NEW project; no merge mode. |
| Export to PLCopen XML | later | Import-only today; no export path. |
| `detectDialect` tightening | later | Matches on the `plcopen`/`tc6` substring in the first 4 KB; a mis-detect self-corrects to a clear FormatException. |

## L5X import (Rockwell Logix → app)

Foundation delivered (2026-07-26, L5X import foundation program): user
DataTypes → structs, AOIs → function blocks (interface + ST logic), controller
+ program tags → tags (flat namespace, scalar values incl. Hex/Binary/Octal
radices), ST routines → ST programs. Proven end-to-end against real Rockwell
exports in `mobile/test/import/import_l5x_e2e_test.dart` (an AOI-typed tag
resolves to its composite/FbDefinition type; an ST-bodied AOI's logic
imports). RLL (ladder) routine translation shipped separately (2026-07-27,
L5X RLL ladder compiler program; see the row below). RLL-bodied AOI logic
shipped on top of that (2026-08-04, L5X sub-project 3 — see the rows below).
See `docs/import/L5X.md` for the full support matrix.

| Item | Priority | Notes |
|---|---|---|
| ~~RLL (ladder) routine translation~~ | ~~near-term~~ | **Shipped** (2026-07-27, L5X RLL ladder compiler): sub-project 2 of 5; imported RLL routines compile per-rung into real, executing `LadderLogic` programs — contacts (`XIC`/`XIO`/`ONS`), coils (`OTE`/`OTL`/`OTU`), compares, math, `MOV`, `TON`/`TOF` timers, `CTU`/`CTD`/`CTUD` counters (preset best-effort), strict AOI-call routing, and single-level `[…]` branches — faithful-or-stub. Proven end-to-end in `mobile/test/import/import_l5x_rll_e2e_test.dart` (handcrafted `XIC`/`OTE` proof + a real-corpus smoke test over `logixlibraries_Numeric_Program.L5X`). See `docs/import/L5X.md`'s "RLL (ladder) compile" section for the full support matrix. |
| ~~Non-ST AOI logic translation (RLL half)~~ | ~~later~~ | **Shipped** (2026-08-04, L5X sub-project 3): an AOI whose `Logic` routine is RLL imports as a **ladder-bodied** `FbDefinition` (`FbDefinition.ladderRungs`) and executes per instance via the scoped ladder executor (`LdScope` + `runScopedLdBody`, `'fb:<instance>'` runtime keys). `EnableIn`/`EnableOut` are retained as internal vars for RLL-logic AOIs. Proven end-to-end in `mobile/test/import/import_l5x_aoi_ladder_e2e_test.dart`. See `docs/import/L5X.md`'s "RLL-Logic AOIs execute" and `docs/iec61131/FUNCTION_BLOCKS.md`'s "Ladder-bodied FBs". |
| ~~FBD-bodied AOI logic~~ | ~~later~~ | **Shipped** (2026-08-07, L5X sub-project 4): an AOI whose `Logic` routine is FBD imports as an **FBD-bodied** `FbDefinition` (`FbDefinition.fbdBlocks`/`fbdWires`/`fbdNetworks`) compiled at import by `translateFbdBody`, and executes per instance via the scoped FBD executor (`runScopedFbdBody` + `LdScope`, `'fb:<instancePath>|<blockId>'` runtime keys). `EnableIn`/`EnableOut` are retained as internal vars for FBD-logic AOIs. Proven end-to-end in `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart`. |
| AOI auxiliary routines (`Prescan`/`Postscan`/`EnableInFalse`) | later | Only the main `Logic` routine is imported and executed; Rockwell's scan-phase routines have no equivalent in the app's scan model. |
| AOI-in-AOI forward references | later | The FB registry grows in document order, so an AOI ladder calling an AOI defined **later** in the file stubs that rung (unknown mnemonic, inventoried). Rockwell exports list dependencies first, so this is rare. |
| FB editor support for ladder bodies | later | A ladder-bodied `FbDefinition` shows its (empty) ST source in the FB editor; there is no view/edit UI for `ladderRungs`. Import is the only producer today. Consequence while that holds: **deleting or renaming an FB var silently reroutes that name's ladder-body references** — `LdScope` only rewrites paths whose root segment is a current var name, so a body reference to a removed/renamed var falls through to a same-named GLOBAL tag (or to nothing) instead of erroring. Renaming an FB *definition* is handled (`renameFbDefinition` traverses ladder bodies); renaming an FB *var* is not. |
| Integer truncation on dotted/scoped math destinations | later | An LD math/MOVE block truncates its result only when the DESTINATION's ROOT tag is an integer type; a dotted destination (`Struct.Member`, and an FB-scoped `A1.Var`) stores the raw double. Pre-existing behaviour, unchanged by the scoped executor. |
| ~~L5X FBD routine translation~~ | ~~later~~ | **Shipped** (2026-08-07, L5X sub-project 4): a `<Routine Type="FBD">`'s `<FBDContent><Sheet>` parses into the neutral `GraphBody` (multi-sheet merge, `ICon`/`OCon` connector resolution, Rockwell type + pin aliasing) and translates through the existing `translateFbdBody` into a real, executing `FunctionBlockDiagram` program, faithful-or-stub per network. See `docs/import/L5X.md`'s "FBD routines translate". |
| AB FBD block synthesis | later | `SCL`, `PIDE`, `MOV`, `MOD`, `ESEL` and other unmapped Rockwell FBD blocks stub their network and are inventoried in `unsupportedFbdBlockTypes`; no synthesis onto native equivalents (e.g. `MOV` as a pass-through wire, `PIDE` -> `PID`). |
| `TONR`/`TOFR` fidelity | later | Mapped best-effort to `TON`/`TOF` with a prominent verify warning; retentive accumulation and the `Reset` pin are not modeled (a wired `Reset` stubs that network). `abOriginal` survives only in the IR and the warning; there is no native field to carry it. |
| `<TextBox>`/`<Attachment>` FBD annotations | later | Dropped at parse (counted in one info warning per routine), not imported as documentation. |
| `EnableIn`/`EnableOut` pass-through on wired FBD pins | later | A *wired* `EnableIn`/`EnableOut` pin on a Rockwell block (built-in-aliased or an AOI call) stubs its network (`unresolved-pin`) plus an info heads-up warning; no IEC-side enable/condition semantics are synthesized. The unwired case (the common one) is unaffected. |
| FB editor support for FBD bodies | later | An FBD-bodied `FbDefinition` shows its (empty) ST source; there is no view/edit UI for `fbdBlocks`. Same consequence as the ladder-body row: renaming or deleting an FB var silently reroutes body references. |
| FB-body online monitoring | later | Scoped ladder and FBD bodies pass `monitor: null`, so imported AOI bodies have no live pin/element values. |
| PLCopen FBD-bodied `functionBlock` POUs | later | The executor supports them; only the `ImportedProject.dialect` gate withholds them, pending PLCopen-specific validation. They keep the existing "graphical body - not imported" warning. |
| Dotted/member operands in FBD refs | later | An `IRef`/`ORef` naming `Timer1.DN` stubs (`complex-expression`), shared with the PLCopen FBD translator's `_isIdentifier` limit. |
| Backing-tag fidelity for FBD `Block` elements | later | A `<Block Type="TONR" Operand="T1">`'s state lives in the translator-managed `FbdRuntime`, not in the `T1` TIMER tag. |
| Nested-FB instance defaults use a `structDefs: []` scratch project (FBD) | later | `fbd_translate.dart`'s two scratch-`PlcProject` sites (building an FB-aware project so `fbdInputPinsFor`/`fbdOutputPinsFor` and `defaultValueFor` can resolve custom-FB pin names and instance-tag defaults, ~line 94-97 and ~line 317-319) both pass `structDefs: []`. A nested FB var whose type is a DUT (struct) therefore gets an incomplete default when its instance tag is expanded — `defaultValueFor` -> `lookupComposite` -> `fbDefinitionFor` can resolve FB-typed members but not struct-typed ones, since the struct registry is empty. Pre-existing; identical on the shipped PLCopen FBD-import path (not new to L5X FBD import). |
| L5X SFC routine translation | later | Sub-project 5: mirrors the PLCopen `sfc_translate.dart` translator for L5X SFC routines. |
| Full 1:1 `ICon`/`OCon` pairing (FBD) | later | Connector matching is name-based and ROUTINE-wide (`_resolveL5xFbdConnectors` in `l5x_parser.dart`), which is what Logix itself guarantees — connector names are unique within a routine. A malformed export that REUSES one name for two independent producer/consumer pairs therefore cross-products: every producer splices onto every consumer of that name. The degradation is deterministic and visible, not silent — the fused component's duplicate wires claim the same input slot and stub on the translator's `unresolved-pin` gate (pinned by a test in `l5x_parser_fbd_test.dart`). Deferred: pairing producers to consumers 1:1 (by sheet proximity or declaration order) so a name-reusing export translates instead of stubbing. |
| BIT-overlay member aliasing | later | A UDT member that overlays a bit of another member (`Target`/`BitNumber`) imports as a plain `BOOL`, not a live alias of that bit. |
| Per-instance composite tag values | later | A `<Structure>`/`<ArrayMember>` tag's per-instance member values are not read; the tag gets its type's structural default instead. |
| Predefined AB/CIP module datatypes | later | Module-defined I/O datatypes (e.g. `AB:1756_MODULE:...`) fall back to `INT16` like any other unresolved type name, rather than being specially modeled. |
| Multi-dimensional arrays | later | Only the first dimension of a multi-dimensional `Dimensions` attribute is imported; the rest are flattened away (info warning). |
| Nested `[…]` branches (RLL) | later | The RLL compiler assembles single-level parallel branches only; a rung with a branch nested inside another branch leg stubs (`complex-topology`). |
| Empty (bypass) branch legs (RLL) | later | An `[…]` branch leg with no instructions (a bare power-through wire) is not modeled; such a rung stubs rather than wiring a direct rail-to-junction pass-through. |
| `RTO` / retentive timers (RLL) | later | Only `TON`/`TOF` map to the app's timer block; `RTO` (retentive-on) has no native equivalent and stubs (`unsupported-instruction`). |
| Exact timer/counter preset fidelity (RLL) | later | A literal preset operand imports exactly; a tag-referenced or expression preset defaults + warns. Rockwell's predefined `TIMER`/`COUNTER` types themselves DO map onto the app's builtin composites (`type_normalize.dart`), so `.PRE`/`.ACC`/`.DN`/`.CV` are real members that execute; what is still deferred is reading the preset **off that backing structure's `.PRE` value** instead of from the operand text alone. |
| Unmapped RLL instructions | later | `CPT`, `JSR`, `PID`, `SQO`, `COP`, `MSG`, and other instructions outside the supported set have no translation and stub the rung (`unsupported-instruction`), recorded in `ImportReport.unsupportedRllInstructions`. |

## QA whole-branch review follow-ups (feat/qa-improvements)

| Item | Priority | Notes |
|---|---|---|
| Project-dropdown scrim | later | The project-select header uses a plain `DropdownButton`, whose modal barrier color isn't overridable through its own API — a real fix needs either a forked/custom dropdown widget or a `NavigatorObserver`-driven overlay. Cosmetic (the stock Material scrim shows instead of the app's), not a functional gap. |
| Tags & Structs FAB-over-list overlap (full fix) | later | The `ListView`'s trailing `EdgeInsets.fromLTRB(16, 16, 16, 96)` padding (`memory_manager_screen.dart`'s `_buildStructDefsTab`) only keeps the LAST card clear of the "Add DUT" FAB once the user has scrolled to the end; a pinned action surface (e.g. a persistent bottom bar instead of a floating FAB) would be the full fix for the overlap at any scroll position. |
| `PannableCanvas` pointer-signal gap | later | A wheel notch delivered inside the viewport but off the canvas's actual content falls back to `InteractiveViewer`'s own zoom-on-wheel behavior (see `pannable_canvas.dart`'s `_onPointerSignal`: `pre == null` early-return) rather than the pan affordance — same as a bare, unwrapped viewer. Edge case; the common case (wheel over the drawn content) pans correctly. |
| FBD lane wheel vs. tall networks | later | With `wheelPansVertically: false`, the plain mouse wheel over an FBD lane drives the outer lane `ListView`, not the individual network canvas. A network whose content exceeds the lane's 1200px height clamp (`fbd_editor_screen.dart`, `(maxY + 220).clamp(260.0, 1200.0)`) is therefore wheel-unreachable past that clamp — drag-to-pan and Shift+wheel (confirmed working against a real Chromium build, which delivers `shiftKey` alongside `dy`) still reach it. |
| Gateway Regenerate confirm-when-non-empty | later | Regenerating the protocol map prompts for confirmation only when the existing map is non-empty (QA batch C, `3312d2b`). This threshold is a judgment call, not a proven-wrong behavior — revisit if it turns out to read as friction in practice (e.g. a near-empty map that still represents deliberate manual edits). |

## Default projects redo (spec 2026-08-06)

| Item | Priority | Notes |
|---|---|---|
| Retired defaults linger on existing installs | near-term | `backfillNewDefaults` can only ADD a default whose id has never been seeded; it cannot remove or replace one the user already has. An existing install therefore shows up to 20 projects until the user runs Reset to Defaults, which is the only path that yields exactly the new 7. A "retire default ids" reconciliation pass (with user confirmation) is deferred. |
| `proj_all_water` refresh invisible to existing installs | later | Same root cause: backfill never overwrites an existing id, so any future data change to the water plant reaches only fresh installs. This is why §4.5 fixed its change list at "move to its own file + add the missing doc comment". A "refresh an existing default in place" migration is deferred. |
| LD-side `GE`/`LE`/`NE`/`MUL`/`DIV`/`TP`/`CTD`/`CTUD` | later | Supported by `ld_exec.dart` and the editor palette, still not showcased in any default project (unchanged from before the redo). Enforced as a set in `test/defaults/default_projects_coverage_test.dart`'s `knownUncoveredLdBlockTypes`. |
| Task type `Event` | later | No default project uses an event-triggered task; the approved flagship lineup fixes it at three tasks (Startup/Continuous/Periodic). Enforced as `knownUncoveredTaskTypes` in the coverage guard. |
| `SignalGen` / bulk simulated test tags | later | No default project ships signal generators. |
| Protocols beyond Modbus + OPC UA | later | MQTT, DNP3, EtherNet/IP, S7, FINS, SLMP and BACnet configs are not pre-populated in any default; the flagship configures Modbus + OPC UA only. |
| PID autotune / interaction-analysis prefill with multiple loops in one project | later | `PidAutoTuneScreen` prefills from the FIRST `PID` block in the FIRST FBD program and `defaultInteractionAnalysisTags` from the first four analog tags in declaration order. `proj_process_lab` works around this by fixing its program and tag ORDER; a loop-selection UI would be the real fix. |
| Project Manager preset projects duplicate retired default names | later | `lib/screens/project_manager_screen.dart`'s `_loadPresetProject` ships two self-contained `PlcProject` literals — `proj_motor` "Basic Motor Start Stop" and `proj_tank` "Tank Level Simulation" — unrelated to `DefaultProjects.all()`. Both names and ids are now retired from the catalog, so the presets read as resurrected defaults. UX decision pending: retire the presets, rename them, or repoint them at the new showcase projects. |
| HVAC filter-life `CTD` cold-boot off-by-one | later | On the very first live scan the HVAC zone is already calling for heat (`Room_Temp` 18 vs `Setpoint` 22), so the `CTD`'s load edge and its first count edge land in the same scan; LD wins and that first heat start is not deducted, leaving `Filter_Life` one higher than the true start count. Harmless and self-correcting (recorded during Task 3); no test asserts `Filter_Life` from a cold boot. |
| No-autostart gate has a Windows classification hole | later | `flagship_gateway_no_autostart_test.dart`'s port probe treats `WSAEACCES`/`SO_EXCLUSIVEADDRUSE`-style Windows bind refusals the same as a POSIX permission-denied skip for privileged port 502, but Windows can also raise an access-denied error for a port a competing process already holds exclusively — a real regression on that platform could be misclassified as "inconclusive, not a regression" rather than a hard failure. Proposed fix: harden the control-port probe to distinguish exclusive-address-in-use from true permission-denied on Windows (e.g. a secondary bind attempt with `SO_REUSEADDR` semantics or an OS-specific error-code table) rather than folding both into one skip path. |
| Integrity guard's `resolves` only validates path roots | later | `default_projects_integrity_test.dart`'s `resolves` helper treats any `System.*`-prefixed reference and any empty string as an automatic pass, and otherwise only checks that the reference's root segment names a real tag — it never walks a dotted/indexed suffix (struct member, array index, FB var) against the actual composite shape. A default project could reference a non-existent struct field or FB var and this guard would not catch it. Registered as a known ceiling; a stricter resolver that walks the full path against `defaultValueFor`/`tag_resolver.dart`'s expansion is a candidate follow-up. |

## Housekeeping

| Item | Priority | Notes |
|---|---|---|
| `generated_plugin_registrant` churn | later | The linux/macos/windows generated plugin-registrant files show as perpetually modified after a `flutter build`. Decide whether to gitignore them. |

---

## Shipped follow-ups

_(Move items here, or strike them through in place, when the PR that closes them
lands. Empty for now.)_
