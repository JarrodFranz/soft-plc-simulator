import 'project_model.dart';
import 'tag_resolver.dart';

/// Reserved for stateful FBD blocks (e.g. TON); the combinational blocks the
/// shipped diagrams use hold no state. Cleared on project switch.
class FbdRuntime {
  void clear() {}
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

dynamic _evalBlock(PlcProject p, FbdBlock b, List<dynamic> inputs) {
  switch (b.type) {
    case 'TAG_INPUT':
      return b.tagBinding.isEmpty ? null : readPath(p, b.tagBinding);
    case 'CONST':
      return _parseConst(b.tagBinding);
    case 'AND':
      if (inputs.isEmpty) {
        return false;
      }
      for (final i in inputs) {
        final t = _truthy(i);
        if (t == null) {
          return null;
        }
        if (!t) {
          return false;
        }
      }
      return true;
    case 'OR':
      if (inputs.isEmpty) {
        return false;
      }
      bool any = false;
      for (final i in inputs) {
        final t = _truthy(i);
        if (t == null) {
          return null;
        }
        if (t) {
          any = true;
        }
      }
      return any;
    case 'NOT':
      if (inputs.isEmpty) {
        return null;
      }
      final t = _truthy(inputs.first);
      return t == null ? null : !t;
    case 'ADD':
    case 'SUB':
    case 'MUL':
    case 'DIV':
      return _arith(b.type, inputs);
    case 'GT':
    case 'LT':
    case 'GE':
    case 'LE':
    case 'EQ':
    case 'NE':
      return _compare(b.type, inputs);
    case 'LIMIT':
      if (inputs.length < 3) {
        return null;
      }
      final mn = inputs[0];
      final inp = inputs[1];
      final mx = inputs[2];
      if (mn is num && inp is num && mx is num) {
        if (inp < mn) {
          return mn;
        }
        if (inp > mx) {
          return mx;
        }
        return inp;
      }
      return null;
    case 'TAG_OUTPUT':
      if (inputs.isEmpty) {
        return null;
      }
      final v = inputs.first;
      if (v != null && b.tagBinding.isNotEmpty) {
        _forceAwareWrite(p, b.tagBinding, v);
      }
      return v;
    default:
      return null; // TON and unknown block types are not executed this release
  }
}

/// Executes every FunctionBlockDiagram program: evaluates the block graph in
/// dependency (topological) order — a block after all blocks feeding it — and
/// TAG_OUTPUT blocks write their input to the bound tag (force-aware). Input
/// order for a block is the order of the matching wires in `fbdWires`. Cycles
/// (not present in shipped diagrams) terminate deterministically without
/// hanging. Never throws.
void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt) {
  for (final prog in p.programs) {
    if (prog.language != 'FunctionBlockDiagram' || prog.fbdBlocks.isEmpty) {
      continue;
    }
    final byId = <String, FbdBlock>{};
    for (final b in prog.fbdBlocks) {
      byId[b.id] = b;
    }
    final inputsOf = <String, List<String>>{};
    for (final b in prog.fbdBlocks) {
      inputsOf[b.id] = <String>[];
    }
    for (final w in prog.fbdWires) {
      if (inputsOf.containsKey(w.toBlockId) && byId.containsKey(w.fromBlockId)) {
        inputsOf[w.toBlockId]!.add(w.fromBlockId);
      }
    }
    final cache = <String, dynamic>{};
    final done = <String>{};

    // Evaluate blocks whose inputs are all resolved; repeat until stable.
    bool progressed = true;
    while (progressed) {
      progressed = false;
      for (final b in prog.fbdBlocks) {
        if (done.contains(b.id)) {
          continue;
        }
        final srcs = inputsOf[b.id]!;
        if (!srcs.every(done.contains)) {
          continue;
        }
        cache[b.id] = _evalBlock(p, b, srcs.map((s) => cache[s]).toList());
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
      cache[b.id] = _evalBlock(p, b, inputsOf[b.id]!.map((s) => cache[s]).toList());
      done.add(b.id);
    }
  }
}
