// Regression coverage for task 6 of the UI-repaint-decoupling effort:
// `_executeScan` must no longer wrap its per-scan model writes in a
// whole-shell `setState`. Repaints must flow ONLY through the `LiveTick`
// (throttled `_repaintThrottle.request()`), with a targeted `setState`
// reserved for the rare structural transitions — a fault first tripping, and
// an AlarmReset-driven clear.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  setUp(() {
    // WorkspaceShell() boots via the real (non-injected) SharedPreferences
    // .getInstance() path. Mock initial values so that call actually
    // resolves inside the test's zone (see shell_responsive_test.dart for
    // the same pattern).
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'repeated scans repaint the toolbar Scan Count via the LiveTick '
      'without incrementing the shell-level build counter', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    expect(find.text('Scan Count: 0'), findsOneWidget);
    final buildsBefore = state.debugBuildCount;

    // Drive several scan ticks directly the way the real Timer-driven scan
    // loop would, one per tick — no ancestor setState involved.
    for (var i = 0; i < 5; i++) {
      state.debugRunScan();
    }

    // Immediately after the scans, the repaint is still coalesced behind the
    // throttle window (NotifyThrottle's trailing timer) — the visible value
    // must still show the stale count.
    await tester.pump();
    expect(find.text('Scan Count: 0'), findsOneWidget);

    // Let the throttle window (100ms @ 10Hz) elapse so the coalesced pulse
    // actually fires.
    await tester.pump(const Duration(milliseconds: 150));

    // (a) the visible value updated over time, via the tick.
    expect(find.text('Scan Count: 5'), findsOneWidget);

    // (b) none of the 5 scans rebuilt the whole shell.
    expect(state.debugBuildCount, buildsBefore);
  });

  testWidgets(
      'a watchdog fault tripped mid-scan still forces an immediate shell '
      'rebuild (fault banner) via a targeted setState', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    // The default active project's own tasks have watchdogMs disabled (0) —
    // add one with a real watchdog limit so a forced-long "execution time"
    // actually trips a fault.
    state.debugAddTask(PlcTask(
      name: 'WatchdogTestTask',
      type: 'Continuous',
      programNames: const ['DummyProg'],
      watchdogMs: 1,
    ));
    final buildsBefore = state.debugBuildCount;

    // Force the per-task measured execution time far past that watchdog, so
    // the very next scan trips the watchdog inside `_executeScan`'s own fault
    // branch — exercising the real rewritten code path, not the
    // `debugForceFault` test shortcut.
    state.debugSetScanElapsedForTest(60000);
    state.debugRunScan();

    // The fault transition must rebuild the shell immediately — no throttle
    // wait required — so the banner is visible on the very next pump.
    await tester.pump();

    expect(state.debugBuildCount, greaterThan(buildsBefore));
    expect(find.text('Clear Fault'), findsOneWidget);
    expect(state.debugFaulted, isTrue);
  });
}
