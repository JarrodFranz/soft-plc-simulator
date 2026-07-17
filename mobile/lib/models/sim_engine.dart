import 'noise_model.dart';
import 'project_model.dart';
import 'tag_resolver.dart';
import 'valve_curve.dart';

/// Per-rule timing state carried across scans.
class RuleRuntime {
  int phaseMs = 0;      // pulse: elapsed within current on/off phase
  bool pulseOn = true;  // pulse: current phase is the on-phase
  int heldMs = 0;       // delayedSet: how long the condition has held
  final List<double> delayBuf = <double>[]; // deadTime: FIFO of source samples
  int? noiseState;      // noise: 32-bit xorshift PRNG state, lazily seeded
  int? driftState;          // noise-drift: 32-bit xorshift PRNG (separate stream)
  double driftValue = 0.0;  // current drift (EMA-filtered wander)
  /// pink: Paul Kellet one-pole cascade filter memory (b0..b6).
  final List<double> pinkState = List<double>.filled(kPinkStateLen, 0.0);
}

class SimRuntime {
  final Map<String, RuleRuntime> byRuleId = {};
  RuleRuntime _for(String id) => byRuleId.putIfAbsent(id, () => RuleRuntime());
}

double _asDouble(dynamic v) => v is num ? v.toDouble() : (v == true ? 1.0 : 0.0);

bool _compare(dynamic left, String cmp, dynamic right) {
  // Bool equality
  if (left is bool || right is bool) {
    final l = left == true;
    final r = right == true;
    if (cmp == '==') {
      return l == r;
    }
    if (cmp == '!=') {
      return l != r;
    }
    return false;
  }
  final l = _asDouble(left);
  final r = _asDouble(right);
  switch (cmp) {
    case '>':
      return l > r;
    case '<':
      return l < r;
    case '>=':
      return l >= r;
    case '<=':
      return l <= r;
    case '==':
      return l == r;
    case '!=':
      return l != r;
    default:
      return false;
  }
}

dynamic _operandValue(PlcProject p, SimClause c) {
  if (c.operandKind == 'tag') {
    return readPath(p, c.operand);
  }
  final t = c.operand.trim().toLowerCase();
  if (t == 'true') {
    return true;
  }
  if (t == 'false') {
    return false;
  }
  return double.tryParse(c.operand.trim()) ?? 0.0;
}

/// AND of all clauses; empty list is always true.
bool evalCondition(PlcProject p, List<SimClause> clauses) {
  for (final c in clauses) {
    final left = readPath(p, c.leftPath);
    if (!_compare(left, c.comparator, _operandValue(p, c))) {
      return false;
    }
  }
  return true;
}

PlcTag? _rootTagOf(PlcProject p, String path) {
  final rootName = path.split('.').first.split('[').first;
  for (final t in p.tags) {
    if (t.name == rootName) {
      return t;
    }
  }
  return null;
}

void _write(PlcProject p, String path, dynamic value) {
  final root = _rootTagOf(p, path);
  if (root != null && root.isForced && root.name == path) {
    return; // forcing wins
  }
  writePath(p, path, value);
}

double _clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

/// Stable FNV-1a hash of [s], used to seed the per-rule [noise] PRNG from
/// [SimRule.id]. Deliberately NOT Dart's `String.hashCode` (which is not
/// guaranteed stable across runs) — this keeps the seed (and therefore the
/// noise sequence) reproducible within a run and across a serialization
/// round-trip.
int _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = (h ^ c) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h == 0 ? 0x1a2b3c4d : h; // xorshift needs a non-zero seed
}

/// One step of a 32-bit xorshift PRNG.
int _xorshift32(int x) {
  x = (x ^ ((x << 13) & 0xffffffff)) & 0xffffffff;
  x = (x ^ (x >> 17)) & 0xffffffff;
  x = (x ^ ((x << 5) & 0xffffffff)) & 0xffffffff;
  return x & 0xffffffff;
}

/// Analog gain for [integrate]/[ramp]: scales the per-second rate by
/// `source / refValue` when a driving tag is set (1.0 — i.e. unscaled — when
/// [SimRule.sourcePath] is empty or [SimRule.refValue] is zero), routed
/// through the rule's valve characteristic ([SimRule.valveCurve]).
double _gain(PlcProject p, SimRule r) {
  if (r.sourcePath.isEmpty || r.refValue == 0) {
    return 1.0;
  }
  final fraction = _asDouble(readPath(p, r.sourcePath)) / r.refValue;
  return valveCurveGain(r.valveCurve, fraction);
}

void applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt) {
  final dt = dtMs / 1000.0;
  for (final rule in rules) {
    if (!rule.enabled) {
      continue;
    }
    final cond = evalCondition(p, rule.condition);
    final st = rt._for(rule.id);
    switch (rule.behavior) {
      case 'setWhileCondition':
        _write(p, rule.targetPath, cond);
        break;
      case 'delayedSet':
        if (cond) {
          st.heldMs += dtMs;
          _write(p, rule.targetPath, st.heldMs >= rule.delayMs);
        } else {
          st.heldMs = 0;
          _write(p, rule.targetPath, false);
        }
        break;
      case 'pulse':
        if (!cond) {
          st.phaseMs = 0;
          st.pulseOn = true;
          _write(p, rule.targetPath, false);
          break;
        }
        st.phaseMs += dtMs;
        final limit = st.pulseOn ? rule.onMs : rule.offMs;
        // A zero/negative phase length flips immediately (skip that phase)
        // rather than sticking in it forever.
        if (limit <= 0 || st.phaseMs >= limit) {
          st.pulseOn = !st.pulseOn;
          st.phaseMs = 0;
        }
        _write(p, rule.targetPath, st.pulseOn);
        break;
      case 'ramp':
        if (cond) {
          final cur = _asDouble(readPath(p, rule.targetPath));
          final step = rule.ratePerSec * dt * _gain(p, rule);
          double next;
          if (cur < rule.targetValue) {
            next = (cur + step).clamp(cur, rule.targetValue).toDouble();
          } else {
            next = (cur - step).clamp(rule.targetValue, cur).toDouble();
          }
          _write(p, rule.targetPath, _clamp(next, rule.minValue, rule.maxValue));
        }
        break;
      case 'integrate':
        if (cond) {
          final cur = _asDouble(readPath(p, rule.targetPath));
          _write(p, rule.targetPath,
              _clamp(cur + rule.ratePerSec * dt * _gain(p, rule), rule.minValue, rule.maxValue));
        }
        break;
      case 'firstOrderLag':
        if (cond) {
          final target = rule.sourcePath.isNotEmpty ? _asDouble(readPath(p, rule.sourcePath)) : rule.targetValue;
          final cur = _asDouble(readPath(p, rule.targetPath));
          final k = rule.tauSec <= 0 ? 1.0 : (dt / rule.tauSec).clamp(0.0, 1.0);
          final next = cur + (target - cur) * k;
          _write(p, rule.targetPath, _clamp(next, rule.minValue, rule.maxValue));
        }
        break;
      case 'deadTime':
        if (cond && rule.sourcePath.isNotEmpty) {
          final src = _asDouble(readPath(p, rule.sourcePath));
          final n = rule.tauSec <= 0 ? 0 : (rule.tauSec / dt).round();
          if (n <= 0) {
            _write(p, rule.targetPath, _clamp(src, rule.minValue, rule.maxValue));
            break;
          }
          // Cap the buffer so an absurd dead time can't grow memory unbounded.
          final cap = (n + 1) > 100000 ? 100000 : (n + 1);
          st.delayBuf.add(src);
          while (st.delayBuf.length > cap) {
            st.delayBuf.removeAt(0);
          }
          // Output the sample from n scans ago; while filling, hold the oldest.
          final idx = st.delayBuf.length > n ? st.delayBuf.length - 1 - n : 0;
          final out = st.delayBuf[idx];
          _write(p, rule.targetPath, _clamp(out, rule.minValue, rule.maxValue));
        }
        break;
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
            } else if (rule.noiseDistribution == kNoisePink) {
              st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
              final u = st.noiseState! / 0xffffffff;
              noise = pinkNoise(st.pinkState, u, a);
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
      default:
        break;
    }
  }
}
