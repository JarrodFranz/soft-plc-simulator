import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/main.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';

// The app is a desktop/tablet-width tool; pump at a realistic surface so the
// smoke tests exercise the intended layout rather than an 800x600 phone frame.
void _useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    _useDesktopSurface(tester);
    await tester.pumpWidget(const SoftPlcApp());
    expect(find.byType(SoftPlcApp), findsOneWidget);
  });

  testWidgets('LD editor renders the conveyor program (incl. TON rung) without overflow',
      (WidgetTester tester) async {
    _useDesktopSurface(tester);

    final project =
        DefaultProjects.all().firstWhere((p) => p.id == 'proj_ld_conveyor');
    final program =
        project.programs.firstWhere((pr) => pr.language == 'LadderLogic');

    await tester.pumpWidget(MaterialApp(
      home: LdEditorScreen(
        currentProject: project,
        program: program,
        onProgramUpdated: () {},
        monitor: LdMonitor(),
        scanRunning: false,
      ),
    ));
    await tester.pump();

    // A RenderFlex overflow (the original TON-block bug) surfaces as a caught
    // exception during layout; assert the editor lays out cleanly.
    expect(tester.takeException(), isNull);
    expect(find.byType(LdEditorScreen), findsOneWidget);
  });
}
