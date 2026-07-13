import 'dart:math' as math;
import 'project_model.dart';
import 'signal_gen.dart';
import 'tag_resolver.dart';

/// Per-run-session signal clock. Reset at run-session boundaries.
class SignalRuntime {
  int elapsedMs = 0;
  void reset() {
    elapsedMs = 0;
  }
}

/// Enabled gens' target paths — the set the logic write path treats read-only.
Set<String> generatedPaths(List<SignalGen> gens) {
  final out = <String>{};
  for (final g in gens) {
    if (g.enabled) {
      out.add(g.targetPath);
    }
  }
  return out;
}

/// FNV-1a 32-bit hash (mirrors the WS14 noise PRNG seed in sim_engine.dart), so
/// `random` is reproducible without `Math.random`.
int _seed(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = (h ^ c) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h == 0 ? 0x1a2b3c4d : h;
}

/// One xorshift32 step.
int _xorshift(int x) {
  x = (x ^ ((x << 13) & 0xffffffff)) & 0xffffffff;
  x = (x ^ (x >> 17)) & 0xffffffff;
  x = (x ^ ((x << 5) & 0xffffffff)) & 0xffffffff;
  return x & 0xffffffff;
}

/// Continuous analog waveform value for [g] at [elapsedMs], in [min,max].
/// (For `counter`/`toggle`/`random` the engine computes discrete values; this
/// covers ramp/sine/square/triangle and is the tested pure surface.)
double signalValueAt(SignalGen g, int elapsedMs) {
  if (g.periodMs <= 0) {
    return g.minValue;
  }
  final span = g.maxValue - g.minValue;
  final frac = (((elapsedMs / g.periodMs) + g.phase) % 1.0 + 1.0) % 1.0;
  switch (g.type) {
    case 'sine':
      return g.minValue + span * (0.5 + 0.5 * math.sin(2 * math.pi * frac));
    case 'square':
      return frac < 0.5 ? g.minValue : g.maxValue;
    case 'triangle':
      return g.minValue + span * (1.0 - (2.0 * frac - 1.0).abs());
    case 'ramp':
    default:
      return g.minValue + span * frac;
  }
}

/// Integer period index for counter/toggle/random: floor(t/period + phase).
int _periodIndex(SignalGen g, int elapsedMs) =>
    ((elapsedMs / g.periodMs) + g.phase).floor();

void applySignalGens(PlcProject p, List<SignalGen> gens, int dtMs, SignalRuntime rt) {
  rt.elapsedMs += dtMs;
  for (final g in gens) {
    if (!g.enabled) {
      continue;
    }
    dynamic value;
    if (g.type == 'counter') {
      if (g.periodMs <= 0) {
        value = g.minValue.round();
      } else {
        final lo = g.minValue.round();
        final hi = g.maxValue.round();
        final n = _periodIndex(g, rt.elapsedMs);
        value = (lo + n).clamp(lo, hi);
      }
    } else if (g.type == 'toggle') {
      final n = g.periodMs <= 0 ? 0 : _periodIndex(g, rt.elapsedMs);
      value = n.isOdd;
    } else if (g.type == 'random') {
      if (g.periodMs <= 0) {
        value = g.minValue;
      } else {
        final n = _periodIndex(g, rt.elapsedMs);
        final r = _xorshift(_seed('${g.id}#$n'));
        final u = r / 0xffffffff; // [0,1]
        value = g.minValue + (g.maxValue - g.minValue) * u;
      }
    } else {
      value = signalValueAt(g, rt.elapsedMs);
    }
    writePath(p, g.targetPath, value);
  }
}
