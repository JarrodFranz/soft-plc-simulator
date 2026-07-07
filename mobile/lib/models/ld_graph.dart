import 'project_model.dart';

/// A parallel branch spanning `main[startIndex..endIndex]` inclusive.
class BranchSpec {
  final int startIndex;
  final int endIndex;
  final List<LdNode> nodes;
  BranchSpec({required this.startIndex, required this.endIndex, required this.nodes});
}

/// A lightweight handle onto a branch lane in a rung.
class LdBranchView {
  final int lane;
  final String firstNodeId;
  final String lastNodeId;
  LdBranchView({required this.lane, required this.firstNodeId, required this.lastNodeId});
}

const String kLeftRailId = 'L';
const String kRightRailId = 'R';

/// Generates a node id not already present in [rung]. Monotonic (max+1) so a
/// deleted node's id is never reused — freed ids would resurrect stale
/// edge/pulse state in the execution runtime.
String newNodeId(LdRung rung) {
  int next = 0;
  for (final t in rung.nodes) {
    if (t.id.startsWith('n')) {
      final num = int.tryParse(t.id.substring(1));
      if (num != null && num >= next) {
        next = num + 1;
      }
    }
  }
  return 'n$next';
}

int maxLane(LdRung rung) {
  int m = 0;
  for (final n in rung.nodes) {
    if (n.row > m) {
      m = n.row;
    }
  }
  return m;
}

int _laneOfNode(LdRung rung, String id) {
  for (final n in rung.nodes) {
    if (n.id == id) {
      return n.row;
    }
  }
  return 0;
}

/// Builds a rung from an ordered main-line list plus optional parallel branches.
LdRung buildRung({
  required int index,
  String comment = '',
  required List<LdNode> main,
  List<BranchSpec> branches = const [],
}) {
  final left = LdNode(id: kLeftRailId, kind: LdKind.leftRail);
  final right = LdNode(id: kRightRailId, kind: LdKind.rightRail);
  final nodes = <LdNode>[left, right];
  final wires = <LdWire>[];

  // Assign ids to the main line and wire it in series, rail to rail.
  for (int i = 0; i < main.length; i++) {
    main[i].id = 'm$i';
    main[i].row = 0;
    nodes.add(main[i]);
  }
  String prev = left.id;
  for (int i = 0; i < main.length; i++) {
    wires.add(LdWire(fromId: prev, toId: main[i].id));
    prev = main[i].id;
  }
  wires.add(LdWire(fromId: prev, toId: right.id));

  // Wire each parallel branch on its own lane.
  int lane = 1;
  for (final b in branches) {
    final sourceId = b.startIndex == 0 ? left.id : main[b.startIndex - 1].id;
    final destId = b.endIndex >= main.length - 1 ? right.id : main[b.endIndex + 1].id;
    String bprev = sourceId;
    for (int k = 0; k < b.nodes.length; k++) {
      b.nodes[k].id = 'b${lane}_$k';
      b.nodes[k].row = lane;
      nodes.add(b.nodes[k]);
      wires.add(LdWire(fromId: bprev, toId: b.nodes[k].id));
      bprev = b.nodes[k].id;
    }
    wires.add(LdWire(fromId: bprev, toId: destId));
    lane++;
  }

  return LdRung(rungIndex: index, comment: comment, nodes: nodes, wires: wires);
}

/// Column = longest path from the left rail. Right rail forced to the max column.
Map<String, int> colAssignment(LdRung rung) {
  final incoming = <String, List<String>>{for (final n in rung.nodes) n.id: <String>[]};
  for (final w in rung.wires) {
    (incoming[w.toId] ??= <String>[]).add(w.fromId);
  }
  final col = <String, int>{};
  final visiting = <String>{};
  int colOf(String id) {
    final cached = col[id];
    if (cached != null) {
      return cached;
    }
    if (!visiting.add(id)) {
      return 0; // cycle guard (should not occur in a valid ladder)
    }
    int m = 0;
    for (final s in incoming[id] ?? const <String>[]) {
      final c = colOf(s) + 1;
      if (c > m) {
        m = c;
      }
    }
    visiting.remove(id);
    return col[id] = m;
  }

  for (final n in rung.nodes) {
    colOf(n.id);
  }
  final maxCol = col.values.isEmpty ? 0 : col.values.reduce((a, b) => a > b ? a : b);
  for (final n in rung.nodes) {
    if (n.kind == LdKind.rightRail) {
      col[n.id] = maxCol;
    }
  }
  return col;
}

/// Every lane > 0 is a branch. First/last node are its leftmost/rightmost by column.
List<LdBranchView> findBranches(LdRung rung) {
  final col = colAssignment(rung);
  final result = <LdBranchView>[];
  final lanes = rung.nodes.map((n) => n.row).where((r) => r > 0).toSet().toList()..sort();
  for (final lane in lanes) {
    final laneNodes = rung.nodes.where((n) => n.row == lane).toList()
      ..sort((a, b) => (col[a.id] ?? 0).compareTo(col[b.id] ?? 0));
    if (laneNodes.isEmpty) {
      continue;
    }
    result.add(LdBranchView(
      lane: lane,
      firstNodeId: laneNodes.first.id,
      lastNodeId: laneNodes.last.id,
    ));
  }
  return result;
}

/// Splits [wire] (F -> T) into F -> newNode -> T.
void insertContactOnWire(LdRung rung, LdWire wire, LdNode newNode) {
  newNode.row = _laneOfNode(rung, wire.fromId);
  final destId = wire.toId;
  wire.toId = newNode.id;
  rung.nodes.add(newNode);
  rung.wires.add(LdWire(fromId: newNode.id, toId: destId));
}

/// Adds a one-contact parallel branch across the main-line span [spanStart..spanEnd].
LdBranchView addParallelBranch(LdRung rung, LdNode spanStart, LdNode spanEnd) {
  final inW = rung.wires.firstWhere((w) => w.toId == spanStart.id);
  final succW = rung.wires.firstWhere((w) => w.fromId == spanEnd.id);
  final lane = maxLane(rung) + 1;
  final node = LdNode(
    id: newNodeId(rung),
    kind: LdKind.contact,
    variable: 'New_Contact',
    row: lane,
  );
  rung.nodes.add(node);
  rung.wires.add(LdWire(fromId: inW.fromId, toId: node.id));
  rung.wires.add(LdWire(fromId: node.id, toId: succW.toId));
  return LdBranchView(lane: lane, firstNodeId: node.id, lastNodeId: node.id);
}

/// Re-points the branch's inbound (tap) wire to originate at [newSource].
void moveBranchTap(LdRung rung, LdBranchView br, LdNode newSource) {
  for (final w in rung.wires) {
    if (w.toId == br.firstNodeId && _laneOfNode(rung, w.fromId) < br.lane) {
      w.fromId = newSource.id;
      return;
    }
  }
}

/// Re-points the branch's outbound (merge) wire to terminate at [newDest].
void moveBranchMerge(LdRung rung, LdBranchView br, LdNode newDest) {
  final lastNode = rung.nodes.firstWhere((n) => n.id == br.lastNodeId);
  // A coil's output must stay on the right rail; never let a drag make it
  // non-terminal by re-pointing it to a non-rail node.
  if (lastNode.kind == LdKind.coil && newDest.kind != LdKind.rightRail) {
    return;
  }
  for (final w in rung.wires) {
    if (w.fromId == br.lastNodeId && _laneOfNode(rung, w.toId) < br.lane) {
      w.toId = newDest.id;
      return;
    }
  }
}

/// Removes `program.rungs[index]` if in range, else no-op.
void deleteRung(PlcProgram program, int index) {
  if (index < 0 || index >= program.rungs.length) {
    return;
  }
  program.rungs.removeAt(index);
}

/// Moves the rung at [from] to [to]. No-op if either is out of range or they
/// are equal. After removal, [to] is clamped into `[0, length]` so moving to
/// (or past) the end lands the rung last.
void moveRung(PlcProgram program, int from, int to) {
  final rungs = program.rungs;
  if (from < 0 || from >= rungs.length || to < 0 || to >= rungs.length) {
    return;
  }
  if (from == to) {
    return;
  }
  final rung = rungs.removeAt(from);
  int dest = to;
  if (dest > rungs.length) {
    dest = rungs.length;
  }
  rungs.insert(dest, rung);
}

/// Adds a new terminal output coil on a fresh lane, wired left-rail -> coil
/// -> right-rail (mirrors `addParallelBranch`'s wiring pattern but spans the
/// full rung width instead of tapping/merging into the main line).
LdNode addOutputCoil(LdRung rung) {
  final lane = maxLane(rung) + 1;
  final node = LdNode(
    id: newNodeId(rung),
    kind: LdKind.coil,
    variable: 'Output_Coil',
    row: lane,
  );
  rung.nodes.add(node);
  rung.wires.add(LdWire(fromId: kLeftRailId, toId: node.id));
  rung.wires.add(LdWire(fromId: node.id, toId: kRightRailId));
  return node;
}

/// Removes [n]. For a series node it reconnects sources to destinations
/// (heals the line); for the sole node on a branch lane it drops the branch
/// entirely (no bypass jumper) instead of shorting the parallel span.
void deleteNode(LdRung rung, LdNode n) {
  final ins = rung.wires.where((w) => w.toId == n.id).toList();
  final outs = rung.wires.where((w) => w.fromId == n.id).toList();
  rung.wires.removeWhere((w) => w.fromId == n.id || w.toId == n.id);
  final soleBranchNode =
      n.row > 0 && !rung.nodes.any((o) => o.id != n.id && o.row == n.row);
  if (!soleBranchNode) {
    for (final i in ins) {
      for (final o in outs) {
        rung.wires.add(LdWire(fromId: i.fromId, toId: o.toId));
      }
    }
  }
  rung.nodes.remove(n);
}
