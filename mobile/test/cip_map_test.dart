// Tests for the per-project CipMap tag-exposure model (EtherNet/IP + CIP
// explicit messaging workstream, Task 4).
//
// Mirrors mobile/test/opcua_map_test.dart's auto-population coverage
// (SimulatedOutput / explicit ReadOnly access -> ReadOnly, everything else
// ReadWrite) plus the reserved System tag, and additionally asserts the one
// place CipMap deliberately diverges from OpcuaMap: STRING tags are SKIPPED
// during auto-population (a symbolic CIP string is a structured type
// requiring the Template Object, deferred to v2 — see cip_map.dart's file
// header).

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/cip_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  group('CipMap.autoPopulate', () {
    PlcProject buildProject() => PlcProject(
          id: 'cip_proj',
          name: 'CIP Project',
          controllerName: 'PLC_CIP',
          tags: [
            // RW: SimulatedInput.
            PlcTag(
              name: 'Start_PB',
              path: 'Inputs/Start_PB',
              dataType: 'BOOL',
              value: false,
              ioType: 'SimulatedInput',
            ),
            // RO: SimulatedOutput.
            PlcTag(
              name: 'Motor_Run',
              path: 'Outputs/Motor_Run',
              dataType: 'BOOL',
              value: false,
              ioType: 'SimulatedOutput',
            ),
            // RW: Internal.
            PlcTag(
              name: 'Setpoint',
              path: 'Internal/Setpoint',
              dataType: 'INT32',
              value: 0,
              ioType: 'Internal',
            ),
            // RO: explicit tag-level ReadOnly access, ioType Internal.
            PlcTag(
              name: 'Locked_Tag',
              path: 'Internal/Locked_Tag',
              dataType: 'INT16',
              value: 5,
              ioType: 'Internal',
              access: 'ReadOnly',
            ),
            // Excluded entirely: STRING leaf, even though ioType/access would
            // otherwise make it ReadWrite.
            PlcTag(
              name: 'Batch_Id',
              path: 'Internal/Batch_Id',
              dataType: 'STRING',
              value: '',
              ioType: 'Internal',
            ),
            // Reserved System tag: forced ReadOnly by NAME, independent of its
            // own `access` field (left at the default ReadWrite here on
            // purpose, to prove the name-based rule — not the access field —
            // is what makes it ReadOnly). Not expanded into per-field leaves
            // (value is a placeholder int, not a Map), same convention as
            // dnp3_map_test.dart's TIMER/COUNTER fixtures.
            PlcTag(
              name: 'System',
              path: 'System',
              dataType: 'SYSTEM',
              value: 0,
              ioType: 'Internal',
            ),
          ],
          structDefs: [],
          programs: [],
          tasks: [],
          hmis: [],
        );

    test('marks SimulatedOutput / explicit ReadOnly / reserved System as ReadOnly; else ReadWrite', () {
      final project = buildProject();
      final map = CipMap.autoPopulate(project);

      // Batch_Id (STRING) must not appear at all.
      expect(map.entries.any((e) => e.tagName == 'Batch_Id'), isFalse);
      expect(map.entries.length, 5);

      final start = map.entries.firstWhere((e) => e.tagName == 'Start_PB');
      expect(start.access, 'ReadWrite');

      final motor = map.entries.firstWhere((e) => e.tagName == 'Motor_Run');
      expect(motor.access, 'ReadOnly');

      final setpoint = map.entries.firstWhere((e) => e.tagName == 'Setpoint');
      expect(setpoint.access, 'ReadWrite');

      final locked = map.entries.firstWhere((e) => e.tagName == 'Locked_Tag');
      expect(locked.access, 'ReadOnly');

      final system = map.entries.firstWhere((e) => e.tagName == 'System');
      expect(system.access, 'ReadOnly');
    });

    test('STRING leaves are skipped even when nested inside an otherwise-exposed composite', () {
      final project = PlcProject(
        id: 'cip_proj2',
        name: 'CIP Project 2',
        controllerName: 'PLC_CIP2',
        structDefs: [
          PlcStructDef(name: 'BatchDUT', fields: [
            StructFieldDef(name: 'Id', dataType: 'STRING', defaultValue: ''),
            StructFieldDef(name: 'Count', dataType: 'INT32', defaultValue: 0),
          ]),
        ],
        tags: [
          PlcTag(
            name: 'Batch1',
            path: 'Internal/Batch1',
            dataType: 'BatchDUT',
            value: {'Id': '', 'Count': 0},
            ioType: 'Internal',
          ),
        ],
        programs: [],
        tasks: [],
        hmis: [],
      );

      final map = CipMap.autoPopulate(project);
      expect(map.entries.any((e) => e.tagName == 'Batch1.Id'), isFalse);
      final count = map.entries.firstWhere((e) => e.tagName == 'Batch1.Count');
      expect(count.access, 'ReadWrite');
      expect(map.entries.length, 1);
    });
  });

  group('CipMapEntry / CipMap json round-trip', () {
    test('CipMapEntry round-trips through toJson/fromJson', () {
      final entry = CipMapEntry(tagName: 'Motor_Run', access: 'ReadOnly');
      final rt = CipMapEntry.fromJson(entry.toJson());
      expect(rt.tagName, 'Motor_Run');
      expect(rt.access, 'ReadOnly');
    });

    test('CipMap json round-trips', () {
      final m = CipMap(entries: [
        CipMapEntry(tagName: 'A', access: 'ReadWrite'),
        CipMapEntry(tagName: 'B', access: 'ReadOnly'),
      ]);
      final r = CipMap.fromJson(m.toJson());
      expect(r.entries.length, 2);
      expect(r.entries[0].tagName, 'A');
      expect(r.entries[0].access, 'ReadWrite');
      expect(r.entries[1].tagName, 'B');
      expect(r.entries[1].access, 'ReadOnly');
    });

    test('CipMap.fromJson tolerates a missing entries key (additive persistence)', () {
      final m = CipMap.fromJson({});
      expect(m.entries, isEmpty);
    });

    test('a JSON entry without an access field defaults to ReadWrite', () {
      final e = CipMapEntry.fromJson({'tag_name': 'NoAccessField'});
      expect(e.tagName, 'NoAccessField');
      expect(e.access, 'ReadWrite');
    });
  });
}
