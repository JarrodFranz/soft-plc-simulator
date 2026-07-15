import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';
import 'package:soft_plc_mobile/screens/hmi_dashboard_builder_screen.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'support/responsive_test_utils.dart';

PlcProject _projectById(String id) => DefaultProjects.all().firstWhere((p) => p.id == id);

void main() {
  group('FbdEditorScreen responsive', () {
    Widget app() {
      final project = _projectById('proj_fbd_hvac');
      final program = project.programs.firstWhere((p) => p.language == 'FunctionBlockDiagram');
      return MaterialApp(
        home: FbdEditorScreen(
          currentProject: project,
          program: program,
          onProgramUpdated: () {},
        ),
      );
    }

    testWidgets('desktop: inline palette visible with search field', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('FBD FUNCTION BLOCK PALETTE'), findsOneWidget);
      expect(find.byType(TextField), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: inline palette hidden, add affordance present', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('FBD FUNCTION BLOCK PALETTE'), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: canvas wrapped in InteractiveViewer for pan/zoom', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop: canvas is pannable (wrapped in InteractiveViewer)', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // The workspace pans/zooms on desktop too, not only on phone.
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: tapping palette FAB opens bottom sheet with palette', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('FBD FUNCTION BLOCK PALETTE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('SfcEditorScreen responsive', () {
    Widget app() {
      final project = _projectById('proj_sfc_filling');
      final program = project.programs.firstWhere((p) => p.language == 'SequentialFunctionChart');
      return MaterialApp(
        home: SfcEditorScreen(
          currentProject: project,
          program: program,
          onProgramUpdated: () {},
          sfcRuntime: SfcRuntime(),
          scanRunning: false,
        ),
      );
    }

    testWidgets('desktop: inline palette visible', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('SFC TAG & CONDITION AUTOCOMPLETE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: inline palette hidden, add affordance present', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('SFC TAG & CONDITION AUTOCOMPLETE'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is FloatingActionButton || (w is IconButton && w.tooltip != null && w.tooltip!.toLowerCase().contains('tag'))),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: step card width fits within screen', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('HmiDashboardBuilderScreen responsive', () {
    Widget app() {
      final project = _projectById('proj_fbd_hvac');
      final hmi = project.hmis.first;
      return LiveTickScope(
        notifier: LiveTick(),
        child: MaterialApp(
          home: HmiDashboardBuilderScreen(
            currentProject: project,
            hmiScreen: hmi,
            onScanTriggered: () {},
            onProjectUpdated: () {},
            historian: TagHistorian(),
          ),
        ),
      );
    }

    Future<void> enterEditMode(WidgetTester tester) async {
      await tester.tap(find.text('EDIT BUILDER'));
      await tester.pumpAndSettle();
    }

    testWidgets('desktop: edit mode shows inline component palette', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await enterEditMode(tester);

      expect(find.text('COMPONENT PALETTE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: edit mode hides inline palette, add affordance present', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await enterEditMode(tester);

      expect(find.text('COMPONENT PALETTE'), findsNothing);
      expect(find.byTooltip('Add HMI Component via Dialog'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: RUN mode renders without overflow', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Default is RUN mode.
      expect(find.text('RUN MODE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): RUN mode no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): EDIT BUILDER mode no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await enterEditMode(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): Configure Component dialog has no overflow', (tester) async {
      // Regression: the component config dialog's dropdowns (long labels like
      // "Process Vessel Graphic ...") overflowed their row without isExpanded.
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await enterEditMode(tester);

      await tester.tap(find.byTooltip('Add HMI Component via Dialog'));
      await tester.pumpAndSettle();

      // Dialog is open (its type dropdown label is shown) and nothing overflows.
      expect(find.text('Component Type'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('LdEditorScreen responsive', () {
    Widget app() {
      final project = _projectById('proj_ld_conveyor');
      final program = project.programs.firstWhere((p) => p.language == 'LadderLogic');
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

    testWidgets('desktop: toolbar and canvas render fine', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Select'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: toolbar does not overflow (Wrap/scroll)', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Select'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
