# MIMO — Two Thermal Zones: Coupled Plant & Interaction Analysis

A **multi-input, multi-output (MIMO)** demo showing what happens when two
control loops are not actually independent — and how to detect and fix that
with real multivariable-control tools instead of guesswork.

## The plant: two adjacent thermal zones

The default project **"MIMO — Two Thermal Zones"** models two adjacent zones
that share a wall:

- **Zone A**: heater `Heater_A` (%), temperature `Temp_A` (°C), setpoint `SP_A`.
- **Zone B**: heater `Heater_B` (%), temperature `Temp_B` (°C), setpoint `SP_B`.
- Both zones lose heat toward a shared ambient tag, `Amb`.

Each zone's temperature is built from **stacked Simulated I/O rules** (the
same rule engine used by every other demo project — see
`docs/measurement-noise.md` and `docs/valve-curves.md` for other examples of
stacking rules on one target tag):

1. **Heater** — an `integrate` rule analog-scaled by the zone's own heater
   output (`Heater_A/100`, `Heater_B/100`), so the actuator drives the zone's
   own temperature up.
2. **Conduction** — a `firstOrderLag` rule that pulls each zone's temperature
   toward the *other* zone's current temperature, with a short time constant
   (`tauSec: 8`). This is the shared-wall heat path and it's what makes the
   plant genuinely MIMO: driving `Heater_A` warms `Temp_A` directly *and*
   warms `Temp_B` indirectly through conduction.
3. **Heat loss** — a slower `firstOrderLag` rule (`tauSec: 40`) that pulls
   each zone's temperature back toward ambient.

Because the conduction time constant is deliberately short relative to the
loss time constant, the cross-zone coupling is strong rather than a rounding
error — the two zones are genuinely coupled, not "basically independent
loops that happen to share a project file."

### How the interaction shows up

Open the project, go online, and step `SP_A` (e.g. from 50 °C to 65 °C) on
the HMI dashboard while watching `Temp_B`. Even though nothing touched
`SP_B`, `Temp_B` visibly moves — Zone A's heater ramping up conducts heat
into Zone B. This is the hallmark of an interacting MIMO process: a change
meant for one loop disturbs the other.

## Interaction Analysis: gain matrix + RGA + pairing

The **Interaction Analysis** panel (alongside PID Auto-Tune in the app's
navigation) quantifies that interaction automatically instead of relying on
watching a trend chart.

### Step 1 — identify the 2×2 steady-state gain matrix

`identifyGainMatrix` (`mobile/lib/models/interaction_analysis.dart`) runs
three **open-loop step tests**, each on its own fresh deep copy of the
project's simulated process:

1. **Base point** — hold both manipulated variables (MVs) at `baseMv` and
   let the process settle.
2. **MV1 step** — step MV1 alone to `baseMv + stepDelta` (MV2 held at base)
   and let it settle.
3. **MV2 step** — step MV2 alone the same way (MV1 held at base) and let it
   settle.

Each run settles when both process variables' (PVs) per-scan change falls
below a tolerance for a run of consecutive scans, or gives up (marked
non-converged) after a scan budget. The four steady-state gains are then
finite differences from the base point:

```
K11 = ΔPV1 / ΔMV1      K12 = ΔPV1 / ΔMV2
K21 = ΔPV2 / ΔMV1      K22 = ΔPV2 / ΔMV2
```

For the shipped demo (`Heater_A`/`Heater_B` → `Temp_A`/`Temp_B`), the
identified matrix is approximately:

```
K = [ 0.645  0.537 ]
    [ 0.537  0.645 ]
```

Off-diagonal gains (`K12`, `K21`) that are a large fraction of the diagonal
gains (`K11`, `K22`) confirm strong interaction — consistent with the short
conduction time constant relative to the loss time constant described above.

### Step 2 — compute the Relative Gain Array (RGA)

`computeRga` turns the gain matrix into the RGA's `λ11` element and a
recommended MV/PV pairing:

```
det    = K11·K22 − K12·K21
λ11    = (K11·K22) / det
```

**How to read λ11:**

| λ11 range | Meaning | Recommendation |
|---|---|---|
| `< 0` | Negative RGA | Pair off-diagonal (MV1→PV2, MV2→PV1); avoid the diagonal entirely |
| `0` to `0.33` | Off-diagonal dominates | Pair off-diagonal |
| `0.33` to `0.67` | Strong interaction (near the 0.5 crossover) | Diagonal pairing, but decoupling strongly recommended |
| `0.67` to `1.5` | **Low interaction** | Diagonal pairing (MV1→PV1, MV2→PV2); loops are close to independent |
| `> 1.5` | Significant interaction | Diagonal pairing, decoupling recommended |

`λ11` near **1** is the ideal case for a diagonal pairing — the two loops
barely interact. The farther `λ11` sits from 1 (in either direction), the
more one loop's action disturbs the other, and the stronger the case for a
decoupler. A near-singular gain matrix (`|det|` too small to trust) is
reported as **ill-conditioned** rather than a division-by-zero — this label
is reserved specifically for that near-singular case, not for `λ11` simply
being far from 1.

### Determinism and safety

Every step test runs against a **JSON round-trip deep copy** of the project
(`PlcProject.fromJson(jsonDecode(jsonEncode(project.toJson())))`), each with
its own fresh `SimRuntime`. The live project, its running scan, and any other
in-memory state are **never touched** — running the analysis while the loop
is live and controlling is safe. The math has no clock and no randomness, so
identical inputs always produce identical gain matrices, `λ11`, and pairing
text.

## The static decoupler

The shipped project's control program (`TwoZone_FBD`) already wires up the
decoupler shape, gains defaulted to zero (fully coupled) until you tune them:

```
Heater_A = LIMIT(0, u_A − d12·u_B, 100)
Heater_B = LIMIT(0, u_B − d21·u_A, 100)
```

`u_A`/`u_B` are each zone's PID output *before* decoupling (exposed as
Internal tags so they're independently observable). `d12`/`d21` are `CONST`
blocks feeding `MUL`/`SUB`/`LIMIT` blocks ahead of the `Heater_A`/`Heater_B`
tag outputs.

To decouple the loops, set the two `CONST` blocks to the RGA-suggested
gains — the Interaction Analysis panel computes and displays them directly:

```
d12 = K12 / K11
d21 = K21 / K22
```

For the shipped demo's identified gains (`K12/K11 ≈ 0.833`, `K21/K22 ≈
0.833`), setting both `d12` and `d21` to `0.833` cancels most of the
cross-zone effect: stepping `SP_A` produces roughly a **51% reduction** in
the peak `Temp_B` disturbance compared to the coupled (`d12 = d21 = 0`) case
(measured in `test/mimo_project_test.dart`: coupled ≈ 13.6 °C peak deviation,
decoupled ≈ 6.7 °C).

The decoupler is intentionally **static** (fixed gains, no dynamics) — it
cancels the steady-state cross-coupling but does not account for the
conduction lag's transient shape. It meaningfully shrinks the disturbance;
it does not eliminate it.

## Summary

| Concept | Where it lives |
|---|---|
| Coupled plant (stacked SimRules) | `mobile/lib/data/default_projects.dart` (`_mimoTwoZoneProject`) |
| Gain-matrix identification + RGA (pure, deterministic) | `mobile/lib/models/interaction_analysis.dart` |
| Interaction Analysis panel (UI) | `mobile/lib/screens/interaction_analysis_screen.dart` |
| Static decoupler (FBD: `MUL`/`SUB`/`LIMIT`) | `TwoZone_FBD` program inside the default project |
| Coverage | `mobile/test/interaction_analysis_test.dart`, `mobile/test/interaction_analysis_screen_test.dart`, `mobile/test/mimo_project_test.dart` |

Multivariable control beyond a static 2×2 decoupler (e.g. dynamic
decoupling, model-predictive control, or plants larger than 2×2) remains a
future enhancement.
