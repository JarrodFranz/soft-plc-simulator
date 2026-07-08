import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('autoGenerate maps scalar tags, metric=name, writable from ioType', () {
    final p = PlcProject(
      id: 'x',
      name: 'X',
      controllerName: 'C',
      structDefs: const [],
      programs: const [],
      tasks: const [],
      hmis: const [],
      tags: [
        PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
        PlcTag(name: 'B', path: 'B', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput'),
        PlcTag(name: 'C', path: 'C', dataType: 'MyStruct', value: {'x': 1}, ioType: 'Internal'),
      ],
    );
    final m = MqttMap.autoGenerate(p);
    expect(m.entries.map((e) => e.tag), containsAll(['A', 'B']));
    expect(m.entries.any((e) => e.tag == 'C'), isFalse); // composites skipped
    expect(m.entries.firstWhere((e) => e.tag == 'A').writable, isTrue); // SimulatedInput -> writable
    expect(m.entries.firstWhere((e) => e.tag == 'B').writable, isFalse); // SimulatedOutput -> read-only
    expect(m.entries.firstWhere((e) => e.tag == 'A').metric, 'A');
  });

  test('MqttMap json round-trips', () {
    final m = MqttMap(entries: [MqttMapEntry(tag: 'A', metric: 'A', writable: true)]);
    final r = MqttMap.fromJson(m.toJson());
    expect(r.entries.single.tag, 'A');
    expect(r.entries.single.writable, isTrue);
  });
}
