import 'project_model.dart';
import 'fbd_pins.dart';
import 'tag_resolver.dart';

/// Per-block timer state for stateful FBD blocks (TON/TOF), keyed by block id
/// (unique within a program; program name is folded into the key to avoid
/// aliasing across programs/projects). Cleared on project switch.
class FbdRuntime {
  final Map<String, num> _elapsedMs = {};
  void clear() => _elapsedMs.clear();
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
/// `{'OUT': v}`; TON/TOF yield `{'Q': bool, 'ET': num}`. Never throws.
Map<String, dynamic> _evalBlock(
  PlcProject p,
  FbdBlock b,
  List<dynamic> inputs,
  int dtMs,
  FbdRuntime rt,
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
    case 'TAG_OUTPUT':
      if (inputs.isEmpty) {
        return {};
      }
      final v = inputs.first;
      if (v != null && b.tagBinding.isNotEmpty) {
        _forceAwareWrite(p, b.tagBinding, v);
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
void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt) {
  for (final prog in p.programs) {
    if (prog.language != 'FunctionBlockDiagram' || prog.fbdBlocks.isEmpty) {
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
        cache[b.id] = _evalBlock(p, b, orderedInputs(b), dtMs, rt);
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
      cache[b.id] = _evalBlock(p, b, orderedInputs(b), dtMs, rt);
      done.add(b.id);
    }
  }
}
