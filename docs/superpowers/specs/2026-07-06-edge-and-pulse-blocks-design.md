# Edge Detectors & Pulse Timer (WS12) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "keep building app side as I can't be
in the loop"). Design made autonomously, mirroring the WS10/WS11 stateful-block
pattern.
**Author:** Claude (pairing with Jarrod)

Completes the standard IEC 61131-3 FBD **function-block library** by adding the
two edge detectors — `R_TRIG` (rising) and `F_TRIG` (falling) — and the pulse
timer `TP`. The engine already executes timers (`TON`/`TOF`), the PID block, and
the counters (`CTU`/`CTD`/`CTUD`); these three are the remaining common standard
blocks. Same approach as before: registry pins + stateful executor in
`FbdRuntime` + palette entries + a demo that proves them working end-to-end.

## The blocks

Three new FBD block types, stateful (per-block state keyed by block id in
`FbdRuntime`, cleared on project switch — mirroring `TON`/`PID`/counters).

### R_TRIG — Rising-edge detector
- **Input pin:** `CLK` (BOOL).
- **Output pin:** `Q` (BOOL) — true for exactly ONE scan when `CLK` goes
  false→true; false otherwise.
- **Semantics per scan:** `Q := CLK AND NOT prevCLK`; then store `prevCLK := CLK`.
- **State:** previous `CLK` level. On the very first scan `prevCLK` defaults
  false, so a `CLK` already true on scan 1 IS treated as a rising edge (standard
  IEC behaviour: the block initialises with `Q` reflecting the first sample).

### F_TRIG — Falling-edge detector
- **Input pin:** `CLK` (BOOL).
- **Output pin:** `Q` (BOOL) — true for exactly ONE scan when `CLK` goes
  true→false; false otherwise.
- **Semantics per scan:** `Q := NOT CLK AND prevCLK`; then store `prevCLK := CLK`.
- **State:** previous `CLK` level. `prevCLK` defaults false on the first scan, so
  a `CLK` that starts false produces no spurious falling edge.

### TP — Pulse timer
- **Input pins:** `IN` (BOOL), `PT` (preset time, milliseconds — a numeric
  input, consistent with how `TON`/`TOF` read `PT`).
- **Output pins:** `Q` (BOOL — pulse active), `ET` (elapsed time, ms).
- **Semantics** (non-retriggerable, per IEC): a rising edge of `IN` while the
  timer is idle starts a pulse — `Q` goes true and `ET` counts up from 0 by
  `dtMs` each scan. `Q` stays true for the full `PT` **even if `IN` drops early**.
  When `ET` reaches `PT`, `Q` goes false and `ET` holds at `PT`. The timer is
  **not** retriggerable while a pulse is running (further `IN` edges are ignored
  until the pulse completes). Once the pulse has completed, `ET` resets to 0
  when `IN` is false again, arming the next pulse. `PT <= 0` yields a zero-width
  pulse (`Q` never latches true beyond the starting scan).
- **State** in `FbdRuntime` keyed by block id: elapsed time, a running flag, and
  the previous `IN` level (for start-edge detection).

### Common rules
- Unwired/missing inputs read false (`_truthy(...) ?? false`) / 0 (`_asNum`),
  never throw. `PT` coerced numerically.
- `TP` uses the scan clock (`dtMs`); `R_TRIG`/`F_TRIG` are clock-independent.
- All single-pass, never hang. Force-aware writes when wired to a `TAG_OUTPUT`.

## Where it plugs in

- **`fbd_pins.dart`:** `R_TRIG` → in `['CLK']`, out `['Q']`; `F_TRIG` → in
  `['CLK']`, out `['Q']`; `TP` → in `['IN','PT']`, out `['Q','ET']`.
- **`fbd_exec.dart`:** `FbdRuntime` gains per-block edge state (previous `CLK`
  for R_TRIG/F_TRIG) and pulse state (`[et, running, prevIN]` for TP), cleared
  in `clear()`; `_evalBlock` gets `case 'R_TRIG'`/`'F_TRIG'`/`'TP'`.
- **`fbd_editor_screen.dart`:** add the three to the palette (pins render from
  the registry).

## Showcase — a one-shot pulse demo (new default project)

Add a default project **"Pulse Output"** demonstrating edge→fixed-width-pulse,
the classic use of these blocks together:
- **Tags:** `Start_Btn` (BOOL, sim input — pulses on/off), `Pulse_Out` (BOOL,
  sim output — the fixed-width pulse), `Pulse_ET` (INT, ms — elapsed),
  `Pulse_Time` (INT, ms preset, e.g. 3000).
- **FBD program `PulseOut_FBD`:** `TAG_INPUT Start_Btn` → `R_TRIG.CLK`;
  `R_TRIG.Q` → `TP.IN`; `Pulse_Time` (TAG_INPUT or CONST) → `TP.PT`; `TP.Q` →
  `TAG_OUTPUT Pulse_Out`; `TP.ET` → `TAG_OUTPUT Pulse_ET`. So each rising edge of
  the button fires a one-shot that holds `Pulse_Out` true for `Pulse_Time`
  **regardless of how long the button is held** — the hallmark of an edge-gated
  pulse.
- **Simulated I/O:** `Start_Btn` driven by a `pulse` behaviour (periodic
  presses, with an on-phase deliberately LONGER than `Pulse_Time` so the demo
  visibly proves the output pulse width is set by `TP`, not by the button).
- **HMI:** a dashboard showing `Start_Btn` (indicator), `Pulse_Out` (indicator/
  lamp), and `Pulse_ET` (numeric).
- **Closed-loop test:** run the scan pipeline; assert (a) `R_TRIG` fires one
  scan per button rising edge, (b) `Pulse_Out` stays true for ~`Pulse_Time`
  after the edge and then drops **even though `Start_Btn` is still held**, and
  (c) a subsequent button press produces another identical pulse. Falsifiable:
  without `R_TRIG` the level-driven `TP.IN` would still one-shot, but without
  `TP` the output would just follow the button; a retriggerable timer would
  extend the pulse while the button is held.

## Testing

- **Engine unit tests** (pure): `R_TRIG` Q true exactly one scan on a rising
  edge (held-true → one pulse); `F_TRIG` Q true one scan on a falling edge;
  first-scan initialisation behaviour; `TP` holds Q for PT independent of IN
  dropping early, is non-retriggerable mid-pulse, ET counts and holds at PT,
  re-arms after IN falls, PT<=0 zero-width; unwired inputs → false/0, no throw;
  `FbdRuntime.clear()` resets all three.
- **Serialization:** the new blocks + wires round-trip (WS6 structural + 20-scan
  scan-equivalence per default project stays green, new demo project included).
  No new persisted field; runtime state correctly non-serialized.
- **Closed-loop integration:** the Pulse Output project produces fixed-width
  pulses gated by the button edge (falsifiable).
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints

No third-party/reference-editor branding (`R_TRIG`/`F_TRIG`/`TP`/`CLK`/`IN`/
`PT`/`Q`/`ET` are standard IEC — generic). Dark theme; responsive. `flutter
analyze` zero. Engines pure Dart in `mobile/lib/models` (UI-free); force-aware
writes; never throws/hangs. Lossless persistence preserved (round-trip guard).
No RenderFlex overflow at 360/320/1400.

## Out of scope (deferred)
- `R_TRIG`/`F_TRIG`/`TP` as ST/IL calls (these are the FBD blocks).
- Retriggerable pulse variants, and the remaining rarer standard blocks
  (bistables SR/RS, MUX beyond SEL) — future if needed.
