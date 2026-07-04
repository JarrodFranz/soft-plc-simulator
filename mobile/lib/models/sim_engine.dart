import 'project_model.dart';
import 'tag_resolver.dart';

/// Per-rule timing state carried across scans.
class RuleRuntime {
  int phaseMs = 0;      // pulse: elapsed within current on/off phase
  bool pulseOn = true;  // pulse: current phase is the on-phase
  int heldMs = 0;       // delayedSet: how long the condition has held
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
          final step = rule.ratePerSec * dt;
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
          _write(p, rule.targetPath, _clamp(cur + rule.ratePerSec * dt, rule.minValue, rule.maxValue));
        }
        break;
      default:
        break;
    }
  }
}
