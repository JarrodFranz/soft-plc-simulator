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
| Custom / user function blocks in FBD | later | The block `type` set is a fixed vocabulary; user-defined FBs are out of scope. Related to the LD custom-FB item below — a shared future capability. |
| Cross-network wiring | later | By design wires are intra-network; cross-network data flows through tags. |

**Minor code-quality follow-ups (from the whole-branch review, non-blocking):**
- Add direct unit tests for the constructor-level `fbdNetworks` normalization + the no-over-extension invariant (currently only indirectly covered).
- `executeFbdPrograms` re-scans blocks/wires per network (O(networks×wires)) — could pre-bucket once; negligible today.
- The desktop palette dock / phone add-block FAB add blocks into network 0 (no "active lane" cue); per-lane add-block is the primary path.
- `_resolvedWireFromPin` in the editor hand-mirrors `fbd_exec`'s private `_resolvedFromPin` — promote the exec helpers to public and share, to remove drift risk.

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
| FBD import translator | near-term | Sub-project 2 of 3; imported FBD POUs currently stub. Cleanest 1:1 mapping. |
| SFC import translator | later | Sub-project 3 of 3; imported SFC POUs currently stub; needs graphical→ST serialization. |

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
