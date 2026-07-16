import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/interaction_analysis_screen.dart';

PlcProject _mimo() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_mimo_two_zone');

Widget _host(PlcProject p) => MaterialApp(
      home: InteractionAnalysisScreen(
        currentProject: p,
        onProjectUpdated: () {},
      ),
    );

/// Reads the current text of the [TextField] whose `key` is [key].
String _fieldText(WidgetTester tester, String key) {
  final tf = tester.widget<TextField>(find.byKey(Key(key)));
  return tf.controller!.text;
}

void main() {
  testWidgets('renders and prefills MV/PV fields from the MIMO project',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(_mimo()));
    await tester.pumpAndSettle();

    expect(find.byType(InteractionAnalysisScreen), findsOneWidget);
    expect(_fieldText(tester, 'interaction-mv1-field'), 'Heater_A');
    expect(_fieldText(tester, 'interaction-mv2-field'), 'Heater_B');
    expect(_fieldText(tester, 'interaction-pv1-field'), 'Temp_A');
    expect(_fieldText(tester, 'interaction-pv2-field'), 'Temp_B');

    expect(tester.takeException(), isNull);
  });

  testWidgets('Run renders gain matrix, RGA and pairing readouts',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(_mimo()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('interaction-run-button')));
    await tester.pumpAndSettle();

    // Gain matrix readout: a label plus the four K entries.
    expect(find.textContaining('Gain'), findsWidgets);
    expect(find.textContaining('K11'), findsWidgets);
    expect(find.textContaining('K22'), findsWidgets);

    // RGA readout with the lambda symbol.
    expect(find.textContaining('λ'), findsWidgets);

    // Pairing recommendation text (engine emits a "Diagonal"/"Off-diagonal"
    // banded recommendation).
    expect(
      find.textContaining(RegExp('Diagonal|Off-diagonal|decoupling',
          caseSensitive: false)),
      findsWidgets,
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 320x568 (narrow phone) before and after Run',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(_mimo()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('interaction-run-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1400x900 (wide desktop) after Run',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_host(_mimo()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('interaction-run-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
