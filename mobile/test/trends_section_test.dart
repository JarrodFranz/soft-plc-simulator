import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'package:soft_plc_mobile/widgets/trend_chart.dart';

void main() {
  testWidgets('Trends tab lists pens and renders a preview chart', (tester) async {
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'A', color: 'green'));
    final historian = TagHistorian()..syncPens(proj.trends);

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: MemoryManagerScreen(
          currentProject: proj,
          onProjectUpdated: () {},
          historian: historian,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Switch to the Trends tab.
    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();

    expect(find.text('A'), findsWidgets); // pen row shows the tag path
    expect(find.byType(TrendChartView), findsOneWidget);
  });

  testWidgets('Trends tab has no overflow at narrow and wide widths', (tester) async {
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'A', color: 'green'));
    final historian = TagHistorian()..syncPens(proj.trends);

    Future<void> pumpAt(double width) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(
        home: LiveTickScope(
          notifier: LiveTick(),
          child: MemoryManagerScreen(
            currentProject: proj,
            onProjectUpdated: () {},
            historian: historian,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trends'));
      await tester.pumpAndSettle();
    }

    await pumpAt(320);
    expect(tester.takeException(), isNull);

    await pumpAt(1400);
    expect(tester.takeException(), isNull);
  });
}
