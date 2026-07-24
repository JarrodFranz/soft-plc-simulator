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
  return _arrange(program.fbdBlocks, program.fbdWires);
}

/// Like [autoArrangeFbd] but scoped to a single network: lays out only the
/// blocks in network [net] (and considers only the wires whose both endpoints
/// are in that network), so each lane arranges independently. Out-of-range
/// [net] (or an empty network) returns an empty map.
Map<String, ({double x, double y})> autoArrangeFbdNetwork(
    PlcProgram program, int net) {
  final blocks = program.fbdBlocks.where((b) => b.network == net).toList();
  if (blocks.isEmpty) {
    return const {};
  }
  final ids = {for (final b in blocks) b.id};
  final wires = program.fbdWires
      .where((w) => ids.contains(w.fromBlockId) && ids.contains(w.toBlockId))
      .toList();
  return _arrange(blocks, wires);
}

/// The canvas geometry for network [net]: a render [offsetX]/[offsetY] to add to
/// every block's stored (x, y) so the whole diagram — including blocks placed at
/// NEGATIVE coordinates (above/left of the origin) — sits inside a positive
/// [width]×[height] box, floored at [minW]×[minH]. Pure; never throws.
///
/// The editor translates block cards, wire anchors, and the grid by this offset
/// so every block lands inside the sized (hit-testable, gridded) area — a block
/// outside that box paints but can't receive drags, which is why an off-grid
/// block used to pan the page instead of moving. Block coordinates themselves
/// are untouched (wiring/serialization unchanged); only rendering is shifted.
///
/// The offset extends into the negative side only as far as the most negative
/// block requires (plus [pad]); a purely positive diagram keeps a fixed [pad]
/// margin, so ordinary positive dragging never re-normalizes the canvas.
({double offsetX, double offsetY, double width, double height}) fbdCanvasGeometry(
  PlcProgram program,
  int net, {
  double minW = 1600,
  double minH = 1200,
  double pad = 240,
}) {
  // min* start at 0 so a purely positive diagram yields offset == pad (a fixed
  // margin), and only genuinely negative blocks push the origin further out.
  var minX = 0.0;
  var minY = 0.0;
  var maxRight = 0.0;
  var maxBottom = 0.0;
  for (final b in program.fbdBlocks) {
    if (b.network != net) {
      continue;
    }
    if (b.x < minX) {
      minX = b.x;
    }
    if (b.y < minY) {
      minY = b.y;
    }
    final right = b.x + _kBlockWidth;
    final bottom = b.y + _blockHeight(b);
    if (right > maxRight) {
      maxRight = right;
    }
    if (bottom > maxBottom) {
      maxBottom = bottom;
    }
  }
  // A purely positive diagram gets offset 0 (blocks render at their stored
  // coordinates, unchanged); only genuinely negative blocks introduce an offset
  // that pulls them back inside the box, with [pad] of breathing room.
  final offsetX = minX < 0 ? pad - minX : 0.0;
  final offsetY = minY < 0 ? pad - minY : 0.0;
  final w = maxRight + offsetX + pad;
  final h = maxBottom + offsetY + pad;
  return (
    offsetX: offsetX,
    offsetY: offsetY,
    width: w < minW ? minW : w,
    height: h < minH ? minH : h,
  );
}

/// Shared dependency-depth layout over an arbitrary [blocks]/[wires] slice.
Map<String, ({double x, double y})> _arrange(
    List<FbdBlock> blocks, List<FbdWire> wires) {
  if (blocks.isEmpty) {
    return const {};
  }
  final ids = {for (final b in blocks) b.id};

  // Dependency source-ids per block (blocks feeding any of its input pins);
  // self-wires and dangling endpoints are ignored.
  final deps = <String, List<String>>{for (final b in blocks) b.id: <String>[]};
  for (final w in wires) {
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
