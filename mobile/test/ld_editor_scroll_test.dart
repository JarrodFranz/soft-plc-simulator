// Regression test for fix/ld-horizontal-scroll: on a NON-compact (desktop)
// pane narrower than the ladder, the whole rung list must scroll
// horizontally as one unit with a visible, mouse-draggable Scrollbar —
// previously each rung had its own no-scrollbar SingleChildScrollView, and
// the mouse wheel drove only the outer vertical ListView, leaving no way to
// reach the right-hand side of a wide rung with a mouse.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'support/responsive_test_utils.dart';

LdNode _contact(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode _coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

PlcProject _buildProject(PlcProgram program) {
  return PlcProject(
    id: 'proj_test_ld_scroll',
    name: 'Test LD Scroll Project',
    controllerName: 'PLC_TEST',
    tags: const [],
    structDefs: const [],
    programs: [program],
    tasks: const [],
    hmis: const [],
  );
}

/// A single wide rung: 8 contacts in series ending in a coil. At kLdColW=116
/// and kLdCellW=66, this rung's minimum content width comes out to roughly
/// 1000px — comfortably wider than a 700px desktop pane (above the 560px
/// compact threshold) but well inside a 1400px one.
PlcProgram _wideRungProgram() {
  return PlcProgram(
    name: 'WideRungProgram',
    language: 'LadderLogic',
    rungs: [
      buildRung(
        index: 0,
        comment: 'Rung 0: wide rung',
        main: [
          _contact('Sensor_1'),
          _contact('Sensor_2'),
          _contact('Sensor_3'),
          _contact('Sensor_4'),
          _contact('Sensor_5'),
          _contact('Sensor_6'),
          _contact('Sensor_7'),
          _coil('Pump_Run'),
        ],
      ),
    ],
  );
}

Widget _app(PlcProgram program) {
  final project = _buildProject(program);
  return MaterialApp(
    home: LdEditorScreen(
      currentProject: project,
      program: program,
      onProgramUpdated: () {},
      monitor: LdMonitor(),
      scanRunning: false,
    ),
  );
}

void main() {
  group('LdEditorScreen unified horizontal scroll (desktop, non-compact)', () {
    testWidgets('narrow-but-non-compact pane (700): visible Scrollbar present and horizontal scroll works',
        (tester) async {
      await setSurface(tester, const Size(700, 800));
      final program = _wideRungProgram();
      await tester.pumpWidget(_app(program));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Non-compact: no InteractiveViewer pan/zoom fallback.
      expect(find.byType(InteractiveViewer), findsNothing);

      final scrollbarFinder = find.byType(Scrollbar);
      expect(scrollbarFinder, findsOneWidget);
      final scrollbar = tester.widget<Scrollbar>(scrollbarFinder);
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.controller, isNotNull);

      final controller = scrollbar.controller!;
      expect(controller.hasClients, isTrue);
      expect(controller.position.maxScrollExtent, greaterThan(0));

      // Drive the scroll and confirm the content actually moves.
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(controller.offset, controller.position.maxScrollExtent);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320px pane: compact InteractiveViewer path still renders without exceptions', (tester) async {
      await setSurface(tester, const Size(320, 700));
      final program = _wideRungProgram();
      await tester.pumpWidget(_app(program));
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('1400px pane: ladder fits, no horizontal Scrollbar forced, no exceptions', (tester) async {
      await setSurface(tester, const Size(1400, 900));
      final program = _wideRungProgram();
      await tester.pumpWidget(_app(program));
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.byType(Scrollbar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
