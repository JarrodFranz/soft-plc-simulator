// Pin registry for Function Block Diagram (FBD) blocks — pure, IEC 61131-3
// style pin names. Maps a block `type` (+ input count for extensible ops) to
// its ordered input and output pin names. Never throws: unknown types yield
// empty pin lists.
library;

import 'project_model.dart';
import 'tag_resolver.dart';

/// Ordered input pin names for a block [type]. [inputCount] only affects the
/// extensible operators (AND/OR/ADD/MUL); it is ignored otherwise.
List<String> fbdInputPins(String type, {int inputCount = 2}) {
  switch (type) {
    case 'TAG_INPUT':
    case 'CONST':
      return const [];
    case 'TAG_OUTPUT':
      return const ['IN'];
    case 'NOT':
      return const ['IN'];
    case 'AND':
    case 'OR':
    case 'ADD':
    case 'MUL':
      final n = inputCount < 1 ? 1 : inputCount;
      return [for (var i = 1; i <= n; i++) 'IN$i'];
    case 'SUB':
    case 'DIV':
      return const ['IN1', 'IN2'];
    case 'GT':
    case 'LT':
    case 'GE':
    case 'LE':
    case 'EQ':
    case 'NE':
      return const ['IN1', 'IN2'];
    case 'LIMIT':
      return const ['MN', 'IN', 'MX'];
    case 'SEL':
      return const ['G', 'IN0', 'IN1'];
    case 'TON':
    case 'TOF':
      return const ['IN', 'PT'];
    case 'PID':
      return const ['SP', 'PV', 'KP', 'KI', 'KD'];
    case 'CTU':
      return const ['CU', 'R', 'PV'];
    case 'CTD':
      return const ['CD', 'LD', 'PV'];
    case 'CTUD':
      return const ['CU', 'CD', 'R', 'LD', 'PV'];
    case 'R_TRIG':
    case 'F_TRIG':
      return const ['CLK'];
    case 'TP':
      return const ['IN', 'PT'];
    default:
      return const [];
  }
}

/// Ordered output pin names for a block [type]. Never throws: unknown types
/// yield an empty list.
List<String> fbdOutputPins(String type) {
  switch (type) {
    case 'TAG_INPUT':
    case 'CONST':
      return const ['OUT'];
    case 'TAG_OUTPUT':
      return const [];
    case 'NOT':
    case 'AND':
    case 'OR':
    case 'ADD':
    case 'MUL':
    case 'SUB':
    case 'DIV':
    case 'GT':
    case 'LT':
    case 'GE':
    case 'LE':
    case 'EQ':
    case 'NE':
    case 'LIMIT':
    case 'SEL':
      return const ['OUT'];
    case 'TON':
    case 'TOF':
      return const ['Q', 'ET'];
    case 'PID':
      return const ['CV'];
    case 'CTU':
    case 'CTD':
      return const ['Q', 'CV'];
    case 'CTUD':
      return const ['QU', 'QD', 'CV'];
    case 'R_TRIG':
    case 'F_TRIG':
      return const ['Q'];
    case 'TP':
      return const ['Q', 'ET'];
    default:
      return const [];
  }
}

/// Every built-in FBD block `type` string handled by the `fbdInputPins`/
/// `fbdOutputPins` switches above (the union of every `case` label). This is
/// the canonical reserved set for FBD: `fbdInputPinsFor`/`fbdOutputPinsFor`
/// (and `fbd_exec.dart`'s own block dispatch) resolve `fbDefinitionFor` BEFORE
/// falling back to these built-ins, so a custom function block sharing one of
/// these names would silently shadow the built-in block project-wide instead
/// of erroring. Kept as a plain literal (not derived via reflection — Dart
/// can't enumerate switch-case labels at runtime) with a guard test
/// (`fbd_pins_test.dart`) that checks every entry actually yields non-empty
/// pins, so a future edit to the switches above that drops an entry here
/// fails loudly.
const List<String> kFbdBuiltinBlockTypes = [
  'TAG_INPUT', 'TAG_OUTPUT', 'CONST',
  'NOT', 'AND', 'OR',
  'ADD', 'SUB', 'MUL', 'DIV',
  'GT', 'LT', 'GE', 'LE', 'EQ', 'NE',
  'LIMIT', 'SEL',
  'TON', 'TOF', 'PID', 'CTU', 'CTD', 'CTUD',
  'R_TRIG', 'F_TRIG', 'TP',
];

/// Ordered input pin names for block [b] in project [p]. When `b.type` names
/// a custom function block (see `fbDefinitionFor`), returns that FB's
/// INPUT-direction var names in declaration order; otherwise falls back to
/// the built-in registry (`fbdInputPins`). Never throws.
List<String> fbdInputPinsFor(PlcProject p, FbdBlock b) {
  final fb = fbDefinitionFor(p, b.type);
  if (fb != null) {
    return [
      for (final v in fb.vars)
        if (v.direction == FbVarDir.input) v.name,
    ];
  }
  return fbdInputPins(b.type, inputCount: b.inputCount);
}

/// Ordered output pin names for block [b] in project [p]. When `b.type`
/// names a custom function block, returns that FB's OUTPUT-direction var
/// names in declaration order (these names ARE the output pin names read by
/// downstream wires); otherwise falls back to the built-in registry
/// (`fbdOutputPins`). Never throws.
List<String> fbdOutputPinsFor(PlcProject p, FbdBlock b) {
  final fb = fbDefinitionFor(p, b.type);
  if (fb != null) {
    return [
      for (final v in fb.vars)
        if (v.direction == FbVarDir.output) v.name,
    ];
  }
  return fbdOutputPins(b.type);
}
