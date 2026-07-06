import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fbd_layout.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

PlcProgram _prog(List<FbdBlock> blocks, List<FbdWire> wires) => PlcProgram(
      name: 'L',
      language: 'FunctionBlockDiagram',
      fbdBlocks: blocks,
      fbdWires: wires,
    );

FbdBlock _b(String id, String type, {double x = 0, double y = 0, int inputCount = 2}) =>
    FbdBlock(id: id, type: type, title: id, x: x, y: y, inputCount: inputCount);

FbdWire _w(String from, String fromPin, String to, String toPin) =>
    FbdWire(fromBlockId: from, fromPin: fromPin, toBlockId: to, toPin: toPin);

void main() {
  group('autoArrangeFbd', () {
    test('empty program yields an empty layout', () {
      expect(autoArrangeFbd(_prog([], [])).isEmpty, isTrue);
    });

    test('a source -> gate -> output chain lays out in left-to-right columns', () {
      // A (TAG_INPUT) -> B (AND) -> C (TAG_OUTPUT)
      final p = _prog(
        [
          _b('A', 'TAG_INPUT', x: 999, y: 999),
          _b('B', 'AND', x: 5, y: 5),
          _b('C', 'TAG_OUTPUT', x: 0, y: 0),
        ],
        [
          _w('A', 'OUT', 'B', 'IN1'),
          _w('B', 'OUT', 'C', 'IN'),
        ],
      );
      final layout = autoArrangeFbd(p);

      // Every block placed, and columns increase along the dataflow.
      expect(layout.length, 3);
      expect(layout['A']!.x < layout['B']!.x, isTrue);
      expect(layout['B']!.x < layout['C']!.x, isTrue);
    });

    test('two independent sources feeding one block share a column, target is right of both', () {
      final p = _prog(
        [
          _b('S1', 'TAG_INPUT'),
          _b('S2', 'TAG_INPUT'),
          _b('G', 'AND'),
        ],
        [
          _w('S1', 'OUT', 'G', 'IN1'),
          _w('S2', 'OUT', 'G', 'IN2'),
        ],
      );
      final layout = autoArrangeFbd(p);

      // Both sources in column 0 (same x), the gate strictly to the right.
      expect(layout['S1']!.x, equals(layout['S2']!.x));
      expect(layout['G']!.x > layout['S1']!.x, isTrue);
      // Stacked sources do not overlap vertically.
      expect(layout['S1']!.y != layout['S2']!.y, isTrue);
    });

    test('an unwired block is placed at the first column', () {
      final p = _prog([_b('lonely', 'CONST', x: 500, y: 500)], []);
      final layout = autoArrangeFbd(p);
      final s1 = autoArrangeFbd(_prog([_b('src', 'TAG_INPUT')], []))['src']!;
      // Same leftmost column x as any other source block.
      expect(layout['lonely']!.x, equals(s1.x));
    });

    test('no two blocks share the same position', () {
      final p = _prog(
        [
          _b('A', 'TAG_INPUT'),
          _b('B', 'TAG_INPUT'),
          _b('C', 'TAG_INPUT'),
          _b('D', 'AND'),
          _b('E', 'OR'),
        ],
        [
          _w('A', 'OUT', 'D', 'IN1'),
          _w('B', 'OUT', 'D', 'IN2'),
          _w('C', 'OUT', 'E', 'IN1'),
        ],
      );
      final layout = autoArrangeFbd(p);
      final seen = <String>{};
      for (final pos in layout.values) {
        final key = '${pos.x},${pos.y}';
        expect(seen.contains(key), isFalse, reason: 'overlap at $key');
        seen.add(key);
      }
    });

    test('a feedback cycle does not throw and positions every block', () {
      // A -> B -> A (a 2-cycle) plus a self-loop that must be ignored.
      final p = _prog(
        [_b('A', 'AND'), _b('B', 'OR')],
        [
          _w('A', 'OUT', 'B', 'IN1'),
          _w('B', 'OUT', 'A', 'IN1'),
          _w('A', 'OUT', 'A', 'IN2'), // self-wire, ignored
        ],
      );
      final layout = autoArrangeFbd(p);
      expect(layout.containsKey('A'), isTrue);
      expect(layout.containsKey('B'), isTrue);
    });
  });
}
