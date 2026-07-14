// Regression coverage for task 5 of the UI-repaint-decoupling effort: the
// HMI dashboard's live component values and the shell toolbar's scan counter
// must repaint on a bare `LiveTick` pulse, not only when an ancestor (the
// shell) setStates. Before this task, both read their bound value once per
// widget build, so a value mutated directly (as the scan loop does) never
// appeared until something else forced a full rebuild.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/hmi_dashboard_builder_screen.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import '../support/responsive_test_utils.dart';

PlcProject _buildHmiProject() {
  final proj = PlcProject(
    id: 'p',
    name: 'p',
    controllerName: 'c',
    tags: [],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  proj.tags.add(
    PlcTag(name: 'Motor_Run', path: 'Motor_Run', dataType: 'BOOL', value: false, ioType: 'Internal'),
  );
  proj.hmis.add(HmiScreenDef(
    id: 'hmi_test',
    title: 'Test HMI',
    components: [
      HmiComponent(
        id: 'comp1',
        title: 'Motor Indicator',
        type: 'LedIndicatorLight',
        tagBinding: 'Motor_Run',
        gridSpanWidth: 1,
        accentColor: 'green',
      ),
    ],
  ));
  return proj;
}

Widget _hmiHarness(PlcProject project, LiveTick tick) {
  return LiveTickScope(
    notifier: tick,
    child: MaterialApp(
      home: HmiDashboardBuilderScreen(
        currentProject: project,
        hmiScreen: project.hmis.first,
        onScanTriggered: () {},
        onProjectUpdated: () {},
      ),
    ),
  );
}

void main() {
  group('HMI dashboard live value', () {
    testWidgets(
        'a bare LiveTick.pulse() (no ancestor rebuild) repaints an LED '
        'indicator bound to a BOOL tag', (tester) async {
      await setSurface(tester, desktopSize);
      final tick = LiveTick();
      addTearDown(tick.dispose);
      final project = _buildHmiProject();
      final tag = project.tags.first;

      await tester.pumpWidget(_hmiHarness(project, tick));
      await tester.pumpAndSettle();

      expect(find.text('INACTIVE / OFF'), findsOneWidget);
      expect(find.text('ACTIVE / ON'), findsNothing);

      // Mutate the tag value directly -- the way the scan loop updates
      // values -- without going through setState on any ancestor.
      tag.value = true;

      // Without a pulse the stale value must still be showing.
      await tester.pump();
      expect(find.text('INACTIVE / OFF'), findsOneWidget);
      expect(find.text('ACTIVE / ON'), findsNothing);

      // A bare pulse (no ancestor setState anywhere in this harness) must
      // repaint the LED indicator with the new value.
      tick.pulse();
      await tester.pump();

      expect(find.text('ACTIVE / ON'), findsOneWidget);
      expect(find.text('INACTIVE / OFF'), findsNothing);
    });
  });

  group('Toolbar scan counter live value', () {
    setUp(() {
      // WorkspaceShell() boots via the real (non-injected) SharedPreferences
      // .getInstance() path. Mock initial values so that call actually
      // resolves inside the test's zone (see shell_responsive_test.dart for
      // the same pattern).
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets(
        'a bare LiveTick.pulse() (no ancestor rebuild) repaints the '
        'toolbar Scan Count', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      final project = state.debugActiveProject;

      expect(find.text('Scan Count: 0'), findsOneWidget);

      // Mutate the System tag directly -- the way `updateSystemStatus`
      // (called from the scan loop) does -- without going through the
      // shell's setState.
      writePath(project, 'System.ScanCount', 777);

      // Without a pulse the stale value must still be showing.
      await tester.pump();
      expect(find.text('Scan Count: 0'), findsOneWidget);
      expect(find.text('Scan Count: 777'), findsNothing);

      // A bare pulse (no ancestor setState) must repaint the toolbar
      // counter with the new value.
      state.debugLiveTick.pulse();
      await tester.pump();

      expect(find.text('Scan Count: 777'), findsOneWidget);
    });
  });
}
