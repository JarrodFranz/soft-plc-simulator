# Ladder Editor Enhancements — Design (WS21)

**Date:** 2026-07-07
**Status:** Approved by user (chat, 2026-07-07): full design + both defaults — CTUD count-down via tag field; rung reorder via ▲/▼ buttons.
**Area:** `mobile/lib/screens/ld_editor_screen.dart`, `mobile/lib/models/ld_graph.dart`, `mobile/lib/models/ld_layout.dart`, `mobile/lib/models/ld_exec.dart`, `mobile/lib/models/project_model.dart` (LdNode).

## Problem

Four gaps in the ladder (LD) editor, reported by the user:

1. **Coil tool places nothing.** `canInsertCoilOnWire` (`ld_layout.dart:53`) only offers a drop-target on a wire running *into the right rail from a non-coil* (coils are enforced terminal/rightmost — correct IEC). But every rung the editor creates already terminates in a coil (default rungs + `_addRung` seeds `New_Contact → Output_Coil`), so there is never an open terminal and the Coil tool shows no target.
2. **No way to delete a rung.** No `deleteRung` exists; the only trash affordance deletes the whole program.
3. **No way to reorder rungs.** No move/reorder exists.
4. **Only timer blocks.** The LD execution engine (`ld_exec.dart` `case LdKind.block`) implements only TON/TOF. Counter/pulse engines built earlier live in the FBD path, not LD.

## Goal

Make the LD editor support placing multiple output coils, deleting and reordering rungs, and a fuller block set: **timers (TON/TOF/TP), counters (CTU/CTD/CTUD), compare (GT/LT/GE/LE/EQ/NE), and math (ADD/SUB/MUL/DIV/MOVE)** — with each block type actually executed by the in-app LD engine.

## Non-goals (YAGNI)

- Two-power-input block shapes (CTUD's second count input is a tag field, not a pin — see §D).
- Drag-to-reorder rungs (▲/▼ buttons instead).
- New block families beyond the four above (no PID/edge blocks in LD — edge is already a contact modifier; PID stays in FBD).
- Any change to FBD/SFC/ST editors or their engines.

## A. Rung delete & reorder

**Pure helpers (`ld_graph.dart`):**
- `void deleteRung(PlcProgram program, int index)` — removes `program.rungs[index]`; safe no-op if out of range; program may go to zero rungs.
- `void moveRung(PlcProgram program, int from, int to)` — removes at `from`, inserts at clamped `to`; no-op if equal or out of range.

**UI (`ld_editor_screen.dart`, rung header row):** a trailing action cluster on each rung's header — **▲** (disabled on the first rung), **▼** (disabled on the last), and a **trash** icon. Trash shows a confirm dialog ("Delete rung N?") before calling `deleteRung`. All three call `setState` + `widget.onProgramUpdated()` (so undo/redo and autosave already wrap them). Display index (`RUNG N`) is positional and re-derived on rebuild, so no stored index to fix up.

## B. Coil placement — stacked parallel output coils

Coils remain terminal/rightmost. In **Coil mode**, in addition to any existing coil-insertable wire targets, the editor shows a single **"＋ add output"** target near the right rail of the rung. Tapping it appends a **new parallel output lane**: a branch spanning the rung's full main width whose single node is a new coil (default variable `Output_Coil`), wired lane→right-rail. This mirrors how ladder logic stacks multiple outputs, and works even when the main line already ends in a coil.

- New helper `LdNode addOutputCoil(LdRung rung)` (`ld_graph.dart`): allocates a new lane (`maxLane(rung)+1`), adds a coil node on it spanning to the right rail, returns the new node so the caller can open the edit dialog.
- The existing edit-dialog **Delete** removes a mis-placed coil (already implemented).
- `canInsertCoilOnWire` is unchanged (still governs in-line coil placement on a genuinely open terminal, e.g. a freshly emptied rung).
- New rungs keep the default single contact→coil.

## C. Block model + single-power blocks (TP, CTU, CTD, CTUD)

### Model (`project_model.dart` `LdNode`)
- Reuse `presetMs` (JSON key `preset_ms`) as the **generic preset int**: milliseconds for timers, **count** for counters. No JSON key change → back-compatible.
- Add two additive fields for data blocks (used in §D, declared here): `String operandA` (JSON `operand_a`, default `''`), `String operandB` (JSON `operand_b`, default `''`). Omitted from `toJson` when empty to keep existing project files byte-stable through the WS6 round-trip.
- `blockType` gains the new values: `'TP'`, `'CTU'`, `'CTD'`, `'CTUD'`, `'GT'|'LT'|'GE'|'LE'|'EQ'|'NE'`, `'ADD'|'SUB'|'MUL'|'DIV'|'MOVE'`.

### Engine (`ld_exec.dart`, `case LdKind.block`)
Single-power blocks keep the timer I/O shape: one power-in (`inputPower(n)`), one power-out (`power[n.id]`), tag-addressed state under `base = n.variable`.

- **TP** (pulse): rising edge of IN starts a pulse; `.DN`/Q holds true for `presetMs` then falls; retriggerable only after completion. Tags `.EN` (IN), `.DN` (Q), `.PRE`, `.ACC` (elapsed), `.TT`. Uses `rt.prevBool` for edge detection (same mechanism as edge contacts).
- **CTU** (count up): counts rising edges of the power input (CU); `.CV += 1` per edge, saturating at `32767` (IEC INT max, so it never runs away); `.QU` (and block power-out) true when `.CV >= .PV`. Reset when boolean tag `<base>.R` is true → `.CV = 0`. Tags `.CU`, `.CV`, `.PV` (= presetMs), `.QU`, `.R`.
- **CTD** (count down): counts rising edges of CD; `.CV` starts at `.PV` on load/reset and decrements to 0; `.QD`/power-out true when `.CV <= 0`. Reset (`<base>.R`) reloads `.CV = .PV`. Tags `.CD`, `.CV`, `.PV`, `.QD`, `.R`.
- **CTUD** (up/down): power input drives **CU** (rising edge → +1). The **count-down input is a boolean tag** named in the edit dialog and stored in `operandA` (a rising edge on that tag → −1). `.CV` clamps to `[0, .PV]`; `.QU` true at `.CV >= .PV`, `.QD` true at `.CV <= 0`; block power-out = `.QU`. Reset (`<base>.R`) sets `.CV = 0`. Documented simplification: the down input is a tag rather than a second power pin.

Edge detection for counters uses per-node keys in `rt.prevBool` so two counters never share state; a freed node id is never reused (`newNodeId` is monotonic — existing invariant).

## D. Data blocks (Compare, Math) + palette

### Shape
A new **data-block visual**: power-in (EN) on the left, two operand fields (A on top, B on bottom) rendered inside the block body, power-out on the right. Operands are tag-or-literal strings (`operandA`, `operandB`); each is resolved via the existing `readPath`/literal-parse used elsewhere (numbers parse as literals, otherwise treated as a tag path).

- **Compare** (`GT/LT/GE/LE/EQ/NE`): power-out = `EN AND (valueA op valueB)`, numeric comparison (bool/int/double coerced to double; EQ/NE also handle bool equality). No output tag written. Block glyph shows the operator symbol (`>`, `<`, `≥`, `≤`, `=`, `≠`).
- **Math** (`ADD/SUB/MUL/DIV/MOVE`): when EN is true, computes `valueA op valueB` (MOVE = copy `valueA`, ignores B) and writes the result to the block's output tag (`n.variable`); power-out = EN (ENO passthrough). **DIV by zero** → result 0 and power-out still EN (documented; no crash). Result type follows the output tag's declared type (int truncates).

### Engine
Add the compare/math cases to `ld_exec.dart`'s block switch, reading operands live and writing `n.variable` for math. Never throw — a bad operand resolves to 0/false.

### Palette (`ld_editor_screen.dart` toolbar)
Replace the single hardcoded-TON "Block" button with a **block picker**: tapping "Block" opens a bottom sheet (adaptive dialog on wide panes) grouped **Timers** (TON, TOF, TP) · **Counters** (CTU, CTD, CTUD) · **Compare** (GT/LT/… default GT) · **Math** (ADD/SUB/… default ADD). Selecting a type sets a pending block-type and enters insert mode; the next wire-target tap inserts that block and opens its edit dialog. `_insertOnWire`'s hardcoded `blockType: 'TON'` is replaced by the pending selection.

### Edit dialog (`_showEditNodeDialog`)
- Timers/counters: tag field + preset field (labelled "Preset Time (PT) ms" for timers, "Preset Count (PV)" for counters) + (CTUD only) a "Count-down tag" field bound to `operandA`.
- Compare: operand A field, operator dropdown, operand B field (no tag/preset).
- Math: output tag field, operand A, operator dropdown, operand B.

### Rendering (`_buildBlock`)
Timer/counter blocks render as today (title + preset). Data blocks render the new two-operand body with the operator symbol. Block height stays `_kBlockH`; the two-operand body must fit without overflow at 320 px pane width.

## Testing

- **Pure unit tests** (`ld_graph`/`ld_layout`): `deleteRung` (incl. to empty), `moveRung` (bounds/no-op/reorder), `addOutputCoil` (new lane + terminal wiring, coil stays rightmost).
- **Engine unit tests** (`ld_exec`): TP pulse width (N scans high then low, non-retrigger mid-pulse); CTU count + `.QU` at PV + reset; CTD reload + decrement + `.QD`; CTUD up/down/clamp/reset; each compare operator at its boundary (`A==B` for GE/LE/EQ); each math op incl. MOVE and DIV-by-zero; power-out passthrough. Deterministic, driven through the existing scan-step harness.
- **Widget tests** (`ld_editor_screen`): block picker lists all groups and inserts the chosen type; rung ▲/▼/trash present, disabled at ends, confirm-on-delete; "＋ add output" adds a second coil; no RenderFlex overflow at 320 and 1400 px.
- **Round-trip**: a project using every new block type + a stacked output coil survives WS6 save/load unchanged (additive fields).
- Full `flutter test` green, `flutter analyze` ZERO, dark mode, no branding.

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix") in strings/identifiers/comments; IEC block mnemonics (TON, CTU, GT, …) are IEC 61131-3 terms and are fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- Additive persistence only: `operand_a`/`operand_b` omitted when empty; `preset_ms` meaning generalized but key unchanged; WS6 round-trip guard stays green.
- LD writes remain force-aware (forcing wins) — unchanged; new blocks write through the same `write`/`readPath` path.
- Pure logic (`ld_graph`, `ld_layout`, `ld_exec`) stays free of Flutter imports.

## Phasing (one spec, three plan phases)

1. **Rung mechanics + coil stacking** — `deleteRung`/`moveRung`/`addOutputCoil` + rung header actions + Coil-mode "＋ add output". Independently shippable.
2. **Single-power blocks** — TP, CTU, CTD, CTUD engine + preset-count dialog + CTUD down-tag + rendering.
3. **Data blocks + palette** — compare/math model fields, engine, two-operand block widget, edit-dialog operand fields, and the block-type picker replacing the hardcoded-TON button.
