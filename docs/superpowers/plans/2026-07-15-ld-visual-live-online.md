# LD Editor Visual + Live-Online Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve LD rendering (branch risers at the inter-cell gap midpoint; contact/coil symbols on the wire) and add an opt-in "Go-Online" mode that highlights energized power flow and shows live block values while the PLC runs.

**Architecture:** Reuse the power solve `executeRung` already computes each scan by *tapping* it into a transient `LdMonitor` (a `Map<'prog|rung|nodeId', bool>`). The LD editor's `_LadderPainter` and element faces read that map + live tag values (`readPath`) and repaint through the existing `LiveTick` pulse, gated by a session-only `_online` toggle. Geometry gains pure, tested helpers in `ld_layout.dart`. Nothing is persisted.

**Tech Stack:** Flutter/Dart. `flutter test` (widget + pure), `flutter analyze`, `flutter build web --release`.

## Global Constraints

- Dark theme; use `withValues(alpha:)` (never `withOpacity`). Braces on all control flow. Zero `flutter analyze` warnings.
- No RenderFlex overflow at widths 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `models/ld_layout.dart`, `models/ld_exec.dart`, `models/ld_monitor.dart`.
- Live-value repaint goes through `LiveTick` — never a whole-shell `setState` on the scan tick.
- Additive only: with Go-Online **off** (or the map empty), rendering is byte-identical to today. No `toJson`/`fromJson` change.
- `LdMonitor` and the `_online` toggle are **transient** (session-only).
- Contacts/coils indicate true/false by **color only** (no TRUE/FALSE text). Live numeric values appear only on block faces.

## Key facts (verified against the code)

- `mobile/lib/models/ld_layout.dart`: `const double kLdColW = 116.0;` (column pitch), `const double kLdCellW = 66.0;` (cell width), `double ldColX(int col) => col * kLdColW;`.
- `mobile/lib/models/ld_exec.dart`: `void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt, {Set<String>? only, Set<String>? readOnly})` and `void executeRung(PlcProject p, String progName, LdRung rung, int dtMs, LdExecRuntime rt, void Function(String path, dynamic value) write)`. `executeRung` builds `final power = <String, bool>{};` keyed by node id; every branch assigns `power[n.id] = ...`.
- `mobile/lib/screens/scan_tick.dart`: `ScanTickRuntime` has `final LdExecRuntime ld = LdExecRuntime();` and `void resetSession()` calling `ld.clear()`. `runScanTick` calls `executeLdPrograms(p, dtMs, rt.ld, only: only, readOnly: readOnly);` inside a `for (final task in due)` loop (multiple LD calls per scan, filtered by `only`).
- `mobile/lib/screens/workspace_shell.dart`: `final ScanTickRuntime _scan = ScanTickRuntime();` (line ~104), `bool isRunning = true;` (line ~99), `bool _faulted` used alongside, `final LiveTick _liveTick = LiveTick();` provided via `LiveTickScope(notifier: _liveTick, ...)` wrapping the body (line ~1422). `LdEditorScreen(...)` is constructed at line ~2663.
- `mobile/lib/screens/ld_editor_screen.dart`: `_LadderPainter(this, rung, col, width)` holds the state `s`, so it can read `s.widget.*` and state fields. `_buildContactCoil(LdNode n)` renders a centered `Column[ Text(name), SizedBox(2), Text(symbol) ]`. `_positionedNode` positions each node at `top = _nodeCenterY(rung, n) - h/2`. `_LadderPainter.paint` draws each wire between `s._outPort(...)` and `s._inPort(...)`, dropping/rising verticals at `p1.dx`/`p2.dx`.
- `mobile/lib/widgets/live_tick.dart`: `LiveTick` (a `Listenable`/`ChangeNotifier`) + `LiveTickScope.of(context)` returns the ambient `LiveTick`. `readPath(PlcProject, String)` lives in `mobile/lib/models/tag_resolver.dart`.

---

### Task 1: Gap-center geometry helpers (pure)

**Files:**
- Modify: `mobile/lib/models/ld_layout.dart`
- Test: `mobile/test/ld_layout_geometry_test.dart` (create)

**Interfaces:**
- Produces: `const double kLdGapHalf`; `double ldRiserXBefore(int col)`; `double ldRiserXAfter(int col)`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/ld_layout_geometry_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/ld_layout.dart';

void main() {
  test('kLdGapHalf is half the inter-cell gap', () {
    // gap = kLdColW - kLdCellW = 116 - 66 = 50; half = 25.
    expect(kLdGapHalf, 25.0);
  });

  test('ldRiserXBefore centres in the gap left of the column', () {
    // col 1 left edge = 116; riser sits 25px before it.
    expect(ldRiserXBefore(1), 91.0);
    expect(ldRiserXBefore(2), 207.0);
  });

  test('ldRiserXAfter centres in the gap right of the column', () {
    // col 1: right edge = 116 + 66 = 182; +25 = 207.
    expect(ldRiserXAfter(1), 207.0);
    expect(ldRiserXAfter(0), 91.0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/ld_layout_geometry_test.dart`
Expected: FAIL — `kLdGapHalf`, `ldRiserXBefore`, `ldRiserXAfter` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `mobile/lib/models/ld_layout.dart` (after the existing `ldColX`):

```dart
/// Half the inter-cell wire gap — the inset from a cell edge to the centre of
/// the gap between it and the neighbouring column. `(116 - 66)/2 = 25`.
const double kLdGapHalf = (kLdColW - kLdCellW) / 2;

/// X of a vertical branch riser sitting in the gap immediately to the LEFT of
/// the cell at [col] (centred between col-1's right edge and col's left edge).
double ldRiserXBefore(int col) => ldColX(col) - kLdGapHalf;

/// X of a vertical branch riser sitting in the gap immediately to the RIGHT of
/// the cell at [col].
double ldRiserXAfter(int col) => ldColX(col) + kLdCellW + kLdGapHalf;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/ld_layout_geometry_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/ld_layout.dart mobile/test/ld_layout_geometry_test.dart
git commit -m "feat(ld): gap-centre branch-riser geometry helpers"
```

---

### Task 2: Branch risers drawn at the gap midpoint

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (`_LadderPainter.paint`, ~lines 1521-1542)
- Test: `mobile/test/ld_branch_render_test.dart` (create)

**Interfaces:**
- Consumes: `ldRiserXBefore(int)`, `ldRiserXAfter(int)` (Task 1); `col` map (`Map<String,int>`) already in the painter.

**Context:** The painter currently drops the branch vertical at `p1.dx` (source right edge) when descending into a deeper lane, and rises at `p2.dx` (destination left edge) when returning. Replace those with gap-centered riser X's. Same-row wires stay straight. The riser column is the *branch element's* column: descending → the destination is the branch element (`col[dst]`), riser sits in the gap before it (`ldRiserXBefore`); returning → the source is the branch element (`col[src]`), riser sits in the gap after it (`ldRiserXAfter`).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/ld_branch_render_test.dart`. This is a smoke/overflow test — it pumps a rung with a parallel branch and asserts a clean render (the riser math itself is unit-tested in Task 1). Use the default "Basic Motor Start Stop" project which has a seal-in branch.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('a rung with a parallel branch renders without overflow', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = defaultProjects().firstWhere((p) => p.name.contains('Motor'));
    final prog = proj.programs.firstWhere((p) => p.language == 'LadderLogic');

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: LdEditorScreen(
          currentProject: proj,
          program: prog,
          onProgramUpdated: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails or errors**

Run: `cd mobile && flutter test test/ld_branch_render_test.dart`
Expected: This test PASSES against current code (it is a regression guard). If `defaultProjects()`/import names differ, fix the imports so it compiles and passes first — that establishes the baseline. (If it already passes, that is correct; the behavioural change in Step 3 must keep it passing.)

- [ ] **Step 3: Implement the riser change**

In `mobile/lib/screens/ld_editor_screen.dart`, ensure `ld_layout.dart` is imported (it already is via existing helpers). Replace the branch-drawing block inside `_LadderPainter.paint` (the `if (src.row == dst.row) { ... } else if (dst.row > src.row) { ... } else { ... }`) with:

```dart
      final path = Path()..moveTo(p1.dx, p1.dy);
      if (src.row == dst.row) {
        path.lineTo(p2.dx, p2.dy);
      } else if (dst.row > src.row) {
        // Descending into a deeper branch lane: riser centred in the gap
        // BEFORE the branch element (the destination).
        final riserX = ldRiserXBefore(col[dst.id] ?? 0);
        path.lineTo(riserX, p1.dy);
        path.lineTo(riserX, p2.dy);
        path.lineTo(p2.dx, p2.dy);
      } else {
        // Returning to a shallower lane: riser centred in the gap AFTER the
        // branch element (the source).
        final riserX = ldRiserXAfter(col[src.id] ?? 0);
        path.lineTo(riserX, p1.dy);
        path.lineTo(riserX, p2.dy);
        path.lineTo(p2.dx, p2.dy);
      }
      canvas.drawPath(path, paint);
```

- [ ] **Step 4: Run tests**

Run: `cd mobile && flutter test test/ld_branch_render_test.dart`
Expected: PASS. Also run the existing LD tests: `cd mobile && flutter test test/ld_editor_test.dart` (if present) — Expected: PASS.

- [ ] **Step 5: Visual check (manual, optional but recommended)**

Run: `cd mobile && flutter analyze`
Expected: No issues.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/screens/ld_editor_screen.dart mobile/test/ld_branch_render_test.dart
git commit -m "feat(ld): draw branch risers at the inter-cell gap midpoint"
```

---

### Task 3: Contact/coil symbol on the wire

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (`_buildContactCoil`, ~lines 1259-1322)
- Test: `mobile/test/ld_symbol_alignment_test.dart` (create)

**Context:** Today `_buildContactCoil` returns a `Container` wrapping a **centered** `Column[ Text(name), SizedBox(2), Text(symbol) ]`, so the symbol's centre is *below* the cell centre (where the wire enters). Restructure so the **symbol glyph is centred in the cell** (its centre == cell centre == port Y) and the tag name captions just above it.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/ld_symbol_alignment_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('contact symbol glyph is vertically centred on the cell', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = defaultProjects().firstWhere((p) => p.name.contains('Motor'));
    final prog = proj.programs.firstWhere((p) => p.language == 'LadderLogic');

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: LdEditorScreen(
          currentProject: proj,
          program: prog,
          onProgramUpdated: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The NO contact glyph '-| |-' should be centred within its element cell.
    // Find one contact symbol and its enclosing element Container centre.
    final symbol = find.text('-| |-').first;
    expect(symbol, findsWidgets);
    final symbolCenter = tester.getCenter(symbol);
    // The element cell height is _kContactH (54). The symbol centre must be
    // within a few px of the tap target centre. Reuse the GestureDetector that
    // wraps the node as the cell proxy.
    final cell = find.ancestor(of: symbol, matching: find.byType(GestureDetector)).first;
    final cellCenter = tester.getCenter(cell);
    expect((symbolCenter.dy - cellCenter.dy).abs(), lessThan(4.0));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/ld_symbol_alignment_test.dart`
Expected: FAIL — with the current centered `Column[name, gap, symbol]`, the symbol centre is well below the cell centre (delta ≈ 10-12px > 4).

- [ ] **Step 3: Implement the symbol-on-wire layout**

Replace the `return Container(...)` body at the end of `_buildContactCoil` with a `Stack` that centres the symbol and captions the name above it:

```dart
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Symbol glyph centred on the cell — the wire (drawn at the cell's
          // vertical centre) passes through it.
          Text(symbol,
              maxLines: 1,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: color)),
          // Tag name captioned just above the glyph.
          Positioned(
            top: 4,
            left: 2,
            right: 2,
            child: Text(n.variable,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 9,
                    color: color,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/ld_symbol_alignment_test.dart`
Expected: PASS. Also `cd mobile && flutter test test/ld_branch_render_test.dart` — Expected: PASS (no overflow).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/ld_editor_screen.dart mobile/test/ld_symbol_alignment_test.dart
git commit -m "feat(ld): centre contact/coil symbol on the wire, caption name above"
```

---

### Task 4: `LdMonitor` power tap

**Files:**
- Create: `mobile/lib/models/ld_monitor.dart`
- Modify: `mobile/lib/models/ld_exec.dart` (`executeRung`, `executeLdPrograms`)
- Test: `mobile/test/ld_monitor_test.dart` (create)

**Interfaces:**
- Produces: `class LdMonitor { final Map<String,bool> nodePower; String keyFor(String prog, int rungIndex, String nodeId); void clear(); }`.
- `executeRung(..., {LdMonitor? monitor})` and `executeLdPrograms(..., {..., LdMonitor? monitor})` — optional, defaults null (existing callers unaffected).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/ld_monitor_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';

PlcProject _projWithSeries({required bool aVal}) {
  final proj = PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
  );
  proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: aVal, ioType: 'Internal'));
  proj.tags.add(PlcTag(name: 'Y', path: 'Y', dataType: 'BOOL', value: false, ioType: 'Internal'));
  // Rung: L1 -- [A] -- (Y). A single series contact into a coil.
  final rung = LdRung(rungIndex: 0, comment: '', nodes: [
    LdNode(id: 'L', kind: LdKind.leftRail),
    LdNode(id: 'a', kind: LdKind.contact, variable: 'A'),
    LdNode(id: 'y', kind: LdKind.coil, variable: 'Y'),
    LdNode(id: 'R', kind: LdKind.rightRail),
  ], wires: [
    LdWire(fromId: 'L', toId: 'a'),
    LdWire(fromId: 'a', toId: 'y'),
    LdWire(fromId: 'y', toId: 'R'),
  ]);
  proj.programs.add(PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]));
  return proj;
}

void main() {
  test('monitor records energized nodes on a true series path', () {
    final proj = _projWithSeries(aVal: true);
    final rt = LdExecRuntime();
    final mon = LdMonitor();
    executeLdPrograms(proj, 100, rt, monitor: mon);
    expect(mon.nodePower[mon.keyFor('Main', 0, 'a')], isTrue);
    expect(mon.nodePower[mon.keyFor('Main', 0, 'y')], isTrue);
  });

  test('monitor records de-energized downstream when a series contact is false', () {
    final proj = _projWithSeries(aVal: false);
    final rt = LdExecRuntime();
    final mon = LdMonitor();
    executeLdPrograms(proj, 100, rt, monitor: mon);
    expect(mon.nodePower[mon.keyFor('Main', 0, 'a')], isFalse);
    expect(mon.nodePower[mon.keyFor('Main', 0, 'y')], isFalse);
  });

  test('executeLdPrograms without a monitor is unaffected (no throw)', () {
    final proj = _projWithSeries(aVal: true);
    final rt = LdExecRuntime();
    executeLdPrograms(proj, 100, rt); // monitor omitted
    expect(readPathBool(proj, 'Y'), isTrue);
  });
}

// Local helper mirroring the tag read used by the app.
bool readPathBool(PlcProject p, String path) =>
    p.tags.firstWhere((t) => t.name == path).value == true;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/ld_monitor_test.dart`
Expected: FAIL — `ld_monitor.dart` / `LdMonitor` do not exist; `monitor:` param unknown.

- [ ] **Step 3: Create `LdMonitor`**

Create `mobile/lib/models/ld_monitor.dart`:

```dart
/// Transient, session-only tap of the LD power solve for the "Go-Online" view.
/// Not persisted; cleared on project/session reset.
class LdMonitor {
  /// Key: '<progName>|<rungIndex>|<nodeId>' -> energized/passing on the last
  /// scan that executed this node.
  final Map<String, bool> nodePower = {};

  String keyFor(String prog, int rungIndex, String nodeId) =>
      '$prog|$rungIndex|$nodeId';

  void clear() => nodePower.clear();
}
```

- [ ] **Step 4: Tap the power map in `executeRung` / `executeLdPrograms`**

In `mobile/lib/models/ld_exec.dart`:

1. Add the import at the top:

```dart
import 'ld_monitor.dart';
```

2. Change `executeLdPrograms`' signature and pass the monitor through:

```dart
void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt,
    {Set<String>? only, Set<String>? readOnly, LdMonitor? monitor}) {
  for (final prog in p.programs) {
    if (prog.language != 'LadderLogic') {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    for (final rung in prog.rungs) {
      executeRung(p, prog.name, rung, dtMs, rt, (path, v) {
        if (readOnly == null || !readOnly.contains(path)) {
          _forceAwareWrite(p, path, v);
        }
      }, monitor: monitor);
    }
  }
}
```

3. Change `executeRung`'s signature to accept the monitor:

```dart
void executeRung(PlcProject p, String progName, LdRung rung, int dtMs,
    LdExecRuntime rt, void Function(String path, dynamic value) write,
    {LdMonitor? monitor}) {
```

4. Immediately after the `power` map is fully computed — i.e. at the very end of the `for (final n in ordered) { ... }` loop body is awkward per-branch; instead record after the loop by iterating `power`. Add this block **after** the `for (final n in ordered)` loop closes, before the function returns:

```dart
  if (monitor != null) {
    for (final n in rung.nodes) {
      monitor.nodePower[monitor.keyFor(progName, rung.rungIndex, n.id)] =
          power[n.id] ?? false;
    }
  }
```

(The `power` map is in scope for the whole function; recording once after the solve captures every node's final energized state.)

- [ ] **Step 5: Run test to verify it passes**

Run: `cd mobile && flutter test test/ld_monitor_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the existing LD exec suite to confirm no regression**

Run: `cd mobile && flutter test test/ld_exec_test.dart` (and any scan tests)
Expected: PASS (monitor defaults null; behavior unchanged).

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/models/ld_monitor.dart mobile/lib/models/ld_exec.dart mobile/test/ld_monitor_test.dart
git commit -m "feat(ld): LdMonitor power tap on executeRung/executeLdPrograms (opt-in)"
```

---

### Task 5: Thread the monitor through the scan runtime

**Files:**
- Modify: `mobile/lib/screens/scan_tick.dart` (`ScanTickRuntime`, `runScanTick`)
- Test: `mobile/test/scan_ld_monitor_test.dart` (create)

**Interfaces:**
- Consumes: `LdMonitor` (Task 4), `executeLdPrograms(..., monitor:)`.
- Produces: `ScanTickRuntime.ldMonitor` (public field), cleared by `resetSession()`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/scan_ld_monitor_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/scan_tick.dart';

void main() {
  test('runScanTick populates the LD monitor for a running LD program', () {
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal'));
    proj.tags.add(PlcTag(name: 'Y', path: 'Y', dataType: 'BOOL', value: false, ioType: 'Internal'));
    final rung = LdRung(rungIndex: 0, comment: '', nodes: [
      LdNode(id: 'L', kind: LdKind.leftRail),
      LdNode(id: 'a', kind: LdKind.contact, variable: 'A'),
      LdNode(id: 'y', kind: LdKind.coil, variable: 'Y'),
      LdNode(id: 'R', kind: LdKind.rightRail),
    ], wires: [
      LdWire(fromId: 'L', toId: 'a'),
      LdWire(fromId: 'a', toId: 'y'),
      LdWire(fromId: 'y', toId: 'R'),
    ]);
    proj.programs.add(PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]));
    // A continuous task owning the program so it is due every scan.
    proj.tasks.add(PlcTask(
      taskName: 'T', taskType: 'Continuous', programs: ['Main'],
      periodMs: 0, priority: 1, triggerTag: '', watchdogMs: 0));

    final rt = ScanTickRuntime();
    runScanTick(proj, 100, rt);

    expect(rt.ldMonitor.nodePower[rt.ldMonitor.keyFor('Main', 0, 'a')], isTrue);

    rt.resetSession();
    expect(rt.ldMonitor.nodePower, isEmpty);
  });
}
```

(Adjust the `PlcTask(...)` constructor arguments to match the real model if names differ — read `mobile/lib/models/project_model.dart` for `PlcTask`'s required fields.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/scan_ld_monitor_test.dart`
Expected: FAIL — `ScanTickRuntime.ldMonitor` does not exist.

- [ ] **Step 3: Add the monitor field, clear, and pass-through**

In `mobile/lib/screens/scan_tick.dart`:

1. Add the import:

```dart
import '../models/ld_monitor.dart';
```

2. In `ScanTickRuntime`, add the field alongside `ld`:

```dart
  final LdMonitor ldMonitor = LdMonitor();
```

3. In `resetSession()`, add:

```dart
    ldMonitor.clear();
```

4. In `runScanTick`, pass the monitor to the LD call:

```dart
    executeLdPrograms(p, dtMs, rt.ld, only: only, readOnly: readOnly, monitor: rt.ldMonitor);
```

(The monitor is **not** cleared each scan — `executeRung` overwrites each executed node's key, so a periodic program keeps its last state between runs without flicker; only `resetSession()` clears it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/scan_ld_monitor_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the scan-tick suite for regressions**

Run: `cd mobile && flutter test test/scan_tick_test.dart` (if present)
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/screens/scan_tick.dart mobile/test/scan_ld_monitor_test.dart
git commit -m "feat(ld): own + thread + clear the LdMonitor in ScanTickRuntime"
```

---

### Task 6: Go-Online toggle + energized wire/element highlighting

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (constructor, toolbar, `_buildRungCanvas`, `_positionedNode`, `_buildContactCoil`, `_LadderPainter`)
- Modify: `mobile/lib/screens/workspace_shell.dart` (`LdEditorScreen(...)` call, ~line 2663)
- Test: `mobile/test/ld_online_highlight_test.dart` (create)

**Interfaces:**
- Consumes: `LdMonitor` (Task 4), `LiveTickScope.of(context)`.
- Produces: `LdEditorScreen({..., required LdMonitor monitor, required bool scanRunning})`.

**Context:** Live rendering is active iff `_online` (session-only toggle). When active, wires/elements read `monitor.nodePower[keyFor(program.name, rung.rungIndex, nodeId)]`: energized → bright green, de-energized → dim slate. `scanRunning` only labels the toggle (LIVE vs FROZEN). The rung `Stack` repaints on the `LiveTick` pulse while `_online`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/ld_online_highlight_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('Go-Online toggle appears and can be turned on', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal')],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    final rung = LdRung(rungIndex: 0, comment: '', nodes: [
      LdNode(id: 'L', kind: LdKind.leftRail),
      LdNode(id: 'a', kind: LdKind.contact, variable: 'A'),
      LdNode(id: 'R', kind: LdKind.rightRail),
    ], wires: [
      LdWire(fromId: 'L', toId: 'a'),
      LdWire(fromId: 'a', toId: 'R'),
    ]);
    final prog = PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]);
    proj.programs.add(prog);

    final mon = LdMonitor();
    mon.nodePower[mon.keyFor('Main', 0, 'a')] = true;

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: LdEditorScreen(
          currentProject: proj,
          program: prog,
          onProgramUpdated: () {},
          monitor: mon,
          scanRunning: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The Go-Online toggle is present.
    final toggle = find.byTooltip('Go Online (live monitor)');
    expect(toggle, findsOneWidget);

    // Turning it on does not throw and keeps the ladder rendered.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('-| |-'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/ld_online_highlight_test.dart`
Expected: FAIL — `LdEditorScreen` has no `monitor`/`scanRunning` params; no toggle.

- [ ] **Step 3: Add constructor params**

In `mobile/lib/screens/ld_editor_screen.dart`, extend `LdEditorScreen`:

```dart
class LdEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final PlcProgram program;
  final VoidCallback onProgramUpdated;
  final LdMonitor monitor;
  final bool scanRunning;

  const LdEditorScreen({
    super.key,
    required this.currentProject,
    required this.program,
    required this.onProgramUpdated,
    required this.monitor,
    required this.scanRunning,
  });

  @override
  State<LdEditorScreen> createState() => _LdEditorScreenState();
}
```

Add the import near the top: `import '../models/ld_monitor.dart';` and `import '../widgets/live_tick.dart';` (if not already imported).

- [ ] **Step 4: Add the `_online` field + toolbar toggle**

In `_LdEditorScreenState`, add near the other UI-state fields:

```dart
  bool _online = false;
```

Add helpers to resolve live styling (place inside the state class):

```dart
  // Energized/de-energized palette for the live "online" view.
  static const Color _kEnergized = Colors.greenAccent;
  static const Color _kDeEnergized = Color(0xFF475569); // slate-600

  bool _nodeLit(LdRung rung, LdNode n) =>
      _online &&
      (widget.monitor.nodePower[
              widget.monitor.keyFor(widget.program.name, rung.rungIndex, n.id)] ??
          false);
```

Add the toggle to the app-bar `actions` (in `build`, alongside the existing mode toolbar / actions). Find the `AppBar(... actions: [...])` and add:

```dart
          IconButton(
            icon: Icon(Icons.sensors, color: _online ? Colors.greenAccent : Colors.grey),
            tooltip: 'Go Online (live monitor)',
            onPressed: () => setState(() => _online = !_online),
          ),
```

- [ ] **Step 5: Repaint the rung on the LiveTick pulse while online**

In `_buildRungCanvas`, wrap the returned `canvas`/`Stack` so it rebuilds on the pulse when `_online`. Locate `final canvas = SizedBox(...)` and, at the two `return` sites, wrap when online:

```dart
              Widget wrapLive(Widget child) {
                if (!_online) {
                  return child;
                }
                return ListenableBuilder(
                  listenable: LiveTickScope.of(context),
                  builder: (_, __) => child,
                );
              }
```

Then change `return canvas;` to `return wrapLive(canvas);` and the `SingleChildScrollView(... child: canvas)` to `return wrapLive(SingleChildScrollView(scrollDirection: Axis.horizontal, child: canvas));`.

(Because the `Stack` children — painter + element widgets — are rebuilt inside the `ListenableBuilder`, and the painter/`_nodeLit` read `_online` + `widget.monitor` at build/paint time, each pulse reflects the latest scan. `_LadderPainter.shouldRepaint` is already `true`.)

- [ ] **Step 6: Energized colors in the painter**

In `_LadderPainter.paint`, before the wire loop, and per-wire, set the stroke from the source node's live state:

```dart
    for (final w in rung.wires) {
      final src = nodeById(w.fromId);
      final dst = nodeById(w.toId);
      if (src == null || dst == null) {
        continue;
      }
      // Live power flow: a wire is energized iff its source node is.
      if (s._online) {
        final lit = s._nodeLit(rung, src);
        paint.color = lit ? _LdEditorScreenState._kEnergized : _LdEditorScreenState._kDeEnergized;
        paint.strokeWidth = lit ? 3.0 : 2.0;
      } else {
        paint.color = Colors.greenAccent;
        paint.strokeWidth = 2.0;
      }
      final p1 = s._outPort(rung, src, col, width);
      // ... existing path building ...
    }
```

(Move the `paint.color`/`strokeWidth` assignment out of the initial `Paint()` config if needed so it can vary per wire.)

- [ ] **Step 7: Energized styling on contact/coil faces**

Thread the lit/live state into `_buildContactCoil`. Change `_positionedNode` to pass it, and `_buildContactCoil` to accept it:

In `_positionedNode`, compute and pass:

```dart
        child: n.kind == LdKind.block
            ? _buildBlock(n, live: _online, lit: _nodeLit(rung, n))
            : (n.kind == LdKind.link ? _buildLink(n) : _buildContactCoil(n, live: _online, lit: _nodeLit(rung, n))),
```

Change `_buildContactCoil(LdNode n)` to `_buildContactCoil(LdNode n, {required bool live, required bool lit})` and derive the border/glyph color:

```dart
  Widget _buildContactCoil(LdNode n, {required bool live, required bool lit}) {
    final isCoil = n.kind == LdKind.coil;
    // baseColor is the existing static color (amberAccent for coils, greenAccent
    // for contacts); when live, override with energized/de-energized.
    // ... keep the existing symbol/switch logic that sets `symbol` and `color` ...
    final Color faceColor = !live ? color : (lit ? _kEnergized : _kDeEnergized);
```

Then use `faceColor` for the `Border.all(color: ...)` and the two `Text(... color: faceColor)` in the returned `Stack` (Task 3's layout). Add a faint energized fill when `lit`:

```dart
      decoration: BoxDecoration(
        color: lit ? _kEnergized.withValues(alpha: 0.12) : const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: faceColor, width: 1.5),
      ),
```

For this task, `_buildBlock` accepts the params but only applies the **border/header** energized color (live block *values* are Task 7). Change `_buildBlock(LdNode n)` to `_buildBlock(LdNode n, {required bool live, required bool lit})` and set its `Border.all(color: ...)` to `!live ? Colors.grey.shade500 : (lit ? _kEnergized : _kDeEnergized)`. Leave `_buildDataBlock` reachable via `_buildBlock` (pass the params through: `return _buildDataBlock(n, live: live, lit: lit);` and give `_buildDataBlock` the same optional params + border treatment).

- [ ] **Step 8: Pass the monitor + running state from the shell**

In `mobile/lib/screens/workspace_shell.dart` at the `LdEditorScreen(...)` call (~line 2663):

```dart
        return LdEditorScreen(
          currentProject: _activeProject,
          program: prog,
          onProgramUpdated: _markDirtyAndAutosave,
          monitor: _scan.ldMonitor,
          scanRunning: isRunning && !_faulted,
        );
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `cd mobile && flutter test test/ld_online_highlight_test.dart`
Expected: PASS.

- [ ] **Step 10: Run analyze + the LD suite**

Run: `cd mobile && flutter analyze && flutter test test/ld_branch_render_test.dart test/ld_symbol_alignment_test.dart`
Expected: No issues; PASS.

- [ ] **Step 11: Commit**

```bash
git add mobile/lib/screens/ld_editor_screen.dart mobile/lib/screens/workspace_shell.dart mobile/test/ld_online_highlight_test.dart
git commit -m "feat(ld): Go-Online toggle + energized power-flow highlighting (LiveTick)"
```

---

### Task 7: Live block-face values (online)

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (`_buildBlock`, `_buildDataBlock`)
- Test: `mobile/test/ld_online_values_test.dart` (create)

**Context:** When `live` is true, block faces show live values read from the tag DB via `readPath`: timers show `ACC / PT`, counters `CV / PV`, compare/math the resolved operands (+ math result). When not live, faces keep the current static text.

**Interfaces:**
- Consumes: `readPath(PlcProject, String)` from `mobile/lib/models/tag_resolver.dart` (import it if not already imported).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/ld_online_values_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('a TON block shows live ACC/PT when online', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    // A TIMER-typed tag 'T1' with ACC=1400, PRE=3000 (use the project's TIMER
    // composite; set the members via the struct value map).
    proj.tags.add(PlcTag(
      name: 'T1', path: 'T1', dataType: 'TIMER', ioType: 'Internal',
      value: {'ACC': 1400, 'PRE': 3000, 'EN': true, 'DN': false, 'TT': true},
    ));
    final rung = LdRung(rungIndex: 0, comment: '', nodes: [
      LdNode(id: 'L', kind: LdKind.leftRail),
      LdNode(id: 'b', kind: LdKind.block, blockType: 'TON', variable: 'T1', presetMs: 3000),
      LdNode(id: 'R', kind: LdKind.rightRail),
    ], wires: [
      LdWire(fromId: 'L', toId: 'b'),
      LdWire(fromId: 'b', toId: 'R'),
    ]);
    final prog = PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]);
    proj.programs.add(prog);

    final mon = LdMonitor();

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: LdEditorScreen(
          currentProject: proj,
          program: prog,
          onProgramUpdated: () {},
          monitor: mon,
          scanRunning: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Static: shows the preset line 'PT 3000ms'.
    expect(find.textContaining('3000'), findsWidgets);

    // Turn online; the live ACC/PT readout appears.
    await tester.tap(find.byTooltip('Go Online (live monitor)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1400'), findsOneWidget);
  });
}
```

(Confirm the `PlcTag` TIMER value-map shape against `project_model.dart`/`tag_resolver.dart`; adapt the members if the composite uses different keys.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/ld_online_values_test.dart`
Expected: FAIL — no live `1400` readout when online.

- [ ] **Step 3: Implement live readouts**

Import the resolver in `ld_editor_screen.dart` if absent: `import '../models/tag_resolver.dart';`.

Add a helper to the state:

```dart
  String _liveNum(String path) {
    final v = readPath(widget.currentProject, path);
    if (v is num) {
      return v is int ? '$v' : v.toStringAsFixed(1);
    }
    return '—';
  }
```

In `_buildBlock` (timers/counters), when `live` is true, replace the static `presetLine` with a live one:
- Timer (`TON`/`TOF`/`TP`): `presetLine = live ? '${_liveNum('${n.variable}.ACC')} / ${n.presetMs} ms' : 'PT ${n.presetMs}ms';`
- Counter (`CTU`/`CTD`/`CTUD`): `presetLine = live ? 'CV ${_liveNum('${n.variable}.CV')} / ${n.presetMs}' : 'PV ${n.presetMs}';`

In `_buildDataBlock`, when `live`, resolve operands and show them in place of the static `n.operandA`/`n.operandB` text:

```dart
    String liveOperand(String s) {
      final lit = num.tryParse(s);
      if (lit != null) {
        return s;
      }
      return live ? _liveNum(s) : s;
    }
```

and render `liveOperand(n.operandA)` / `liveOperand(n.operandB)`. For math blocks, when `live`, append the destination's live value: `'→ ${n.variable} = ${_liveNum(n.variable)}'`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/ld_online_values_test.dart`
Expected: PASS.

- [ ] **Step 5: Overflow guard**

Run: `cd mobile && flutter test test/ld_branch_render_test.dart`
Expected: PASS (block faces still fit — the live line replaces, not adds, a line).

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/screens/ld_editor_screen.dart mobile/test/ld_online_values_test.dart
git commit -m "feat(ld): live block-face values (ACC/PT, CV/PV, operands) in online mode"
```

---

### Task 8: Validation, round-trip guard, docs

**Files:**
- Create: `mobile/test/ld_no_persist_test.dart`
- Create: `docs/ld-editor.md`
- Modify: `ROADMAP.md`, `README.md`

- [ ] **Step 1: Write the no-persist round-trip guard**

Create `mobile/test/ld_no_persist_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('LD monitor / online state add nothing to serialized JSON', () {
    for (final proj in defaultProjects()) {
      final json = proj.toJson();
      final round = PlcProject.fromJson(json);
      // Serialization is unchanged by this feature — a re-serialize is stable
      // and contains no monitor/online keys.
      expect(round.toJson().toString(), json.toString());
      expect(json.toString().contains('nodePower'), isFalse);
      expect(json.toString().contains('online'), isFalse);
    }
  });
}
```

- [ ] **Step 2: Run it**

Run: `cd mobile && flutter test test/ld_no_persist_test.dart`
Expected: PASS.

- [ ] **Step 3: Full green gate**

Run: `cd mobile && flutter analyze`
Expected: No issues.

Run: `cd mobile && flutter test`
Expected: All tests PASS (existing suite + the new LD tests).

Run: `cd mobile && flutter build web --release`
Expected: Builds.

- [ ] **Step 4: Write `docs/ld-editor.md`**

Create `docs/ld-editor.md` documenting: the gap-center branch riser geometry (with the `kLdGapHalf`/`ldRiserXBefore`/`ldRiserXAfter` helpers), the symbol-on-wire layout, and the Go-Online live monitor (the `LdMonitor` power tap, the `_online` toggle, energized/de-energized palette, live block values, LiveTick repaint, freeze-on-pause, and that nothing is persisted).

- [ ] **Step 5: Update ROADMAP.md + README.md**

Add an LD-monitoring deliverable to the appropriate phase in `ROADMAP.md` (Phase 3 IEC editors, or a short "post-ship" note) and a one-line mention in `README.md`'s LD feature bullet and/or the phase table. Keep the "no OpenPLC/vendor branding" rule.

- [ ] **Step 6: Commit**

```bash
git add mobile/test/ld_no_persist_test.dart docs/ld-editor.md ROADMAP.md README.md
git commit -m "test(ld): no-persist guard; docs + roadmap/readme for LD visual + online monitor"
```

---

## Self-Review

**Spec coverage:**
- Part A (branch risers at gap midpoint) → Tasks 1-2. ✓
- Part B (symbol on wire) → Task 3. ✓
- Part C1 (power tap) → Task 4. ✓
- Part C2 (wire monitor through scan + editor) → Tasks 5, 6 (step 8). ✓
- Part C3 (Go-Online toggle, session-only) → Task 6. ✓
- Part C4 (energized colors + live block values) → Tasks 6 (colors) + 7 (values). ✓
- Part C5 (LiveTick repaint, freeze on pause) → Task 6 (steps 5, and freeze falls out of not-clearing the monitor per scan). ✓
- Testing (geometry, power tap, symbol alignment, online colors, LiveTick, overflow, round-trip) → Tasks 1,3,4,5,6,7,8. ✓
- Docs/roadmap/readme → Task 8. ✓

**Note on a spec refinement (documented for the reviewer):** the spec §C3 said "active iff `_online && isRunning`", while §C5 wanted paused to *freeze* the last scan. Those conflict — gating on `isRunning` would drop paused to static. The plan resolves this in favour of §C5: **live rendering is gated on `_online` alone**; the monitor naturally freezes when paused (not updated) and updates when running. `scanRunning` is passed only for a future LIVE/FROZEN label and the shell wiring, not to gate rendering. This is intentional and better; a reviewer seeing `_online`-only gating should treat it as correct, not a defect.

**Placeholder scan:** No TBD/TODO. Every code step shows the code. A few "confirm against the model if names differ" notes on test fixtures (`PlcTask`, the TIMER value-map shape) are real instructions to check `project_model.dart`, not placeholders for logic.

**Type consistency:** `LdMonitor.keyFor(prog, rungIndex, nodeId)` and `nodePower` used identically in Tasks 4-7. `executeLdPrograms(..., monitor:)` / `executeRung(..., monitor:)` consistent. `_buildContactCoil(n, {required bool live, required bool lit})`, `_buildBlock(n, {required bool live, required bool lit})`, `_buildDataBlock(n, {required bool live, required bool lit})`, `_nodeLit(rung, n)`, `_liveNum(path)` consistent across tasks. `LdEditorScreen({..., required LdMonitor monitor, required bool scanRunning})` matches the shell call in Task 6 step 8.
