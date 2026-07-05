// Pin registry for Function Block Diagram (FBD) blocks — pure, IEC 61131-3
// style pin names. Maps a block `type` (+ input count for extensible ops) to
// its ordered input and output pin names. Never throws: unknown types yield
// empty pin lists.
library;

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
    default:
      return const [];
  }
}
