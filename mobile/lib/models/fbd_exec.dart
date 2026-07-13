import 'project_model.dart';
import 'fbd_pins.dart';
import 'tag_resolver.dart';

/// Per-block timer state for stateful FBD blocks (TON/TOF), keyed by block id
/// (block ids are unique within a project's FBD programs). Cleared on project
/// switch.
class FbdRuntime {
  final Map<String, num> _elapsedMs = {};

  /// Per-block PID state keyed by block id: `[integral, prevError]`.
  final Map<String, List<double>> _pid = {};

  /// Per-block counter state keyed by block id: `[cv, prevCU, prevCD]`. The
  /// prev-CU/prev-CD levels are stored as 0/1 so a rising edge is detected as
  /// "input true now AND stored prev level 0". CTU only tracks/uses prevCU,
  /// CTD only prevCD, CTUD uses both.
  final Map<String, List<num>> _counters = {};

  /// Per-block previous CLK level for edge detectors (R_TRIG/F_TRIG), keyed
  /// by block id. Defaults to false on first read (see `_prevClk[b.id] ??
  /// false` at call sites), so a CLK already true on scan 1 is a rising edge.
  final Map<String, bool> _prevClk = {};

  /// Per-block pulse-timer (TP) state keyed by block id: `[et, running,
  /// prevIN]`. `running`/`prevIN` stored as 0/1.
  final Map<String, List<num>> _pulse = {};

  void clear() {
    _elapsedMs.clear();
    _pid.clear();
    _counters.clear();
    _prevClk.clear();
    _pulse.clear();
  }
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

void _forceAwareWrite(PlcProject p, String path, dynamic value) {
  final root = _rootTagOf(p, path);
  if (root != null && root.isForced && root.name == path) {
    return; // forcing wins
  }
  writePath(p, path, value);
}

bool? _truthy(dynamic v) {
  if (v is bool) {
    return v;
  }
  if (v is num) {
    return v != 0;
  }
  return null;
}

dynamic _parseConst(String s) {
  final t = s.trim();
  if (t.isEmpty) {
    return null;
  }
  final up = t.toUpperCase();
  if (up == 'TRUE') {
    return true;
  }
  if (up == 'FALSE') {
    return false;
  }
  final i = int.tryParse(t);
  if (i != null) {
    return i;
  }
  return double.tryParse(t);
}

dynamic _arith(String op, List<dynamic> inputs) {
  final nums = <num>[];
  for (final i in inputs) {
    if (i is num) {
      nums.add(i);
    } else {
      return null;
    }
  }
  if (nums.isEmpty) {
    return null;
  }
  num acc = nums.first;
  for (int k = 1; k < nums.length; k++) {
    final n = nums[k];
    switch (op) {
      case 'ADD':
        acc = acc + n;
        break;
      case 'SUB':
        acc = acc - n;
        break;
      case 'MUL':
        acc = acc * n;
        break;
      case 'DIV':
        if (n == 0) {
          return null;
        }
        acc = acc / n;
        break;
    }
  }
  return acc;
}

/// Coerces a possibly-null/non-numeric wire value to a `double`, defaulting
/// to 0.0 for unwired/non-numeric pins. Never throws.
double _asNum(dynamic v) => v is num ? v.toDouble() : 0.0;

dynamic _compare(String op, List<dynamic> inputs) {
  if (inputs.length < 2) {
    return null;
  }
  final a = inputs[0];
  final b = inputs[1];
  if (a is num && b is num) {
    switch (op) {
      case 'GT':
        return a > b;
      case 'LT':
        return a < b;
      case 'GE':
        return a >= b;
      case 'LE':
        return a <= b;
      case 'EQ':
        return a == b;
      case 'NE':
        return a != b;
    }
  }
  if (op == 'EQ') {
    return a == b;
  }
  if (op == 'NE') {
    return a != b;
  }
  return null;
}

/// Evaluates block [b] given its ordered input-pin values [inputs] (aligned
/// with `fbdInputPins(b.type, inputCount: b.inputCount)`), returning a map of
/// output-pin-name -> value. Single-output combinational blocks yield
/// `{'OUT': v}`; TON/TOF yield `{'Q': bool, 'ET': num}`; PID yields
/// `{'CV': double}` (stateful, conditional-anti-windup, clamped 0-100).
/// CTU/CTD/CTUD are stateful, edge-triggered counters (clock-independent,
/// `dtMs` unused): CTU/CTD yield `{'Q': bool, 'CV': int}`, CTUD yields
/// `{'QU': bool, 'QD': bool, 'CV': int}`.
/// Never throws.
Map<String, dynamic> _evalBlock(
  PlcProject p,
  FbdBlock b,
  List<dynamic> inputs,
  int dtMs,
  FbdRuntime rt,
  Set<String>? readOnly,
) {
  switch (b.type) {
    case 'TAG_INPUT':
      return {'OUT': b.tagBinding.isEmpty ? null : readPath(p, b.tagBinding)};
    case 'CONST':
      return {'OUT': _parseConst(b.tagBinding)};
    case 'AND':
      if (inputs.isEmpty) {
        return {'OUT': false};
      }
      for (final i in inputs) {
        final t = _truthy(i);
        if (t == null) {
          return {'OUT': null};
        }
        if (!t) {
          return {'OUT': false};
        }
      }
      return {'OUT': true};
    case 'OR':
      if (inputs.isEmpty) {
        return {'OUT': false};
      }
      bool any = false;
      for (final i in inputs) {
        final t = _truthy(i);
        if (t == null) {
          return {'OUT': null};
        }
        if (t) {
          any = true;
        }
      }
      return {'OUT': any};
    case 'NOT':
      if (inputs.isEmpty) {
        return {'OUT': null};
      }
      final t = _truthy(inputs.first);
      return {'OUT': t == null ? null : !t};
    case 'ADD':
    case 'SUB':
    case 'MUL':
    case 'DIV':
      return {'OUT': _arith(b.type, inputs)};
    case 'GT':
    case 'LT':
    case 'GE':
    case 'LE':
    case 'EQ':
    case 'NE':
      return {'OUT': _compare(b.type, inputs)};
    case 'LIMIT':
      if (inputs.length < 3) {
        return {'OUT': null};
      }
      final mn = inputs[0];
      final inp = inputs[1];
      final mx = inputs[2];
      if (mn is num && inp is num && mx is num) {
        if (inp < mn) {
          return {'OUT': mn};
        }
        if (inp > mx) {
          return {'OUT': mx};
        }
        return {'OUT': inp};
      }
      return {'OUT': null};
    case 'SEL':
      if (inputs.length < 3) {
        return {'OUT': null};
      }
      final g = _truthy(inputs[0]);
      if (g == null) {
        return {'OUT': null};
      }
      return {'OUT': g ? inputs[2] : inputs[1]};
    case 'TON':
    case 'TOF':
      {
        final inVal = inputs.isNotEmpty ? _truthy(inputs[0]) ?? false : false;
        final pt = (inputs.length > 1 && inputs[1] is num) ? (inputs[1] as num) : 0;
        num et = rt._elapsedMs[b.id] ?? 0;
        bool q;
        if (b.type == 'TON') {
          if (inVal) {
            et = et + dtMs;
            if (et > pt) {
              et = pt;
            }
            q = et >= pt;
          } else {
            et = 0;
            q = false;
          }
        } else {
          // TOF: Q true immediately while IN, stays true for PT after IN falls.
          if (inVal) {
            et = 0;
            q = true;
          } else {
            et = et + dtMs;
            if (et > pt) {
              et = pt;
            }
            q = et < pt;
          }
        }
        rt._elapsedMs[b.id] = et;
        return {'Q': q, 'ET': et};
      }
    case 'PID':
      {
        // Ordered inputs follow fbdInputPins('PID'): SP, PV, KP, KI, KD.
        final sp = _asNum(inputs.isNotEmpty ? inputs[0] : null);
        final pv = _asNum(inputs.length > 1 ? inputs[1] : null);
        final kp = _asNum(inputs.length > 2 ? inputs[2] : null);
        final ki = _asNum(inputs.length > 3 ? inputs[3] : null);
        final kd = _asNum(inputs.length > 4 ? inputs[4] : null);

        final dt = dtMs / 1000.0;
        final e = sp - pv;
        final state = rt._pid[b.id] ?? [0.0, 0.0];
        final integral = state[0];
        final prevError = state[1];
        final deriv = dt <= 0 ? 0.0 : (e - prevError) / dt;

        // Conditional anti-windup: only accumulate the integral if doing so
        // keeps (or brings) the output within [0,100]; if the un-integrated
        // output is already saturated and integrating pushes it further into
        // saturation, freeze the integral instead.
        final candidateInteg = integral + e * dt;
        var raw = kp * e + ki * candidateInteg + kd * deriv;
        double integ;
        if (raw >= 0 && raw <= 100) {
          integ = candidateInteg;
        } else {
          integ = integral;
          raw = kp * e + ki * integral + kd * deriv;
        }
        final cv = raw.clamp(0.0, 100.0);
        rt._pid[b.id] = [integ, e];
        return {'CV': cv};
      }
    case 'CTU':
      {
        // Ordered inputs follow fbdInputPins('CTU'): CU, R, PV.
        final cu = inputs.isNotEmpty ? _truthy(inputs[0]) ?? false : false;
        final r = inputs.length > 1 ? _truthy(inputs[1]) ?? false : false;
        final pv = _asNum(inputs.length > 2 ? inputs[2] : null).toInt();

        final state = rt._counters[b.id] ?? [0, 0, 0];
        num cv = state[0];
        final prevCU = state[1];

        if (r) {
          cv = 0;
        } else if (cu && prevCU == 0) {
          cv = cv + 1;
        }
        rt._counters[b.id] = [cv, cu ? 1 : 0, state[2]];
        final q = cv >= pv;
        return {'Q': q, 'CV': cv.toInt()};
      }
    case 'CTD':
      {
        // Ordered inputs follow fbdInputPins('CTD'): CD, LD, PV.
        final cd = inputs.isNotEmpty ? _truthy(inputs[0]) ?? false : false;
        final ld = inputs.length > 1 ? _truthy(inputs[1]) ?? false : false;
        final pv = _asNum(inputs.length > 2 ? inputs[2] : null).toInt();

        final state = rt._counters[b.id] ?? [0, 0, 0];
        num cv = state[0];
        final prevCD = state[2];

        if (ld) {
          cv = pv;
        } else if (cd && prevCD == 0 && cv > 0) {
          cv = cv - 1;
        }
        if (cv < 0) {
          cv = 0;
        }
        rt._counters[b.id] = [cv, state[1], cd ? 1 : 0];
        final q = cv <= 0;
        return {'Q': q, 'CV': cv.toInt()};
      }
    case 'CTUD':
      {
        // Ordered inputs follow fbdInputPins('CTUD'): CU, CD, R, LD, PV.
        final cu = inputs.isNotEmpty ? _truthy(inputs[0]) ?? false : false;
        final cd = inputs.length > 1 ? _truthy(inputs[1]) ?? false : false;
        final r = inputs.length > 2 ? _truthy(inputs[2]) ?? false : false;
        final ld = inputs.length > 3 ? _truthy(inputs[3]) ?? false : false;
        final pv = _asNum(inputs.length > 4 ? inputs[4] : null).toInt();

        final state = rt._counters[b.id] ?? [0, 0, 0];
        num cv = state[0];
        final prevCU = state[1];
        final prevCD = state[2];

        if (r) {
          cv = 0;
        } else if (ld) {
          cv = pv;
        } else {
          if (cu && prevCU == 0) {
            cv = cv + 1;
          }
          if (cd && prevCD == 0) {
            cv = cv - 1;
          }
        }
        // CV never goes negative — floors the down path and a negative preset load.
        if (cv < 0) {
          cv = 0;
        }
        rt._counters[b.id] = [cv, cu ? 1 : 0, cd ? 1 : 0];
        final qu = cv >= pv;
        final qd = cv <= 0;
        return {'QU': qu, 'QD': qd, 'CV': cv.toInt()};
      }
    case 'R_TRIG':
      {
        final clk = inputs.isNotEmpty ? _truthy(inputs[0]) ?? false : false;
        final prev = rt._prevClk[b.id] ?? false;
        final q = clk && !prev;
        rt._prevClk[b.id] = clk;
        return {'Q': q};
      }
    case 'F_TRIG':
      {
        final clk = inputs.isNotEmpty ? _truthy(inputs[0]) ?? false : false;
        final prev = rt._prevClk[b.id] ?? false;
        final q = !clk && prev;
        rt._prevClk[b.id] = clk;
        return {'Q': q};
      }
    case 'TP':
      {
        // Ordered inputs follow fbdInputPins('TP'): IN, PT.
        final inVal = inputs.isNotEmpty ? _truthy(inputs[0]) ?? false : false;
        final pt = _asNum(inputs.length > 1 ? inputs[1] : null);

        final state = rt._pulse[b.id] ?? [0, 0, 0];
        num et = state[0];
        num running = state[1];
        final prevIN = state[2];

        final startEdge = inVal && prevIN == 0;

        if (running == 0 && startEdge && pt > 0) {
          running = 1;
          et = 0;
        }
        if (running == 1) {
          et += dtMs;
          if (et >= pt) {
            et = pt;
            running = 0;
          }
        } else if (!startEdge && !inVal) {
          et = 0;
        }

        rt._pulse[b.id] = [et, running, inVal ? 1 : 0];
        final q = running == 1;
        return {'Q': q, 'ET': et};
      }
    case 'TAG_OUTPUT':
      if (inputs.isEmpty) {
        return {};
      }
      final v = inputs.first;
      if (v != null && b.tagBinding.isNotEmpty) {
        if (readOnly == null || !readOnly.contains(b.tagBinding)) {
          _forceAwareWrite(p, b.tagBinding, v);
        }
      }
      return {};
    default:
      return {}; // unknown block types are not executed
  }
}

/// Resolves a wire's effective source output pin, falling back to the source
/// block's first output pin when the wire predates pin-addressing.
String _resolvedFromPin(FbdWire w, FbdBlock? fromBlock) {
  if (w.fromPin.isNotEmpty) {
    return w.fromPin;
  }
  if (fromBlock == null) {
    return '';
  }
  final outs = fbdOutputPins(fromBlock.type);
  return outs.isNotEmpty ? outs.first : '';
}

/// Resolves a wire's effective target input pin, falling back to the target
/// block's first input pin when the wire predates pin-addressing.
String _resolvedToPin(FbdWire w, FbdBlock? toBlock) {
  if (w.toPin.isNotEmpty) {
    return w.toPin;
  }
  if (toBlock == null) {
    return '';
  }
  final ins = fbdInputPins(toBlock.type, inputCount: toBlock.inputCount);
  return ins.isNotEmpty ? ins.first : '';
}

/// Executes every FunctionBlockDiagram program: evaluates the block graph in
/// dependency (topological) order — a block after all blocks feeding any of
/// its input pins — producing a `Map<String,dynamic>` of output-pin values
/// per block. An input pin's value is resolved from the wire targeting
/// `(block, pin)`, read from the source block's named output in the cache.
/// Arithmetic/comparator operand order follows the registry's pin order
/// (`IN1`, `IN2`, ... / `MN`, `IN`, `MX`), not wire-insertion order.
/// TON/TOF are executed statefully (per-block state in [rt]), producing both
/// `Q` and `ET` outputs. TAG_OUTPUT writes its `IN` force-aware. Cycles
/// terminate deterministically without hanging. Never throws.
void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt, {Set<String>? only, Set<String>? readOnly}) {
  for (final prog in p.programs) {
    if (prog.language != 'FunctionBlockDiagram' || prog.fbdBlocks.isEmpty) {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    final byId = <String, FbdBlock>{};
    for (final b in prog.fbdBlocks) {
      byId[b.id] = b;
    }

    // For each block, the ordered list of (fromBlockId, fromPin) feeding each
    // of its input pins in registry order (null entry = unconnected input).
    final inputWireFor = <String, List<FbdWire?>>{};
    for (final b in prog.fbdBlocks) {
      final pins = fbdInputPins(b.type, inputCount: b.inputCount);
      inputWireFor[b.id] = List<FbdWire?>.filled(pins.length, null);
    }
    for (final w in prog.fbdWires) {
      final toBlock = byId[w.toBlockId];
      final fromBlock = byId[w.fromBlockId];
      if (toBlock == null || fromBlock == null) {
        continue;
      }
      final toPin = _resolvedToPin(w, toBlock);
      if (toPin.isEmpty) {
        continue;
      }
      final pins = fbdInputPins(toBlock.type, inputCount: toBlock.inputCount);
      final idx = pins.indexOf(toPin);
      if (idx < 0) {
        continue;
      }
      inputWireFor[toBlock.id]![idx] = w;
    }

    // Dependency ids (source block ids) per block, for the topological pass.
    final depsOf = <String, List<String>>{};
    for (final b in prog.fbdBlocks) {
      depsOf[b.id] = [
        for (final w in inputWireFor[b.id]!)
          if (w != null) w.fromBlockId,
      ];
    }

    final cache = <String, Map<String, dynamic>>{};
    final done = <String>{};

    dynamic resolveInput(FbdWire? w) {
      if (w == null) {
        return null;
      }
      final fromBlock = byId[w.fromBlockId];
      final fromPin = _resolvedFromPin(w, fromBlock);
      final outMap = cache[w.fromBlockId];
      if (outMap == null || fromPin.isEmpty) {
        return null;
      }
      return outMap[fromPin];
    }

    List<dynamic> orderedInputs(FbdBlock b) =>
        inputWireFor[b.id]!.map(resolveInput).toList();

    // Evaluate blocks whose dependencies are all resolved; repeat until
    // stable (topological worklist).
    bool progressed = true;
    while (progressed) {
      progressed = false;
      for (final b in prog.fbdBlocks) {
        if (done.contains(b.id)) {
          continue;
        }
        final deps = depsOf[b.id]!;
        if (!deps.every(done.contains)) {
          continue;
        }
        cache[b.id] = _evalBlock(p, b, orderedInputs(b), dtMs, rt, readOnly);
        done.add(b.id);
        progressed = true;
      }
    }
    // Any block left unresolved is in a cycle: evaluate once with whatever is
    // cached so the scan always terminates.
    for (final b in prog.fbdBlocks) {
      if (done.contains(b.id)) {
        continue;
      }
      cache[b.id] = _evalBlock(p, b, orderedInputs(b), dtMs, rt, readOnly);
      done.add(b.id);
    }
  }
}
