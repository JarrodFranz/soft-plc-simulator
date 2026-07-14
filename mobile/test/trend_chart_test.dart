import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'package:soft_plc_mobile/widgets/trend_chart.dart';

void main() {
  test('trendColorFromName maps the vocabulary and falls back to cyan', () {
    expect(trendColorFromName('green'), isA<Color>());
    expect(trendColorFromName('nonsense'), trendColorFromName('cyan'));
  });

  testWidgets('painter renders analog + digital pens without throwing', (tester) async {
    const pens = [
      TrendPenView(tagPath: 'A', color: Colors.cyan, label: 'A', isDigital: false),
      TrendPenView(tagPath: 'B', color: Colors.green, label: 'B', isDigital: false),
      TrendPenView(tagPath: 'D', color: Colors.amber, label: 'D', isDigital: true),
    ];
    final buffers = <String, List<TrendSample>>{
      'A': [const TrendSample(0, 0), const TrendSample(500, 50), const TrendSample(1000, 100)],
      'B': [const TrendSample(0, 5), const TrendSample(1000, 5)], // flat series
      'D': [const TrendSample(0, 0), const TrendSample(400, 1), const TrendSample(800, 0)],
    };
    List<TrendSample> bufferOf(String p) => buffers[p] ?? const [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomPaint(
          size: const Size(400, 200),
          painter: TrendChartPainter(
            pens: pens,
            bufferOf: bufferOf,
            windowMs: 1000,
            nowMs: 1000,
            axisColor: Colors.white,
            gridColor: Colors.grey,
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty buffers paint without dividing by zero', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomPaint(
          size: const Size(300, 150),
          painter: TrendChartPainter(
            pens: const [TrendPenView(tagPath: 'A', color: Colors.cyan, label: 'A', isDigital: false)],
            bufferOf: (_) => const [],
            windowMs: 5000,
            nowMs: 5000,
            axisColor: Colors.white,
            gridColor: Colors.grey,
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  group('trace-cursor pure helpers', () {
    test('TrendChartGeometry maps time<->x and clamps', () {
      const geo = TrendChartGeometry(width: 200, nowMs: 10000, windowMs: 1000);
      // right edge = now, left edge = now-window
      expect(geo.xOfTime(10000), closeTo(geo.plotRight, 0.001));
      expect(geo.xOfTime(9000), closeTo(geo.plotLeft, 0.001));
      // timeAtX inverts xOfTime
      expect(geo.timeAtX(geo.xOfTime(9500)), closeTo(9500, 2));
      // clamp beyond the plot bounds
      expect(geo.timeAtX(-100), 9000);
      expect(geo.timeAtX(99999), 10000);
    });

    test('nearestSample picks closest by |dt|, null on empty', () {
      final buf = [const TrendSample(0, 1), const TrendSample(100, 2), const TrendSample(300, 3)];
      expect(nearestSample(buf, 110)!.v, 2);
      expect(nearestSample(buf, 260)!.v, 3);
      expect(nearestSample(const [], 50), isNull);
    });

    test('relativeAgo formats now / seconds / minutes', () {
      expect(relativeAgo(10000, 10000), 'now');
      expect(relativeAgo(9550, 10000), 'now'); // <1s rounds toward 0 -> treated as now
      expect(relativeAgo(9000, 10000), '-1s');
      expect(relativeAgo(-62000 + 10000 + 62000, 10000), 'now'); // sanity guard, no throw
      expect(relativeAgo(10000 - 72000, 10000), '-1m 12s');
    });

    test('clockHms formats a fixed epoch ms to HH:mm:ss', () {
      final dt = DateTime(2026, 1, 2, 14, 32, 5);
      expect(clockHms(dt.millisecondsSinceEpoch), '14:32:05');
    });

    test('formatPenValue: null dash, digital ON/OFF, analog 2dp', () {
      const analog = TrendPenView(tagPath: 'A', color: Color(0xFF00FFFF), label: 'A', isDigital: false);
      const digital = TrendPenView(tagPath: 'D', color: Color(0xFF00FFFF), label: 'D', isDigital: true);
      expect(formatPenValue(analog, null), '—');
      expect(formatPenValue(digital, const TrendSample(0, 0.6)), 'ON');
      expect(formatPenValue(digital, const TrendSample(0, 0.2)), 'OFF');
      expect(formatPenValue(analog, const TrendSample(0, 3.14159)), '3.14');
    });
  });

  testWidgets('trace cursor: tap shows readout, drag moves, ✕ clears', (tester) async {
    final historian = TagHistorian();
    // One analog pen 'A' with a rising ramp over the last ~1s, and a digital 'D'.
    final pen = TrendPen(tagPath: 'A', color: 'cyan', sampleIntervalMs: 0, retentionMode: 'time', windowMs: 60000);
    final penD = TrendPen(tagPath: 'D', color: 'green', sampleIntervalMs: 0, retentionMode: 'time', windowMs: 60000);
    historian.syncPens([pen, penD]);
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
        PlcTag(name: 'D', path: 'D', dataType: 'BOOL', value: false, ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    final pens = [
      TrendChartView.viewForPen(proj, pen),
      TrendChartView.viewForPen(proj, penD),
    ];
    // Seed buffers by directly sampling at known-ish times relative to now.
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < 5; i++) {
      historian.sample([pen, penD], (path) => path == 'A' ? (i * 10).toDouble() : (i.isEven ? 1.0 : 0.0), now - (4 - i) * 100);
    }

    final live = LiveTick();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiveTickScope(
          notifier: live,
          child: TrendChartView(project: proj, historian: historian, pens: pens, windowMs: 60000, height: 220),
        ),
      ),
    ));
    await tester.pump();

    // No readout before interaction.
    expect(find.byIcon(Icons.close), findsNothing);

    // Tap in the middle of the chart → readout appears (has a ✕ and a pen row).
    // MaterialApp's debug-mode banner is also a CustomPaint spanning the full
    // surface and sorts first in the widget tree, so target our painter
    // specifically rather than relying on `find.byType(CustomPaint).first`.
    final chartPaintFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TrendChartPainter);
    await tester.tapAt(tester.getCenter(chartPaintFinder));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.textContaining('A:'), findsOneWidget);

    // Clearing via ✕ removes the readout.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('trace cursor readout has no overflow at 320/360/1400', (tester) async {
    final historian = TagHistorian();
    final pen = TrendPen(tagPath: 'A', color: 'cyan', sampleIntervalMs: 0, windowMs: 60000);
    historian.syncPens([pen]);
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal')],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    historian.sample([pen], (_) => 1.0, now - 100);
    for (final w in [320.0, 360.0, 1400.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: w,
            child: LiveTickScope(
              notifier: LiveTick(),
              child: TrendChartView(project: proj, historian: historian, pens: [TrendChartView.viewForPen(proj, pen)], windowMs: 60000),
            ),
          ),
        ),
      ));
      final chartPaintFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TrendChartPainter);
      await tester.tapAt(tester.getCenter(chartPaintFinder));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $w');
    }
  });
}
