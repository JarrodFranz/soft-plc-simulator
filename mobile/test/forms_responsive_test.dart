import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/st_editor_screen.dart';
import 'package:soft_plc_mobile/screens/project_manager_screen.dart';
import 'package:soft_plc_mobile/screens/simulated_io_screen.dart';
import 'package:soft_plc_mobile/widgets/tag_inspector_dock.dart';
import 'support/responsive_test_utils.dart';

PlcProject _project() => DefaultProjects.all().first;

void main() {
  group('StEditorScreen', () {
    Widget app(PlcProject project) => MaterialApp(
          home: StEditorScreen(
            currentProject: project,
            onSaveProgram: (_) {},
          ),
        );

    testWidgets('phone: no overflow', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop: no overflow', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('ProjectManagerScreen', () {
    Widget app(PlcProject project) => MaterialApp(
          home: ProjectManagerScreen(
            currentProject: project,
            onLoadProject: (_) {},
          ),
        );

    testWidgets('phone: no overflow', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop: no overflow', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('SimulatedIoScreen', () {
    Widget app(PlcProject project) => MaterialApp(
          home: SimulatedIoScreen(
            currentProject: project,
            onProjectUpdated: () {},
          ),
        );

    testWidgets('phone: no overflow', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop: no overflow', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: rule dialog opens without overflow and clamps width',
        (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Rule'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);

      final dialogSize = tester.getSize(find.byType(AlertDialog));
      expect(dialogSize.width, lessThanOrEqualTo(phoneSize.width));
    });
  });

  group('TagInspectorDock', () {
    Widget app(PlcProject project, Size size) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width,
              child: TagInspectorDock(
                tags: project.tags,
                onTagStateChanged: () {},
                onClose: () {},
              ),
            ),
          ),
        );

    testWidgets('phone: no overflow', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app(_project(), phoneSize));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop: no overflow', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app(_project(), desktopSize));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
