# Ladder Diagram Editor Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ladder-diagram (LD) editor with a PLCopen-style node-and-wire graph model that renders a continuous power-rail frame with unbroken wires, fixes the TON block overflow, and lets the user add parallel (OR) branches over any span of elements with draggable start/end handles.

**Architecture:** A rung is a graph of `LdNode`s (left rail, right rail, contacts, coils, blocks) joined by `LdWire`s referencing node ports — series is a wire chain, an OR is two wires converging on one input. A pure-Dart layer (`ld_graph.dart`) builds rungs, assigns columns by longest-path from the left rail, and mutates the graph (insert-in-series, add-branch, move-branch-endpoint, delete). The editor renders one continuous L1/L2 frame with each rung's wires drawn by a `CustomPainter` and interactive element widgets positioned above it.

**Tech Stack:** Flutter / Dart (web), `flutter test` for pure-logic unit tests, `flutter analyze` for lint, Chrome preview extension for visual validation.

## Global Constraints

- No third-party or reference-editor branding anywhere in user-facing UI, labels, dialogs, comments, or identifiers.
- Dark theme preserved (canvas `#0F172A`, cards `#1E293B`).
- `flutter analyze` must report **zero** issues. Use `withValues(alpha:)` (never `withOpacity`) and `initialValue:` (never `value:`) on `DropdownButtonFormField`.
- Prefer `const` constructors; use `x.isNotEmpty` not `x.length >= 1`; always wrap flow-control bodies in braces.
- All shell commands run from `mobile/` unless stated otherwise.

---

### Task 1: New LD graph data model + pure-logic layer

**Files:**
- Modify: `mobile/lib/models/project_model.dart:97-135` (replace `LdInstruction`, `LdBranch`, `LdRung`)
- Create: `mobile/lib/models/ld_graph.dart`
- Test: `mobile/test/ld_graph_test.dart`

**Interfaces:**
- Produces (consumed by all later tasks):
  - `enum LdKind { leftRail, rightRail, contact, coil, block }`
  - `class LdNode { String id; LdKind kind; String variable; String modifier; String blockType; int presetMs; String comment; int col; int row; }`
  - `class LdWire { String fromId; String fromPort; String toId; String toPort; }`
  - `class LdRung { int rungIndex; String comment; List<LdNode> nodes; List<LdWire> wires; }`
  - `class BranchSpec { int startIndex; int endIndex; List<LdNode> nodes; }`
  - `class LdBranchView { int lane; String firstNodeId; String lastNodeId; }`
  - `LdRung buildRung({required int index, String comment, required List<LdNode> main, List<BranchSpec> branches})`
  - `Map<String,int> colAssignment(LdRung rung)`
  - `int maxLane(LdRung rung)`
  - `List<LdBranchView> findBranches(LdRung rung)`
  - `void insertContactOnWire(LdRung rung, LdWire wire, LdNode newNode)`
  - `LdBranchView addParallelBranch(LdRung rung, LdNode spanStart, LdNode spanEnd)`
  - `void moveBranchTap(LdRung rung, LdBranchView br, LdNode newSource)`
  - `void moveBranchMerge(LdRung rung, LdBranchView br, LdNode newDest)`
  - `void deleteNode(LdRung rung, LdNode n)`
  - `String newNodeId(LdRung rung)`

- [ ] **Step 1: Replace the LD model classes in `project_model.dart`**

Delete the existing block at `mobile/lib/models/project_model.dart:97-135` (the `LdInstruction`, `LdBranch`, `LdRung` classes and their `// LADDER LOGIC` banner) and replace with:

```dart
// -------------------------------------------------------------
// LADDER LOGIC (LD) — node-and-wire graph model
// -------------------------------------------------------------
enum LdKind { leftRail, rightRail, contact, coil, block }

class LdNode {
  String id;
  LdKind kind;
  String variable;   // bound tag (contact/coil); '' for rails/blocks
  String modifier;   // 'normal'|'negated'|'rising'|'falling'|'set'|'reset'
  String blockType;  // 'TON'|'TOF'|'CTU'|... when kind == LdKind.block
  int presetMs;      // block preset time (TON/TOF)
  String comment;
  int col;           // grid column (series index) — assigned by layout
  int row;           // grid lane (0 = main line)

  LdNode({
    required this.id,
    required this.kind,
    this.variable = '',
    this.modifier = 'normal',
    this.blockType = '',
    this.presetMs = 5000,
    this.comment = '',
    this.col = 0,
    this.row = 0,
  });
}

class LdWire {
  String fromId;
  String fromPort;
  String toId;
  String toPort;

  LdWire({
    required this.fromId,
    this.fromPort = 'out',
    required this.toId,
    this.toPort = 'in',
  });
}

class LdRung {
  int rungIndex;
  String comment;
  List<LdNode> nodes;
  List<LdWire> wires;

  LdRung({
    required this.rungIndex,
    this.comment = '',
    required this.nodes,
    required this.wires,
  });
}
```

- [ ] **Step 2: Write the failing tests for `ld_graph.dart`**

Create `mobile/test/ld_graph_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';

LdNode contact(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

void main() {
  test('buildRung wires a series main line rail-to-rail', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final left = r.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    final right = r.nodes.firstWhere((n) => n.kind == LdKind.rightRail);
    // left rail feeds first element; coil feeds right rail
    expect(r.wires.any((w) => w.fromId == left.id), isTrue);
    expect(r.wires.any((w) => w.toId == right.id), isTrue);
    // every non-rail node has an inbound and outbound wire
    for (final n in r.nodes.where((n) =>
        n.kind != LdKind.leftRail && n.kind != LdKind.rightRail)) {
      expect(r.wires.any((w) => w.toId == n.id), isTrue);
      expect(r.wires.any((w) => w.fromId == n.id), isTrue);
    }
  });

  test('colAssignment increments along a series chain', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final col = colAssignment(r);
    final ids = r.nodes.where((n) => n.kind == LdKind.contact || n.kind == LdKind.coil).toList();
    final a = ids.firstWhere((n) => n.variable == 'A');
    final b = ids.firstWhere((n) => n.variable == 'B');
    final y = ids.firstWhere((n) => n.variable == 'Y');
    expect(col[a.id]! < col[b.id]!, isTrue);
    expect(col[b.id]! < col[y.id]!, isTrue);
    // right rail sits at the last column
    final right = r.nodes.firstWhere((n) => n.kind == LdKind.rightRail);
    expect(col[right.id], equals(col.values.reduce((x, z) => x > z ? x : z)));
  });

  test('buildRung branch parallels a span on a new lane', () {
    final r = buildRung(
      index: 0,
      main: [contact('Start'), contact('Stop'), coil('Motor')],
      branches: [BranchSpec(startIndex: 0, endIndex: 0, nodes: [contact('Seal')])],
    );
    final seal = r.nodes.firstWhere((n) => n.variable == 'Seal');
    expect(seal.row, equals(1));
    final left = r.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    // seal taps off the left rail (predecessor of Start) and merges into Stop
    final stop = r.nodes.firstWhere((n) => n.variable == 'Stop');
    expect(r.wires.any((w) => w.fromId == left.id && w.toId == seal.id), isTrue);
    expect(r.wires.any((w) => w.fromId == seal.id && w.toId == stop.id), isTrue);
  });

  test('addParallelBranch adds a lane and OR-converges', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final before = maxLane(r);
    final br = addParallelBranch(r, a, a);
    expect(maxLane(r), equals(before + 1));
    expect(br.lane, equals(before + 1));
    // new branch node exists on the new lane
    expect(r.nodes.any((n) => n.row == br.lane), isTrue);
  });

  test('moveBranchMerge re-points the branch end', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final y = r.nodes.firstWhere((n) => n.variable == 'Y');
    final br = addParallelBranch(r, a, a); // merges into B initially
    moveBranchMerge(r, br, y);
    final last = br.lastNodeId;
    expect(r.wires.any((w) => w.fromId == last && w.toId == y.id), isTrue);
    expect(r.wires.any((w) => w.fromId == last && w.toId == b.id), isFalse);
  });

  test('insertContactOnWire splits the wire in series', () {
    final r = buildRung(index: 0, main: [contact('A'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final wire = r.wires.firstWhere((w) => w.fromId == a.id);
    final destBefore = wire.toId;
    final n = LdNode(id: newNodeId(r), kind: LdKind.contact, variable: 'C');
    insertContactOnWire(r, wire, n);
    expect(wire.toId, equals(n.id));                 // A -> C
    expect(r.wires.any((w) => w.fromId == n.id && w.toId == destBefore), isTrue); // C -> Y
  });

  test('deleteNode heals the series wires', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final y = r.nodes.firstWhere((n) => n.variable == 'Y');
    deleteNode(r, b);
    expect(r.nodes.contains(b), isFalse);
    expect(r.wires.any((w) => w.fromId == a.id && w.toId == y.id), isTrue);
  });
}
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `flutter test test/ld_graph_test.dart`
Expected: FAIL — `ld_graph.dart` does not exist / functions undefined.

- [ ] **Step 4: Implement `ld_graph.dart`**

Create `mobile/lib/models/ld_graph.dart`:

```dart
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

/// Generates a node id not already present in [rung].
String newNodeId(LdRung rung) {
  int i = 0;
  final used = rung.nodes.map((n) => n.id).toSet();
  while (used.contains('n$i')) {
    i++;
  }
  return 'n$i';
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
  final w = rung.wires.firstWhere(
    (w) => w.toId == br.firstNodeId && _laneOfNode(rung, w.fromId) < br.lane,
  );
  w.fromId = newSource.id;
}

/// Re-points the branch's outbound (merge) wire to terminate at [newDest].
void moveBranchMerge(LdRung rung, LdBranchView br, LdNode newDest) {
  final w = rung.wires.firstWhere(
    (w) => w.fromId == br.lastNodeId && _laneOfNode(rung, w.toId) < br.lane,
  );
  w.toId = newDest.id;
}

/// Removes [n] and reconnects each of its sources to each of its destinations.
void deleteNode(LdRung rung, LdNode n) {
  final ins = rung.wires.where((w) => w.toId == n.id).toList();
  final outs = rung.wires.where((w) => w.fromId == n.id).toList();
  rung.wires.removeWhere((w) => w.fromId == n.id || w.toId == n.id);
  for (final i in ins) {
    for (final o in outs) {
      rung.wires.add(LdWire(fromId: i.fromId, toId: o.toId));
    }
  }
  rung.nodes.remove(n);
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `flutter test test/ld_graph_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/models/project_model.dart mobile/lib/models/ld_graph.dart mobile/test/ld_graph_test.dart
git commit -m "feat(ld): add node-and-wire graph model and pure-logic layer"
```

---

### Task 2: Migrate default projects and demo rungs to the graph model

**Files:**
- Modify: `mobile/lib/data/default_projects.dart` (LD rungs in `_ldConveyorProject` ~line 219, `_allWaterProject`/`PumpControl_LD` ~line 524)
- Modify: `mobile/lib/screens/ld_editor_screen.dart:34-80` (`_ensureDefaultRungs` demo rungs) — temporary shim until Task 3 rewrites the file

**Interfaces:**
- Consumes: `buildRung`, `BranchSpec`, `LdNode`, `LdKind` from Task 1.
- Produces: all `PlcProgram.rungs` for LD programs are `List<LdRung>` built via `buildRung`.

**Note:** `workspace_shell._evaluateActiveLogic` uses hardcoded per-project physics and does **not** read rung structure, so simulation is unaffected. This task only needs the app to compile and all 7 projects to load.

- [ ] **Step 1: Add an import and helper to `default_projects.dart`**

At the top of `mobile/lib/data/default_projects.dart`, ensure this import is present:

```dart
import '../models/ld_graph.dart';
```

Add these private helpers near the top of the `DefaultProjects` class (after the class opening brace):

```dart
  static LdNode _xic(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'normal', comment: c);
  static LdNode _xio(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'negated', comment: c);
  static LdNode _ote(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'normal', comment: c);
  static LdNode _otl(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'set', comment: c);
  static LdNode _otu(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'reset', comment: c);
  static LdNode _ton(String v, int ms, [String c = '']) =>
      LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: v, presetMs: ms, comment: c);
```

- [ ] **Step 2: Replace the `ConveyorBelt_LD` rungs**

In `_ldConveyorProject`, replace the entire `rungs: [ ... ]` list (the six `LdRung(...)` literals) with:

```dart
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Belt Start/Stop — E-Stop and Jam Alarm Interlocks',
            main: [
              _xic('Start_PB', 'Start NO'),
              _xio('Stop_PB', 'Stop NC'),
              _xic('EStop', 'E-Stop healthy NC'),
              _xio('Belt_Jammed', 'Jam interlock NC'),
              _ote('Belt_Motor', 'Belt drive contactor'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [_xic('Belt_Latch', 'Seal-in aux')]),
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [_xic('Manual_Jog', 'Manual jog')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Belt Motor Running — Set Seal-In Latch',
            main: [_xic('Belt_Motor', 'Motor aux'), _otl('Belt_Latch', 'Latch set')],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: Part Detection — Photo Eye Signal',
            main: [_xic('Photo_Eye', 'Part detected NO'), _ote('Part_Present', 'Part present flag')],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: Jam Detection — Belt Running With No Parts for 5 Seconds',
            main: [
              _xic('Belt_Motor', 'Belt running'),
              _xio('Part_Present', 'No part NC'),
              _ton('JamTimer', 5000, '5s jam timer'),
            ],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Belt Jammed Alarm Output',
            main: [_xic('JamTimer.DN', 'Timer done'), _ote('Belt_Jammed', 'Jam beacon')],
          ),
          buildRung(
            index: 5,
            comment: 'Rung 5: Jam Reset — Photo Eye Clears Jam and Unlatches Seal-In',
            main: [_xic('Photo_Eye', 'Part resets jam'), _otu('Belt_Latch', 'Unlatch')],
          ),
        ],
```

- [ ] **Step 3: Replace the `PumpControl_LD` rungs**

In `_allWaterProject`, replace the `PumpControl_LD` program's `rungs: [ ... ]` list with:

```dart
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Pump Start/Stop — E-Stop and Quality Interlocks',
            main: [
              _xic('Start_PB', 'Start NO'),
              _xio('Stop_PB', 'Stop NC'),
              _xic('EStop', 'E-Stop NC healthy'),
              _xio('Alarm_Active', 'Alarm NC interlock'),
              _ote('Pump_Motor', 'Main pump contactor'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [_xic('Pump_Latch', 'Seal-in')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Pump Running Seal-In Latch',
            main: [_xic('Pump_Motor', 'Motor aux'), _otl('Pump_Latch', 'Latch set')],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: Chemical Dosing Interlock — Dose When Quality Fails',
            main: [
              _xic('Pump_Motor', 'Pump running'),
              _xio('Quality_OK', 'Quality not OK NC'),
              _ote('Treat_Dosing', 'Dosing pump output'),
            ],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: Backwash TON — High Turbidity Triggers Backwash Timer',
            main: [
              _xio('Quality_OK', 'Quality not OK NC'),
              _xic('Pump_Motor', 'Pump running'),
              _ton('BackwashTimer', 30000, '30s backwash timer'),
            ],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Backwash Active Output',
            main: [_xic('BackwashTimer.DN', 'Timer done'), _ote('Backwash_Active', 'Backwash active')],
          ),
        ],
```

- [ ] **Step 4: Update the demo rungs in `_ensureDefaultRungs`**

In `mobile/lib/screens/ld_editor_screen.dart`, replace the body of `_ensureDefaultRungs()` (lines ~34-80) with:

```dart
  void _ensureDefaultRungs() {
    if (widget.program.rungs.isEmpty) {
      widget.program.rungs.addAll([
        buildRung(
          index: 0,
          comment: 'Rung 0: Motor Start/Stop Seal-In Circuit',
          main: [
            LdNode(id: '', kind: LdKind.contact, variable: 'Start_PB', comment: 'Start PB'),
            LdNode(id: '', kind: LdKind.contact, variable: 'Stop_PB', modifier: 'negated', comment: 'Stop PB'),
            LdNode(id: '', kind: LdKind.contact, variable: 'Overload_OK', modifier: 'negated', comment: 'Overload'),
            LdNode(id: '', kind: LdKind.coil, variable: 'Motor_Run', comment: 'Starter coil'),
          ],
          branches: [
            BranchSpec(startIndex: 0, endIndex: 0, nodes: [
              LdNode(id: '', kind: LdKind.contact, variable: 'Motor_Run', comment: 'Seal-in aux'),
            ]),
          ],
        ),
        buildRung(
          index: 1,
          comment: 'Rung 1: TON Timer Block (IN, Q, PT, ET)',
          main: [
            LdNode(id: '', kind: LdKind.contact, variable: 'TONTimer.DN', modifier: 'negated', comment: 'Done NC'),
            LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'TONTimer', presetMs: 5000, comment: '5s timer'),
            LdNode(id: '', kind: LdKind.coil, variable: 'MixerMotor', comment: 'Mixer coil'),
          ],
        ),
      ]);
    }
  }
```

Add `import '../models/ld_graph.dart';` to the top of `ld_editor_screen.dart` if not present.

- [ ] **Step 5: Confirm the app compiles and analyzes clean**

Run: `flutter analyze`
Expected: the only remaining errors (if any) are inside `ld_editor_screen.dart`'s *rendering* code that still references the old `LdInstruction` API — those are rewritten in Task 3. The model/data files (`project_model.dart`, `ld_graph.dart`, `default_projects.dart`) must report **no** errors.

If `default_projects.dart` shows errors, fix them before continuing. It is expected that `ld_editor_screen.dart` still has errors until Task 3.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/data/default_projects.dart mobile/lib/screens/ld_editor_screen.dart
git commit -m "refactor(ld): migrate default projects and demo rungs to graph model"
```

---

### Task 3: Rebuild LD editor rendering (frame, wires, elements)

**Files:**
- Rewrite: `mobile/lib/screens/ld_editor_screen.dart`

**Interfaces:**
- Consumes: `LdRung`, `LdNode`, `LdWire`, `LdKind`, `colAssignment`, `findBranches` from Tasks 1-2.
- Produces (used by Task 4): the `_LdEditorScreenState` with:
  - layout getters `double _laneHeight(LdRung, int lane)`, `double _laneTop(LdRung, int lane)`, `double _colX(int col)`, `double _nodeH(LdNode)`, `Offset _outPort(LdRung, LdNode, Map<String,int>)`, `Offset _inPort(LdRung, LdNode, Map<String,int>)`, `double _rungHeight(LdRung)`, `double _rungWidth(LdRung, Map<String,int>)`
  - `Widget _buildRungCanvas(LdRung rung, int index)`

- [ ] **Step 1: Replace the file header, constants, and `build` scaffold**

Rewrite `mobile/lib/screens/ld_editor_screen.dart` top-to-`build`. Keep `_ensureDefaultRungs` from Task 2. Use these constants and the continuous-frame scaffold:

```dart
import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/ld_graph.dart';

const double _kColW = 116.0;   // column pitch (cell + wire)
const double _kCellW = 66.0;   // element cell width
const double _kContactH = 54.0;
const double _kBlockH = 92.0;
const double _kLaneGap = 10.0;
const double _kRailW = 6.0;
const double _kRungGap = 8.0;

class LdEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final PlcProgram program;
  final VoidCallback onProgramUpdated;

  const LdEditorScreen({
    super.key,
    required this.currentProject,
    required this.program,
    required this.onProgramUpdated,
  });

  @override
  State<LdEditorScreen> createState() => _LdEditorScreenState();
}

class _LdEditorScreenState extends State<LdEditorScreen> {
  String _editMode = 'select'; // 'select' | 'contact' | 'coil' | 'block' | 'branch'
  LdNode? _branchStart;        // first element tapped in branch mode

  @override
  void initState() {
    super.initState();
    _ensureDefaultRungs();
  }

  // _ensureDefaultRungs() from Task 2 goes here unchanged.
```

- [ ] **Step 2: Add the layout geometry helpers**

Add these methods to `_LdEditorScreenState`:

```dart
  double _nodeH(LdNode n) => n.kind == LdKind.block ? _kBlockH : _kContactH;

  double _laneHeight(LdRung rung, int lane) {
    double h = _kContactH;
    for (final n in rung.nodes) {
      if (n.row == lane) {
        final nh = _nodeH(n);
        if (nh > h) {
          h = nh;
        }
      }
    }
    return h;
  }

  double _laneTop(LdRung rung, int lane) {
    double y = 0;
    for (int l = 0; l < lane; l++) {
      y += _laneHeight(rung, l) + _kLaneGap;
    }
    return y;
  }

  double _rungHeight(LdRung rung) {
    final lanes = maxLane(rung);
    return _laneTop(rung, lanes) + _laneHeight(rung, lanes);
  }

  double _colX(int col) => col * _kColW;

  double _rungWidth(LdRung rung, Map<String, int> col) {
    int maxc = 0;
    for (final n in rung.nodes) {
      final c = col[n.id] ?? 0;
      if (c > maxc) {
        maxc = c;
      }
    }
    return _colX(maxc);
  }

  double _nodeCenterY(LdRung rung, LdNode n) =>
      _laneTop(rung, n.row) + _laneHeight(rung, n.row) / 2;

  Offset _outPort(LdRung rung, LdNode n, Map<String, int> col, double width) {
    if (n.kind == LdKind.leftRail) {
      return Offset(0, _nodeCenterY(rung, n));
    }
    final x = _colX(col[n.id] ?? 0) + _kCellW;
    return Offset(x, _nodeCenterY(rung, n));
  }

  Offset _inPort(LdRung rung, LdNode n, Map<String, int> col, double width) {
    if (n.kind == LdKind.rightRail) {
      return Offset(width, _nodeCenterY(rung, n));
    }
    return Offset(_colX(col[n.id] ?? 0), _nodeCenterY(rung, n));
  }
```

- [ ] **Step 3: Add the `build` method with the continuous L1/L2 frame**

```dart
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.program.name} — Ladder Diagram (LD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: Column(
        children: [
          _buildToolbar(),
          Expanded(
            child: Container(
              color: const Color(0xFF0F172A),
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: _kRailW, color: Colors.greenAccent), // continuous L1
                  Expanded(
                    child: ListView.separated(
                      itemCount: widget.program.rungs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: _kRungGap),
                      itemBuilder: (context, i) => _buildRungCanvas(widget.program.rungs[i], i),
                    ),
                  ),
                  Container(width: _kRailW, color: Colors.blueAccent), // continuous L2
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    // Full implementation added in Task 4; placeholder keeps the app compiling now.
    return Container(
      height: 44,
      color: const Color(0xFF1E293B),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: const Text('LADDER TOOLBAR', style: TextStyle(color: Colors.cyanAccent, fontSize: 11)),
    );
  }
```

- [ ] **Step 4: Add the rung canvas (painter + positioned element widgets)**

```dart
  Widget _buildRungCanvas(LdRung rung, int index) {
    final col = colAssignment(rung);
    final width = _rungWidth(rung, col);
    final height = _rungHeight(rung);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111C30),
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: Text('RUNG $index   ${rung.comment}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          SizedBox(
            height: height,
            width: width,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Wires + branch brackets, drawn behind the elements.
                Positioned.fill(
                  child: CustomPaint(painter: _LadderPainter(this, rung, col, width)),
                ),
                // Element widgets.
                ...rung.nodes
                    .where((n) => n.kind == LdKind.contact ||
                        n.kind == LdKind.coil ||
                        n.kind == LdKind.block)
                    .map((n) => _positionedNode(rung, n, col)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _positionedNode(LdRung rung, LdNode n, Map<String, int> col) {
    final h = _nodeH(n);
    final top = _nodeCenterY(rung, n) - h / 2;
    return Positioned(
      left: _colX(col[n.id] ?? 0),
      top: top,
      width: _kCellW,
      height: h,
      child: GestureDetector(
        onTap: () => _onNodeTap(rung, n),
        onDoubleTap: () => _showEditNodeDialog(rung, n),
        child: n.kind == LdKind.block ? _buildBlock(n) : _buildContactCoil(n),
      ),
    );
  }

  // Stubs so the file compiles now; full versions land in Task 4.
  void _onNodeTap(LdRung rung, LdNode n) {}
  void _showEditNodeDialog(LdRung rung, LdNode n) {}
```

- [ ] **Step 5: Add the element widgets (contact / coil / block)**

```dart
  Widget _buildContactCoil(LdNode n) {
    final isCoil = n.kind == LdKind.coil;
    String symbol;
    Color color;
    if (isCoil) {
      color = Colors.amberAccent;
      switch (n.modifier) {
        case 'negated': symbol = '-(/)-'; break;
        case 'set': symbol = '-(S)-'; break;
        case 'reset': symbol = '-(R)-'; break;
        case 'rising': symbol = '-(P)-'; break;
        case 'falling': symbol = '-(N)-'; break;
        default: symbol = '-( )-';
      }
    } else {
      color = Colors.greenAccent;
      switch (n.modifier) {
        case 'negated': symbol = '-|/|-'; break;
        case 'rising': symbol = '-|P|-'; break;
        case 'falling': symbol = '-|N|-'; break;
        default: symbol = '-| |-';
      }
    }
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(n.variable,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 9, color: color, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(symbol,
              style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 14, color: color)),
        ],
      ),
    );
  }

  Widget _buildBlock(LdNode n) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade500, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: const BoxDecoration(
              color: Color(0xFF334155),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(3), topRight: Radius.circular(3)),
            ),
            child: Text(n.blockType,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white, fontFamily: 'monospace'),
                textAlign: TextAlign.center),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(n.variable,
                    style: const TextStyle(fontSize: 8, color: Colors.cyanAccent, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis),
                const _BlockPinRow(left: 'IN', right: 'Q'),
                Text('PT ${n.presetMs}ms',
                    style: const TextStyle(fontSize: 7, color: Colors.grey), overflow: TextOverflow.ellipsis),
                const _BlockPinRow(left: 'PT', right: 'ET'),
              ],
            ),
          ),
        ],
      ),
    );
  }
```

Add this small helper widget at the end of the file (after the state class):

```dart
class _BlockPinRow extends StatelessWidget {
  final String left;
  final String right;
  const _BlockPinRow({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(left, style: const TextStyle(fontSize: 8, color: Colors.greenAccent, fontFamily: 'monospace')),
        Text(right, style: const TextStyle(fontSize: 8, color: Colors.greenAccent, fontFamily: 'monospace')),
      ],
    );
  }
}
```

- [ ] **Step 6: Add the `_LadderPainter`**

Add at the end of the file:

```dart
class _LadderPainter extends CustomPainter {
  final _LdEditorScreenState s;
  final LdRung rung;
  final Map<String, int> col;
  final double width;

  _LadderPainter(this.s, this.rung, this.col, this.width);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    LdNode nodeById(String id) => rung.nodes.firstWhere((n) => n.id == id);

    for (final w in rung.wires) {
      final src = nodeById(w.fromId);
      final dst = nodeById(w.toId);
      final p1 = s._outPort(rung, src, col, width);
      final p2 = s._inPort(rung, dst, col, width);
      final path = Path()..moveTo(p1.dx, p1.dy);
      if (src.row == dst.row) {
        path.lineTo(p2.dx, p2.dy);
      } else if (dst.row > src.row) {
        // going into a deeper branch lane: vertical at source's right boundary
        path.lineTo(p1.dx, p2.dy);
        path.lineTo(p2.dx, p2.dy);
      } else {
        // returning to a shallower lane: vertical at destination's left boundary
        path.lineTo(p2.dx, p1.dy);
        path.lineTo(p2.dx, p2.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LadderPainter old) => true;
}
```

- [ ] **Step 7: Analyze, build, and validate visually in Chrome**

Run: `flutter analyze`
Expected: **No issues found!**

Run: `flutter build web --release`
Expected: build succeeds.

Then restart the preview server and open the LD editor for the "LD — Conveyor Belt Control" project. Confirm visually:
- The continuous green L1 rail (left) and blue L2 rail (right) run the full height.
- Rung 0 shows the main line plus two parallel seal-in/jog branches with clean vertical brackets.
- Rung 3 shows the TON block with **no** overflow stripe.

- [ ] **Step 8: Commit**

```bash
git add mobile/lib/screens/ld_editor_screen.dart
git commit -m "feat(ld): render graph rungs with continuous frame, unbroken wires, fitted TON block"
```

---

### Task 4: LD editor interaction (modes, insert, branch, drag, edit, delete)

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart`

**Interfaces:**
- Consumes: `insertContactOnWire`, `addParallelBranch`, `moveBranchTap`, `moveBranchMerge`, `deleteNode`, `findBranches`, `LdBranchView`, `newNodeId` from Task 1; geometry helpers from Task 3.
- Produces: fully interactive editor (terminal deliverable).

- [ ] **Step 1: Implement the real toolbar with mode buttons**

Replace the `_buildToolbar` stub from Task 3 with:

```dart
  Widget _buildToolbar() {
    Widget modeBtn(String mode, IconData icon, String label) {
      final active = _editMode == mode;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: TextButton.icon(
          icon: Icon(icon, size: 15, color: active ? Colors.black : Colors.cyanAccent),
          label: Text(label, style: TextStyle(fontSize: 11, color: active ? Colors.black : Colors.cyanAccent)),
          style: TextButton.styleFrom(
            backgroundColor: active ? Colors.cyanAccent : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
          onPressed: () => setState(() {
            _editMode = mode;
            _branchStart = null;
          }),
        ),
      );
    }

    return Container(
      height: 44,
      color: const Color(0xFF1E293B),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        modeBtn('select', Icons.near_me, 'Select'),
        modeBtn('contact', Icons.horizontal_rule, 'Contact'),
        modeBtn('coil', Icons.radio_button_unchecked, 'Coil'),
        modeBtn('block', Icons.widgets, 'Block'),
        modeBtn('branch', Icons.account_tree, 'Branch'),
        const Spacer(),
        TextButton.icon(
          icon: const Icon(Icons.add, size: 15, color: Colors.greenAccent),
          label: const Text('Add Rung', style: TextStyle(fontSize: 11, color: Colors.greenAccent)),
          onPressed: _addRung,
        ),
        if (_editMode == 'branch')
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Text('Tap span start, then span end', style: TextStyle(fontSize: 10, color: Colors.amberAccent)),
          ),
      ]),
    );
  }

  void _addRung() {
    setState(() {
      widget.program.rungs.add(buildRung(
        index: widget.program.rungs.length,
        comment: 'New Rung',
        main: [
          LdNode(id: '', kind: LdKind.contact, variable: 'New_Contact'),
          LdNode(id: '', kind: LdKind.coil, variable: 'Output_Coil'),
        ],
      ));
    });
    widget.onProgramUpdated();
  }
```

- [ ] **Step 2: Implement node tap (branch selection) and wire-insert targets**

Replace the `_onNodeTap` stub with branch-span selection, and add wire-insert targets. First replace `_onNodeTap`:

```dart
  void _onNodeTap(LdRung rung, LdNode n) {
    if (_editMode == 'branch') {
      if (_branchStart == null) {
        setState(() => _branchStart = n);
      } else {
        final start = _branchStart!;
        final col = colAssignment(rung);
        // order the two picks left-to-right by column
        final a = (col[start.id] ?? 0) <= (col[n.id] ?? 0) ? start : n;
        final b = identical(a, start) ? n : start;
        setState(() {
          addParallelBranch(rung, a, b);
          _branchStart = null;
          _editMode = 'select';
        });
        widget.onProgramUpdated();
      }
      return;
    }
    // select mode: single tap selects (highlight handled via _branchStart reuse is avoided)
  }
```

Then, in `_buildRungCanvas`'s `Stack` children (Task 3, Step 4), add wire-insert targets after the element widgets when a placement mode is active:

```dart
                // Insert targets on wires (contact/coil/block modes).
                if (_editMode == 'contact' || _editMode == 'coil' || _editMode == 'block')
                  ...rung.wires.map((w) => _wireInsertTarget(rung, w, col, width)),
```

Add the helper:

```dart
  Widget _wireInsertTarget(LdRung rung, LdWire w, Map<String, int> col, double width) {
    final src = rung.nodes.firstWhere((n) => n.id == w.fromId);
    final dst = rung.nodes.firstWhere((n) => n.id == w.toId);
    final p1 = _outPort(rung, src, col, width);
    final p2 = _inPort(rung, dst, col, width);
    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    return Positioned(
      left: mid.dx - 11,
      top: mid.dy - 11,
      width: 22,
      height: 22,
      child: GestureDetector(
        onTap: () => _insertOnWire(rung, w),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.cyanAccent.withValues(alpha: 0.85),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.add, size: 14, color: Colors.black),
        ),
      ),
    );
  }

  void _insertOnWire(LdRung rung, LdWire w) {
    final LdNode node;
    if (_editMode == 'coil') {
      node = LdNode(id: newNodeId(rung), kind: LdKind.coil, variable: 'Output_Coil');
    } else if (_editMode == 'block') {
      node = LdNode(id: newNodeId(rung), kind: LdKind.block, blockType: 'TON', variable: 'Timer', presetMs: 5000);
    } else {
      node = LdNode(id: newNodeId(rung), kind: LdKind.contact, variable: 'New_Contact');
    }
    setState(() {
      insertContactOnWire(rung, w, node);
      _editMode = 'select';
    });
    widget.onProgramUpdated();
    _showEditNodeDialog(rung, node);
  }
```

- [ ] **Step 3: Implement draggable branch endpoint handles**

In `_buildRungCanvas`'s `Stack` children, add branch handles (always visible so they can be grabbed):

```dart
                // Draggable branch start/end handles.
                ...findBranches(rung).expand((br) => _branchHandles(rung, br, col, width)),
```

Add the helpers. Dragging snaps to the nearest main-line (lane 0) element column:

```dart
  List<Widget> _branchHandles(LdRung rung, LdBranchView br, Map<String, int> col, double width) {
    final first = rung.nodes.firstWhere((n) => n.id == br.firstNodeId);
    final last = rung.nodes.firstWhere((n) => n.id == br.lastNodeId);
    final startPt = _inPort(rung, first, col, width);
    final endPt = _outPort(rung, last, col, width);
    return [
      _handle(startPt, Colors.tealAccent, (dx) => _dragBranchTap(rung, br, dx)),
      _handle(endPt, Colors.tealAccent, (dx) => _dragBranchMerge(rung, br, dx)),
    ];
  }

  Widget _handle(Offset at, Color color, void Function(double globalDx) onDrag) {
    return Positioned(
      left: at.dx - 8,
      top: at.dy - 8,
      width: 16,
      height: 16,
      child: GestureDetector(
        onHorizontalDragUpdate: (d) => onDrag(d.localPosition.dx + at.dx - 8),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 1),
          ),
        ),
      ),
    );
  }

  /// Finds the lane-0 node whose column boundary is nearest to pixel x.
  LdNode _nearestMainNode(LdRung rung, Map<String, int> col, double x) {
    LdNode best = rung.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    double bestDist = double.infinity;
    for (final n in rung.nodes) {
      if (n.row != 0) {
        continue;
      }
      final nx = _colX(col[n.id] ?? 0);
      final d = (nx - x).abs();
      if (d < bestDist) {
        bestDist = d;
        best = n;
      }
    }
    return best;
  }

  void _dragBranchTap(LdRung rung, LdBranchView br, double x) {
    final col = colAssignment(rung);
    final target = _nearestMainNode(rung, col, x);
    setState(() => moveBranchTap(rung, br, target));
    widget.onProgramUpdated();
  }

  void _dragBranchMerge(LdRung rung, LdBranchView br, double x) {
    final col = colAssignment(rung);
    final target = _nearestMainNode(rung, col, x);
    setState(() => moveBranchMerge(rung, br, target));
    widget.onProgramUpdated();
  }
```

- [ ] **Step 4: Implement the edit-node dialog (variable + modifier + preset + delete)**

Replace the `_showEditNodeDialog` stub with:

```dart
  void _showEditNodeDialog(LdRung rung, LdNode n) {
    final tagCtrl = TextEditingController(text: n.variable);
    final presetCtrl = TextEditingController(text: n.presetMs.toString());
    String modifier = n.modifier;
    final isCoil = n.kind == LdKind.coil;
    final isBlock = n.kind == LdKind.block;

    final contactMods = const [
      DropdownMenuItem(value: 'normal', child: Text('Normally Open  -| |-')),
      DropdownMenuItem(value: 'negated', child: Text('Normally Closed  -|/|-')),
      DropdownMenuItem(value: 'rising', child: Text('Rising Edge  -|P|-')),
      DropdownMenuItem(value: 'falling', child: Text('Falling Edge  -|N|-')),
    ];
    final coilMods = const [
      DropdownMenuItem(value: 'normal', child: Text('Coil  -( )-')),
      DropdownMenuItem(value: 'negated', child: Text('Negated  -(/)-')),
      DropdownMenuItem(value: 'set', child: Text('Set / Latch  -(S)-')),
      DropdownMenuItem(value: 'reset', child: Text('Reset / Unlatch  -(R)-')),
      DropdownMenuItem(value: 'rising', child: Text('Rising  -(P)-')),
      DropdownMenuItem(value: 'falling', child: Text('Falling  -(N)-')),
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          title: Text('Edit ${isBlock ? n.blockType : (isCoil ? "Coil" : "Contact")}'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: widget.currentProject.tags.any((t) => t.name == n.variable) ? n.variable : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Tag'),
                  items: widget.currentProject.tags
                      .map((t) => DropdownMenuItem(value: t.name, child: Text('${t.name} [${t.dataType}]', overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) => tagCtrl.text = v ?? tagCtrl.text,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: tagCtrl,
                  decoration: const InputDecoration(labelText: 'Tag / literal', isDense: true, border: OutlineInputBorder()),
                ),
                if (!isBlock) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: modifier,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: isCoil ? coilMods : contactMods,
                    onChanged: (v) => setDlg(() => modifier = v!),
                  ),
                ],
                if (isBlock) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: presetCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Preset Time (PT) ms'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() => deleteNode(rung, n));
                widget.onProgramUpdated();
                Navigator.pop(ctx);
              },
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  n.variable = tagCtrl.text.trim();
                  n.modifier = modifier;
                  n.presetMs = int.tryParse(presetCtrl.text) ?? n.presetMs;
                });
                widget.onProgramUpdated();
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
```

- [ ] **Step 5: Analyze**

Run: `flutter analyze`
Expected: **No issues found!** (Fix any `withOpacity`/`value:`/brace/`const` lints inline.)

- [ ] **Step 6: Build and validate the full interaction in Chrome**

Run: `flutter build web --release`

Restart the preview server and open the "LD — Conveyor Belt Control" LD editor. Verify each:
1. **Modes** — toolbar highlights the active mode.
2. **Series insert** — pick "Contact", tap a `＋` target on a wire, edit dialog opens, contact appears in series with unbroken wires.
3. **Add branch** — pick "Branch", tap one element then another; a new parallel lane appears wired across that span.
4. **Movable endpoints** — drag a branch's teal start/end handle; it snaps to a different element column and the branch re-spans.
5. **Edit/modifier** — double-tap a contact, switch Normally Open→Normally Closed, Apply; symbol updates to `-|/|-`.
6. **Delete** — open a node, Delete; wires heal (no gap).
7. **TON block** — no overflow stripe anywhere.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/screens/ld_editor_screen.dart
git commit -m "feat(ld): mode toolbar, series insert, span branch with draggable endpoints, edit/delete"
```

---

### Task 5: Final validation across all projects

**Files:**
- None (verification only; small fixes if regressions surface).

- [ ] **Step 1: Run the full test suite**

Run: `flutter test`
Expected: all tests pass (including `ld_graph_test.dart` and the app smoke test).

- [ ] **Step 2: Analyze**

Run: `flutter analyze`
Expected: **No issues found!**

- [ ] **Step 3: Build and walk every project in Chrome**

Run: `flutter build web --release`, restart preview, and for each of the 7 projects confirm it loads. For the two ladder programs ("LD — Conveyor Belt Control" → `ConveyorBelt_LD`, and "All Languages — Water Treatment Plant" → `PumpControl_LD`) confirm:
- Continuous L1/L2 frame + unbroken wires.
- Rung 0 parallel branches render with clean brackets.
- The TON rungs show no overflow.
- Adding a branch, dragging its endpoints, editing, and deleting all work.

- [ ] **Step 4: Confirm branding and theme constraints**

Grep the touched files for forbidden branding and confirm none is present in user-facing strings:

Run: `grep -riE "external brand names" mobile/lib/screens/ld_editor_screen.dart mobile/lib/models/ld_graph.dart mobile/lib/data/default_projects.dart`
Expected: no matches.

- [ ] **Step 5: Final commit (if any fixes were made)**

```bash
git add -A
git commit -m "test(ld): validate ladder editor across all projects; analyze clean"
```

---

## Self-review notes

- **Spec coverage:** graph model (Task 1) ✓; continuous frame + unbroken wires (Task 3) ✓; branch over arbitrary span (Task 4 add-branch) ✓; draggable branch endpoints with snapping (Task 4 handles) ✓; TON overflow fix via content-sized lanes (Task 3 `_laneHeight`) ✓; migration of both LD projects + demo rungs (Task 2) ✓; simulation untouched (noted in Task 2) ✓; zero-analyze + dark theme + no branding (Global Constraints, Task 5) ✓.
- **Type consistency:** `LdNode`/`LdWire`/`LdRung`/`LdKind`, `LdBranchView`, `BranchSpec`, and every `ld_graph.dart` function name are used identically across Tasks 2-4.
- **Known simplification:** `deleteNode` uses a full cross-join heal (fine for the single-in/single-out series case that the editor produces); `_outPort/_inPort` take an unused `width` param only where rails need it — retained for a uniform signature.
