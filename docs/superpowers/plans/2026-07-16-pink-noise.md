# Pink (1/f) Noise Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pink (1/f) noise as a third `noiseDistribution` for the Simulated I/O `noise` behaviour, alongside the shipped `uniform` and `gaussian`.

**Architecture:** A Paul Kellet one-pole cascade in the pure `noise_model.dart` (stateless math; the engine holds the filter state, exactly as `driftStep` works), a new `RuleRuntime.pinkState`, a third case in the engine's noise-distribution dispatch drawing from the existing `noiseState` stream, and a third dropdown item. Purely additive — no persisted schema change, no default project touched.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`. Package `soft_plc_mobile`.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `noise_model.dart`.
- Deterministic/pure: no clock, no `Math.random`; identical seed + inputs → identical output.
- Additive/backward-compatible: `noiseDistribution == 'uniform'` (the default) must reproduce today's EXACT per-scan sequence — the existing golden byte-identity test and the Noisy Level demo integration test stay green, unchanged. Default projects' 20-scan scan-equivalence stays green (no default project altered).
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Key facts (verified)

- `mobile/lib/models/noise_model.dart` (pure, imports only `dart:math`): `kNoiseUniform = 'uniform'`, `kNoiseGaussian = 'gaussian'`, `uniformNoise(u, amplitude) => (2*u-1)*amplitude`, `gaussianNoise(u1,u2,sigma)`, `driftStep(prev,target,alpha)`, `driftAlpha(dtMs,tauSec)`. The file's pattern: **stateless math, caller holds state**.
- `mobile/lib/models/sim_engine.dart`: `class RuleRuntime { int phaseMs; bool pulseOn; int heldMs; final List<double> delayBuf; int? noiseState; int? driftState; double driftValue = 0.0; }`. The `noise` branch is at **line ~223**; its distribution dispatch is:
  ```dart
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
  ```
  followed by the drift term (separate `driftState` stream, seeded `_fnv1a('${rule.id}#drift')`) and `_write(p, rule.targetPath, _clamp(clean + noise + drift, rule.minValue, rule.maxValue));`. Helpers: `_xorshift32(int)`, `_fnv1a(String)`, `_clamp`, `_asDouble`, `_write`.
- `SimRule.noiseDistribution` (String, default `'uniform'`, json `noise_dist`) already exists and round-trips — **no schema change needed**.
- `mobile/lib/screens/simulated_io_screen.dart` Distribution dropdown (~line 353):
  ```dart
  initialValue: r.noiseDistribution == kNoiseGaussian ? kNoiseGaussian : kNoiseUniform,
  decoration: const InputDecoration(labelText: 'Distribution', isDense: true),
  items: const [
    DropdownMenuItem(value: kNoiseUniform, child: Text('Uniform', style: TextStyle(fontSize: 12))),
    DropdownMenuItem(value: kNoiseGaussian, child: Text('Gaussian', style: TextStyle(fontSize: 12))),
  ],
  onChanged: (v) => setDlg(() => r.noiseDistribution = v ?? kNoiseUniform),
  ```
  **GOTCHA:** that `initialValue` coerces anything-not-Gaussian to Uniform — a pink rule would display as "Uniform". Task 3 MUST fix it to reflect pink.
- Existing tests: `mobile/test/noise_model_test.dart` (pure), `mobile/test/sim_noise_drift_test.dart` (engine, incl. the **golden byte-identity sequence** for uniform+no-drift), `mobile/test/noise_measurement_integration_test.dart` (Noisy Level demo guard), `mobile/test/simulated_io_screen_test.dart` (widget).

---

### Task 1: Pure pink math (`pinkStep` / `pinkNoise`)

**Files:**
- Modify: `mobile/lib/models/noise_model.dart`
- Test: `mobile/test/noise_model_test.dart` (add a pink group)

**Interfaces:**
- Produces: `const String kNoisePink = 'pink';`, `const int kPinkStateLen = 7;`, `const double kPinkNormalise = <derived>;`, `double pinkStep(List<double> b, double w)`, `double pinkNoise(List<double> b, double u, double amplitude)`.

- [ ] **Step 1: Write the failing tests**

Add a `group('pink', ...)` to `mobile/test/noise_model_test.dart`:

```dart
List<double> _st() => List<double>.filled(kPinkStateLen, 0.0);

/// Deterministic pseudo-uniform sequence in [0,1] (no Random — pure).
double _u(int i, int n) => ((i * 2654435761) % n) / n;

test('pinkStep is deterministic and evolves the state', () {
  final a = _st();
  final b = _st();
  final ra = pinkStep(a, 0.5);
  final rb = pinkStep(b, 0.5);
  expect(ra, rb);                     // same state + input -> same output
  expect(a.any((x) => x != 0.0), isTrue, reason: 'filter state must evolve');
  expect(a, b);                        // state evolves identically
});

test('pinkStep stays finite and stable over 10k steps', () {
  final b = _st();
  var last = 0.0;
  for (var i = 0; i < 10000; i++) {
    last = pinkStep(b, 2 * _u(i, 9973) - 1);
    expect(last.isFinite, isTrue);
  }
  for (final x in b) {
    expect(x.isFinite, isTrue);
  }
});

test('pinkNoise sample std ~= amplitude (locks kPinkNormalise)', () {
  const n = 20000;
  const amp = 3.0;
  final b = _st();
  final xs = <double>[];
  for (var i = 0; i < n; i++) {
    xs.add(pinkNoise(b, _u(i, 9973), amp));
  }
  final mean = xs.reduce((p, q) => p + q) / n;
  final variance = xs.map((x) => (x - mean) * (x - mean)).reduce((p, q) => p + q) / n;
  final std = math.sqrt(variance);
  expect(std, closeTo(amp, amp * 0.25), reason: 'amplitude must mean output std');
});

test('pinkNoise scales linearly with amplitude', () {
  final b1 = _st();
  final b2 = _st();
  for (var i = 0; i < 50; i++) {
    final x1 = pinkNoise(b1, _u(i, 9973), 1.0);
    final x2 = pinkNoise(b2, _u(i, 9973), 4.0);
    expect(x2, closeTo(x1 * 4.0, 1e-9));
  }
});

test('pink is genuinely 1/f: block-averaging retains more variance than white', () {
  const n = 20000;
  const block = 50;
  final b = _st();
  final pink = <double>[];
  final white = <double>[];
  for (var i = 0; i < n; i++) {
    final u = _u(i, 9973);
    pink.add(pinkNoise(b, u, 1.0));
    white.add(uniformNoise(u, 1.0));
  }
  double retainedRatio(List<double> xs) {
    double varOf(List<double> v) {
      final m = v.reduce((p, q) => p + q) / v.length;
      return v.map((x) => (x - m) * (x - m)).reduce((p, q) => p + q) / v.length;
    }
    final blocks = <double>[];
    for (var i = 0; i + block <= xs.length; i += block) {
      final slice = xs.sublist(i, i + block);
      blocks.add(slice.reduce((p, q) => p + q) / block);
    }
    return varOf(blocks) / varOf(xs);
  }
  // White block-means collapse (~1/block); pink retains far more LF energy.
  expect(retainedRatio(pink), greaterThan(retainedRatio(white) * 5),
      reason: 'pink must retain substantially more low-frequency energy than white');
});
```

(The test file already imports `dart:math as math` and the model; if not, add the imports. `_u` must be pure — no `Random`.)

- [ ] **Step 2: Run — expect FAIL** (`kNoisePink`/`pinkStep`/`pinkNoise` undefined).

Run: `cd mobile && flutter test test/noise_model_test.dart`

- [ ] **Step 3: Implement**

In `mobile/lib/models/noise_model.dart` add:

```dart
const String kNoisePink = 'pink';

/// Filter-state slots a pink generator needs (Kellet b0..b6).
const int kPinkStateLen = 7;

/// Scales the raw Kellet output so that, for white input uniform in [-1,1],
/// the result's standard deviation is ~1.0 — making `amplitude` mean the
/// output's standard deviation, matching [gaussianNoise]'s sigma.
/// Derived empirically (see the std test in noise_model_test.dart, which
/// locks this value).
const double kPinkNormalise = 0.11;  // <- DERIVE: see Step 4

/// Advances the Paul Kellet one-pole cascade one step. [b] is the
/// [kPinkStateLen]-element filter state (mutated in place); [w] is white noise
/// in [-1,1]. Returns the RAW pink sample (before normalisation). All poles
/// have |coefficient| < 1, so the cascade is stable and cannot diverge.
double pinkStep(List<double> b, double w) {
  b[0] = 0.99886 * b[0] + w * 0.0555179;
  b[1] = 0.99332 * b[1] + w * 0.0750759;
  b[2] = 0.96900 * b[2] + w * 0.1538520;
  b[3] = 0.86650 * b[3] + w * 0.3104856;
  b[4] = 0.55000 * b[4] + w * 0.5329522;
  b[5] = -0.7616 * b[5] - w * 0.0168980;
  final pink = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362;
  b[6] = w * 0.115926;
  return pink;
}

/// Pink (1/f) noise normalised so the output's standard deviation ≈
/// [amplitude]. [u] is one uniform draw in [0,1]; [b] is the per-rule filter
/// state (mutated in place).
double pinkNoise(List<double> b, double u, double amplitude) =>
    pinkStep(b, 2 * u - 1) * kPinkNormalise * amplitude;
```

- [ ] **Step 4: DERIVE `kPinkNormalise`**

The placeholder `0.11` is a starting guess. Derive the real value: write a throwaway script/test that runs `pinkStep` over the same 20000-sample pseudo-uniform sequence the std test uses, measures the RAW output's standard deviation `s`, then set `kPinkNormalise = 1 / s` (rounded to ~4 significant figures) and document the measured `s` in the doc comment. Re-run the std test — it must pass with the tolerance in Step 1. Do NOT loosen the test tolerance to fit a wrong constant; fix the constant.

- [ ] **Step 5: Run — expect PASS.**

Run: `cd mobile && flutter test test/noise_model_test.dart`
Expected: all pink tests pass (incl. the std/normalisation guard and the 1/f spectral check), plus the existing uniform/gaussian/drift tests unchanged.

- [ ] **Step 6: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/noise_model.dart test/noise_model_test.dart` (zero warnings; still pure — only `dart:math`).

```bash
git add mobile/lib/models/noise_model.dart mobile/test/noise_model_test.dart
git commit -m "feat(sim): pure pink (1/f) noise — Kellet one-pole cascade, normalised to amplitude=std"
```

---

### Task 2: Engine state + noise-branch case

**Files:**
- Modify: `mobile/lib/models/sim_engine.dart`
- Test: `mobile/test/sim_noise_drift_test.dart` (add pink cases)

**Interfaces:**
- Consumes: `kNoisePink`, `kPinkStateLen`, `pinkNoise` (Task 1).
- Produces: `RuleRuntime.pinkState` (`List<double>`, length `kPinkStateLen`).

- [ ] **Step 1: Write the failing tests**

Add to `mobile/test/sim_noise_drift_test.dart` (reuse its existing `_proj` / `_run` / `_noiseRule` / `_tags` helpers; the file's `_noiseRule` takes a `dist` param):

```dart
test('pink differs from uniform and stays clamped', () {
  final u = _run(_proj([_noiseRule(dist: 'uniform')], _tags()), 30);
  final p = _run(_proj([_noiseRule(dist: 'pink')], _tags()), 30);
  expect(p, isNot(equals(u)));
  for (final v in p) {
    expect(v, inInclusiveRange(-100.0, 100.0));
  }
});

test('pink is deterministic: same seed -> same sequence', () {
  final a = _run(_proj([_noiseRule(dist: 'pink')], _tags()), 25);
  final b = _run(_proj([_noiseRule(dist: 'pink')], _tags()), 25);
  expect(a, b);
});

test('pink + drift stays bounded and deterministic', () {
  final a = _run(_proj([_noiseRule(dist: 'pink', drift: 2.0)], _tags()), 40);
  final b = _run(_proj([_noiseRule(dist: 'pink', drift: 2.0)], _tags()), 40);
  expect(a, b);
  for (final v in a) {
    expect(v.isFinite, isTrue);
    expect(v, inInclusiveRange(-100.0, 100.0));
  }
});
```

(If `_noiseRule`'s signature lacks a `dist`/`drift` param, match the file's real helper. Keep the assertions.)

- [ ] **Step 2: Run — expect FAIL** (pink not handled → behaves as uniform, so `isNot(equals(u))` fails).

Run: `cd mobile && flutter test test/sim_noise_drift_test.dart`

- [ ] **Step 3: Add `RuleRuntime.pinkState`**

In `sim_engine.dart`, add to `RuleRuntime`:
```dart
/// pink: Paul Kellet one-pole cascade filter memory (b0..b6).
final List<double> pinkState = List<double>.filled(kPinkStateLen, 0.0);
```
(`noise_model.dart` is already imported by `sim_engine.dart`.)

- [ ] **Step 4: Add the pink case to the noise dispatch**

In the `noise` branch (~line 223), insert a branch BETWEEN the gaussian test and the uniform `else`:

```dart
} else if (rule.noiseDistribution == kNoisePink) {
  st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
  final u = st.noiseState! / 0xffffffff;
  noise = pinkNoise(st.pinkState, u, a);
} else {
```

Leave the gaussian and uniform paths byte-for-byte unchanged, and leave the drift term and the final `_clamp(clean + noise + drift, ...)` write untouched.

- [ ] **Step 5: Run — expect PASS + byte-identity guards green**

Run: `cd mobile && flutter test test/sim_noise_drift_test.dart test/noise_measurement_integration_test.dart test/serialization_roundtrip_test.dart`
Expected: the new pink cases pass AND the existing **golden uniform byte-identity** test plus the Noisy Level demo guard pass **unchanged** (the uniform path must be untouched).

- [ ] **Step 6: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/sim_engine.dart test/sim_noise_drift_test.dart` (zero warnings).

```bash
git add mobile/lib/models/sim_engine.dart mobile/test/sim_noise_drift_test.dart
git commit -m "feat(sim): pink noise in the engine noise branch (uniform path byte-identical)"
```

---

### Task 3: Editor dropdown + full gate + docs

**Files:**
- Modify: `mobile/lib/screens/simulated_io_screen.dart`
- Test: `mobile/test/simulated_io_screen_test.dart` (extend)
- Docs: `docs/measurement-noise.md`, `ROADMAP.md`, `README.md` (if it enumerates distributions)

**Interfaces:**
- Consumes: `kNoisePink` (Task 1).

- [ ] **Step 1: Write the failing widget test**

Extend `mobile/test/simulated_io_screen_test.dart` (mirror its existing noise-rule editor pump): for a `noise`-behaviour rule, assert the Distribution dropdown offers a **`Pink (1/f)`** item, and that a rule whose `noiseDistribution` is already `'pink'` displays as **Pink (1/f)** (NOT "Uniform" — this catches the `initialValue` coercion gotcha). Assert no overflow at 320 and 1400. FAIL first.

- [ ] **Step 2: Run — expect FAIL.**

Run: `cd mobile && flutter test test/simulated_io_screen_test.dart`

- [ ] **Step 3: Add the dropdown item AND fix the initialValue coercion**

In `simulated_io_screen.dart` (~line 353), the current `initialValue` is:
```dart
initialValue: r.noiseDistribution == kNoiseGaussian ? kNoiseGaussian : kNoiseUniform,
```
This coerces anything-not-Gaussian to Uniform, so a pink rule would show as "Uniform". Replace it with a whitelist that reflects all three values and still falls back safely for an unknown string:
```dart
initialValue: (r.noiseDistribution == kNoiseGaussian || r.noiseDistribution == kNoisePink)
    ? r.noiseDistribution
    : kNoiseUniform,
```
and add the third item:
```dart
DropdownMenuItem(value: kNoisePink, child: Text('Pink (1/f)', style: TextStyle(fontSize: 12))),
```
Leave `onChanged` as-is (`v ?? kNoiseUniform`). Keep the existing styling; no overflow at 320/360/1400.

- [ ] **Step 4: Run — expect PASS.** `cd mobile && flutter test test/simulated_io_screen_test.dart`.

- [ ] **Step 5: Full gate**

Run: `cd mobile && flutter analyze` (whole project, zero warnings); `cd mobile && flutter test` (ALL pass — record the exact count; `gateway_screen_test.dart`'s "Start hosting..." is known-flaky — pre-existing only if it passes in isolation); `cd mobile && flutter build web --release` (builds). Report failures verbatim.

- [ ] **Step 6: Docs**

- `docs/measurement-noise.md`: add a Pink (1/f) section — what 1/f noise is (energy falls with frequency; it wanders on long timescales instead of the memoryless jitter of white/Gaussian, which is what real instrument and process noise usually looks like), that `amplitude` means the output's **standard deviation** (same as Gaussian sigma) so you can switch distributions and keep comparable magnitude, that it composes with drift, and that it's deterministic (per-rule filter state, seeded from the rule id).
- `ROADMAP.md`: note pink noise shipped (the optional Phase 9 follow-on).
- `README.md`: extend the noise/Simulated I/O bullet if it enumerates the distributions.
- No forbidden branding / reverse-engineering wording.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/screens/simulated_io_screen.dart mobile/test/simulated_io_screen_test.dart docs ROADMAP.md README.md
git commit -m "feat(sim): Pink (1/f) distribution option in the noise editor; docs"
```

---

## Self-Review

**Spec coverage:**
- Component 1 pure pink math (`kNoisePink`/`kPinkStateLen`/`kPinkNormalise`/`pinkStep`/`pinkNoise`) → Task 1. ✓
- Component 2 `RuleRuntime.pinkState` → Task 2. ✓
- Component 3 engine noise-branch case (uniform byte-identical) → Task 2. ✓
- Component 4 editor dropdown item → Task 3. ✓
- Normalisation guard, spectral 1/f check, stability, determinism, engine byte-identity, round-trip, widget → Tasks 1-3 tests. ✓
- Full gate + docs → Task 3. ✓

**Placeholder scan:** `kPinkNormalise` ships as a starting guess with an explicit derivation step (Task 1 Step 4: measure the raw std over the same fixed sequence, set the constant to 1/s, document s) and is locked by the std test — a specified procedure, not a TBD. Test snippets carry real assertions; the implementer adjusts only helper signatures to match the real files.

**Type consistency:** `kNoisePink`/`kPinkStateLen`/`pinkStep`/`pinkNoise` (Task 1) consumed by `sim_engine.dart` (Task 2, `RuleRuntime.pinkState` sized by `kPinkStateLen`) and the editor (Task 3). `pinkNoise(b, u, amplitude)` takes ONE uniform (like `uniformNoise`), so the pink engine path uses one `_xorshift32` draw per scan. `SimRule.noiseDistribution` is unchanged (existing field, existing json key).

**Note for the executor:** the binding properties are (a) `uniform` + no drift stays **byte-identical** (the existing golden test and Noisy Level demo guard must pass untouched); (b) `amplitude` ≈ output std for pink (the normalisation guard — derive the constant, don't loosen the test); (c) pink is genuinely 1/f (the block-averaging spectral check); (d) the dropdown reflects a pink rule as Pink, not Uniform (the `initialValue` coercion fix).
