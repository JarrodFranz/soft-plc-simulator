# Pink (1/f) Noise — Design Spec

**Date:** 2026-07-16
**Status:** Approved (design)
**Workstream:** Phase 9 optional follow-on (the four headline Phase 9 features — valve curves, richer noise + drift, PID auto-tune, MIMO — are shipped).

## Goal

Add spectrally-shaped **pink (1/f) noise** as a third `noiseDistribution` for the Simulated I/O `noise` behaviour, alongside the shipped `uniform` and `gaussian`. Pink is the realistic "process noise" colour — its low-frequency content wanders like real instrument/process noise instead of the memoryless jitter of white noise. Pure, deterministic, and additive: existing rules stay byte-identical.

## Current behaviour (as-found)

- `mobile/lib/models/noise_model.dart` is **stateless math**; the caller holds state:
  - `const String kNoiseUniform = 'uniform'; const String kNoiseGaussian = 'gaussian';`
  - `double uniformNoise(double u, double amplitude) => (2 * u - 1) * amplitude;`
  - `double gaussianNoise(double u1, double u2, double sigma)` (Box-Muller, `u1` guarded to `1e-12`).
  - `double driftStep(double prev, double target, double alpha)` — pure; the engine holds `prev` in `RuleRuntime`.
  - `double driftAlpha(int dtMs, double tauSec)`.
- `mobile/lib/models/sim_engine.dart`: `class RuleRuntime { ... int? noiseState; int? driftState; double driftValue = 0.0; }`. The `noise` branch draws from the per-rule `noiseState` xorshift stream (seeded `_fnv1a(rule.id)`), composes `clean + noise + drift`, and writes `_clamp(clean + noise + drift, minValue, maxValue)`. Drift uses a **separate** stream seeded `_fnv1a('${rule.id}#drift')`.
- `SimRule.noiseDistribution` (String, default `'uniform'`, json `noise_dist`) already exists and round-trips — a new value needs **no** schema change.
- The editor's **Distribution** `DropdownButtonFormField<String>` in `simulated_io_screen.dart`'s `_behaviorParams` `noise` block currently offers Uniform / Gaussian.
- A golden characterization test pins the uniform + no-drift per-scan sequence (the byte-identity guard); the Noisy Level demo integration test guards the real project.

## Non-goals / YAGNI

- No new persisted schema (`noiseDistribution` already exists; `'pink'` is just a new value).
- No default-project change — no scan-equivalence re-baseline.
- No configurable spectral slope (no brown/blue/-3dB-per-octave parameter); pink only.
- No new PRNG — reuse the existing per-rule `noiseState` xorshift stream.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `noise_model.dart`.
- Deterministic/pure: no clock, no `Math.random`; identical seed + inputs → identical output; survives a serialization round-trip.
- Additive/backward-compatible: `noiseDistribution == 'uniform'` (the default) reproduces today's **exact** per-scan sequence — the existing golden guard must stay green; the default projects' 20-scan scan-equivalence stays green.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Component 1 — Pure pink math (`mobile/lib/models/noise_model.dart`, extend)

Follows the file's stateless-math / caller-holds-state pattern (as `driftStep` does).

```dart
const String kNoisePink = 'pink';

/// Number of filter-state slots a pink generator needs (Kellet b0..b6).
const int kPinkStateLen = 7;

/// Normalisation applied to the raw Kellet output so that, for white input
/// uniform in [-1,1], the result's standard deviation is ~1.0 — making
/// `amplitude` mean the output's standard deviation, matching what it means
/// for [gaussianNoise] (sigma). Empirically derived and locked by a
/// statistical test.
const double kPinkNormalise = /* determined at implementation, ~0.10-0.12 */;

/// Advances the Paul Kellet one-pole cascade one step. [b] is the
/// [kPinkStateLen]-element filter state, mutated in place; [w] is white noise
/// in [-1,1]. Returns the RAW pink sample (before normalisation).
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

All poles have |coefficient| < 1, so the cascade is BIBO-stable — the state cannot diverge. `kPinkNormalise` is derived empirically at implementation time (measure the raw output's std over a long pseudo-uniform sequence; set the constant to 1/that) and **locked by the statistical test below**, so a future change to the coefficients or the constant fails loudly.

## Component 2 — Engine state (`sim_engine.dart`)

One additive `RuleRuntime` field, mirroring `driftValue`:

```dart
/// pink: Paul Kellet one-pole cascade filter memory (b0..b6).
final List<double> pinkState = List<double>.filled(kPinkStateLen, 0.0);
```

Reset with the rest of `RuleRuntime` on project switch (`SimRuntime` is recreated).

## Component 3 — Engine wiring (`noise` branch)

Add a third case to the existing distribution dispatch, drawing from the **same `noiseState` stream** (one draw per scan, exactly like uniform):

```dart
if (a > 0) {
  if (rule.noiseDistribution == kNoiseGaussian) {
    // ... unchanged (two draws, Box-Muller)
  } else if (rule.noiseDistribution == kNoisePink) {
    st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
    final u = st.noiseState! / 0xffffffff;
    noise = pinkNoise(st.pinkState, u, a);
  } else {
    // ... unchanged uniform (one draw, uniformNoise(u, a))
  }
}
```

Byte-identity: the `uniform` path is untouched (same single `_xorshift32` draw, same `(2u−1)·a`), so the golden guard and the Noisy Level demo stay green. Pink composes with **drift** for free — drift runs afterwards on its own `driftState` stream and is unaffected. The final write remains `_clamp(clean + noise + drift, minValue, maxValue)`.

## Component 4 — Editor (`simulated_io_screen.dart`)

The existing **Distribution** `DropdownButtonFormField<String>` in the `noise` block gains a third item: **`Pink (1/f)`** with value `kNoisePink`. No other UI change; the Drift amplitude / Drift period controls are orthogonal and already present.

## Data flow

Scan tick → `applySimRules` → `noise` branch reads `clean`, draws one uniform from `noiseState`, advances the per-rule Kellet filter via `pinkNoise` (normalised by `amplitude`), optionally adds drift (separate stream), writes `clamp(clean + noise + drift)`. Editor edits mutate `rule.noiseDistribution` in place + autosave. Filter state lives only in `RuleRuntime`; nothing new persisted.

## Error handling / edge cases

- `amplitude <= 0` → noise term 0 and the filter is **not** advanced (consistent with the existing `a > 0` gate).
- Filter state is stable by construction (all poles |coef| < 1); the final `_clamp` bounds any tail regardless.
- An unknown `noiseDistribution` string still falls through to the `else` (uniform) branch — unchanged.

## Testing

- **Pure (`noise_model_test`, extend):**
  - `pinkStep` is deterministic for a fixed state + input; the state actually evolves (not stuck at zero); output stays finite over 10k steps (stability).
  - **Normalisation guard:** over a long fixed pseudo-uniform sequence, `pinkNoise(...)`'s sample standard deviation ≈ `amplitude` within tolerance (this locks `kPinkNormalise`); and the output scales linearly with `amplitude`.
  - **Spectral check (it's genuinely 1/f, not white):** build a pink series and a white series of equal std; block-average (decimate) each by N; the pink decimated series retains substantially more variance than the white decimated series (white's block means collapse ~1/√N, pink's do not). Assert pink's retained variance ratio clearly exceeds white's.
- **Engine (`sim_noise_drift_test`, extend):** pink produces a different, clamped sequence vs uniform for the same rule/seed; pink is deterministic (same seed → same sequence); pink + drift stays bounded and deterministic; **the existing uniform + no-drift golden byte-identity test stays green unchanged**.
- **Round-trip:** a `SimRule` with `noiseDistribution: 'pink'` survives `toJson`/`fromJson`; default projects' round-trip / 20-scan scan-equivalence unchanged (no default project touched).
- **Widget (`simulated_io_screen_test`, extend):** the Distribution dropdown offers `Pink (1/f)` for a `noise` rule; selecting it sets `rule.noiseDistribution` to `'pink'`; no overflow at 320/360/1400.
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`.

## Files

- **Modify:** `mobile/lib/models/noise_model.dart` (`kNoisePink`, `kPinkStateLen`, `kPinkNormalise`, `pinkStep`, `pinkNoise`), `mobile/lib/models/sim_engine.dart` (`RuleRuntime.pinkState` + the `noise` branch case), `mobile/lib/screens/simulated_io_screen.dart` (dropdown item).
- **Test:** extend `mobile/test/noise_model_test.dart`, `mobile/test/sim_noise_drift_test.dart`, `mobile/test/simulated_io_screen_test.dart`.
- **Docs:** extend `docs/measurement-noise.md` (pink section: what 1/f is, when to use it, that `amplitude` = output std); `ROADMAP.md` note; README bullet if the noise line enumerates distributions.

## Decomposition (plan-time)

~3 tasks: (1) pure `pinkStep`/`pinkNoise` + normalisation + spectral tests; (2) engine `pinkState` + branch case + byte-identity/determinism tests; (3) editor dropdown item + full gate + docs.
