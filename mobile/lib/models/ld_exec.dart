import 'dart:math' as math;

import 'project_model.dart';
import 'ld_graph.dart';
import 'ld_monitor.dart';
import 'tag_resolver.dart';
import 'fb_exec.dart';

/// Prev-scan state for edge contacts and pulse coils, keyed by
/// "program|rungIndex|nodeId".
///
/// Precondition: rungIndex values must be unique within a program and program
/// names unique within a project — the state key aliases otherwise.
class LdExecRuntime {
  final Map<String, bool> prevBool = {};
  void clear() => prevBool.clear();
}

/// Scopes ladder execution to one FB instance: bare references to the FB's own
/// vars resolve/write against `<instancePath>.<var>` instead of a global tag
/// path. Mirrors `StScope` (st_exec.dart) exactly — same root-segment test,
/// same "anything else falls through global" rule.
class LdScope {
  final String instancePath; // e.g. 'A1' (or 'A1.Inner' for a nested FB call)
  final Set<String> localVars; // the FB's var names

  LdScope(this.instancePath, this.localVars);

  /// Rewrites a tag path into the instance's namespace when its root segment
  /// is one of this scope's local vars (handles `x`, `x.y`, and `x[i]`);
  /// otherwise the path is left untouched (falls through global).
  String rewrite(String path) {
    final root = path.split('.').first.split('[').first;
    return localVars.contains(root) ? '$instancePath.$path' : path;
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
    return; // forcing wins over executed logic
  }
  writePath(p, path, value);
}

/// Resolves a compare/math operand: a numeric literal parses directly,
/// otherwise it is treated as a tag path (scoped through [scope] when one is
/// supplied — a LITERAL is parsed first and is therefore never rewritten).
/// Never throws — a non-numeric or absent tag resolves to 0.
double _operandValue(PlcProject p, String s, [LdScope? scope]) {
  final lit = num.tryParse(s);
  if (lit != null) {
    return lit.toDouble();
  }
  final v = readPath(p, scope == null ? s : scope.rewrite(s));
  if (v is bool) {
    return v ? 1 : 0;
  }
  if (v is num) {
    return v.toDouble();
  }
  return 0;
}

/// Every built-in LD block `type` string this file's `LdKind.block` dispatch
/// (below) recognizes by name BEFORE it checks `fbDefinitionFor`: the
/// compare/math operator sets, the pulse/counter blocks, and the TON/TOF
/// timer default. This is the canonical reserved set for LD — a custom
/// function block sharing one of these names would either never be reached
/// (compare/math/TP/CTU/CTD/CTUD are checked first) or would itself hijack
/// every plain TON/TOF timer block in the project (the FB check runs before
/// the unconditional TON/TOF fallback). Kept as a literal (Dart can't
/// enumerate an `if`-chain's string literals at runtime); a guard test
/// exercises the dispatch order directly.
const List<String> kLdBuiltinBlockTypes = [
  'GT', 'LT', 'GE', 'LE', 'EQ', 'NE', // compareOps
  'ADD', 'SUB', 'MUL', 'DIV', 'MOVE', // mathOps
  'TP', 'CTU', 'CTD', 'CTUD', 'TON', 'TOF',
];

/// Executes every LadderLogic program in [p], rungs top-to-bottom, once.
/// Writes are immediately visible to later rungs (seal-in works).
void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt,
    {Set<String>? only, Set<String>? readOnly, LdMonitor? monitor}) {
  for (final prog in p.programs) {
    if (prog.language != 'LadderLogic') {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    for (final rung in prog.rungs) {
      executeRung(p, prog.name, rung, dtMs, rt, (path, v) {
        if (readOnly == null || !readOnly.contains(path)) {
          _forceAwareWrite(p, path, v);
        }
      }, monitor: monitor);
    }
  }
}

/// Power-flow evaluation of one rung: nodes in column (topological) order;
/// a node's input power is the OR of its inbound wires' source powers, so
/// series chains AND and parallel convergences OR.
void executeRung(PlcProject p, String progName, LdRung rung, int dtMs,
    LdExecRuntime rt, void Function(String path, dynamic value) write,
    {LdMonitor? monitor, LdScope? scope}) {
  // EVERY tag path this rung touches goes through `sp`. With no scope it is
  // the identity, so program-rung execution is byte-identical to before this
  // feature; inside an FB body it maps the FB's own var names into the
  // instance struct. Runtime/monitor state keys are NOT scoped here — the
  // caller supplies a per-instance `progName` (see `runScopedLdBody`).
  String sp(String path) => scope == null ? path : scope.rewrite(path);
  final col = colAssignment(rung);
  final ordered = [...rung.nodes]
    ..sort((a, b) => (col[a.id] ?? 0).compareTo(col[b.id] ?? 0));
  final power = <String, bool>{};
  // The element's OWN evaluated true-state (decoupled from upstream power): a
  // contact's conducting condition, a coil/timer/counter's energized-active
  // state, a compare block's result. Drives the online element highlight;
  // `power` (power flow) still drives the wire colour.
  final elemTrue = <String, bool>{};

  bool inputPower(LdNode n) {
    bool any = false;
    for (final w in rung.wires) {
      if (w.toId == n.id && (power[w.fromId] ?? false)) {
        any = true;
      }
    }
    return any;
  }

  for (final n in ordered) {
    switch (n.kind) {
      case LdKind.leftRail:
        power[n.id] = true;
        elemTrue[n.id] = true;
        break;
      case LdKind.rightRail:
        power[n.id] = inputPower(n);
        elemTrue[n.id] = power[n.id]!;
        break;
      case LdKind.contact:
        final inP = inputPower(n);
        final val = readPath(p, sp(n.variable)) == true;
        final key = '$progName|${rung.rungIndex}|${n.id}';
        final prev = rt.prevBool[key] ?? val; // no spurious edge on first scan
        rt.prevBool[key] = val;
        bool cond;
        switch (n.modifier) {
          case 'negated':
            cond = !val;
            break;
          case 'rising':
            cond = val && !prev;
            break;
          case 'falling':
            cond = !val && prev;
            break;
          default:
            cond = val;
        }
        power[n.id] = inP && cond;
        elemTrue[n.id] = cond; // glow when this contact is conducting
        break;
      case LdKind.coil:
        final inP = inputPower(n);
        power[n.id] = inP;
        elemTrue[n.id] = inP; // glow when this coil is energized
        final key = '$progName|${rung.rungIndex}|${n.id}';
        final prevP = rt.prevBool[key] ?? inP;
        rt.prevBool[key] = inP;
        final target = sp(n.variable);
        switch (n.modifier) {
          case 'negated':
            write(target, !inP);
            break;
          case 'set':
            if (inP) {
              write(target, true);
            }
            break;
          case 'reset':
            if (inP) {
              write(target, false);
            }
            break;
          case 'rising':
            write(target, inP && !prevP); // one-scan pulse on power edge
            break;
          case 'falling':
            write(target, !inP && prevP);
            break;
          default:
            write(target, inP); // OTE
        }
        break;
      case LdKind.block:
        final inP = inputPower(n);
        // Scoping `base` is what moves an FB-local timer/counter's `.ACC`/
        // `.PRE`/`.CV` members inside the instance (`T` -> `A1.T`).
        final base = sp(n.variable);
        final pre = n.presetMs;
        final key = '$progName|${rung.rungIndex}|${n.id}';

        const compareOps = {'GT', 'LT', 'GE', 'LE', 'EQ', 'NE'};
        const mathOps = {'ADD', 'SUB', 'MUL', 'DIV', 'MOVE'};

        if (compareOps.contains(n.blockType)) {
          final a = _operandValue(p, n.operandA, scope);
          final b = _operandValue(p, n.operandB, scope);
          bool res;
          switch (n.blockType) {
            case 'GT':
              res = a > b;
              break;
            case 'LT':
              res = a < b;
              break;
            case 'GE':
              res = a >= b;
              break;
            case 'LE':
              res = a <= b;
              break;
            case 'EQ':
              res = a == b;
              break;
            default: // NE
              res = a != b;
          }
          power[n.id] = inP && res;
          elemTrue[n.id] = res; // glow when the comparison is true
          break;
        }

        if (mathOps.contains(n.blockType)) {
          if (inP) {
            final a = _operandValue(p, n.operandA, scope);
            final b = _operandValue(p, n.operandB, scope);
            double r;
            switch (n.blockType) {
              case 'ADD':
                r = a + b;
                break;
              case 'SUB':
                r = a - b;
                break;
              case 'MUL':
                r = a * b;
                break;
              case 'DIV':
                r = b == 0 ? 0 : a / b;
                break;
              default: // MOVE
                r = a;
            }
            // NOTE: the integer-truncation probe stays a ROOT-tag lookup (not
            // a per-member type walk) so global behaviour is unchanged — a
            // dotted destination (`Struct.Member`, and now `A1.Var`) already
            // did not truncate before this feature. Tracked in
            // docs/DEFERRED.md.
            final dest = sp(n.variable);
            final outRoot = _rootTagOf(p, dest);
            final dynamic outVal =
                outRoot != null && isIntegerType(outRoot.dataType) ? r.truncate() : r;
            write(dest, outVal);
          }
          power[n.id] = inP;
          elemTrue[n.id] = inP; // glow while the math block executes
          break;
        }

        if (n.blockType == 'TP') {
          int acc = (readPath(p, '$base.ACC') as num?)?.toInt() ?? 0;
          final prevIn = rt.prevBool[key] ?? inP;
          rt.prevBool[key] = inP;
          final rising = inP && !prevIn;
          final timing = acc > 0 && acc < pre;
          if (rising && !timing) {
            acc = dtMs; // start the pulse (non-retriggerable while timing)
          } else if (timing) {
            acc = acc + dtMs;
          }
          // The pulse must be observable for at least the scan it starts on,
          // even when presetMs <= dtMs makes acc reach pre in that same scan.
          bool q = (acc > 0 && acc < pre) || rising;
          if (acc >= pre) {
            acc = 0; // pulse complete; ready to retrigger on next rising edge
          }
          write('$base.EN', inP);
          write('$base.PRE', pre);
          write('$base.ACC', acc);
          write('$base.DN', q);
          write('$base.TT', q);
          power[n.id] = q;
          elemTrue[n.id] = inP; // glow while the pulse timer is triggered
          break;
        }

        if (n.blockType == 'CTU') {
          int cv = (readPath(p, '$base.CV') as num?)?.toInt() ?? 0;
          final prevIn = rt.prevBool[key] ?? inP;
          rt.prevBool[key] = inP;
          if (inP && !prevIn) {
            cv = math.min(cv + 1, 32767);
          }
          final reset = readPath(p, '$base.R') == true;
          if (reset) {
            cv = 0;
          }
          final qu = cv >= pre;
          write('$base.CU', inP);
          write('$base.PV', pre);
          write('$base.CV', cv);
          write('$base.QU', qu);
          write('$base.R', reset);
          power[n.id] = qu;
          elemTrue[n.id] = inP; // glow while the counter is enabled
          break;
        }

        if (n.blockType == 'CTD') {
          final rawCv = readPath(p, '$base.CV');
          int cv = rawCv == null ? pre : (rawCv as num).toInt();
          final initKey = '$key|init';
          if (rt.prevBool[initKey] != true) {
            // First-ever scan for this CTD node: an editor-placed COUNTER tag
            // initializes .CV to 0 (not null), so the `rawCv == null` load
            // above never fires for it. Preload CV to PV unconditionally on
            // the first scan so QD isn't spuriously true before any counting.
            cv = pre;
            rt.prevBool[initKey] = true;
          }
          final prevIn = rt.prevBool[key] ?? inP;
          rt.prevBool[key] = inP;
          if (inP && !prevIn) {
            cv = math.max(cv - 1, 0);
          }
          final reset = readPath(p, '$base.R') == true;
          if (reset) {
            cv = pre;
          }
          final qd = cv <= 0;
          write('$base.CD', inP);
          write('$base.PV', pre);
          write('$base.CV', cv);
          write('$base.QD', qd);
          write('$base.R', reset);
          power[n.id] = qd;
          elemTrue[n.id] = inP; // glow while the counter is enabled
          break;
        }

        if (n.blockType == 'CTUD') {
          int cv = (readPath(p, '$base.CV') as num?)?.toInt() ?? 0;
          final prevUp = rt.prevBool[key] ?? inP;
          rt.prevBool[key] = inP;
          final downIn = readPath(p, sp(n.operandA)) == true;
          final downKey = '$key|dn';
          final prevDown = rt.prevBool[downKey] ?? downIn;
          rt.prevBool[downKey] = downIn;
          if (inP && !prevUp) {
            cv = cv + 1;
          }
          if (downIn && !prevDown) {
            cv = cv - 1;
          }
          cv = cv.clamp(0, pre);
          final reset = readPath(p, '$base.R') == true;
          if (reset) {
            cv = 0;
          }
          final qu = cv >= pre;
          final qd = cv <= 0;
          write('$base.CU', inP);
          write('$base.CD', downIn);
          write('$base.PV', pre);
          write('$base.CV', cv);
          write('$base.QU', qu);
          write('$base.QD', qd);
          write('$base.R', reset);
          power[n.id] = qu;
          elemTrue[n.id] = inP; // glow while the up/down counter is enabled
          break;
        }

        final fb = fbDefinitionFor(p, n.blockType);
        if (fb != null) {
          // Custom function block instance: a data block (like compare/math),
          // transparent to power flow. Execution/writes are gated on input
          // power exactly like the math-block ENO convention above; power
          // passes straight through regardless (`power[n.id] = inP`), so the
          // FB never breaks the rung.
          if (inP) {
            final inputs = <String, dynamic>{};
            for (final v in fb.vars) {
              if (v.direction == FbVarDir.input) {
                final raw = n.pinBindings[v.name];
                if (raw != null && raw.isNotEmpty) {
                  // Scoped so a nested FB call inside an FB body binds the
                  // OUTER FB's own vars. A literal binding is unaffected: its
                  // root segment can never match a var name.
                  final tag = sp(raw);
                  // Most pin bindings name a tag path, but the import
                  // translator (custom-FB call routing) folds a literal
                  // operand (e.g. an inVariable wired to `2.0`) into
                  // pinBindings exactly like a tag name — there is no
                  // separate "literal" representation upstream (mirrors how
                  // compare/math `operandA`/`operandB` already accept either).
                  // An unresolved tag path (not found -> null) falls back to
                  // a numeric-literal parse instead of silently dropping the
                  // input; a tag that resolves normally is never affected.
                  final resolved = readPath(p, tag);
                  if (resolved != null) {
                    inputs[v.name] = resolved;
                  } else {
                    final lit = num.tryParse(tag);
                    if (lit != null) {
                      inputs[v.name] = lit;
                    }
                  }
                }
              }
            }
            // The instance name is scoped too: a nested call's instance var
            // lives inside the outer instance ('Inner' -> 'A1.Inner'), which
            // also keeps its 'fb:<path>' runtime keys disjoint.
            final outputs = executeFbInstance(p, fb, sp(n.variable), inputs);
            outputs.forEach((name, value) {
              final tag = n.pinBindings[name];
              if (tag != null && tag.isNotEmpty && value != null) {
                write(sp(tag), value);
              }
            });
          }
          power[n.id] = inP;
          elemTrue[n.id] = inP; // glow while the FB block executes
          break;
        }

        int acc = (readPath(p, '$base.ACC') as num?)?.toInt() ?? 0;
        bool dn;
        if (n.blockType == 'TOF') {
          if (inP) {
            acc = 0;
            dn = true; // Q true while IN
          } else {
            acc = acc + dtMs;
            if (acc > pre) {
              acc = pre;
            }
            dn = acc < pre; // holds until the off-delay expires
          }
        } else {
          // TON (default)
          if (inP) {
            acc = acc + dtMs;
            if (acc > pre) {
              acc = pre;
            }
            dn = acc >= pre;
          } else {
            acc = 0;
            dn = false;
          }
        }
        write('$base.EN', inP);
        write('$base.PRE', pre); // keep the visible tag synced to the block
        write('$base.ACC', acc);
        write('$base.DN', dn);
        write('$base.TT', n.blockType == 'TOF' ? (!inP && dn) : (inP && !dn));
        power[n.id] = dn; // block output (Q) feeds downstream elements
        elemTrue[n.id] = inP; // glow while the timer is enabled/counting
        break;
      case LdKind.link:
        // Empty branch placeholder: open (no power), writes nothing. A
        // guided-editing scaffold until filled with a real element.
        power[n.id] = false;
        elemTrue[n.id] = false;
        break;
    }
  }

  if (monitor != null) {
    for (final n in rung.nodes) {
      final k = monitor.keyFor(progName, rung.rungIndex, n.id);
      monitor.nodePower[k] = power[n.id] ?? false;
      monitor.nodeTrue[k] = elemTrue[n.id] ?? (power[n.id] ?? false);
    }
  }
}

/// Runs a ladder FB body scoped to one instance: every rung executes through
/// [executeRung] with [scope] applied to every tag path, under the synthetic
/// program key `'fb:<instancePath>'`. Sanitized program names can never
/// contain `:`, so these keys never collide with a real program's edge/pulse
/// state, and two instances of the same FB get disjoint state for free.
/// Writes are force-aware, exactly like program-rung execution. Placeholder
/// rungs (rails + one wire) execute as harmless no-ops. Never throws.
/// (The ladder analog of `runScopedStBody` in st_exec.dart.)
void runScopedLdBody(PlcProject p, List<LdRung> rungs, LdScope scope, int dtMs,
    LdExecRuntime rt) {
  final progKey = 'fb:${scope.instancePath}';
  for (final rung in rungs) {
    executeRung(p, progKey, rung, dtMs, rt,
        (path, v) => _forceAwareWrite(p, path, v), scope: scope);
  }
}
