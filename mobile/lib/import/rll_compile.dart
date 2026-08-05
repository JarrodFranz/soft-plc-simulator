import '../models/project_model.dart';
import '../models/ld_graph.dart';
import 'import_ir.dart';

/// One element of a parsed RLL rung: an instruction or a parallel branch group.
sealed class RllElement {}

class RllInstruction extends RllElement {
  final String mnemonic;
  final List<String> operands;
  RllInstruction(this.mnemonic, this.operands);
}

class RllBranch extends RllElement {
  final List<List<RllElement>> legs;
  RllBranch(this.legs);
}

/// Thrown by [parseRllText] on malformed neutral text. Always caught inside
/// [compileRllRungs] (a parse error degrades that rung to a placeholder).
class RllParseException implements Exception {
  final String message;
  RllParseException(this.message);
  @override
  String toString() => 'RllParseException: $message';
}

class _Cursor {
  final String s;
  int i = 0;
  _Cursor(this.s);
}

final RegExp _identRe = RegExp(r'[A-Za-z0-9_]');

bool _isIdent(String ch) => _identRe.hasMatch(ch);

void _skipWs(_Cursor c) {
  while (c.i < c.s.length && (c.s[c.i] == ' ' || c.s[c.i] == '\t' ||
      c.s[c.i] == '\n' || c.s[c.i] == '\r')) {
    c.i++;
  }
}

/// Maximum branch-nesting depth the recursive-descent tokenizer will follow.
/// Legitimate exports never nest branches (branch legs are single-level-only
/// and stub past depth 1 in [_assembleRung] anyway); this cap exists purely to
/// bound recursion depth so adversarial/malformed text (thousands of nested
/// `[`) throws a catchable [RllParseException] instead of overflowing the
/// Dart call stack with an uncatchable `StackOverflowError`.
const _kMaxBranchDepth = 32;

/// Tokenizes a rung's neutral text into a top-level element sequence. A trailing
/// `;` and inter-instruction whitespace are tolerated. Throws
/// [RllParseException] on unbalanced brackets, excessive branch nesting, or a
/// missing/empty instruction.
List<RllElement> parseRllText(String text) {
  var t = text.trim();
  if (t.endsWith(';')) t = t.substring(0, t.length - 1);
  final c = _Cursor(t);
  final els = _parseSeq(c, 0);
  _skipWs(c);
  if (c.i != c.s.length) {
    throw RllParseException('unexpected "${c.s[c.i]}" at ${c.i}');
  }
  return els;
}

/// Parses a sequence of elements, stopping at a top-level ',' or ']'.
/// [depth] tracks how many enclosing `[` brackets we're inside.
List<RllElement> _parseSeq(_Cursor c, int depth) {
  final out = <RllElement>[];
  while (c.i < c.s.length) {
    _skipWs(c);
    if (c.i >= c.s.length) break;
    final ch = c.s[c.i];
    if (ch == ',' || ch == ']') break;
    if (ch == '[') {
      out.add(_parseBranch(c, depth));
    } else {
      out.add(_parseInstr(c));
    }
  }
  return out;
}

RllBranch _parseBranch(_Cursor c, int depth) {
  if (depth >= _kMaxBranchDepth) {
    throw RllParseException('branch nesting too deep');
  }
  c.i++; // consume '['
  final legs = <List<RllElement>>[_parseSeq(c, depth + 1)];
  while (c.i < c.s.length && c.s[c.i] == ',') {
    c.i++; // consume ','
    legs.add(_parseSeq(c, depth + 1));
  }
  if (c.i >= c.s.length || c.s[c.i] != ']') {
    throw RllParseException('unclosed branch "["');
  }
  c.i++; // consume ']'
  return RllBranch(legs);
}

RllInstruction _parseInstr(_Cursor c) {
  final start = c.i;
  while (c.i < c.s.length && _isIdent(c.s[c.i])) {
    c.i++;
  }
  final mnemonic = c.s.substring(start, c.i);
  if (mnemonic.isEmpty) {
    throw RllParseException('expected an instruction at ${c.i}');
  }
  _skipWs(c);
  if (c.i >= c.s.length || c.s[c.i] != '(') {
    throw RllParseException('expected "(" after "$mnemonic"');
  }
  c.i++; // consume '('
  final operands = _parseArgs(c);
  return RllInstruction(mnemonic, operands);
}

/// Reads to the matching ')', splitting on top-level ',' (respecting nested
/// () and []). '(' must have been consumed by the caller.
List<String> _parseArgs(_Cursor c) {
  final args = <String>[];
  final buf = StringBuffer();
  var paren = 0, brack = 0;
  var closed = false;
  while (c.i < c.s.length) {
    final ch = c.s[c.i];
    if (ch == ')' && paren == 0 && brack == 0) {
      c.i++;
      closed = true;
      break;
    }
    if (ch == ',' && paren == 0 && brack == 0) {
      args.add(buf.toString().trim());
      buf.clear();
      c.i++;
      continue;
    }
    if (ch == '(') paren++;
    if (ch == ')') paren--;
    if (ch == '[') brack++;
    if (ch == ']') brack--;
    buf.write(ch);
    c.i++;
  }
  if (!closed) throw RllParseException('unclosed "("');
  final last = buf.toString().trim();
  if (last.isNotEmpty || args.isNotEmpty) args.add(last);
  return args;
}

class RllTranslation {
  final List<LdRung> rungs;
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedInstructions;
  final Map<String, int> stubReasons;
  final List<ImportWarning> warnings;
  RllTranslation({
    required this.rungs,
    required this.translatedRungCount,
    required this.stubbedRungCount,
    required this.unsupportedInstructions,
    required this.stubReasons,
    required this.warnings,
  });
}

/// Per-rung bail-out; always caught in [compileRllRungs].
class _RllStub implements Exception {
  final String reason;
  final String detail;
  _RllStub(this.reason, this.detail);
}

/// Compiles a [NeutralLadderBody] into native `LdRung`s. Each rung compiles
/// fully or degrades to a commented placeholder rung (rung index preserved).
/// The one non-stub degrade is a timer/counter with an unresolvable preset
/// (defaulted + warning). Pure, deterministic, never-throws.
RllTranslation compileRllRungs(
  NeutralLadderBody body, {
  required String pouName,
  Map<String, FbDefinition> fbRegistry = const {},
  Map<String, String> fbRenameMap = const {},
}) {
  final rungs = <LdRung>[];
  final warnings = <ImportWarning>[];
  final unsupported = <String>{};
  final reasons = <String, int>{};
  var translated = 0;
  var stubbed = 0;

  for (var i = 0; i < body.rungs.length; i++) {
    final rr = body.rungs[i];
    try {
      final els = parseRllText(rr.text);
      rungs.add(_assembleRung(els, i, rr.comment, unsupported, fbRegistry,
          fbRenameMap, warnings));
      translated++;
    } on RllParseException catch (e) {
      _stub(reasons, 'parse-error', e.message, rr, i, rungs, warnings, pouName);
      stubbed++;
    } on _RllStub catch (e) {
      _stub(reasons, e.reason, e.detail, rr, i, rungs, warnings, pouName);
      stubbed++;
    }
  }

  return RllTranslation(
    rungs: rungs,
    translatedRungCount: translated,
    stubbedRungCount: stubbed,
    unsupportedInstructions: unsupported,
    stubReasons: reasons,
    warnings: warnings,
  );
}

void _stub(Map<String, int> reasons, String reason, String detail, RllRung rr,
    int i, List<LdRung> rungs, List<ImportWarning> warnings, String pouName) {
  reasons[reason] = (reasons[reason] ?? 0) + 1;
  warnings.add(ImportWarning(
      severity: WarningSeverity.warning,
      message: 'POU "$pouName" rung ${i + 1}: not compiled ($reason: $detail).'));
  rungs.add(LdRung(
    rungIndex: i,
    comment: 'Rung not compiled on import ($reason): $detail. Source: ${rr.text}',
    nodes: [
      LdNode(id: kLeftRailId, kind: LdKind.leftRail),
      LdNode(id: kRightRailId, kind: LdKind.rightRail),
    ],
    wires: [LdWire(fromId: kLeftRailId, toId: kRightRailId)],
  ));
}

/// Lowers one rung's element sequence to a main line + parallel branches and
/// builds it. A branch's first leg extends the main line; other legs become
/// `BranchSpec`s spanning that leg's index range. Nested/empty legs stub.
/// A bare `NOP()` at top level is a true no-op: it contributes no node (an
/// all-NOP rung compiles to an empty rail-to-rail rung, not a stub).
LdRung _assembleRung(
  List<RllElement> els,
  int index,
  String comment,
  Set<String> unsupported,
  Map<String, FbDefinition> fbRegistry,
  Map<String, String> fbRenameMap,
  List<ImportWarning> warnings,
) {
  final main = <LdNode>[];
  final branches = <BranchSpec>[];

  LdNode toNode(RllElement e) {
    if (e is! RllInstruction) {
      throw _RllStub('complex-topology', 'nested branch');
    }
    return _instrToNode(e, unsupported, fbRegistry, fbRenameMap, warnings);
  }

  for (final el in els) {
    if (el is RllInstruction) {
      if (el.mnemonic.toUpperCase() == 'NOP') {
        continue; // no-op: contributes nothing to the rendered rung
      }
      main.add(_instrToNode(el, unsupported, fbRegistry, fbRenameMap, warnings));
    } else if (el is RllBranch) {
      for (final leg in el.legs) {
        if (leg.isEmpty) {
          throw _RllStub('complex-topology', 'empty (bypass) branch leg');
        }
        if (leg.any((e) => e is RllBranch)) {
          throw _RllStub('complex-topology', 'nested branch');
        }
      }
      final startIdx = main.length;
      for (final e in el.legs.first) {
        main.add(toNode(e));
      }
      final endIdx = main.length - 1;
      for (var li = 1; li < el.legs.length; li++) {
        branches.add(BranchSpec(
          startIndex: startIdx,
          endIndex: endIdx,
          nodes: [for (final e in el.legs[li]) toNode(e)],
        ));
      }
    }
  }

  return buildRung(index: index, comment: comment, main: main, branches: branches);
}

/// Maps one instruction to an `LdNode`, or throws `_RllStub`. Task 4 inserts the
/// AOI-call branch at the top (before the switch).
LdNode _instrToNode(
  RllInstruction instr,
  Set<String> unsupported,
  Map<String, FbDefinition> fbRegistry,
  Map<String, String> fbRenameMap,
  List<ImportWarning> warnings,
) {
  // Custom-AOI call: a mnemonic that (after fbRenameMap) names an imported AOI
  // routes to an FB-call node. Strict: the arg count must match the interface.
  //
  // Neutral text passes the INSTANCE tag then the AOI's INTERFACE parameters,
  // in declaration order. Internal vars — AOI LocalTags, and the EnableIn/
  // EnableOut an RLL-logic AOI retains — are never passed, so they take part
  // in neither the arity check nor the positional binding. (An FB with no
  // internal vars binds exactly as before: same count, same order.)
  final effective = fbRenameMap[instr.mnemonic] ?? instr.mnemonic;
  final fb = fbRegistry[effective];
  if (fb != null) {
    final iface = [
      for (final v in fb.vars)
        if (v.direction != FbVarDir.internal) v,
    ];
    final ops = instr.operands;
    if (ops.isEmpty || ops.length - 1 != iface.length) {
      unsupported.add(instr.mnemonic);
      throw _RllStub('aoi-mismatch',
          'AOI "$effective" arg count ${ops.isEmpty ? 0 : ops.length - 1} != ${iface.length}');
    }
    final pin = <String, String>{};
    for (var k = 0; k < iface.length; k++) {
      pin[iface[k].name] = ops[k + 1];
    }
    return LdNode(id: '', kind: LdKind.block, blockType: effective,
        variable: ops[0], pinBindings: pin);
  }

  final m = instr.mnemonic.toUpperCase();
  final ops = instr.operands;
  switch (m) {
    case 'XIC':
      return _contact(ops, 'normal');
    case 'XIO':
      return _contact(ops, 'negated');
    case 'ONS':
      return _contact(ops, 'rising');
    case 'OTE':
      return _coil(ops, 'normal');
    case 'OTL':
      return _coil(ops, 'set');
    case 'OTU':
      return _coil(ops, 'reset');
    case 'TON':
    case 'TOF':
    case 'CTU':
    case 'CTD':
    case 'CTUD':
      return _timerCounter(m, ops, warnings);
    case 'EQU':
      return _compare('EQ', ops);
    case 'NEQ':
      return _compare('NE', ops);
    case 'LEQ':
      return _compare('LE', ops);
    case 'GEQ':
      return _compare('GE', ops);
    case 'LES':
      return _compare('LT', ops);
    case 'GRT':
      return _compare('GT', ops);
    case 'ADD':
    case 'SUB':
    case 'MUL':
    case 'DIV':
      return _math(m, ops);
    case 'MOV':
    case 'MOVE':
      return _move(ops);
    default:
      unsupported.add(instr.mnemonic);
      throw _RllStub('unsupported-instruction', 'unsupported instruction "$m"');
  }
}

LdNode _contact(List<String> ops, String mod) {
  if (ops.length != 1) throw _RllStub('unresolved-operand', 'contact needs 1 operand');
  return LdNode(id: '', kind: LdKind.contact, variable: ops[0], modifier: mod);
}

LdNode _coil(List<String> ops, String mod) {
  if (ops.length != 1) throw _RllStub('unresolved-operand', 'coil needs 1 operand');
  return LdNode(id: '', kind: LdKind.coil, variable: ops[0], modifier: mod);
}

LdNode _compare(String op, List<String> ops) {
  if (ops.length != 2) throw _RllStub('unresolved-operand', 'compare needs 2 operands');
  return LdNode(id: '', kind: LdKind.block, blockType: op, operandA: ops[0], operandB: ops[1]);
}

LdNode _math(String op, List<String> ops) {
  if (ops.length != 3) throw _RllStub('unresolved-operand', '$op needs 3 operands');
  return LdNode(id: '', kind: LdKind.block, blockType: op,
      operandA: ops[0], operandB: ops[1], variable: ops[2]);
}

LdNode _move(List<String> ops) {
  if (ops.length != 2) throw _RllStub('unresolved-operand', 'MOV needs 2 operands');
  return LdNode(id: '', kind: LdKind.block, blockType: 'MOVE', operandA: ops[0], variable: ops[1]);
}

/// Timer/counter: variable = instance operand; preset best-effort from a literal
/// second operand, else defaulted + a prominent warning (never silent).
LdNode _timerCounter(String type, List<String> ops, List<ImportWarning> warnings) {
  if (ops.isEmpty) throw _RllStub('unresolved-operand', '$type needs an instance operand');
  final node = LdNode(id: '', kind: LdKind.block, blockType: type, variable: ops[0]);
  final preset = ops.length > 1 ? int.tryParse(ops[1].trim()) : null;
  if (preset != null) {
    node.presetMs = preset;
  } else {
    warnings.add(ImportWarning(
        severity: WarningSeverity.warning,
        message: 'Timer/counter "${ops[0]}" preset could not be resolved from the '
            'neutral text — defaulted, verify.'));
  }
  return node;
}
