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
| Graphical-bodied FBs (LD/FBD body) | later | v1 FBs have an ST body; a graphical body needs nested-engine execution + instance-scoped state for stateful sub-blocks. Import mapping explicitly skips these with a warning (`mapImportedFbs`) — not imported. |
| FB calling another FB (nesting/recursion) | later | The app's ST subset has no FB-call syntax, so v1 FB bodies can't instantiate other FBs. |
| FB body ST beyond the app's ST subset | later | An imported FB whose ST exceeds IF/ELSIF/ELSE + assignments is handled as ST programs are today (partial). |
| IEC *functions* (stateless POUs) | later | v1 is function *blocks* (stateful instances); stateless FUNs are a separate POU kind. |
| Imported `VAR_IN_OUT` mapped to input | later | `mapImportedFbs` maps an FB's `VAR_IN_OUT` vars to `FbVarDir.input` (by-reference IEC semantics aren't representable in the app's by-value FB model) and emits an info warning naming the var; the FB still imports rather than being skipped. |
| Boolean-literal FB input pin binding | later | `ld_exec.dart`'s custom-FB block resolves a literal `pinBindings` value via `num.tryParse` only (tag lookup first, else numeric literal). A BOOL-typed FB input bound to a literal `TRUE`/`FALSE` (e.g. from imported LD) resolves to null and leaves the instance field at its prior value. Consistent with `_operandValue`'s pre-existing numeric-only literal handling; add boolean-literal parsing when a case appears. (IMPORT-FB Task 4 review.) |
| Imported FB output wired directly to a coil | later | The LD import translator folds an FB output only when it feeds an `<outVariable>`; an FB boolean output wired DIRECTLY to a coil leaves the FB→coil edge as a power wire AND binds the coil tag in `pinBindings`. At scan the coil is then driven by rung power (FB is power-transparent) while the pinBinding write sets it to `FB.Out` — same tag, possibly different value (last-write-wins). Rare wiring; not in any corpus. Fold FB→coil the same as FB→outVariable when a case appears. (IMPORT-FB whole-branch review.) |
| ~~`<expression>`-dialect FB call operands~~ | ~~later~~ | **Shipped** (2026-07-26, FBD import translator feature): `plcopen_parser` now reads a graph node's operand from a descendant `<expression>` element as a fallback when no `<variable>` element is present (identifier or literal only), so an `<inVariable>`/`<outVariable>` bound via `<expression>` resolves instead of stubbing. Proven in `mobile/test/import/import_fbd_e2e_test.dart`. (IMPORT-FB whole-branch review.) |
| Dotted read into a struct-typed local FB var | later | `StScope.readVars` only keys bare top-level var names, and `st_expr` lexes `SubVar.Field` as one dotted identifier → a body read of `SubVar.Field` (SubVar a local struct-typed var) misses the scope and falls through to a global. No current FB has struct-typed locals; revisit if Tasks 4-5 introduce them. (CFBX Task 3 review.) |
| FB interface-var rename does not propagate to pin refs | later | Renaming an `FbVar` (interface var) in the FB editor does not propagate to already-set `LdNode.pinBindings` keys or FBD wire pin references for placed instances of that FB — the FB continues to resolve (name-keyed), but existing pin bindings keyed to the old var name go stale. Consistent with the existing (also non-propagating) behavior of struct-field renames in `memory_manager_screen.dart`'s `_showEditStructDialog`, which likewise never updates any binding/reference that named the old field. `renameFbDefinition` (Task 6 fix pass, `tag_resolver.dart`) DOES propagate an FB *definition* rename (name itself) everywhere, since that mirrors `renameStructDef`'s existing propagation contract — only the var-level rename is deferred. |

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
| Other vendor dialects (Rockwell L5X, Siemens TIA) | later | Only PLCopen TC6 is autodetected; the IR is vendor-neutral so parsers can be added. |
| Merge-into-existing-project import | later | Import always creates a NEW project; no merge mode. |
| Export to PLCopen XML | later | Import-only today; no export path. |
| `detectDialect` tightening | later | Matches on the `plcopen`/`tc6` substring in the first 4 KB; a mis-detect self-corrects to a clear FormatException. |

## Housekeeping

| Item | Priority | Notes |
|---|---|---|
| `generated_plugin_registrant` churn | later | The linux/macos/windows generated plugin-registrant files show as perpetually modified after a `flutter build`. Decide whether to gitignore them. |

---

## Shipped follow-ups

_(Move items here, or strike them through in place, when the PR that closes them
lands. Empty for now.)_
