import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';

void main() {
  test('groupEntriesByFolder buckets entries by their tag folder, root first', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [
          PlcTag(name: 'Root1', path: 'Root1', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'R1', path: 'R1', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', folder: 'ramp1'),
        ],
        structDefs: [], programs: [], tasks: [], hmis: []);
    final entries = [
      ModbusMapEntry(tag: 'R1', table: 'input', address: 0, access: 'ReadOnly'),
      ModbusMapEntry(tag: 'Root1', table: 'discrete', address: 0, access: 'ReadOnly'),
    ];
    final grouped = groupEntriesByFolder<ModbusMapEntry>(entries, (e) => e.tag, p);
    expect(grouped.keys.first, ''); // root first
    expect(grouped['']!.single.tag, 'Root1');
    expect(grouped['ramp1']!.single.tag, 'R1');
  });
}
