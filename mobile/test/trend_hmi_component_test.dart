import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/hmi_dashboard_builder_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'package:soft_plc_mobile/widgets/trend_chart.dart';

void main() {
  testWidgets('a TrendChartDisplay component renders a TrendChartView', (tester) async {
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'A', color: 'green'));
    final historian = TagHistorian()..syncPens(proj.trends);
    final hmi = HmiScreenDef(id: 'h1', title: 'Screen', components: [
      HmiComponent(id: 'c1', title: 'Trend', type: kTrendChartDisplay, tagBinding: '',
          trendPens: [TrendPenRef(penTagPath: 'A')], windowMs: 60000),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: HmiDashboardBuilderScreen(
          currentProject: proj,
          hmiScreen: hmi,
          onScanTriggered: () {},
          onProjectUpdated: () {},
          historian: historian,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TrendChartView), findsOneWidget);
  });

  testWidgets('a TrendChartDisplay component does not overflow at 320/360/1400', (tester) async {
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'A', color: 'green'));
    final historian = TagHistorian()..syncPens(proj.trends);
    final hmi = HmiScreenDef(id: 'h1', title: 'Screen', components: [
      HmiComponent(id: 'c1', title: 'Trend', type: kTrendChartDisplay, tagBinding: '',
          trendPens: [TrendPenRef(penTagPath: 'A')], windowMs: 60000, gridSpanWidth: 4),
    ]);

    Widget app() => MaterialApp(
          home: LiveTickScope(
            notifier: LiveTick(),
            child: HmiDashboardBuilderScreen(
              currentProject: proj,
              hmiScreen: hmi,
              onScanTriggered: () {},
              onProjectUpdated: () {},
              historian: historian,
            ),
          ),
        );

    for (final width in [320.0, 360.0, 1400.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });
}
