import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/simulated_io_screen.dart';
import 'support/responsive_test_utils.dart';

PlcProject _projectById(String id) => DefaultProjects.all().firstWhere((p) => p.id == id);

void main() {
  group('SimulatedIoScreen rule editor', () {
    Widget app(PlcProject project) {
      return MaterialApp(
        home: SimulatedIoScreen(
          currentProject: project,
          onProjectUpdated: () {},
        ),
      );
    }

    Future<void> openFirstRuleEditor(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.edit).first);
      await tester.pumpAndSettle();
    }

    for (final size in [phoneSize, desktopSize]) {
      final sizeLabel = size == phoneSize ? 'phone' : 'desktop';

      testWidgets('$sizeLabel: selecting First-Order Lag shows tau + target fields and edits update the rule',
          (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        // Switch behaviour to First-Order Lag.
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('First-Order Lag (process response)').last);
        await tester.pumpAndSettle();

        expect(find.text('Time constant τ (seconds)'), findsOneWidget);
        expect(find.text('Target value'), findsOneWidget);
        expect(find.text('Target from tag (optional)'), findsOneWidget);

        // Edit tau.
        await tester.enterText(find.widgetWithText(TextFormField, 'Time constant τ (seconds)'), '8.5');
        await tester.pump();

        // Edit target value.
        await tester.enterText(find.widgetWithText(TextFormField, 'Target value'), '42');
        await tester.pump();

        // Save.
        await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
        await tester.pumpAndSettle();

        final saved = project.simRules.firstWhere((r) => r.id == 'sim0');
        expect(saved.behavior, 'firstOrderLag');
        expect(saved.tauSec, 8.5);
        expect(saved.targetValue, 42.0);

        expect(tester.takeException(), isNull);
      });

      testWidgets('$sizeLabel: selecting integrate shows rate-source-tag + refValue fields and edits update the rule',
          (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        // Rule sim0 already defaults to 'integrate' behaviour, so the fields
        // should already be visible without changing the dropdown.
        expect(find.text('Rate driven by tag (optional)'), findsOneWidget);
        expect(find.textContaining('Rate source tag'), findsOneWidget);
        expect(find.text('= 100% rate at'), findsOneWidget);

        await tester.enterText(find.widgetWithText(TextFormField, '= 100% rate at'), '75');
        await tester.pump();

        final tagField = find.widgetWithText(TextField, 'Rate source tag (blank = fixed rate)');
        expect(tagField, findsOneWidget);
        await tester.enterText(tagField, 'Temp_SP');
        await tester.pump();

        await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
        await tester.pumpAndSettle();

        final saved = project.simRules.firstWhere((r) => r.id == 'sim0');
        expect(saved.behavior, 'integrate');
        expect(saved.refValue, 75.0);
        expect(saved.sourcePath, 'Temp_SP');

        expect(tester.takeException(), isNull);
      });

      testWidgets('$sizeLabel: selecting Transport Dead-Time shows source + tau fields and edits update the rule',
          (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        // Switch behaviour to Transport Dead-Time.
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Transport Dead-Time').last);
        await tester.pumpAndSettle();

        expect(find.text('Delayed source tag'), findsOneWidget);
        expect(find.text('Dead time τ (seconds)'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, 'Min'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, 'Max'), findsOneWidget);

        // Edit the delayed source tag.
        final sourceField = find.widgetWithText(TextField, 'Delayed source tag');
        expect(sourceField, findsOneWidget);
        await tester.enterText(sourceField, 'Temp_PV');
        await tester.pump();

        // Edit tau.
        await tester.enterText(find.widgetWithText(TextFormField, 'Dead time τ (seconds)'), '3.0');
        await tester.pump();

        // Save.
        await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
        await tester.pumpAndSettle();

        final saved = project.simRules.firstWhere((r) => r.id == 'sim0');
        expect(saved.behavior, 'deadTime');
        expect(saved.sourcePath, 'Temp_PV');
        expect(saved.tauSec, 3.0);

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('320x568: rule editor opens without overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      final project = _projectById('proj_st_reactor');
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openFirstRuleEditor(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('First-Order Lag (process response)').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('360x740: rule editor opens without overflow', (tester) async {
      await setSurface(tester, phoneSize);
      final project = _projectById('proj_st_reactor');
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openFirstRuleEditor(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('First-Order Lag (process response)').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('320x568: Transport Dead-Time rule editor opens without overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      final project = _projectById('proj_st_reactor');
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openFirstRuleEditor(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transport Dead-Time').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('360x740: Transport Dead-Time rule editor opens without overflow', (tester) async {
      await setSurface(tester, phoneSize);
      final project = _projectById('proj_st_reactor');
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openFirstRuleEditor(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transport Dead-Time').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
