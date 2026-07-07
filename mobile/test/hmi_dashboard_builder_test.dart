import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/hmi_dashboard_builder_screen.dart';
import 'support/responsive_test_utils.dart';

PlcProject _projectById(String id) => DefaultProjects.all().firstWhere((p) => p.id == id);

void main() {
  group('HmiDashboardBuilderScreen wide-card header controls', () {
    // A 2-column-span component (e.g. the Status Value Pill) renders via the
    // "wide card" (>=360px) header Row, which must only show the resize/gear/
    // delete controls in EDIT mode — RUN mode is meant to be chrome-free.
    Widget app(HmiScreenDef hmi, PlcProject project) {
      return MaterialApp(
        home: HmiDashboardBuilderScreen(
          currentProject: project,
          hmiScreen: hmi,
          onScanTriggered: () {},
          onProjectUpdated: () {},
        ),
      );
    }

    late PlcProject project;
    late HmiScreenDef hmi;

    setUp(() {
      project = _projectById('proj_fbd_hvac');
      hmi = project.hmis.first;
      hmi.components
        ..clear()
        ..add(HmiComponent(
          id: 'comp_wide',
          title: 'Status Pill',
          type: 'StatusPillDisplay',
          tagBinding: '',
          gridSpanWidth: 2,
          accentColor: 'amber',
        ));
    });

    testWidgets('RUN mode: no resize/gear/delete controls on a wide (2-col) card', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app(hmi, project));
      await tester.pumpAndSettle();

      // Default is RUN mode.
      expect(find.text('RUN MODE'), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsNothing);
      expect(find.byIcon(Icons.delete), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('EDIT mode: resize/gear/delete controls present on a wide (2-col) card', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app(hmi, project));
      await tester.pumpAndSettle();

      await tester.tap(find.text('EDIT BUILDER'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.settings), findsOneWidget);
      expect(find.byIcon(Icons.delete), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
