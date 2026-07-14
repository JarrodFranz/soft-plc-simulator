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
}
