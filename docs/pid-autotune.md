# PID Auto-Tune (Relay Feedback)

This document covers the in-app PID auto-tuner: the relay-feedback experiment
that estimates a loop's ultimate gain and period, the classic tuning rules
computed from those two numbers, how to run it against the built-in "Tank
Level PID Control" demo, and how an accepted result is applied back onto a
loop's gain sources.

Implementation: `mobile/lib/models/pid_autotune.dart` (`RelayTuneParams`,
`TunePoint`, `RelayTuneResult`, `relayAutoTune`, `TuningSuggestion`,
`tuningRules`, `PidLoopBinding`, `resolvePidLoop`) and
`mobile/lib/screens/pid_autotune_screen.dart` (the **PID Auto-Tune** panel:
loop picker, experiment parameters, oscillation trend, and the Apply table).

## What the relay-feedback method does

Manually tuning a PID loop by trial and error is slow, and a full step-test
identification requires knowing the process model. The **relay-feedback**
(Åström–Hägglund) method sidesteps both: instead of guessing gains directly,
it drives the loop's control output with a simple two-level bang-bang relay
around the operating point and lets the process itself oscillate into a
sustained limit cycle. That limit cycle's amplitude and period are enough to
estimate the loop's ultimate gain and ultimate period without ever forming an
explicit process model.

The panel implements this as a closed-loop simulation, one scan at a time:

1. **Relay switching.** Each scan, the process value (PV) is compared against
   the target setpoint with a hysteresis band. Once PV crosses above
   `setpoint + hysteresis`, the relay output drops to its low level; once PV
   crosses below `setpoint - hysteresis`, it snaps back to its high level.
   This bang-bang drive is written to the control value (CV) and the
   simulated process is stepped forward exactly like a normal scan.
2. **Limit-cycle detection.** Every relay switch closes out a half-cycle, and
   the engine records that half-cycle's PV extremum (peak or trough) and, on
   every low-to-high switch, the elapsed time. Consecutive (peak, trough)
   pairs give a run of full-cycle amplitudes; consecutive rising-switch times
   give a run of periods.
3. **Convergence check.** The engine only accepts a result once the most
   recent run of cycles (`settleCycles`, 3 by default) has both period and
   amplitude spread — `(max − min) / mean` — within a 5% tolerance. If the
   relay never completes enough full cycles, or the cycles it does complete
   haven't settled to within that tolerance, the run reports **not
   converged** with a specific warning message instead of a fabricated
   answer.
4. **Ku / Pu.** Once converged, the ultimate period `Pu` is the mean of the
   settled periods, and the ultimate gain is the standard relay-feedback
   formula:

   ```
   Ku = 4d / (π·a)
   ```

   where `d` is the relay's half-amplitude (`(relayHigh − relayLow) / 2`) and
   `a` is the mean settled oscillation amplitude of PV.

Every sample taken during the run — PV and CV at each scan — is kept in
`RelayTuneResult.trace` regardless of whether the run converges, so the panel
can always render the oscillation as a trend even on a failed attempt (useful
for judging whether the relay levels or hysteresis need adjusting).

## Tuning rules offered

Once `Ku`/`Pu` are known, `tuningRules` computes six classic gain sets from
three families, each with a PID and a PI variant (`Ki = Kp / Ti`, guarded
against `Ti ≤ 0`; `Kd = Kp · Td`, and PI variants always report `Kd = 0`):

| Rule | Form | Kp | Ti | Td |
|---|---|---|---|---|
| Ziegler-Nichols | PID | `0.6·Ku` | `0.5·Pu` | `0.125·Pu` |
| Ziegler-Nichols | PI | `0.45·Ku` | `0.833·Pu` | — |
| Tyreus-Luyben | PID | `Ku/2.2` | `2.2·Pu` | `Pu/6.3` |
| Tyreus-Luyben | PI | `Ku/3.2` | `2.2·Pu` | — |
| ZN no-overshoot | PID | `0.2·Ku` | `0.5·Pu` | `Pu/3.0` |
| ZN no-overshoot | PI | `0.13·Ku` | `0.5·Pu` | — |

- **Ziegler-Nichols** is the original 1942 quarter-amplitude-decay rule —
  fast but noticeably underdamped.
- **Tyreus-Luyben** trades some speed for a much better damping ratio; a
  common choice when overshoot matters more than settling time.
- **ZN no-overshoot** is the most conservative of the three, aimed at loops
  where any overshoot past setpoint is undesirable (e.g. a level that must
  never overfill).

The gains reported are the **parallel form** (`Kp`, `Ki`, `Kd` feeding
`error`, `∫error`, `Δerror` directly), matching the PID function block's own
implementation (`fbd_exec.dart`), so a suggested row can be applied straight
onto a loop without any unit conversion.

## Running it on the "Tank Level PID Control" demo

The default project **Tank Level PID Control** is a single closed loop: a
`PID` FBD block reads `Level_PV` (process value) and `Level_SP` (setpoint,
60%), and drives `Valve_CV` (0–100%), which scales the tank's inflow against
a constant outflow disturbance.

To auto-tune it:

1. Open the **PID Auto-Tune** section from the project's navigation (the
   `Icons.tune` entry, alongside Simulated I/O and Outbound Protocols).
2. In the **PID Loop** dropdown, select `Level PID (p_pid) — LevelPID_FBD`.
   The panel resolves the loop's wiring automatically — PV/CV tag paths and
   the current setpoint are pre-filled from the FBD graph.
3. In **Relay Experiment**, set the relay high/low around the loop's normal
   operating range for `Valve_CV` (for example, high `80`, low `10`, rather
   than the full `0`–`100` swing, so the oscillation stays inside a realistic
   valve-travel band) and leave the setpoint at `60`. Hysteresis defaults to
   `0.5`; step `dt` defaults to the project's scan period.
4. Press **Run Auto-Tune**. The experiment runs to completion synchronously
   (it does not need the live scan loop) and the panel redraws with the
   recorded PV/CV trend.
5. Review the result:
   - If converged, a green banner reports `Ku`, `Pu` (in seconds), and the
     measured oscillation amplitude, followed by the six-row **Suggested
     Gains** table.
   - If not converged, an amber banner explains why (not enough cycles
     completed, or the cycles haven't settled) — widen `Max duration (scans)`
     or revisit the relay levels/hysteresis and re-run.
6. Press **Apply** on a row to write that rule's `Kp`/`Ki`/`Kd` onto the
   loop's gain sources.

## Deep-copy isolation and determinism

`relayAutoTune` takes a JSON round-trip deep copy of the whole project
(`PlcProject.fromJson(jsonDecode(jsonEncode(project.toJson())))`) before doing
anything else, and every relay step operates only on that copy's simulated
process — the copy is discarded once the run finishes. **The live loop,
its tags, and the running scan are never touched by the experiment itself**;
a project mid-Run keeps regulating exactly as it was while a tune is in
progress, and a converged/failed result never depends on what the live scan
happens to be doing at the same moment.

The experiment is also fully deterministic: it steps the copied process on
its own fixed-size loop (no wall-clock timer, no external randomness), so
running the same params against the same project always produces the same
trace, the same convergence verdict, and the same `Ku`/`Pu`.

## Applying gains

Pressing **Apply** on a suggested row is the only step that touches the live
project. `resolvePidLoop` walks the FBD wiring backwards from the `PID`
block's `KP`/`KI`/`KD` input pins to find whichever upstream block feeds each
gain — typically a `CONST` block (a literal, as in the Tank Level demo's
`p_kp`/`p_ki`/`p_kd`), but a `TAG_INPUT` block is also supported. Applying a
row then writes the new value directly into that source:

- A `CONST` source has its literal `tagBinding` replaced with the formatted
  gain value.
- A `TAG_INPUT` source has the underlying tag written via the normal
  path-resolver write path.

A PI-form row deliberately leaves any wired `Kd` source untouched (it never
zeroes an existing derivative gain), and a gain whose pin has no resolvable
upstream source is reported as skipped rather than silently dropped. A
snackbar summarizes exactly what was applied and what was skipped so the
change is always visible before you go back online with the loop.
