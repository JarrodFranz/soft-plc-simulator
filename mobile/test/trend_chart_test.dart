import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
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
}
