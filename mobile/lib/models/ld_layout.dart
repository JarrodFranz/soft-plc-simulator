import 'project_model.dart';

/// Horizontal column pitch (cell + wire).
const double kLdColW = 116.0;

/// Element cell width.
const double kLdCellW = 66.0;

/// Gap between a right-pinned coil's right edge and the right rail.
const double kLdCoilRailGap = 40.0;

/// Left-anchored x for a grid column.
double ldColX(int col) => col * kLdColW;

/// Left-x of a node. Coils right-anchor against the rail; everything else
/// left-anchors from L1 at its assigned column.
double ldNodeX(LdNode n, int col, double width) {
  if (n.kind == LdKind.coil) {
    return width - kLdCellW - kLdCoilRailGap;
  }
  return ldColX(col);
}

/// Minimum canvas width so left-anchored input elements never overlap the
/// right-pinned coil zone.
double ldMinContentWidth(LdRung rung, Map<String, int> col) {
  double maxInputRight = kLdColW;
  for (final n in rung.nodes) {
    if (n.kind == LdKind.coil ||
        n.kind == LdKind.leftRail ||
        n.kind == LdKind.rightRail) {
      continue;
    }
    final right = ldColX(col[n.id] ?? 0) + kLdCellW;
    if (right > maxInputRight) {
      maxInputRight = right;
    }
  }
  return maxInputRight + kLdCoilRailGap + kLdCellW + 16.0;
}

LdNode _nodeById(LdRung rung, String id) =>
    rung.nodes.firstWhere((n) => n.id == id);

/// A contact/block may be inserted on a wire only if it would not follow a
/// coil (coils are terminal).
bool canInsertContactOnWire(LdRung rung, LdWire w) =>
    _nodeById(rung, w.fromId).kind != LdKind.coil;

/// A coil may be inserted only on a terminal segment (into the right rail)
/// whose path does not already end in a coil — keeping coils terminal and
/// rightmost.
bool canInsertCoilOnWire(LdRung rung, LdWire w) =>
    _nodeById(rung, w.toId).kind == LdKind.rightRail &&
    _nodeById(rung, w.fromId).kind != LdKind.coil;
