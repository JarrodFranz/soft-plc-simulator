# MIMO Coupled Plant + Interaction Analysis (RGA) — Design Spec

**Date:** 2026-07-16
**Status:** Approved (design)
**Workstream:** Phase 9, feature 4 of 4 (final).

## Goal

Demonstrate multi-loop (MIMO) interaction and the value of decoupling: a **Two Thermal Zones** coupled plant (2×2), two PID loops, and a **static decoupler**, plus a new **Interaction Analysis** panel that identifies the plant's 2×2 steady-state gain matrix by automated step tests, computes the **Relative Gain Array (RGA)**, and recommends loop pairing. The plant is built entirely from existing SimRules (the engine already runs multiple rules per target — as Cascade Tanks does), so no new sim-engine construct is needed. The analysis reuses the auto-tune deep-copy experiment pattern.

## Current behaviour (as-found)

- `applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt)` loops over **all** rules, each modifying its target in place. Multiple rules can target the same tag (Cascade Tanks stacks inflow + outflow on `Tank_A_Level`). Behaviours: `integrate` (`cur += ratePerSec·dt·(source/refValue)`), `firstOrderLag` (`cur += (source − cur)·dt/τ`), `deadTime`, etc. `firstOrderLag` with a tag `source` yields exactly a difference term `(source − cur)·dt/τ` — the conduction coupling.
- FBD blocks (`fbd_pins.dart`): `MUL` (`IN1..→OUT`), `SUB` (`IN1,IN2→OUT`), `LIMIT` (`MN,IN,MX→OUT`), `CONST`/`TAG_INPUT`/`TAG_OUTPUT`, `PID` (`SP,PV,KP,KI,KD→CV`). Engine `fbd_exec.dart`.
- Auto-tune (`models/pid_autotune.dart`) already does deep-copy sim experiments: `PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())))`, drive a tag each scan via `writePath`, run `applySimRules`, read a PV via `readPath`. Reuse this pattern.
- Default projects live in `DefaultProjects.all()`; new projects backfill non-destructively onto existing installs (shipped feature). No golden project count is hardcoded.

## Non-goals / YAGNI

- No new sim-engine behaviour or gain-matrix model — stacked SimRules express the coupled dynamics.
- No persisted schema change; the Interaction panel's params are session-only.
- 2×2 only (two zones / two loops). No general N×N RGA.
- No dynamic decoupler / model-predictive control; the decoupler is a static (steady-state) 2×2 feedforward.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `models/interaction_analysis.dart`.
- Deterministic/pure: no clock, no `Math.random`; identical project + params → identical result; experiments run on a deep copy and never mutate live tags.
- Additive/backward-compatible: no persisted schema change; the new default project appends to `DefaultProjects.all()`; existing projects unchanged; default-projects round-trip/scan-equivalence stays green.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Component 1 — The plant: Two Thermal Zones (in the new default project)

Tags (FLOAT64 °C / %):
- MVs: `Heater_A`, `Heater_B` (SimulatedOutput, 0–100 %).
- PVs: `Temp_A`, `Temp_B` (SimulatedInput, °C).
- Setpoints: `SP_A`, `SP_B` (Internal). Ambient: `Amb` (Internal, e.g. 20 °C).
- PID outputs (pre-decoupler): `u_A`, `u_B` (Internal). Decoupler gains: `d12`, `d21` (Internal / CONST, default 0).

Plant SimRules (stacked per PV; forward-Euler of the coupled ODE):
- `Temp_A`:
  - `integrate` heat from heater: `ratePerSec = heatRate`, `sourcePath = Heater_A`, `refValue = 100`, `minValue/maxValue` clamp.
  - `firstOrderLag` conduction toward `Temp_B`: `sourcePath = Temp_B`, `tauSec = tauCouple`.
  - `firstOrderLag` loss toward `Amb`: `sourcePath = Amb`, `tauSec = tauLoss`.
- `Temp_B`: symmetric (heat from `Heater_B`, conduction toward `Temp_A` at `tauCouple`, loss toward `Amb` at `tauLoss`).

Tuning targets (indicative, refined at build to give clear but stable coupling): `heatRate ≈ 3 °C/s at 100 %`, `tauCouple ≈ 8 s` (meaningful cross-conduction), `tauLoss ≈ 40 s`. The off-diagonal gain (Heater_A → Temp_B via conduction) must be clearly non-zero so the RGA shows real interaction.

## Component 2 — RGA analysis engine (`mobile/lib/models/interaction_analysis.dart`, pure)

```dart
class StepTestParams {
  final double baseMv;      // hold level for both MVs during settle
  final double stepDelta;   // step applied to one MV
  final int dtMs, maxScans;
  final double settleEps;   // |ΔPV| per scan below this = steady (over a window)
  final int settleWindow;   // consecutive scans within eps to declare steady
}

class GainMatrix { final double k11, k12, k21, k22; final bool converged; final String? warning; }
class RgaResult  { final double lambda11; final String pairing; final String? warning; }

GainMatrix identifyGainMatrix(PlcProject project,
    {required String mv1Path, required String mv2Path,
     required String pv1Path, required String pv2Path, required StepTestParams params});

RgaResult computeRga(GainMatrix g);
```

`identifyGainMatrix` (deep copy; plant SimRules only — the PID program is NOT run):
1. Hold both MVs at `baseMv`; run to steady state (both PVs' per-scan change < `settleEps` for `settleWindow` scans, or `maxScans`); record `p10, p20`.
2. Set MV1 = `baseMv + stepDelta`, MV2 = `baseMv`; run to steady state; `K11 = (PV1 − p10)/stepDelta`, `K21 = (PV2 − p20)/stepDelta`.
3. Reset to baseline (fresh deep copy or re-settle at base); set MV2 = `baseMv + stepDelta`, MV1 = `baseMv`; run; `K12 = (PV1 − p10)/stepDelta`, `K22 = (PV2 − p20)/stepDelta`.
4. `converged` = all step tests settled; else `warning` "step test did not settle — increase duration".

`computeRga(g)`: `det = k11·k22 − k12·k21`; if `|det| < ε` → `warning` "ill-conditioned (near-singular gain matrix)", `lambda11 = double.nan` (panel shows the warning). Else `lambda11 = (k11·k22)/det`. Pairing:
- `lambda11 ≥ ~0.67` → "Diagonal: MV1→PV1, MV2→PV2 (low interaction)".
- `~0.33 < lambda11 < ~0.67` → "Strong interaction — decoupling recommended (diagonal pairing)".
- `lambda11 ≤ ~0.33` (incl. negative up to 0) → "Off-diagonal: MV1→PV2, MV2→PV1".
- `lambda11 < 0` or `> 1` → append "ill-conditioned — pairing sensitive".

## Component 3 — Interaction Analysis panel (`mobile/lib/screens/interaction_analysis_screen.dart`, new nav section)

A new center-workspace section (`_activeViewId == 'INTERACTION'`, sibling to the Auto-Tune entry; `Icons.grain` or `Icons.blur_on`), mirroring `PidAutoTuneScreen`'s structure and the `SimulatedIoScreen`/`SimIO` nav wiring:
- MV1/MV2 + PV1/PV2 selectors (tag fields), prefilled for the MIMO project (`Heater_A`/`Heater_B`, `Temp_A`/`Temp_B`).
- Step-test params (base MV, step delta, max duration).
- **Run** → `identifyGainMatrix` synchronously → render the **2×2 gain matrix** (a small grid), `computeRga` → the **RGA** (2×2) with `λ11`, the **recommended pairing** text, and the interaction/ill-conditioned warning if present. Also surface the suggested decoupler gains `d12 = K12/K11`, `d21 = K21/K22` (so the user can copy them into the project's `d12`/`d21` constants).
- Constructor mirrors `SimulatedIoScreen({required PlcProject currentProject, required VoidCallback onProjectUpdated})` (onProjectUpdated may be unused if the panel is read-only; keep it for consistency / a future "apply decoupler gains" affordance).

## Component 4 — Two PID loops + static decoupler (in the MIMO project's FBD program)

FBD program `TwoZone_FBD`:
- PID_A: `SP_A`,`Temp_A`, gains (CONST) → `u_A` (TAG_OUTPUT). PID_B: `SP_B`,`Temp_B`, gains → `u_B`.
- Static decoupler per zone: `Heater_A = LIMIT(0, u_A − d12·u_B, 100)` via `MUL(d12,u_B)→m1`, `SUB(u_A,m1)→s1`, `LIMIT(MN=0,IN=s1,MX=100)→Heater_A`; symmetric for `Heater_B` with `d21·u_A`. `d12`/`d21` CONST default `0` (→ `Heater_A = u_A`, independent loops).
- With `d12`/`d21` = 0 the loops interact (stepping `SP_A` disturbs `Temp_B`); setting them to the RGA-derived gains cancels the cross-effect — the decoupling payoff, toggled by two constants in one project.

## Data flow

Scan → PID_A/PID_B compute `u_A`/`u_B` → decoupler FBD computes `Heater_A`/`Heater_B` → plant SimRules update `Temp_A`/`Temp_B` (heat + conduction + loss). The Interaction panel runs open-loop step tests on a deep copy (plant only), never disturbing the live loop; deterministic. Nothing new persisted.

## Error handling / edge cases

- Step test not settling → `converged=false` + warning; RGA not computed.
- Near-singular gain matrix (`|det|<ε`) → RGA warning, `λ11` shown as N/A.
- Unresolved MV/PV selection → panel requires it before Run.
- Decoupler `LIMIT` clamps heater commands to 0–100 so decoupling can't drive an actuator out of range.

## Testing

- **Pure (`interaction_analysis_test`):** `identifyGainMatrix` on the Two-Zone plant returns a `GainMatrix` with clearly non-zero off-diagonal (`k12`,`k21` ≠ 0 — real coupling), `converged==true`; deterministic (same project+params → identical matrix); `computeRga` golden `λ11` for a fixed `GainMatrix`, correct pairing string per band; singular matrix → warning + NaN `λ11`.
- **Plant/decoupling (`mimo_project_test`):** the MIMO project registers in `DefaultProjects.all()` and round-trips; a multi-scan closed-loop run with `d12==0` shows an `SP_A` step visibly disturbing `Temp_B` (|ΔTemp_B| above a threshold); the SAME run with `d12`/`d21` set to the decoupling gains reduces that cross-disturbance (smaller |ΔTemp_B|). Deterministic.
- **Widget (`interaction_analysis_screen_test`):** the panel renders; MV/PV prefilled for the MIMO project; **Run** shows a gain-matrix grid + RGA + pairing text; no overflow at 320/1400.
- **Round-trip / scan-equivalence:** default-projects round-trip stays green; the analysis deep-copy does not mutate the source project.
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`.

## Files

- **Create:** `mobile/lib/models/interaction_analysis.dart` (pure: `StepTestParams`/`GainMatrix`/`RgaResult`/`identifyGainMatrix`/`computeRga`) + its test; `mobile/lib/screens/interaction_analysis_screen.dart` + its widget test; a `mimo_project_test.dart`.
- **Modify:** `mobile/lib/data/default_projects.dart` (new `_mimoTwoZoneProject()` + register in `all()`), `mobile/lib/screens/workspace_shell.dart` (nav entry + center-view case).
- **Docs:** `docs/mimo-coupled-plant.md` + `ROADMAP.md` (Phase 9 feature 4 — MIMO — done, Phase 9 complete) + the README control-features bullet.

## Optional (plan-time)

Decompose into ~5 tasks: (1) RGA pure engine + tests; (2) Interaction panel + nav; (3) Two-Zone MIMO default project (plant SimRules + PID loops + decoupler FBD) + registration/round-trip test; (4) coupling/decoupling multi-scan test; (5) validation + docs. Tasks 3-4 may merge if the project test is written alongside the project.
