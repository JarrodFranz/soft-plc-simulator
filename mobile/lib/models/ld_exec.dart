import 'dart:math' as math;

import 'project_model.dart';
import 'ld_graph.dart';
import 'tag_resolver.dart';

/// Prev-scan state for edge contacts and pulse coils, keyed by
/// "program|rungIndex|nodeId".
///
/// Precondition: rungIndex values must be unique within a program and program
/// names unique within a project — the state key aliases otherwise.
class LdExecRuntime {
  final Map<String, bool> prevBool = {};
  void clear() => prevBool.clear();
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
/// otherwise it is treated as a tag path. Never throws — a non-numeric or
/// absent tag resolves to 0.
double _operandValue(PlcProject p, String s) {
  final lit = num.tryParse(s);
  if (lit != null) {
    return lit.toDouble();
  }
  final v = readPath(p, s);
  if (v is bool) {
    return v ? 1 : 0;
  }
  if (v is num) {
    return v.toDouble();
  }
  return 0;
}

/// Executes every LadderLogic program in [p], rungs top-to-bottom, once.
/// Writes are immediately visible to later rungs (seal-in works).
void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt) {
  for (final prog in p.programs) {
    if (prog.language != 'LadderLogic') {
      continue;
    }
    for (final rung in prog.rungs) {
      executeRung(p, prog.name, rung, dtMs, rt, (path, v) => _forceAwareWrite(p, path, v));
    }
  }
}

/// Power-flow evaluation of one rung: nodes in column (topological) order;
/// a node's input power is the OR of its inbound wires' source powers, so
/// series chains AND and parallel convergences OR.
void executeRung(PlcProject p, String progName, LdRung rung, int dtMs,
    LdExecRuntime rt, void Function(String path, dynamic value) write) {
  final col = colAssignment(rung);
  final ordered = [...rung.nodes]
    ..sort((a, b) => (col[a.id] ?? 0).compareTo(col[b.id] ?? 0));
  final power = <String, bool>{};

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
        break;
      case LdKind.rightRail:
        power[n.id] = inputPower(n);
        break;
      case LdKind.contact:
        final inP = inputPower(n);
        final val = readPath(p, n.variable) == true;
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
        break;
      case LdKind.coil:
        final inP = inputPower(n);
        power[n.id] = inP;
        final key = '$progName|${rung.rungIndex}|${n.id}';
        final prevP = rt.prevBool[key] ?? inP;
        rt.prevBool[key] = inP;
        switch (n.modifier) {
          case 'negated':
            write(n.variable, !inP);
            break;
          case 'set':
            if (inP) {
              write(n.variable, true);
            }
            break;
          case 'reset':
            if (inP) {
              write(n.variable, false);
            }
            break;
          case 'rising':
            write(n.variable, inP && !prevP); // one-scan pulse on power edge
            break;
          case 'falling':
            write(n.variable, !inP && prevP);
            break;
          default:
            write(n.variable, inP); // OTE
        }
        break;
      case LdKind.block:
        final inP = inputPower(n);
        final base = n.variable;
        final pre = n.presetMs;
        final key = '$progName|${rung.rungIndex}|${n.id}';

        const compareOps = {'GT', 'LT', 'GE', 'LE', 'EQ', 'NE'};
        const mathOps = {'ADD', 'SUB', 'MUL', 'DIV', 'MOVE'};

        if (compareOps.contains(n.blockType)) {
          final a = _operandValue(p, n.operandA);
          final b = _operandValue(p, n.operandB);
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
          break;
        }

        if (mathOps.contains(n.blockType)) {
          if (inP) {
            final a = _operandValue(p, n.operandA);
            final b = _operandValue(p, n.operandB);
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
            final outRoot = _rootTagOf(p, n.variable);
            final dynamic outVal =
                outRoot != null && isIntegerType(outRoot.dataType) ? r.truncate() : r;
            write(n.variable, outVal);
          }
          power[n.id] = inP;
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
          break;
        }

        if (n.blockType == 'CTUD') {
          int cv = (readPath(p, '$base.CV') as num?)?.toInt() ?? 0;
          final prevUp = rt.prevBool[key] ?? inP;
          rt.prevBool[key] = inP;
          final downIn = readPath(p, n.operandA) == true;
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
        break;
    }
  }
}
