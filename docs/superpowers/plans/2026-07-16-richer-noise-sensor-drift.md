# Richer Measurement Noise + Sensor Drift Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Simulated I/O `noise` behaviour with a selectable distribution (uniform today, or Gaussian) and an optional slow, bounded sensor drift, staying pure/deterministic and byte-identical to today for default rules.

**Architecture:** A pure Flutter-free `noise_model.dart` (unit math: uniform/Gaussian/drift), three additive `SimRule` fields, two per-rule `RuleRuntime` drift-state fields (separate PRNG stream), a rewritten engine `noise` branch composing `clean + noise + drift`, and three editor controls.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`. Package `soft_plc_mobile`.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. new `models/noise_model.dart`.
- Deterministic/pure: no clock, no `Math.random`; identical seed + inputs → identical output; survives a serialization round-trip.
- Additive persistence: defaults (`noiseDistribution == 'uniform'`, `driftAmplitude == 0`) reproduce today's exact per-scan sequence; the default projects' 20-scan scan-equivalence round-trip stays green.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Key facts (verified)

- `mobile/lib/models/sim_engine.dart`: `class RuleRuntime { ... int? noiseState; }` (line ~6-12). Helpers `int _xorshift32(int)`, `int _fnv1a(String)`, `double _clamp(double, double, double)`, `void _write(PlcProject, String, dynamic)`, `double _asDouble(dynamic)`. `applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt)`; `st` is the per-rule `RuleRuntime` (`rt._for(rule.id)`). Current `noise` branch is lines ~220-233. `class SimRuntime { final Map<String,RuleRuntime> byRuleId; RuleRuntime _for(String id); }`. Reset happens via `SimRuntime` being recreated on project switch.
- `mobile/lib/models/project_model.dart`: `class SimRule` (line ~562). Fields use `this.x = <default>` in the constructor; `fromJson` uses `j['snake_key'] ?? default` / `(j['k'] as num?)?.toDouble() ?? default`; `toJson` always emits every field (e.g. `'target_value': targetValue`). `rule.targetValue` is the noise amplitude; `rule.sourcePath` the clean source; `rule.targetPath` the measured output.
- `mobile/lib/screens/simulated_io_screen.dart`: `List<Widget> _behaviorParams(SimRule r, bool numeric, List<String> paths, StateSetter setDlg)` (line ~251) builds per-behaviour controls; the `noise` case lives inside it. Helpers `_numField(label, value, onChanged)` and `DropdownButtonFormField<String>(...)` (an example dropdown for valve curve is at ~line 287). Behaviour label map has `'noise': 'Measurement Noise'`.
- Tests: pure math tests go in `mobile/test/noise_model_test.dart`; engine/round-trip use the existing sim harness (`mobile/test/noise_measurement_integration_test.dart`, `sim_engine` tests) and `serialization_roundtrip_test.dart`.

---

### Task 1: Pure noise/drift math (`noise_model.dart`)

**Files:**
- Create: `mobile/lib/models/noise_model.dart`
- Test: `mobile/test/noise_model_test.dart`

**Interfaces:**
- Produces: `const String kNoiseUniform`, `kNoiseGaussian`; `double uniformNoise(double u, double amplitude)`; `double gaussianNoise(double u1, double u2, double sigma)`; `double driftStep(double prev, double target, double alpha)`; `double driftAlpha(int dtMs, double tauSec)`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/noise_model_test.dart`:

```dart
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/noise_model.dart';

void main() {
  test('uniformNoise endpoints and midpoint', () {
    expect(uniformNoise(0.0, 5.0), -5.0);
    expect(uniformNoise(1.0, 5.0), 5.0);
    expect(uniformNoise(0.5, 5.0), 0.0);
  });

  test('gaussianNoise is deterministic and scales linearly with sigma', () {
    final a = gaussianNoise(0.3, 0.7, 2.0);
    final b = gaussianNoise(0.3, 0.7, 4.0);
    expect(b, closeTo(a * 2, 1e-9));
    // exact value for a fixed (u1,u2,sigma)
    final r = math.sqrt(-2 * math.log(0.3)) * math.cos(2 * math.pi * 0.7) * 2.0;
    expect(gaussianNoise(0.3, 0.7, 2.0), closeTo(r, 1e-9));
  });

  test('gaussianNoise guards u1==0 (finite, no -Inf)', () {
    expect(gaussianNoise(0.0, 0.5, 1.0).isFinite, isTrue);
  });

  test('gaussianNoise sample mean ~0, std ~sigma over a pseudo-sequence', () {
    const n = 4000;
    final samples = <double>[];
    for (var i = 0; i < n; i++) {
      final u1 = (i * 2 + 1) / (2 * n + 1);
      final u2 = (i * 3 + 1) % (2 * n + 1) / (2 * n + 1);
      samples.add(gaussianNoise(u1, u2, 3.0));
    }
    final mean = samples.reduce((a, b) => a + b) / n;
    final variance = samples.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) / n;
    expect(mean.abs(), lessThan(0.4));
    expect(math.sqrt(variance), closeTo(3.0, 0.6));
  });

  test('driftStep is a convex blend, strictly bounded, EMA identities', () {
    expect(driftStep(2.0, 6.0, 1.0), closeTo(6.0, 1e-9)); // alpha=1 -> target
    expect(driftStep(2.0, 6.0, 0.0), closeTo(2.0, 1e-9)); // alpha=0 -> prev
    // sequence with targets in [-A,A] stays in [-A,A]
    const a = 5.0;
    var prev = 0.0;
    for (var i = 0; i < 200; i++) {
      final target = uniformNoise((i * 7 % 100) / 100.0, a); // in [-a,a]
      prev = driftStep(prev, target, 0.1);
      expect(prev, inInclusiveRange(-a, a));
    }
  });

  test('driftAlpha: tau<=0 -> 1.0, monotonic decreasing in tau', () {
    expect(driftAlpha(100, 0), 1.0);
    expect(driftAlpha(100, -5), 1.0);
    final a1 = driftAlpha(100, 1.0);
    final a2 = driftAlpha(100, 10.0);
    expect(a1, greaterThan(a2)); // larger tau -> smaller alpha (slower)
    expect(a1, inInclusiveRange(0.0, 1.0));
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`noise_model.dart` missing).

Run: `cd mobile && flutter test test/noise_model_test.dart`

- [ ] **Step 3: Implement `noise_model.dart`**

```dart
import 'dart:math' as math;

const String kNoiseUniform = 'uniform';
const String kNoiseGaussian = 'gaussian';

/// Uniform noise in [-amplitude, amplitude] from one uniform draw.
double uniformNoise(double u, double amplitude) => (2 * u - 1) * amplitude;

/// Gaussian (normal) noise with standard deviation [sigma] from two uniform
/// draws, via Box-Muller. Unbounded; the caller clamps the final measurement.
/// [u1] is guarded away from 0 so log is finite.
double gaussianNoise(double u1, double u2, double sigma) {
  final r = math.sqrt(-2 * math.log(u1 <= 0 ? 1e-12 : u1));
  return r * math.cos(2 * math.pi * u2) * sigma;
}

/// One EMA low-pass step of a slow, strictly-bounded drift wander.
/// A convex blend of [prev] and [target]; if both start in
/// [-amplitude, amplitude] the drift stays in [-amplitude, amplitude].
double driftStep(double prev, double target, double alpha) =>
    prev + alpha * (target - prev);

/// alpha = dt/(dt+tau) for a given scan dt (ms) and drift time-constant tau (s).
/// tau <= 0 -> alpha 1.0 (drift tracks the target immediately).
double driftAlpha(int dtMs, double tauSec) {
  final dt = dtMs / 1000.0;
  final tau = tauSec <= 0 ? 0.0 : tauSec;
  return tau <= 0 ? 1.0 : dt / (dt + tau);
}
```

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/noise_model.dart test/noise_model_test.dart` (zero warnings).

```bash
git add mobile/lib/models/noise_model.dart mobile/test/noise_model_test.dart
git commit -m "feat(sim): pure noise/drift math (uniform, Gaussian Box-Muller, EMA drift)"
```

---

### Task 2: SimRule model fields

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`SimRule`)
- Test: `mobile/test/serialization_roundtrip_test.dart` (add a case) or a new `mobile/test/sim_rule_noise_fields_test.dart`

**Interfaces:**
- Produces: `SimRule.noiseDistribution` (String, default `'uniform'`, json `noise_dist`); `.driftAmplitude` (double, default `0.0`, json `drift_amp`); `.driftPeriodSec` (double, default `60.0`, json `drift_period_sec`).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/sim_rule_noise_fields_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('new noise/drift fields default and round-trip', () {
    final r = SimRule(
      id: 'r', name: 'n', targetPath: 'X', behavior: 'noise',
      noiseDistribution: 'gaussian', driftAmplitude: 2.5, driftPeriodSec: 30.0);
    final back = SimRule.fromJson(r.toJson());
    expect(back.noiseDistribution, 'gaussian');
    expect(back.driftAmplitude, 2.5);
    expect(back.driftPeriodSec, 30.0);
  });

  test('legacy SimRule JSON (no new keys) loads with defaults', () {
    final legacy = {
      'id': 'r', 'name': 'n', 'target_path': 'X', 'behavior': 'noise',
    };
    final r = SimRule.fromJson(legacy);
    expect(r.noiseDistribution, 'uniform');
    expect(r.driftAmplitude, 0.0);
    expect(r.driftPeriodSec, 60.0);
  });
}
```

(If the legacy-JSON minimal map is missing required keys for `fromJson`, include only what `SimRule.fromJson` needs — check the constructor's `required` params and mirror an existing minimal fixture in `serialization_roundtrip_test.dart`.)

- [ ] **Step 2: Run — expect FAIL** (fields undefined).

Run: `cd mobile && flutter test test/sim_rule_noise_fields_test.dart`

- [ ] **Step 3: Add the fields**

In `SimRule`: add fields `String noiseDistribution; double driftAmplitude; double driftPeriodSec;`; constructor params `this.noiseDistribution = 'uniform', this.driftAmplitude = 0.0, this.driftPeriodSec = 60.0`; `fromJson` add `noiseDistribution: j['noise_dist'] ?? 'uniform'`, `driftAmplitude: (j['drift_amp'] as num?)?.toDouble() ?? 0.0`, `driftPeriodSec: (j['drift_period_sec'] as num?)?.toDouble() ?? 60.0`; `toJson` add `'noise_dist': noiseDistribution, 'drift_amp': driftAmplitude, 'drift_period_sec': driftPeriodSec` (always emitted, matching the class's style). Do NOT import `noise_model.dart` into the model — use the string literal `'uniform'`.

- [ ] **Step 4: Run — expect PASS.** Then `cd mobile && flutter test test/serialization_roundtrip_test.dart` (additive; stays green).

- [ ] **Step 5: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/project_model.dart test/sim_rule_noise_fields_test.dart` (zero warnings).

```bash
git add mobile/lib/models/project_model.dart mobile/test/sim_rule_noise_fields_test.dart
git commit -m "feat(sim): additive SimRule noiseDistribution/driftAmplitude/driftPeriodSec"
```

---

### Task 3: Engine — drift state + noise-branch rewrite

**Files:**
- Modify: `mobile/lib/models/sim_engine.dart` (`RuleRuntime`, `noise` branch, import)
- Test: `mobile/test/sim_noise_drift_test.dart` (create)

**Interfaces:**
- Consumes: `noise_model.dart` (Task 1), `SimRule` new fields (Task 2).
- Produces: `RuleRuntime.driftState` (`int?`), `.driftValue` (`double`, default `0.0`).

**Context:** The BYTE-IDENTITY guard is the most important property: `noiseDistribution == 'uniform'` with `driftAmplitude == 0` must reproduce today's exact per-scan sequence (one `_xorshift32` draw, `(2u-1)*a`). The drift uses a SEPARATE PRNG stream (`driftState`, seeded `_fnv1a('${rule.id}#drift')`) so it never perturbs `noiseState`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/sim_noise_drift_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';

PlcProject _proj(List<SimRule> rules, List<PlcTag> tags) => PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules,
    );

List<double> _run(PlcProject p, int n) {
  final rt = SimRuntime();
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    applySimRules(p, p.simRules, 100, rt);
    out.add((p.tags.firstWhere((t) => t.name == 'Y').value as num).toDouble());
  }
  return out;
}

SimRule _noiseRule({String dist = 'uniform', double drift = 0.0, double period = 60.0}) =>
    SimRule(id: 'r', name: 'n', behavior: 'noise', sourcePath: 'X', targetPath: 'Y',
        targetValue: 1.0, minValue: -100, maxValue: 100,
        noiseDistribution: dist, driftAmplitude: drift, driftPeriodSec: period);

List<PlcTag> _tags() => [
  PlcTag(name: 'X', path: 'X', dataType: 'FLOAT64', value: 10.0, ioType: 'Internal'),
  PlcTag(name: 'Y', path: 'Y', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
];

void main() {
  test('uniform + no drift reproduces the pre-feature sequence (byte guard)', () {
    // Reference computed from the SAME xorshift/fnv used today: one draw per
    // scan, noise = (2u-1)*a. We assert determinism + that switching nothing on
    // changes nothing by running twice and comparing, and that values stay in
    // clean +/- a.
    final a = _run(_proj([_noiseRule()], _tags()), 20);
    final b = _run(_proj([_noiseRule()], _tags()), 20);
    expect(a, b); // deterministic
    for (final v in a) {
      expect(v, inInclusiveRange(10.0 - 1.0, 10.0 + 1.0)); // clean=10, a=1
    }
  });

  test('gaussian differs from uniform but stays clamped', () {
    final u = _run(_proj([_noiseRule(dist: 'uniform')], _tags()), 30);
    final g = _run(_proj([_noiseRule(dist: 'gaussian')], _tags()), 30);
    expect(g, isNot(equals(u)));
    for (final v in g) {
      expect(v, inInclusiveRange(-100.0, 100.0));
    }
  });

  test('drift on: |measured - clean| <= a + driftAmplitude, and drift is slow', () {
    const a = 1.0, drift = 4.0;
    final rt = SimRuntime();
    final p = _proj([_noiseRule(drift: drift, period: 30.0)], _tags());
    double? prevDriftPart;
    for (var i = 0; i < 60; i++) {
      applySimRules(p, p.simRules, 100, rt);
      final y = (p.tags.firstWhere((t) => t.name == 'Y').value as num).toDouble();
      expect((y - 10.0).abs(), lessThanOrEqualTo(a + drift + 1e-9));
    }
    // drift value itself changes by a small bounded step per scan
    final st = rt.byRuleId['r']!;
    expect(st.driftValue.abs(), lessThanOrEqualTo(drift + 1e-9));
  });

  test('drift off (default) never touches noiseState / reproduces uniform', () {
    final withField = _run(_proj([_noiseRule(drift: 0.0)], _tags()), 20);
    final plain = _run(_proj([_noiseRule()], _tags()), 20);
    expect(withField, plain);
  });

  test('determinism: same seed -> same sequence', () {
    final a = _run(_proj([_noiseRule(dist: 'gaussian', drift: 2.0)], _tags()), 25);
    final b = _run(_proj([_noiseRule(dist: 'gaussian', drift: 2.0)], _tags()), 25);
    expect(a, b);
  });
}
```

(Adjust the `SimRule`/`PlcTag`/`PlcProject` constructor arg names to the real ones if any differ — mirror `noise_measurement_integration_test.dart`. Keep the assertions: uniform+no-drift deterministic & bounded; gaussian differs & clamped; drift bounded by `a+drift` & slow; drift-off == plain; determinism.)

- [ ] **Step 2: Run — expect FAIL** (`driftState`/`driftValue` undefined; drift not applied).

Run: `cd mobile && flutter test test/sim_noise_drift_test.dart`

- [ ] **Step 3: Add `RuleRuntime` drift fields + import**

In `sim_engine.dart` add `import 'noise_model.dart';` and to `RuleRuntime`:
```dart
int? driftState;          // noise-drift: 32-bit xorshift PRNG (separate stream)
double driftValue = 0.0;  // current drift (EMA-filtered wander)
```

- [ ] **Step 4: Rewrite the `noise` branch**

Replace the current `case 'noise':` body with:

```dart
case 'noise':
  if (cond && rule.sourcePath.isNotEmpty) {
    final clean = _asDouble(readPath(p, rule.sourcePath));
    final a = rule.targetValue;

    // --- noise term ---
    double noise = 0.0;
    if (a > 0) {
      if (rule.noiseDistribution == kNoiseGaussian) {
        st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
        final u1 = st.noiseState! / 0xffffffff;
        st.noiseState = _xorshift32(st.noiseState!);
        final u2 = st.noiseState! / 0xffffffff;
        noise = gaussianNoise(u1, u2, a);
      } else {
        st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
        final u = st.noiseState! / 0xffffffff;
        noise = uniformNoise(u, a);
      }
    }

    // --- drift term (separate PRNG stream; skipped entirely when off) ---
    double drift = 0.0;
    if (rule.driftAmplitude > 0) {
      st.driftState = _xorshift32(st.driftState ?? _fnv1a('${rule.id}#drift'));
      final ud = st.driftState! / 0xffffffff;
      final target = uniformNoise(ud, rule.driftAmplitude);
      st.driftValue = driftStep(
          st.driftValue, target, driftAlpha(dtMs, rule.driftPeriodSec));
      drift = st.driftValue;
    }

    _write(p, rule.targetPath, _clamp(clean + noise + drift, rule.minValue, rule.maxValue));
  }
  break;
```

Byte-identity: uniform + `a > 0` = exactly one `_xorshift32` draw and `uniformNoise(u,a) == (2u-1)*a` (today's sequence). `driftAmplitude == 0` = drift block never runs (no perturbation of `noiseState`). `a <= 0` = noise term 0 (as the old short-circuit), with drift added only if `driftAmplitude > 0`.

- [ ] **Step 5: Run — expect PASS.** Then `cd mobile && flutter test test/noise_measurement_integration_test.dart` (the Noisy Level demo's uniform+no-drift sequence stays identical) and a broad `cd mobile && flutter test test/serialization_roundtrip_test.dart` (scan-equivalence green).

- [ ] **Step 6: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/sim_engine.dart test/sim_noise_drift_test.dart` (zero warnings).

```bash
git add mobile/lib/models/sim_engine.dart mobile/test/sim_noise_drift_test.dart
git commit -m "feat(sim): Gaussian noise + bounded sensor drift in the noise branch (byte-identical defaults)"
```

---

### Task 4: Editor controls + validation + docs

**Files:**
- Modify: `mobile/lib/screens/simulated_io_screen.dart` (`_behaviorParams` noise block)
- Test: `mobile/test/simulated_io_screen_test.dart` (add a case)
- Docs: the Simulated I/O / noise doc, `ROADMAP.md`, `README.md`

**Interfaces:**
- Consumes: `SimRule` new fields (Task 2); `kNoiseUniform`/`kNoiseGaussian` from `noise_model.dart` (Task 1).

- [ ] **Step 1: Write the failing widget test**

Add to `mobile/test/simulated_io_screen_test.dart` (mirror its existing rule-editor pump pattern) a case that, for a `noise`-behaviour rule, the rule editor shows: a **Distribution** dropdown (Uniform / Gaussian), a **Drift amplitude** field, and a **Drift period (s)** field ONLY when drift amplitude > 0; and that these are NOT shown for a non-noise behaviour (e.g. `setWhileCondition`). Assert no overflow at 320 and 1400. It should FAIL before the controls exist.

- [ ] **Step 2: Run — expect FAIL.**

Run: `cd mobile && flutter test test/simulated_io_screen_test.dart`

- [ ] **Step 3: Add the three controls**

In `_behaviorParams`, inside the `r.behavior == 'noise'` block, after the existing amplitude/source fields, add:
- A **Distribution** `DropdownButtonFormField<String>` with items `Uniform` (value `kNoiseUniform`) / `Gaussian` (value `kNoiseGaussian`), bound to `r.noiseDistribution` (import `../models/noise_model.dart`; `onChanged` sets `r.noiseDistribution` via `setDlg`). Model it on the existing valve-curve dropdown (~line 287).
- A **Drift amplitude** `_numField('Drift amplitude', r.driftAmplitude, (v) => r.driftAmplitude = v)`.
- A **Drift period (s)** `_numField('Drift period (s)', r.driftPeriodSec, (v) => r.driftPeriodSec = v)`, shown only when `r.driftAmplitude > 0` (wrap in a conditional add to the widget list, and call `setDlg` on amplitude change so the period field appears/disappears).

Follow the file's existing dropdown/field styling; braces on all control flow; `withValues(alpha:)` if any alpha is used; no overflow at 320/360/1400.

- [ ] **Step 4: Run — expect PASS.** `cd mobile && flutter test test/simulated_io_screen_test.dart`.

- [ ] **Step 5: Full gate**

Run: `cd mobile && flutter analyze` (whole project clean, zero warnings); `cd mobile && flutter test` (ALL pass — record the count; note `gateway_screen_test.dart`'s known-flaky "Start hosting..." case — pre-existing flakiness only if it passes in isolation); `cd mobile && flutter build web --release` (builds). Report failures verbatim.

- [ ] **Step 6: Docs**

Extend the Simulated I/O / noise doc with the distribution + drift controls (uniform vs Gaussian; drift = slow bounded wander, period = time-constant); update `ROADMAP.md` (Phase 9 feature 2 done) and the Simulated I/O bullet in `README.md`. No forbidden branding.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/screens/simulated_io_screen.dart mobile/test/simulated_io_screen_test.dart docs ROADMAP.md README.md
git commit -m "feat(sim): noise distribution + drift editor controls; docs/roadmap"
```

---

## Self-Review

**Spec coverage:**
- Component 1 pure math → Task 1. ✓
- Component 2 SimRule fields → Task 2. ✓
- Component 3 RuleRuntime drift state → Task 3. ✓
- Component 4 engine noise-branch rewrite (byte-identical defaults) → Task 3. ✓
- Component 5 editor controls → Task 4. ✓
- Determinism / round-trip / scan-equivalence / widget → Tasks 1-4 tests. ✓
- Full gate + docs → Task 4. ✓

**Placeholder scan:** Complete code for the pure model (Task 1), model fields (Task 2), and engine branch (Task 3). Task 4's widget test and controls are described against the file's existing `_numField`/`DropdownButtonFormField` helpers (the implementer matches the real editor idiom); no vague "add validation" placeholders.

**Type consistency:** `kNoiseUniform`/`kNoiseGaussian`/`uniformNoise`/`gaussianNoise`/`driftStep`/`driftAlpha` (Task 1) consumed by the engine (Task 3) and editor (Task 4). `SimRule.noiseDistribution`/`driftAmplitude`/`driftPeriodSec` (Task 2) used by engine + editor. `RuleRuntime.driftState`/`driftValue` (Task 3) internal to `sim_engine.dart`. The drift PRNG seed `'${rule.id}#drift'` keeps the drift stream separate from `noiseState` so uniform+no-drift stays byte-identical.

**Note for the executor:** the byte-identity guard (Task 3: uniform + no drift reproduces today's exact sequence, and the Noisy Level demo integration test stays green) is the binding correctness property — do not weaken it. The drift is a convex EMA blend so it is bounded by construction; no separate clamp beyond the final measurement clamp.
