# Counter Function Blocks (WS11) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "keep building app side as I can't be
in the loop"). Design made autonomously, mirroring the WS10 PID pattern.
**Author:** Claude (pairing with Jarrod)

Adds the IEC 61131-3 **counter** function blocks — `CTU` (count up), `CTD`
(count down), `CTUD` (up/down) — as executable, stateful FBD blocks. Counters
are a fundamental IEC building block (they already appear in the ST autocomplete
palette from Phase 2) but have never been executable. This closes that gap the
same way WS10 added `PID`: registry pins + a stateful executor in `FbdRuntime` +
palette entries + a demo that proves the block works end-to-end in a running
project.

## The blocks

Three new FBD block types, stateful like `TON`/`PID` (per-block state keyed by
block id in `FbdRuntime`, cleared on project switch). All counting is
**edge-triggered**: a counter advances only on a **rising edge** of its count
input (input false→true between scans), so holding an input true counts once,
not every scan. Edge detection stores the previous input level per block.

### CTU — Count Up
- **Input pins:** `CU` (count-up, BOOL, rising-edge), `R` (reset, BOOL), `PV`
  (preset value, INT).
- **Output pins:** `Q` (BOOL — `CV >= PV`), `CV` (INT — current count).
- **Semantics per scan** (in priority order):
  - `R` true → `CV := 0` (reset wins; no count this scan).
  - else on a rising edge of `CU` → `CV := CV + 1`.
  - `Q := CV >= PV`.
- Counting is capped at one increment per scan (edge-triggered), so `CV` grows
  bounded; no unbounded per-scan growth.

### CTD — Count Down
- **Input pins:** `CD` (count-down, BOOL, rising-edge), `LD` (load, BOOL), `PV`
  (preset value, INT).
- **Output pins:** `Q` (BOOL — `CV <= 0`), `CV` (INT — current count).
- **Semantics per scan** (priority order):
  - `LD` true → `CV := PV` (load wins; no count this scan).
  - else on a rising edge of `CD`, if `CV > 0` → `CV := CV - 1` (does not go
    below 0).
  - `Q := CV <= 0`.

### CTUD — Count Up/Down
- **Input pins:** `CU` (count-up, rising-edge), `CD` (count-down, rising-edge),
  `R` (reset), `LD` (load), `PV` (preset).
- **Output pins:** `QU` (BOOL — `CV >= PV`), `QD` (BOOL — `CV <= 0`), `CV` (INT).
- **Semantics per scan** (priority order, per IEC): `R` → `CV := 0`; else `LD`
  → `CV := PV`; else apply a rising edge on `CU` (`CV+1`) and/or a rising edge
  on `CD` (`CV-1`) (both may fire the same scan; net ±0 if both). `CV` is
  clamped to `>= 0` on the down path. `QU := CV >= PV`, `QD := CV <= 0`.

### Common rules
- `PV` is read as an integer (`_asNum` coercion, truncated to int); a missing/
  unwired `PV` reads 0. Missing/unwired BOOL inputs read false. Never throws.
- **State** in `FbdRuntime` keyed by block id: the current count plus the
  previous levels of each edge input (`CU`/`CD`). Cleared on project switch,
  mirroring the `TON` (`_elapsedMs`) / `PID` (`_pid`) pattern.
- Counters have no clock dependency — `dtMs` is unused (unlike timers). Purely
  a function of inputs + stored state; single-pass, never hangs.
- `CV` output is an `int`; `Q`/`QU`/`QD` are `bool`. Force-aware writes apply
  when wired to a `TAG_OUTPUT`.

## Where it plugs in

- **`fbd_pins.dart`:** add `CTU` → inputs `['CU','R','PV']`, outputs `['Q','CV']`;
  `CTD` → inputs `['CD','LD','PV']`, outputs `['Q','CV']`; `CTUD` → inputs
  `['CU','CD','R','LD','PV']`, outputs `['QU','QD','CV']`.
- **`fbd_exec.dart`:** `FbdRuntime` gains a per-block counter-state map;
  `_evalBlock` gets `case 'CTU'`/`'CTD'`/`'CTUD'` producing the output maps.
  Stays pure, never throws, never hangs.
- **`fbd_editor_screen.dart`:** add `CTU`/`CTD`/`CTUD` to the block palette
  (pins render automatically from the registry — the down-counter shows 3 input
  dots, CTUD shows 5, etc.).

## Showcase — a batch-counter demo (new default project)

Add a default project **"Batch Counter"** demonstrating a real counting loop:
- **Tags:** `Part_Sensor` (BOOL, sim input — pulses as parts pass), `Batch_Size`
  (INT, internal, e.g. 5), `Batch_Done` (BOOL, sim/internal output), `Count`
  (INT, output — the live count), `Reset_Btn` (BOOL, internal).
- **FBD program `BatchCount_FBD`:** a `CTU` block — `CU`←`Part_Sensor`
  (TAG_INPUT), `R`←(`Batch_Done` fed back, or `Reset_Btn`), `PV`←`Batch_Size`
  (TAG_INPUT or CONST) — `Q`→`TAG_OUTPUT Batch_Done`, `CV`→`TAG_OUTPUT Count`.
  Wiring `Q` back to `R` gives a self-resetting batch counter: it counts parts,
  raises `Batch_Done` at the preset, and resets to begin the next batch.
- **Simulated I/O:** `Part_Sensor` driven by a `pulse` behaviour (parts arrive
  periodically) so the counter advances on its own in RUN mode.
- **HMI:** a dashboard showing `Count` (numeric/gauge), `Batch_Size`, and a
  `Batch_Done` indicator.
- **Closed-loop test:** run the scan pipeline; assert `Count` advances on
  successive part pulses (one per rising edge, not per scan), `Batch_Done`
  fires when `Count` reaches `Batch_Size`, and the self-reset returns `Count`
  toward 0 to start the next batch. Falsifiable: a level-triggered (non-edge)
  counter would over-count; a broken reset would latch `Batch_Done` forever.

## Testing

- **Engine unit tests** (pure): rising-edge counting (held-true input counts
  once, not per scan); `CTU` `Q` at `CV >= PV`; `R` resets and has priority;
  `CTD` counts down, floors at 0, `LD` loads `PV`, `Q` at `CV <= 0`; `CTUD`
  up/down with `R`/`LD` priority and both-edges-same-scan; unwired inputs →
  false/0, no throw; `FbdRuntime.clear()` resets counter state.
- **Serialization:** the new blocks + wires round-trip (WS6 structural + 20-scan
  scan-equivalence per default project stays green — the new demo project
  included and self-consistent). No new persisted field (reuses `type` + pins/
  wires); runtime counter state is correctly non-serialized (rebuilt).
- **Closed-loop integration:** the Batch Counter project counts parts, fires
  `Batch_Done` at the preset, and self-resets (falsifiable).
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints

No third-party/reference-editor branding (IEC-style pin names `CU`/`CD`/`R`/
`LD`/`PV`/`Q`/`CV`/`QU`/`QD` are generic and standard). Dark theme; responsive.
`flutter analyze` zero. Engines pure Dart in `mobile/lib/models` (UI-free);
force-aware writes; never throws/hangs. Lossless persistence preserved
(round-trip guard). No RenderFlex overflow at 360/320/1400.

## Out of scope (deferred)
- Counters as ST/IL function-block calls (this is the FBD block; the ST
  interpreter remains IF + assignment only, as with PID).
- Retentive counters, counter presets driven mid-run from the HMI beyond the
  provided tag wiring, and 64-bit/DINT range specifics (Dart `int` suffices).
