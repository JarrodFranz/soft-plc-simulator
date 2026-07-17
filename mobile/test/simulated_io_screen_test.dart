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

      testWidgets('$sizeLabel: selecting Measurement Noise shows source + amplitude fields and edits update the rule',
          (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        // Switch behaviour to Measurement Noise.
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Measurement Noise').last);
        await tester.pumpAndSettle();

        expect(find.text('Clean source tag'), findsOneWidget);
        expect(find.text('Noise amplitude (±)'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, 'Min'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, 'Max'), findsOneWidget);

        // Edit the clean source tag.
        final sourceField = find.widgetWithText(TextField, 'Clean source tag');
        expect(sourceField, findsOneWidget);
        await tester.enterText(sourceField, 'Temp_PV');
        await tester.pump();

        // Edit the noise amplitude.
        await tester.enterText(find.widgetWithText(TextFormField, 'Noise amplitude (±)'), '2.5');
        await tester.pump();

        // Save.
        await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
        await tester.pumpAndSettle();

        final saved = project.simRules.firstWhere((r) => r.id == 'sim0');
        expect(saved.behavior, 'noise');
        expect(saved.sourcePath, 'Temp_PV');
        expect(saved.targetValue, 2.5);

        expect(tester.takeException(), isNull);
      });

      testWidgets(
          '$sizeLabel: Measurement Noise shows distribution + drift amplitude, drift period only when amplitude > 0',
          (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        // Switch behaviour to Measurement Noise.
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Measurement Noise').last);
        await tester.pumpAndSettle();

        expect(find.text('Distribution'), findsOneWidget);
        expect(find.text('Drift amplitude'), findsOneWidget);
        // No drift configured by default -> period field hidden.
        expect(find.text('Drift period (s)'), findsNothing);

        // Select Gaussian distribution.
        final distributionDropdown = find.ancestor(
          of: find.text('Distribution'),
          matching: find.byType(DropdownButtonFormField<String>),
        );
        await tester.ensureVisible(distributionDropdown);
        await tester.tap(distributionDropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Gaussian').last);
        await tester.pumpAndSettle();

        // Set a non-zero drift amplitude -> period field should appear.
        await tester.enterText(find.widgetWithText(TextFormField, 'Drift amplitude'), '1.5');
        await tester.pump();

        expect(find.text('Drift period (s)'), findsOneWidget);

        await tester.enterText(find.widgetWithText(TextFormField, 'Drift period (s)'), '30');
        await tester.pump();

        // Save.
        await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
        await tester.pumpAndSettle();

        final saved = project.simRules.firstWhere((r) => r.id == 'sim0');
        expect(saved.behavior, 'noise');
        expect(saved.noiseDistribution, 'gaussian');
        expect(saved.driftAmplitude, 1.5);
        expect(saved.driftPeriodSec, 30.0);

        expect(tester.takeException(), isNull);
      });

      testWidgets(
          '$sizeLabel: Measurement Noise distribution dropdown offers Pink (1/f) and selecting it updates the rule',
          (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        // Switch behaviour to Measurement Noise.
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Measurement Noise').last);
        await tester.pumpAndSettle();

        final distributionDropdown = find.ancestor(
          of: find.text('Distribution'),
          matching: find.byType(DropdownButtonFormField<String>),
        );
        await tester.ensureVisible(distributionDropdown);
        await tester.tap(distributionDropdown);
        await tester.pumpAndSettle();

        expect(find.text('Pink (1/f)'), findsOneWidget);

        await tester.tap(find.text('Pink (1/f)').last);
        await tester.pumpAndSettle();

        // Save.
        await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
        await tester.pumpAndSettle();

        final saved = project.simRules.firstWhere((r) => r.id == 'sim0');
        expect(saved.behavior, 'noise');
        expect(saved.noiseDistribution, 'pink');

        expect(tester.takeException(), isNull);
      });

      testWidgets(
          '$sizeLabel: a rule already set to pink displays as Pink (1/f), not Uniform (initialValue coercion guard)',
          (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        final rule = project.simRules.firstWhere((r) => r.id == 'sim0');
        // Pre-set the rule directly (as if loaded from a saved project) so the
        // dropdown's initialValue must reflect it on open, without the test
        // touching the behaviour or distribution dropdowns itself.
        rule.behavior = 'noise';
        rule.noiseDistribution = 'pink';
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        // Before the initialValue fix, anything-not-Gaussian was coerced to
        // Uniform, so a rule already saved as 'pink' would incorrectly show
        // "Uniform" here instead of "Pink (1/f)".
        expect(find.text('Pink (1/f)'), findsOneWidget);
        expect(find.text('Uniform'), findsNothing);

        expect(tester.takeException(), isNull);
      });

      testWidgets('$sizeLabel: non-noise behaviour does not show distribution/drift controls', (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        // Switch behaviour to Set While Condition (non-noise).
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Set While Condition').last);
        await tester.pumpAndSettle();

        expect(find.text('Distribution'), findsNothing);
        expect(find.text('Drift amplitude'), findsNothing);
        expect(find.text('Drift period (s)'), findsNothing);

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

    testWidgets('320x568: Measurement Noise rule editor opens without overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      final project = _projectById('proj_st_reactor');
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openFirstRuleEditor(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Measurement Noise').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('360x740: Measurement Noise rule editor opens without overflow', (tester) async {
      await setSurface(tester, phoneSize);
      final project = _projectById('proj_st_reactor');
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openFirstRuleEditor(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Measurement Noise').last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    for (final size in [smallPhoneSize, desktopSize]) {
      final sizeLabel = size == smallPhoneSize ? '320x568' : '1400x900';

      testWidgets('$sizeLabel: Measurement Noise distribution + drift controls open without overflow',
          (tester) async {
        await setSurface(tester, size);
        final project = _projectById('proj_st_reactor');
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openFirstRuleEditor(tester);

        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Measurement Noise').last);
        await tester.pumpAndSettle();

        // Set a non-zero drift amplitude so the drift period field is also
        // present, to exercise the widest control set at this size.
        await tester.enterText(find.widgetWithText(TextFormField, 'Drift amplitude'), '1.5');
        await tester.pump();

        expect(find.text('Drift period (s)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
