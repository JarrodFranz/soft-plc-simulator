import 'project_model.dart';
import 'fbd_pins.dart';

// Layout geometry — the block width mirrors the editor's `_kBlockWidth`; the
// rest are generous spacing values so an auto-arranged diagram breathes.
const double _kBlockWidth = 180;
const double _kHeaderHeight = 40;
const double _kPinRowHeight = 30;
const double _kFooterHeight = 44;
const double _kLeftMargin = 60;
const double _kTopMargin = 60;
const double _kColumnGap = 110; // horizontal gap between dependency columns
const double _kRowGap = 48; // vertical gap between blocks stacked in a column

double _blockHeight(FbdBlock b) {
  final ins = fbdInputPins(b.type, inputCount: b.inputCount).length;
  final outs = fbdOutputPins(b.type).length;
  final rows = [ins, outs, 1].reduce((a, c) => a > c ? a : c);
  return _kHeaderHeight + rows * _kPinRowHeight + _kFooterHeight;
}

/// Computes a tidy dependency-ordered layout for [program]'s FBD blocks: each
/// block is placed in a column equal to its dataflow depth (to the right of
/// every block feeding one of its inputs) and stacked vertically within that
/// column with generous spacing, so signals read left-to-right. Pure; never
/// throws; feedback cycles are broken deterministically so every block still
/// gets a position. Returns a map of block id -> (x, y); an empty program (or
/// a program with no blocks) returns an empty map.
Map<String, ({double x, double y})> autoArrangeFbd(PlcProgram program) {
  final blocks = program.fbdBlocks;
  if (blocks.isEmpty) {
    return const {};
  }
  final ids = {for (final b in blocks) b.id};

  // Dependency source-ids per block (blocks feeding any of its input pins);
  // self-wires and dangling endpoints are ignored.
  final deps = <String, List<String>>{for (final b in blocks) b.id: <String>[]};
  for (final w in program.fbdWires) {
    if (w.toBlockId != w.fromBlockId &&
        ids.contains(w.toBlockId) &&
        ids.contains(w.fromBlockId)) {
      deps[w.toBlockId]!.add(w.fromBlockId);
    }
  }

  // Longest-path depth (column index) via cycle-safe memoized DFS. A block
  // currently being computed that is reached again is a back-edge (cycle) and
  // is treated as depth 0 so the recursion terminates.
  final column = <String, int>{};
  final computing = <String>{};
  int depthOf(String id) {
    final cached = column[id];
    if (cached != null) {
      return cached;
    }
    if (!computing.add(id)) {
      return 0; // back-edge in a cycle
    }
    var maxDep = -1;
    for (final d in deps[id]!) {
      final dd = depthOf(d);
      if (dd > maxDep) {
        maxDep = dd;
      }
    }
    computing.remove(id);
    final col = maxDep + 1;
    column[id] = col;
    return col;
  }

  for (final b in blocks) {
    depthOf(b.id);
  }

  // Group blocks by column, preserving their original order within a column.
  final byColumn = <int, List<FbdBlock>>{};
  for (final b in blocks) {
    byColumn.putIfAbsent(column[b.id]!, () => <FbdBlock>[]).add(b);
  }

  final result = <String, ({double x, double y})>{};
  final sortedCols = byColumn.keys.toList()..sort();
  for (final c in sortedCols) {
    final x = _kLeftMargin + c * (_kBlockWidth + _kColumnGap);
    var y = _kTopMargin;
    for (final b in byColumn[c]!) {
      result[b.id] = (x: x, y: y);
      y += _blockHeight(b) + _kRowGap;
    }
  }
  return result;
}
