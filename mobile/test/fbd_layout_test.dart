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

  group('fbdCanvasGeometry', () {
    test('an empty network floors at the default minimum with no offset', () {
      final geo = fbdCanvasGeometry(_prog([], []), 0);
      expect(geo.width, 1600);
      expect(geo.height, 1200);
      // No negative blocks -> no render offset (blocks draw at their real coords).
      expect(geo.offsetX, 0);
      expect(geo.offsetY, 0);
    });

    test('a purely positive network floors at the minimum with no offset', () {
      final p = _prog([_b('A', 'TAG_INPUT', x: 20, y: 20)], []);
      final geo = fbdCanvasGeometry(p, 0);
      expect(geo.width, 1600);
      expect(geo.height, 1200);
      // A positive-only diagram is not re-normalized: it renders unshifted.
      expect(geo.offsetX, 0);
      expect(geo.offsetY, 0);
    });

    test('a block far to the right grows the width to contain it (never clips)', () {
      // Auto-arrange can push a deep column past the old fixed 1600 width.
      final p = _prog([_b('A', 'TAG_INPUT', x: 2000, y: 20)], []);
      final geo = fbdCanvasGeometry(p, 0);
      // Must reach past the block's right edge (x + block width) with padding.
      expect(geo.width, greaterThan(2000 + 180));
      expect(geo.height, 1200); // vertical still at floor
    });

    test('a block far below grows the height to contain it', () {
      final p = _prog([_b('A', 'TAG_INPUT', x: 20, y: 1500)], []);
      final geo = fbdCanvasGeometry(p, 0);
      expect(geo.height, greaterThan(1500));
      expect(geo.width, 1600);
    });

    test('a negative-coordinate block is pulled inside the box by the offset', () {
      // A block placed above/left of the origin must render at a POSITIVE canvas
      // position (block.x + offsetX >= 0) so it stays inside the hit-testable box.
      final p = _prog([_b('A', 'AND', x: -500, y: -300)], []);
      final geo = fbdCanvasGeometry(p, 0);
      expect(-500 + geo.offsetX, greaterThanOrEqualTo(0));
      expect(-300 + geo.offsetY, greaterThanOrEqualTo(0));
      // The offset extends further than the default pad to make room for it.
      final empty = fbdCanvasGeometry(_prog([], []), 0);
      expect(geo.offsetX, greaterThan(empty.offsetX));
      expect(geo.offsetY, greaterThan(empty.offsetY));
    });

    test('only blocks in the queried network count toward its geometry', () {
      // A block way out in network 1 must not inflate network 0's canvas.
      final p = _prog([
        _b('A', 'TAG_INPUT', x: 20, y: 20),
        FbdBlock(id: 'far', type: 'TAG_INPUT', title: 'far', x: 9000, y: 9000, network: 1),
      ], []);
      final geo0 = fbdCanvasGeometry(p, 0);
      expect(geo0.width, 1600);
      expect(geo0.height, 1200);
      // Network 1, by contrast, grows to contain its far-out block.
      final geo1 = fbdCanvasGeometry(p, 1);
      expect(geo1.width, greaterThan(9000));
      expect(geo1.height, greaterThan(9000));
    });
  });
}
