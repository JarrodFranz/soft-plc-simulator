// Regression coverage for QA Bug 2: "Scan Count resets to near-zero on
// Pause->resume (3/3 tries) and on the first Undo after an edit."
//
// `System.ScanCount` (the toolbar's "Scan Count: N") is fed from the shell's
// `_sessionScans` counter. Two paths were zeroing it when they should not:
//   - `_startRunSession()` zeroed it on EVERY stopped -> running transition,
//     including a plain pause -> resume within the same project.
//   - `_applySnapshot()` (the undo/redo restore path) -> `_beginProjectSession()`
//     zeroed it on every snapshot restore, including a genuine undo/redo of an
//     edit within the same project.
//
// The contract this suite locks in:
//   1. Pause -> resume within the same project: Scan Count CONTINUES.
//   2. Undo/redo of an edit within the same project: Scan Count CONTINUES.
//   3. Switching to a DIFFERENT project: Scan Count resets to 0 (a genuinely
//      new session).
//
// All three tests pin the run/pause toggle to "paused" for everything except
// the transition under test, and drive scans exclusively via `debugRunScan()`
// (which bypasses the `isRunning` gate `_executeScan` sits behind in the real
// Timer-driven loop). That keeps the counter's value fully deterministic even
// while other `pump()` calls advance the fake clock for unrelated debounce/
// dialog-animation reasons.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

Widget _app() => const MaterialApp(home: WorkspaceShell());

// Boot-active project (all()[0] = 'Ladder — Conveyor Line'). The shell injects
// the reserved System tag at load, so the rendered count is tags.length + 1.
String _tagsLabel({int extra = 0}) {
  final p = DefaultProjects.all().first;
  return 'Tags & Structs (${p.tags.length + 1 + extra} Tags, ${p.structDefs.length} Structs)';
}

final String _baseLabel = _tagsLabel();
final String _plusOneLabel = _tagsLabel(extra: 1);

Future<void> _goToMemoryView(WidgetTester tester) async {
  await tester.tap(find.text(_baseLabel).hitTestable());
  await tester.pumpAndSettle();
}

Future<void> _addTagViaUi(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FloatingActionButton, 'Add Tag'));
  await tester.pump();
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, 'Add Tag'));
  await tester.pump();
  await tester.pump();
}

/// Taps the run/pause toggle by its current tooltip and settles one frame
/// (deliberately not `pumpAndSettle`, to avoid advancing the fake clock far
/// enough to let the real scan-loop Timer fire and perturb the counter).
Future<void> _tapRunToggle(WidgetTester tester, {required String tooltip}) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Scan Count continues across pause -> resume (same project)', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    // Freeze the real Timer-driven scan loop immediately so debugRunScan()
    // is the sole source of scan-count movement for the rest of the test.
    await _tapRunToggle(tester, tooltip: 'Pause Scan Loop');

    for (var i = 0; i < 5; i++) {
      state.debugRunScan();
    }
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Scan Count: 5'), findsOneWidget);

    // Resume: this is the transition under test.
    await _tapRunToggle(tester, tooltip: 'Run Scan Loop');

    // One more scan after resume must extend the count, not restart it.
    state.debugRunScan();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Scan Count: 6'), findsOneWidget,
        reason: 'Pause -> resume must not reset Scan Count within the same project');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Scan Count survives a genuine Undo/Redo of an edit (same project)', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    await _tapRunToggle(tester, tooltip: 'Pause Scan Loop');

    for (var i = 0; i < 4; i++) {
      state.debugRunScan();
    }
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Scan Count: 4'), findsOneWidget);

    await _goToMemoryView(tester);
    await _addTagViaUi(tester);
    expect(find.text(_plusOneLabel), findsOneWidget);

    // Let the autosave/history debounce (800ms) elapse so the edit is
    // captured as a real undo step.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Scan Count: 4'), findsOneWidget,
        reason: 'Merely elapsing the debounce must not touch the scan count');

    // Undo the structural edit -> a genuine snapshot restore. `_applySnapshot`
    // re-backfills the `System` tag via `ensureSystemTag` (so the *displayed*
    // count transiently reads its default until the next scan tick writes
    // the real `_sessionScans` back out) — drive one more scan to observe
    // the counter actually driving the display again, and assert it resumed
    // from where it left off rather than restarting from ~0/1.
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();

    expect(find.text(_baseLabel), findsOneWidget);
    state.debugRunScan();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Scan Count: 5'), findsOneWidget,
        reason: 'A genuine Undo must not reset Scan Count within the same project');

    // Redo re-applies the edit; the count must still be untouched.
    await tester.tap(find.byTooltip('Redo'));
    await tester.pumpAndSettle();

    expect(find.text(_plusOneLabel), findsOneWidget);
    state.debugRunScan();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Scan Count: 6'), findsOneWidget,
        reason: 'A genuine Redo must not reset Scan Count within the same project');
    expect(tester.takeException(), isNull);
  });

  // Final-review F4: `_clearFault()` zeroes min/max scan time but not
  // `_sessionScans`, and no path resets `_sessionScans` on a fault clear — so
  // the old `_sessionScans == 1` seed condition never re-fired and
  // `System.MinScanTimeMs` stayed pinned at 0 forever after the first fault.
  testWidgets('System.MinScanTimeMs re-seeds from a real sample after a fault is cleared',
      (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    await _tapRunToggle(tester, tooltip: 'Pause Scan Loop');

    // A few scans so min/max hold real samples. (A `Stopwatch` inside the
    // test's FakeAsync zone measures exactly 0 around a synchronous scan, so
    // the sample is supplied through the same kind of test seam the watchdog
    // measurement already uses.)
    state.debugSetScanTimeMsForTest(5.0);
    state.debugRunScan();
    state.debugSetScanTimeMsForTest(9.0);
    state.debugRunScan();
    await tester.pump(const Duration(milliseconds: 150));
    expect(readPath(state.debugActiveProject, 'System.MinScanTimeMs'), 5.0);
    expect(readPath(state.debugActiveProject, 'System.MaxScanTimeMs'), 9.0);

    state.debugForceFault('MainContinuousTask');
    await tester.pump();
    await tester.tap(find.text('Clear Fault'));
    await tester.pump();
    expect(state.debugFaulted, isFalse);

    // The clear zeroed min/max deliberately (they described the pre-fault
    // run); the very next scan after the clear must RE-SEED them.
    state.debugSetScanTimeMsForTest(7.0);
    state.debugRunScan();
    await tester.pump(const Duration(milliseconds: 150));

    final min = readPath(state.debugActiveProject, 'System.MinScanTimeMs') as double;
    final last = readPath(state.debugActiveProject, 'System.ScanTimeMs') as double;
    final max = readPath(state.debugActiveProject, 'System.MaxScanTimeMs') as double;
    expect(last, 7.0);
    expect(min, greaterThan(0.0), reason: 'MinScanTime must not stay pinned at 0 after a fault clear');
    expect(min, equals(last), reason: 'the first scan after a clear seeds min from its own sample');
    expect(max, equals(last));
    expect(tester.takeException(), isNull);
  });

  // Final-review F8: `_beginProjectSession` restarted the uptime stopwatch
  // unconditionally, so an undo/redo (which passes preserveScanCount: true —
  // the scan loop never actually stopped) snapped System.UptimeMs back to 0
  // even though Scan Count correctly continued.
  testWidgets('Uptime continues across a genuine Undo (same project)', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    await _tapRunToggle(tester, tooltip: 'Pause Scan Loop');

    await _goToMemoryView(tester);
    await _addTagViaUi(tester);
    await tester.pump(const Duration(seconds: 1));

    state.debugRunScan();
    await tester.pump(const Duration(milliseconds: 150));
    final before = readPath(state.debugActiveProject, 'System.UptimeMs') as int;
    expect(before, greaterThan(500), reason: 'the session has been up for at least a second by now');

    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    state.debugRunScan();
    await tester.pump(const Duration(milliseconds: 150));

    final after = readPath(state.debugActiveProject, 'System.UptimeMs') as int;
    expect(after, greaterThanOrEqualTo(before),
        reason: 'an undo is not a new run session — the uptime clock must keep running');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Scan Count resets to 0 when switching to a different project', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    await _tapRunToggle(tester, tooltip: 'Pause Scan Loop');

    for (var i = 0; i < 5; i++) {
      state.debugRunScan();
    }
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Scan Count: 5'), findsOneWidget);

    // Switch active project via the dropdown in the left dock.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(DefaultProjects.all()[1].name).last);
    await tester.pumpAndSettle();

    expect(find.text('Scan Count: 0'), findsOneWidget,
        reason: 'Switching to a different project is a genuinely new session');
    expect(tester.takeException(), isNull);
  });
}
