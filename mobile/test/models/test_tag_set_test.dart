import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/test_tag_set.dart';

void main() {
  test('buildTestSet produces N padded FLOAT64 tags + phase-staggered gens', () {
    final r = buildTestSet(TestSetSpec(
      folder: 'ramp1', baseName: 'Ramp', count: 3, type: 'ramp',
      minValue: 0, maxValue: 100, periodMs: 1000));
    expect(r.tags.map((t) => t.name), ['Ramp1', 'Ramp2', 'Ramp3']);
    expect(r.tags.every((t) => t.folder == 'ramp1'), isTrue);
    expect(r.tags.every((t) => t.ioType == 'SimulatedOutput'), isTrue);
    expect(r.tags.every((t) => t.dataType == 'FLOAT64'), isTrue);
    expect(r.gens.map((g) => g.phase), [0.0, closeTo(1 / 3, 1e-9), closeTo(2 / 3, 1e-9)]);
  });

  test('counter set is INT32, toggle set is BOOL', () {
    expect(buildTestSet(TestSetSpec(folder: 'f', baseName: 'C', count: 1, type: 'counter',
      minValue: 0, maxValue: 10, periodMs: 100)).tags.first.dataType, 'INT32');
    expect(buildTestSet(TestSetSpec(folder: 'f', baseName: 'B', count: 1, type: 'toggle',
      minValue: 0, maxValue: 1, periodMs: 100)).tags.first.dataType, 'BOOL');
  });

  test('names zero-pad to the width of count', () {
    final r = buildTestSet(TestSetSpec(folder: 'f', baseName: 'S', count: 100, type: 'sine',
      minValue: 0, maxValue: 1, periodMs: 1000));
    expect(r.tags.first.name, 'S001');
    expect(r.tags.last.name, 'S100');
  });

  test('appendToModbusMap adds input-table entries after existing ones, no collision', () {
    final map = ModbusMap(entries: [
      ModbusMapEntry(tag: 'Existing', table: 'input', address: 0, access: 'ReadOnly'),
    ]);
    final tags = buildTestSet(TestSetSpec(folder: 'r', baseName: 'R', count: 2, type: 'ramp',
      minValue: 0, maxValue: 1, periodMs: 1000)).tags;
    appendToModbusMap(map, tags);
    final added = map.entries.where((e) => e.tag.startsWith('R')).toList();
    expect(added.length, 2);
    // FLOAT64 -> input table, 4 regs each, starting after the existing FLOAT64 at 0..3.
    expect(added[0].address, 4);
    expect(added[1].address, 8);
    expect(added.every((e) => e.access == 'ReadOnly'), isTrue);
    expect(map.entries.first.address, 0); // existing untouched
  });

  test('appendToDnpMap continues the analogInput index space', () {
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'A', pointType: 'analogInput', index: 0),
      DnpMapEntry(tag: 'B', pointType: 'analogInput', index: 1),
    ]);
    final tags = buildTestSet(TestSetSpec(folder: 'r', baseName: 'R', count: 2, type: 'ramp',
      minValue: 0, maxValue: 1, periodMs: 1000)).tags;
    appendToDnpMap(map, tags);
    final added = map.entries.where((e) => e.tag.startsWith('R')).toList();
    expect(added.map((e) => e.index), [2, 3]);
  });

  test('appenders never duplicate an already-mapped tag', () {
    final tags = buildTestSet(TestSetSpec(folder: 'r', baseName: 'R', count: 1, type: 'ramp',
      minValue: 0, maxValue: 1, periodMs: 1000)).tags;
    final map = MqttMap(entries: [MqttMapEntry(tag: 'R1', metric: 'R1')]);
    appendToMqttMap(map, tags);
    expect(map.entries.where((e) => e.tag == 'R1').length, 1);
  });

  test('appendToMqttMap folder-prefixes generated metrics', () {
    final tags = buildTestSet(TestSetSpec(
      folder: 'Ramp1',
      baseName: 'R',
      count: 2,
      type: 'ramp',
      minValue: 0,
      maxValue: 1,
      periodMs: 1000,
    )).tags;
    final map = MqttMap(entries: []);
    appendToMqttMap(map, tags);
    expect(map.entries.map((e) => e.metric), ['Ramp1/R1', 'Ramp1/R2']);
    expect(map.entries.map((e) => e.tag), ['R1', 'R2']);
  });
}
