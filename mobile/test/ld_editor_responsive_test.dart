import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'support/responsive_test_utils.dart';

PlcProject _projectById(String id) => DefaultProjects.all().firstWhere((p) => p.id == id);

void main() {
  group('LdEditorScreen local-width responsiveness', () {
    Widget app() {
      final project = _projectById('proj_ld_conveyor');
      final program = project.programs.firstWhere((p) => p.language == 'LadderLogic');
      return MaterialApp(
        home: LdEditorScreen(
          currentProject: project,
          program: program,
          onProgramUpdated: () {},
        ),
      );
    }

    testWidgets(
        'narrow pane (257) inside a DESKTOP-sized window: toolbar does not overflow '
        '(reproduces bug where window-width isExpanded was used instead of local pane width)',
        (tester) async {
      // Window itself is desktop-sized, so context.isExpanded would be true —
      // but the editor is embedded in a narrow 257px pane (both docks open).
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 257,
                height: 640,
                child: Builder(builder: (context) => app()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('phone size (360): InteractiveViewer present for pan/zoom, no overflow', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop full width (1400): no overflow, toolbar Row path used (desktop unchanged)', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Select'), findsOneWidget);
      // Desktop (wide local pane) must not force the compact InteractiveViewer.
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
