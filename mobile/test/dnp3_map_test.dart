// Tests for the per-project DnpMap tag<->point model (DNP3 outstation Task 1).
//
// Mirrors mobile/test/modbus_map_test.dart's structure but for DNP3: instead
// of Modbus data tables, tags are assigned into one of four DNP3 point types
// (binary input / binary output / analog input / analog output), each with
// its own independently-numbered 0-based index space.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';

void main() {
  group('DnpMap.autoGenerate', () {
    PlcProject buildProject() => PlcProject(
          id: 'dnp_proj',
          name: 'DNP3 Project',
          controllerName: 'PLC_DNP',
          tags: [
            // RO BOOL -> binaryInput
            PlcTag(
              name: 'Motor_Run',
              path: 'Outputs/Motor_Run',
              dataType: 'BOOL',
              value: false,
              ioType: 'SimulatedOutput',
            ),
            // RW BOOL -> binaryOutput
            PlcTag(
              name: 'Start_PB',
              path: 'Inputs/Start_PB',
              dataType: 'BOOL',
              value: false,
              ioType: 'SimulatedInput',
            ),
            // RO numeric (FLOAT64) -> analogInput
            PlcTag(
              name: 'Tank_Level',
              path: 'Outputs/Tank_Level',
              dataType: 'FLOAT64',
              value: 0.0,
              ioType: 'SimulatedOutput',
            ),
            // RW numeric (INT32) -> analogOutput
            PlcTag(
              name: 'Setpoint',
              path: 'Internal/Setpoint',
              dataType: 'INT32',
              value: 0,
              ioType: 'Internal',
            ),
            // Composite (array) -> skipped
            PlcTag(
              name: 'Recipe_Array',
              path: 'Internal/Recipe_Array',
              dataType: 'INT32',
              arrayLength: 4,
              value: <int>[0, 0, 0, 0],
              ioType: 'Internal',
            ),
            // TIMER -> skipped
            PlcTag(
              name: 'Delay_Timer',
              path: 'Internal/Delay_Timer',
              dataType: 'TIMER',
              value: 0,
              ioType: 'Internal',
            ),
            // COUNTER -> skipped
            PlcTag(
              name: 'Cycle_Counter',
              path: 'Internal/Cycle_Counter',
              dataType: 'COUNTER',
              value: 0,
              ioType: 'Internal',
            ),
            // STRING -> skipped
            PlcTag(
              name: 'Batch_Id',
              path: 'Internal/Batch_Id',
              dataType: 'STRING',
              value: '',
              ioType: 'Internal',
            ),
          ],
          structDefs: [],
          programs: [],
          tasks: [],
          hmis: [],
        );

    test('maps BOOL/numeric x RO/RW into the 4 point types with per-type indexes', () {
      final project = buildProject();
      final m = DnpMap.autoGenerate(project);

      // Recipe_Array (INT32[4]) expands into 4 scalar analogOutput leaves
      // alongside the 4 base scalar tags below. Delay_Timer/Cycle_Counter
      // here carry a placeholder int (not a real struct Map), so scalarLeaves
      // doesn't expand them — they stay single opaque leaves whose
      // TIMER/COUNTER dataType is skipped, same as before.
      expect(m.entries.length, 8);

      final binaryInputs = m.entries.where((e) => e.pointType == 'binaryInput').toList();
      expect(binaryInputs.length, 1);
      expect(binaryInputs.single.tag, 'Motor_Run');
      expect(binaryInputs.single.index, 0);

      final binaryOutputs = m.entries.where((e) => e.pointType == 'binaryOutput').toList();
      expect(binaryOutputs.length, 1);
      expect(binaryOutputs.single.tag, 'Start_PB');
      expect(binaryOutputs.single.index, 0);

      final analogInputs = m.entries.where((e) => e.pointType == 'analogInput').toList();
      expect(analogInputs.length, 1);
      expect(analogInputs.single.tag, 'Tank_Level');
      expect(analogInputs.single.index, 0);

      final analogOutputs = m.entries.where((e) => e.pointType == 'analogOutput').toList();
      expect(analogOutputs.map((e) => e.tag).toList(),
          ['Setpoint', 'Recipe_Array[0]', 'Recipe_Array[1]', 'Recipe_Array[2]', 'Recipe_Array[3]']);
      expect(analogOutputs.map((e) => e.index).toList(), [0, 1, 2, 3, 4]);

      // TIMER / COUNTER / STRING (placeholder int/'' values, not real
      // struct maps) are all skipped.
      expect(m.entries.any((e) => e.tag == 'Delay_Timer'), isFalse);
      expect(m.entries.any((e) => e.tag == 'Cycle_Counter'), isFalse);
      expect(m.entries.any((e) => e.tag == 'Batch_Id'), isFalse);
    });

    test('assigns per-point-type indexes independently in tag order', () {
      final project = PlcProject(
        id: 'dnp_proj2',
        name: 'DNP3 Project 2',
        controllerName: 'PLC_DNP2',
        tags: [
          PlcTag(name: 'B1', path: 'B1', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
          PlcTag(name: 'B2', path: 'B2', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
          PlcTag(name: 'A1', path: 'A1', dataType: 'INT16', value: 0, ioType: 'SimulatedInput'),
          PlcTag(name: 'B3', path: 'B3', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );

      final m = DnpMap.autoGenerate(project);
      final binaryOutputs = m.entries.where((e) => e.pointType == 'binaryOutput').toList();
      expect(binaryOutputs.map((e) => e.tag).toList(), ['B1', 'B2', 'B3']);
      expect(binaryOutputs.map((e) => e.index).toList(), [0, 1, 2]);

      final analogOutputs = m.entries.where((e) => e.pointType == 'analogOutput').toList();
      expect(analogOutputs.single.tag, 'A1');
      expect(analogOutputs.single.index, 0);
    });
  });

  group('DnpMapEntry / DnpMap json round-trip', () {
    test('DnpMapEntry round-trips through toJson/fromJson', () {
      final entry = DnpMapEntry(tag: 'Motor_Run', pointType: 'binaryInput', index: 3);
      final rt = DnpMapEntry.fromJson(entry.toJson());
      expect(rt.tag, 'Motor_Run');
      expect(rt.pointType, 'binaryInput');
      expect(rt.index, 3);
    });

    test('DnpMap json round-trips', () {
      final m = DnpMap(entries: [
        DnpMapEntry(tag: 'A', pointType: 'binaryInput', index: 0),
        DnpMapEntry(tag: 'B', pointType: 'analogOutput', index: 1),
      ]);
      final r = DnpMap.fromJson(m.toJson());
      expect(r.entries.length, 2);
      expect(r.entries[0].tag, 'A');
      expect(r.entries[0].pointType, 'binaryInput');
      expect(r.entries[0].index, 0);
      expect(r.entries[1].tag, 'B');
      expect(r.entries[1].pointType, 'analogOutput');
      expect(r.entries[1].index, 1);
    });

    test('DnpMap.fromJson tolerates a missing entries key', () {
      final m = DnpMap.fromJson({});
      expect(m.entries, isEmpty);
    });

    test('DnpMapEntry carries eventClass and round-trips; older JSON defaults to 0', () {
      final e = DnpMapEntry(tag: 'Level', pointType: 'analogInput', index: 3, eventClass: 2);
      final round = DnpMapEntry.fromJson(e.toJson());
      expect(round.eventClass, 2);
      // Back-compat: JSON without event_class defaults to 0 (static-only).
      final legacy = DnpMapEntry.fromJson({'tag': 'X', 'point_type': 'binaryInput', 'index': 0});
      expect(legacy.eventClass, 0);
    });

    test('DnpMapEntry.fromJson clamps out-of-range event_class into 0..3', () {
      // Corrupted/hand-edited JSON with an out-of-range high value clamps to 3.
      final high = DnpMapEntry.fromJson({
        'tag': 'Y',
        'point_type': 'analogInput',
        'index': 0,
        'event_class': 99,
      });
      expect(high.eventClass, 3);

      // A negative value clamps to 0.
      final low = DnpMapEntry.fromJson({
        'tag': 'Z',
        'point_type': 'analogInput',
        'index': 0,
        'event_class': -1,
      });
      expect(low.eventClass, 0);

      // A normal in-range value still round-trips unchanged.
      final normal = DnpMapEntry.fromJson({
        'tag': 'W',
        'point_type': 'analogInput',
        'index': 0,
        'event_class': 2,
      });
      expect(normal.eventClass, 2);

      // The missing-key default is still 0.
      final missing = DnpMapEntry.fromJson({
        'tag': 'V',
        'point_type': 'analogInput',
        'index': 0,
      });
      expect(missing.eventClass, 0);
    });
  });
}
