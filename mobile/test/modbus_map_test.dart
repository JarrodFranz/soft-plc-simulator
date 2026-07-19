import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';

void main() {
  test('regsForType maps widths', () {
    expect(ModbusMap.regsForType('INT16'), 1);
    expect(ModbusMap.regsForType('INT32'), 2);
    expect(ModbusMap.regsForType('FLOAT64'), 4);
    expect(ModbusMap.regsForType('BOOL'), 1);
  });

  test('autoGenerate assigns tables + sequential addresses by type/access', () {
    final p = PlcProject(id: 'x', name: 'X', controllerName: 'C', structDefs: const [],
      programs: const [], tasks: const [], hmis: const [], tags: [
        PlcTag(name: 'Run', path: 'Run', dataType: 'BOOL', value: false, ioType: 'Internal'),        // RW bool -> coil 0
        PlcTag(name: 'Lamp', path: 'Lamp', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput'),// RO bool -> discrete 0
        PlcTag(name: 'Speed', path: 'Speed', dataType: 'INT16', value: 0, ioType: 'Internal'),        // RW int16 -> holding 0
        PlcTag(name: 'Count', path: 'Count', dataType: 'INT32', value: 0, ioType: 'Internal'),        // RW int32 -> holding 1..2
        PlcTag(name: 'Level', path: 'Level', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput'), // RO f64 -> input 0..3
      ]);
    final m = ModbusMap.autoGenerate(p);
    ModbusMapEntry e(String t) => m.entries.firstWhere((x) => x.tag == t);
    expect([e('Run').table, e('Run').address, e('Run').access], ['coil', 0, 'ReadWrite']);
    expect([e('Lamp').table, e('Lamp').address, e('Lamp').access], ['discrete', 0, 'ReadOnly']);
    expect([e('Speed').table, e('Speed').address], ['holding', 0]);
    expect([e('Count').table, e('Count').address], ['holding', 1]); // after the 1-reg INT16
    expect([e('Level').table, e('Level').address, e('Level').access], ['input', 0, 'ReadOnly']);
  });

  test('marks the reserved System tag read-only by name, even if its own access is left at the default ReadWrite', () {
    final p = PlcProject(id: 'x', name: 'X', controllerName: 'C', structDefs: const [],
      programs: const [], tasks: const [], hmis: const [], tags: [
        PlcTag(
          name: 'System',
          path: 'System',
          dataType: 'SYSTEM',
          value: {'ScanCount': 0, 'Running': false},
          ioType: 'Internal',
          // access intentionally left at its default 'ReadWrite', to prove
          // the name-based rule -- not the access field -- is what forces
          // this read-only.
        ),
      ]);
    final m = ModbusMap.autoGenerate(p);
    final scanCount = m.entries.firstWhere((e) => e.tag == 'System.ScanCount');
    expect(scanCount.table, 'input');
    expect(scanCount.access, 'ReadOnly');
    final running = m.entries.firstWhere((e) => e.tag == 'System.Running');
    expect(running.table, 'discrete');
    expect(running.access, 'ReadOnly');
  });

  test('array tags expand into per-element entries; unregistered struct tags stay skipped', () {
    final p = PlcProject(id: 'x', name: 'X', controllerName: 'C', structDefs: const [],
      programs: const [], tasks: const [], hmis: const [], tags: [
        PlcTag(name: 'Speed', path: 'Speed', dataType: 'INT16', value: 0, ioType: 'Internal'), // scalar -> mapped
        // Array of a scalar: each element is now its own scalar leaf,
        // mapped individually (dotted/indexed path), not skipped.
        PlcTag(name: 'Trend', path: 'Trend', dataType: 'INT32', value: <int>[0, 0, 0],
          arrayLength: 3, ioType: 'Internal'),
        // Struct: an unregistered custom type name (no matching structDefs
        // entry) isn't expanded by scalarLeaves — it stays an opaque leaf
        // whose dataType still fails the Modbus scalar-type filter.
        PlcTag(name: 'Motor', path: 'Motor', dataType: 'MotorType', value: <String, dynamic>{'run': false},
          ioType: 'Internal'),
      ]);
    final m = ModbusMap.autoGenerate(p);
    expect(m.entries.map((e) => e.tag).toList(), ['Speed', 'Trend[0]', 'Trend[1]', 'Trend[2]']);
    expect(m.entries.any((e) => e.tag == 'Motor'), isFalse);
  });

  test('ModbusProtocolConfig round-trips and ProtocolSettings omits modbus when null', () {
    final cfg = ModbusProtocolConfig(enabled: true, port: 5020,
      map: ModbusMap(entries: [ModbusMapEntry(tag: 'Run', table: 'coil', address: 3, access: 'ReadWrite')]));
    final back = ModbusProtocolConfig.fromJson(cfg.toJson());
    expect(back.enabled, true);
    expect(back.port, 5020);
    expect(back.map.entries.single.address, 3);
    final ps = ProtocolSettings(); // no modbus
    expect(ps.toJson().containsKey('modbus'), isFalse);
  });
}
