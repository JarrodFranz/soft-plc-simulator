import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';

void main() {
  test('TrendPen round-trips all fields', () {
    final pen = TrendPen(
      tagPath: 'Ramp1/Ramp_00',
      color: 'green',
      sampleIntervalMs: 500,
      retentionMode: 'points',
      maxPoints: 600,
      windowMs: 120000,
    );
    final back = TrendPen.fromJson(pen.toJson());
    expect(back.tagPath, 'Ramp1/Ramp_00');
    expect(back.color, 'green');
    expect(back.sampleIntervalMs, 500);
    expect(back.retentionMode, 'points');
    expect(back.maxPoints, 600);
    expect(back.windowMs, 120000);
    expect(back, isA<TrendPenLike>());
  });

  test('TrendPen defaults when keys absent', () {
    final back = TrendPen.fromJson({'tag_path': 'X'});
    expect(back.color, 'cyan');
    expect(back.sampleIntervalMs, 250);
    expect(back.retentionMode, 'time');
    expect(back.maxPoints, 1200);
    expect(back.windowMs, 300000);
  });

  test('TrendPenRef round-trips, override may be null', () {
    final r = TrendPenRef(penTagPath: 'A', colorOverride: 'red');
    final back = TrendPenRef.fromJson(r.toJson());
    expect(back.penTagPath, 'A');
    expect(back.colorOverride, 'red');
    final noOverride = TrendPenRef.fromJson({'pen_tag_path': 'B'});
    expect(noOverride.colorOverride, isNull);
  });

  test('PlcProject.trends round-trips; absent key -> empty', () {
    final p = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    p.trends.add(TrendPen(tagPath: 'A'));
    final back = PlcProject.fromJson(p.toJson());
    expect(back.trends.length, 1);
    expect(back.trends.first.tagPath, 'A');
    // Legacy project JSON with no `trends` key.
    final legacy = PlcProject.fromJson({'name': 'Old'});
    expect(legacy.trends, isEmpty);
  });

  test('HmiComponent trendPens + windowMs round-trip; legacy loads clean', () {
    final c = HmiComponent(
      id: 'c1', title: 'Trend', type: kTrendChartDisplay, tagBinding: '',
    );
    c.trendPens.add(TrendPenRef(penTagPath: 'A', colorOverride: 'amber'));
    c.windowMs = 60000;
    final back = HmiComponent.fromJson(c.toJson());
    expect(back.type, 'TrendChartDisplay');
    expect(back.trendPens.length, 1);
    expect(back.trendPens.first.penTagPath, 'A');
    expect(back.trendPens.first.colorOverride, 'amber');
    expect(back.windowMs, 60000);
    // Legacy component with no trend fields.
    final legacy = HmiComponent.fromJson({
      'id': 'c2', 'title': 'LED', 'type': 'LedIndicatorLight', 'tag_binding': 'X',
    });
    expect(legacy.trendPens, isEmpty);
    expect(legacy.windowMs, isNull);
  });
}
