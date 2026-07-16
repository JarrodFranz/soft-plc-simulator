import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/pid_autotune_screen.dart';
import 'support/responsive_test_utils.dart';

PlcProject _project() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_tank_level_pid');

FbdBlock _kpBlock(PlcProject p) {
  final prog = p.programs.firstWhere((pr) => pr.language == 'FunctionBlockDiagram');
  return prog.fbdBlocks.firstWhere((b) => b.id == 'p_kp');
}

FbdBlock _kdBlock(PlcProject p) {
  final prog = p.programs.firstWhere((pr) => pr.language == 'FunctionBlockDiagram');
  return prog.fbdBlocks.firstWhere((b) => b.id == 'p_kd');
}

Widget _app(PlcProject project) => MaterialApp(
      home: PidAutoTuneScreen(
        currentProject: project,
        onProjectUpdated: () {},
      ),
    );

void main() {
  group('PidAutoTuneScreen', () {
    testWidgets('renders and prefills PV=Level_PV / CV=Valve_CV from the loop',
        (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app(_project()));
      await tester.pumpAndSettle();

      final pv = tester.widget<TextField>(find.byKey(const Key('pidtune-pv-field')));
      final cv = tester.widget<TextField>(find.byKey(const Key('pidtune-cv-field')));
      expect(pv.controller?.text, 'Level_PV');
      expect(cv.controller?.text, 'Valve_CV');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Run Auto-Tune yields Ku/Pu + a suggestions table; Apply writes gains',
        (tester) async {
      await setSurface(tester, desktopSize);
      final project = _project();
      await tester.pumpWidget(_app(project));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Run Auto-Tune'));
      await tester.pumpAndSettle();

      // Converged run: Ku/Pu readout + the Ziegler-Nichols tuning-rule rows.
      expect(find.textContaining('Ku'), findsWidgets);
      expect(find.text('Ziegler-Nichols'), findsWidgets);

      // Applying the first rule row rewrites the p_kp CONST block's binding.
      final before = _kpBlock(project).tagBinding;
      final applyBtn = find.widgetWithText(ElevatedButton, 'Apply').first;
      await tester.ensureVisible(applyBtn);
      await tester.pumpAndSettle();
      await tester.tap(applyBtn);
      await tester.pumpAndSettle();
      expect(_kpBlock(project).tagBinding, isNot(before));

      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Applying a PI-form row writes Kd=0 (true PI, not a stale PID gain)',
        (tester) async {
      await setSurface(tester, desktopSize);
      final project = _project();
      await tester.pumpWidget(_app(project));
      await tester.pumpAndSettle();

      // The demo's Kd CONST block starts wired to a nonzero (PID) gain.
      expect(double.parse(_kdBlock(project).tagBinding), isNot(0.0));

      await tester.tap(find.text('Run Auto-Tune'));
      await tester.pumpAndSettle();

      // tuningRules() emits [ZN PID, ZN PI, Tyreus-Luyben PID, ...]: row index
      // 1 is the Ziegler-Nichols PI row (form == 'PI', kd == 0).
      final applyButtons = find.widgetWithText(ElevatedButton, 'Apply');
      final piApplyBtn = applyButtons.at(1);
      await tester.ensureVisible(piApplyBtn);
      await tester.pumpAndSettle();
      await tester.tap(piApplyBtn);
      await tester.pumpAndSettle();

      // Applying a PI row must write Kd=0 to the resolved Kd source so the
      // loop actually behaves as PI, instead of leaving the old PID Kd wired.
      expect(double.parse(_kdBlock(project).tagBinding), 0.0);

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow / no exception at 320x568', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(_app(_project()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Run Auto-Tune'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Auto-Tune'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow / no exception at 1400x900', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app(_project()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Run Auto-Tune'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Auto-Tune'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
