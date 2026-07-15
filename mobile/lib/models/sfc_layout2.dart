// Pure 2D layout for the SFC region tree (SFC-v2 Task 4).
//
// Turns a region tree (`SfcRegion` from Task 3) into concrete 2D geometry that
// a canvas (Task 5) can draw directly: absolute-positioned [SfcBox]es (step /
// transition / goto / fork-bar / join-bar), [SfcConn] connector segments, and
// an overall bounding [SfcLayout.width] / [SfcLayout.height].
//
// This module is PURE Dart — it imports only the domain model and the region
// tree, holds no Flutter dependency, and produces no side effects.
//
// Algorithm: a single recursive pass builds each region into a `_Frag` whose
// coordinates are LOCAL (top-left at the origin). A region is sized from its
// children (bottom-up), children are placed relative to it, then the whole
// fragment is translated into its parent's coordinate space (top-down). Every
// fragment is symmetric: its entry (top) and exit (bottom) connection points
// sit on the horizontal centre, so a parent stacks children by centring them
// and drops straight vertical connectors between exit and entry.
//
// Handoff caveats honoured (see sfc_region.dart): `AltRegion.merge` and
// `ParRegion.after` are POINTERS to a step that the ENCLOSING sequence places
// authoritatively — this module renders the connector toward the convergence /
// post-join funnel but never emits a second box for that step.

import 'project_model.dart';
import 'sfc_region.dart';

// ---- output types (consumed verbatim by the Task 5 canvas) ------------------

/// A positioned rectangle. [kind] is one of
/// `'step' | 'trans' | 'goto' | 'forkBar' | 'joinBar'`. [step] is set for
/// `'step'` boxes; [transition] is set for `'trans'` / `'goto'` boxes and for
/// the fork / join bars (carrying the originating transition).
class SfcBox {
  final String kind;
  final SfcStep? step;
  final SfcTransition? transition;
  final double x;
  final double y;
  final double w;
  final double h;

  SfcBox({
    required this.kind,
    this.step,
    this.transition,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}

/// A connector line segment from (x1,y1) to (x2,y2). [doubleBar] is true for
/// the parallel fork / join links (drawn as the SFC double line).
class SfcConn {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final bool doubleBar;

  SfcConn({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.doubleBar = false,
  });
}

/// The full laid-out chart: every [boxes] / [conns] coordinate lies within
/// `[0, width] x [0, height]`.
class SfcLayout {
  final List<SfcBox> boxes;
  final List<SfcConn> conns;
  final double width;
  final double height;

  SfcLayout({
    required this.boxes,
    required this.conns,
    required this.width,
    required this.height,
  });
}

// ---- metrics (all layout magnitudes live here as named consts) --------------

const double _kStepW = 140;
const double _kStepH = 64;
const double _kTransW = 160;
const double _kTransH = 40;
const double _kGotoW = 120;
const double _kGotoH = 32;
const double _kVGap = 28;
const double _kBranchColGap = 32;
const double _kBarH = 10;

double _max(double a, double b) => a > b ? a : b;

// ---- internal fragment ------------------------------------------------------

/// A laid-out region in LOCAL coordinates (top-left at origin). [entryX] is the
/// x of the top connection point (at y = 0) and [exitX] the x of the bottom
/// connection point (at y = [h]); both sit on the centre for every region kind.
class _Frag {
  final List<SfcBox> boxes;
  final List<SfcConn> conns;
  final double w;
  final double h;
  final double entryX;
  final double exitX;

  _Frag(this.boxes, this.conns, this.w, this.h, this.entryX, this.exitX);
}

/// Translate a fragment by (dx, dy).
_Frag _shift(_Frag f, double dx, double dy) {
  final boxes = <SfcBox>[
    for (final b in f.boxes)
      SfcBox(
        kind: b.kind,
        step: b.step,
        transition: b.transition,
        x: b.x + dx,
        y: b.y + dy,
        w: b.w,
        h: b.h,
      ),
  ];
  final conns = <SfcConn>[
    for (final c in f.conns)
      SfcConn(
        x1: c.x1 + dx,
        y1: c.y1 + dy,
        x2: c.x2 + dx,
        y2: c.y2 + dy,
        doubleBar: c.doubleBar,
      ),
  ];
  return _Frag(boxes, conns, f.w, f.h, f.entryX + dx, f.exitX + dx);
}

// ---- public entry point -----------------------------------------------------

/// Lay out [root] into absolute 2D geometry. The returned [SfcLayout.width] /
/// [SfcLayout.height] bound every emitted box.
SfcLayout layoutSfcRegion(SfcRegion root) {
  final f = _frag(root);
  var width = f.w;
  var height = f.h;
  for (final b in f.boxes) {
    width = _max(width, b.x + b.w);
    height = _max(height, b.y + b.h);
  }
  return SfcLayout(
    boxes: f.boxes,
    conns: f.conns,
    width: width,
    height: height,
  );
}

// ---- recursive layout -------------------------------------------------------

_Frag _frag(SfcRegion r) {
  if (r is StepRegion) {
    return _stepFrag(r.step);
  }
  if (r is TransRegion) {
    return _transFrag(r);
  }
  if (r is SeqRegion) {
    return _seqFrag(r.items);
  }
  if (r is AltRegion) {
    return _altFrag(r);
  }
  if (r is ParRegion) {
    return _parFrag(r);
  }
  return _Frag(const <SfcBox>[], const <SfcConn>[], 0, 0, 0, 0);
}

_Frag _stepFrag(SfcStep s) {
  final box = SfcBox(kind: 'step', step: s, x: 0, y: 0, w: _kStepW, h: _kStepH);
  return _Frag([box], const <SfcConn>[], _kStepW, _kStepH, _kStepW / 2,
      _kStepW / 2);
}

_Frag _transFrag(TransRegion t) {
  final goto = t.isGoto;
  final kind = goto ? 'goto' : 'trans';
  final w = goto ? _kGotoW : _kTransW;
  final h = goto ? _kGotoH : _kTransH;
  final box =
      SfcBox(kind: kind, transition: t.transition, x: 0, y: 0, w: w, h: h);
  return _Frag([box], const <SfcConn>[], w, h, w / 2, w / 2);
}

/// Trans fragment for a raw guard transition (rendered as a plain trans block).
_Frag _guardFrag(SfcTransition g) {
  final box = SfcBox(
      kind: 'trans', transition: g, x: 0, y: 0, w: _kTransW, h: _kTransH);
  return _Frag([box], const <SfcConn>[], _kTransW, _kTransH, _kTransW / 2,
      _kTransW / 2);
}

/// Stack [items] vertically, centred on a common axis, with straight vertical
/// connectors between each item's exit and the next item's entry.
_Frag _seqFrag(List<SfcRegion> items) {
  final frags = <_Frag>[for (final it in items) _frag(it)];
  if (frags.isEmpty) {
    return _Frag(const <SfcBox>[], const <SfcConn>[], 0, 0, 0, 0);
  }

  var w = 0.0;
  for (final f in frags) {
    w = _max(w, f.w);
  }

  final boxes = <SfcBox>[];
  final conns = <SfcConn>[];
  var y = 0.0;
  var firstEntryX = w / 2;
  var lastExitX = w / 2;
  var hasPrev = false;
  var prevExitX = 0.0;
  var prevBottomY = 0.0;

  for (var i = 0; i < frags.length; i++) {
    final f = frags[i];
    final dx = (w - f.w) / 2;
    final placed = _shift(f, dx, y);
    if (i == 0) {
      firstEntryX = placed.entryX;
    }
    if (hasPrev) {
      conns.add(SfcConn(
        x1: prevExitX,
        y1: prevBottomY,
        x2: placed.entryX,
        y2: y,
      ));
    }
    boxes.addAll(placed.boxes);
    conns.addAll(placed.conns);
    prevExitX = placed.exitX;
    prevBottomY = y + f.h;
    lastExitX = placed.exitX;
    hasPrev = true;
    y += f.h + _kVGap;
  }

  final totalH = y - _kVGap;
  return _Frag(boxes, conns, w, totalH, firstEntryX, lastExitX);
}

/// Alternative divergence/convergence: [head] on top, then each guarded branch
/// in its own adjacent column, funnelling down to a shared convergence point
/// (the enclosing sequence draws the final link to the merge step).
_Frag _altFrag(AltRegion alt) {
  final headF = _stepFrag(alt.head);

  // Each column = its guard transition block, then the branch body.
  final cols = <_Frag>[];
  for (var i = 0; i < alt.branches.length; i++) {
    if (i < alt.guards.length) {
      // Prepend the divergence guard as a trans block above the branch body.
      cols.add(_columnWithGuard(alt.guards[i], alt.branches[i]));
    } else {
      cols.add(_seqFrag(alt.branches[i]));
    }
  }

  if (cols.isEmpty) {
    return headF;
  }

  var branchRowW = 0.0;
  for (final c in cols) {
    branchRowW += c.w;
  }
  branchRowW += _kBranchColGap * (cols.length - 1);

  final w = _max(headF.w, branchRowW);

  final boxes = <SfcBox>[];
  final conns = <SfcConn>[];

  // Head centred at top.
  final headDx = (w - headF.w) / 2;
  final placedHead = _shift(headF, headDx, 0);
  boxes.addAll(placedHead.boxes);
  conns.addAll(placedHead.conns);
  final headExitX = placedHead.exitX;
  final headBottomY = headF.h;

  final branchTopY = headF.h + _kVGap;
  final startX = (w - branchRowW) / 2;

  var cx = startX;
  var maxColH = 0.0;
  final exits = <List<double>>[];
  for (final col in cols) {
    final placed = _shift(col, cx, branchTopY);
    // Divergence link: head bottom-centre to this column's entry.
    conns.add(SfcConn(
      x1: headExitX,
      y1: headBottomY,
      x2: placed.entryX,
      y2: branchTopY,
    ));
    boxes.addAll(placed.boxes);
    conns.addAll(placed.conns);
    exits.add([placed.exitX, branchTopY + col.h]);
    maxColH = _max(maxColH, col.h);
    cx += col.w + _kBranchColGap;
  }

  final convergeY = branchTopY + maxColH;
  final convergeX = w / 2;
  for (final e in exits) {
    // Convergence link: each column's exit to the shared merge funnel.
    conns.add(SfcConn(x1: e[0], y1: e[1], x2: convergeX, y2: convergeY));
  }

  return _Frag(boxes, conns, w, convergeY, w / 2, w / 2);
}

/// A single Alt column: the guard transition block stacked above the branch.
_Frag _columnWithGuard(SfcTransition guard, List<SfcRegion> branch) {
  final guardF = _guardFrag(guard);
  final bodyF = _seqFrag(branch);

  if (bodyF.boxes.isEmpty) {
    return guardF;
  }

  final w = _max(guardF.w, bodyF.w);
  final boxes = <SfcBox>[];
  final conns = <SfcConn>[];

  final gDx = (w - guardF.w) / 2;
  final placedGuard = _shift(guardF, gDx, 0);
  boxes.addAll(placedGuard.boxes);
  conns.addAll(placedGuard.conns);

  final bodyY = guardF.h + _kVGap;
  final bDx = (w - bodyF.w) / 2;
  final placedBody = _shift(bodyF, bDx, bodyY);
  conns.add(SfcConn(
    x1: placedGuard.exitX,
    y1: guardF.h,
    x2: placedBody.entryX,
    y2: bodyY,
  ));
  boxes.addAll(placedBody.boxes);
  conns.addAll(placedBody.conns);

  final totalH = bodyY + bodyF.h;
  return _Frag(boxes, conns, w, totalH, w / 2, w / 2);
}

/// Parallel fork/join: a [forkBar] on top and a [joinBar] on the bottom, each
/// spanning the branch columns, with double-line connectors to every branch.
_Frag _parFrag(ParRegion par) {
  final cols = <_Frag>[for (final b in par.branches) _seqFrag(b)];

  var branchRowW = 0.0;
  for (final c in cols) {
    branchRowW += c.w;
  }
  if (cols.length > 1) {
    branchRowW += _kBranchColGap * (cols.length - 1);
  }

  final w = _max(branchRowW, _kStepW);
  final startX = (w - branchRowW) / 2;

  final boxes = <SfcBox>[];
  final conns = <SfcConn>[];

  // Fork bar spans the branch columns.
  boxes.add(SfcBox(
    kind: 'forkBar',
    transition: par.fork,
    x: startX,
    y: 0,
    w: branchRowW,
    h: _kBarH,
  ));

  const branchTopY = _kBarH + _kVGap;
  var cx = startX;
  var maxColH = 0.0;
  final exits = <double>[];
  for (final col in cols) {
    final placed = _shift(col, cx, branchTopY);
    // Fork link: bar bottom down into the branch (double line).
    conns.add(SfcConn(
      x1: placed.entryX,
      y1: _kBarH,
      x2: placed.entryX,
      y2: branchTopY,
      doubleBar: true,
    ));
    boxes.addAll(placed.boxes);
    conns.addAll(placed.conns);
    exits.add(placed.exitX);
    maxColH = _max(maxColH, col.h);
    cx += col.w + _kBranchColGap;
  }

  final joinY = branchTopY + maxColH + _kVGap;
  boxes.add(SfcBox(
    kind: 'joinBar',
    transition: par.join,
    x: startX,
    y: joinY,
    w: branchRowW,
    h: _kBarH,
  ));

  final branchBottomY = branchTopY + maxColH;
  for (final ex in exits) {
    // Join link: branch bottom up into the join bar (double line).
    conns.add(SfcConn(
      x1: ex,
      y1: branchBottomY,
      x2: ex,
      y2: joinY,
      doubleBar: true,
    ));
  }

  final totalH = joinY + _kBarH;
  return _Frag(boxes, conns, w, totalH, w / 2, w / 2);
}
