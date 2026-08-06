import 'project_model.dart';
import 'fbd_pins.dart';

// Layout geometry. These are the ONE source of truth for a block's rendered
// extents — the editor's card is built from the same numbers, and both
// auto-arrange and new-block placement measure against them.
const double kFbdBlockWidth = 180;
const double kFbdBlockHeaderHeight = 40;
const double kFbdPinRowHeight = 30;
const double kFbdBlockFooterHeight = 44;

/// The canvas grid interval (`GridPaper(interval: …)` behind the blocks), and
/// therefore the step a placement scan moves by, so new blocks land on the
/// same grid the user sees.
const double kFbdGridStep = 40;

/// Where a block added from the palette lands when nothing is in its way.
const double kFbdDefaultBlockX = 150;
const double kFbdDefaultBlockY = 150;

const double _kLeftMargin = 60;
const double _kTopMargin = 60;
const double _kColumnGap = 110; // horizontal gap between dependency columns
const double _kRowGap = 48; // vertical gap between blocks stacked in a column

double _heightForRows(int ins, int outs) {
  final rows = [ins, outs, 1].reduce((a, c) => a > c ? a : c);
  return kFbdBlockHeaderHeight + rows * kFbdPinRowHeight + kFbdBlockFooterHeight;
}

double _blockHeight(FbdBlock b) => _heightForRows(
      fbdInputPins(b.type, inputCount: b.inputCount).length,
      fbdOutputPins(b.type).length,
    );

/// Rendered height of [b] as the editor actually draws it: a block's card grows
/// one pin row at a time, and for a CUSTOM function block the pin count comes
/// from the FB's own declared vars rather than the built-in registry — hence
/// the [project]. Pure; never throws.
double fbdBlockHeightFor(PlcProject project, FbdBlock b) => _heightForRows(
      fbdInputPinsFor(project, b).length,
      fbdOutputPinsFor(project, b).length,
    );

/// Finds a position for [candidate] in [program]'s network that clears every
/// block already there (QA #14: a palette add used to drop on a fixed anchor,
/// landing on top of whatever was already at that spot).
///
/// Scans outward from ([anchorX], [anchorY]) in [gridStep] increments — across
/// a row first, then down to the next row — and returns the first candidate
/// position whose bounds intersect nothing. The scan is capped at
/// [maxColumns] x [maxRows] steps; if the whole capped region is occupied the
/// result is the anchor plus a rotating stacking offset, so successive adds on
/// a saturated canvas are at least individually grabbable rather than exactly
/// coincident.
///
/// [candidate] is measured but never mutated, and is ignored if it happens to
/// already be in `program.fbdBlocks` (matched by id). Pure; never throws.
({double x, double y}) findFreeFbdBlockSlot(
  PlcProject project,
  PlcProgram program,
  FbdBlock candidate, {
  int? network,
  double anchorX = kFbdDefaultBlockX,
  double anchorY = kFbdDefaultBlockY,
  double gridStep = kFbdGridStep,
  int maxColumns = 24,
  int maxRows = 24,
}) {
  final net = network ?? candidate.network;
  final siblings = [
    for (final b in program.fbdBlocks)
      if (b.network == net && b.id != candidate.id) b,
  ];
  if (siblings.isEmpty) {
    return (x: anchorX, y: anchorY);
  }

  final step = gridStep > 0 ? gridStep : kFbdGridStep;
  final height = fbdBlockHeightFor(project, candidate);
  final occupied = [
    for (final b in siblings) (x: b.x, y: b.y, h: fbdBlockHeightFor(project, b)),
  ];

  bool isFree(double x, double y) {
    for (final o in occupied) {
      final hit = x < o.x + kFbdBlockWidth &&
          o.x < x + kFbdBlockWidth &&
          y < o.y + o.h &&
          o.y < y + height;
      if (hit) {
        return false;
      }
    }
    return true;
  }

  final cols = maxColumns < 0 ? 0 : maxColumns;
  final rows = maxRows < 0 ? 0 : maxRows;
  for (var row = 0; row <= rows; row++) {
    for (var col = 0; col <= cols; col++) {
      final x = anchorX + col * step;
      final y = anchorY + row * step;
      if (isFree(x, y)) {
        return (x: x, y: y);
      }
    }
  }

  final stack = (siblings.length % 8) + 1;
  return (x: anchorX + stack * step, y: anchorY + stack * step);
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
    final right = b.x + kFbdBlockWidth;
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
    final x = _kLeftMargin + c * (kFbdBlockWidth + _kColumnGap);
    var y = _kTopMargin;
    for (final b in byColumn[c]!) {
      result[b.id] = (x: x, y: y);
      y += _blockHeight(b) + _kRowGap;
    }
  }
  return result;
}
