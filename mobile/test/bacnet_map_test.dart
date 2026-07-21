// Tests for BacnetMap (models/bacnet_map.dart) — tag<->(AV|BV instance)
// binding model, JSON persistence, and autoGenerate. Mirrors
// `slmp_map_test.dart`'s coverage shape for the analogous SLMP model.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/bacnet_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  PlcProject buildProject() => PlcProject(
        id: 'bacnet_map_test',
        name: 'BACnet Map Test',
        controllerName: 'PLC_BACNET',
        programs: [],
        tasks: [],
        hmis: [],
        structDefs: [
          PlcStructDef(name: 'VesselType', fields: [
            StructFieldDef(name: 'Level', dataType: 'INT16', defaultValue: 0),
          ]),
        ],
        tags: [
          // Tag order matters: this is the order autoGenerate must walk.
          PlcTag(name: 'Flag1', path: 'Flag1', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'Word1', path: 'Word1', dataType: 'INT16', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Flag2', path: 'Flag2', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'Name1', path: 'Name1', dataType: 'STRING', value: '', ioType: 'Internal'),
          PlcTag(name: 'Dint1', path: 'Dint1', dataType: 'INT32', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Lint1', path: 'Lint1', dataType: 'INT64', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Real1', path: 'Real1', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
          PlcTag(
            name: 'RoTag',
            path: 'RoTag',
            dataType: 'INT16',
            value: 11,
            ioType: 'Internal',
            access: 'ReadOnly',
          ),
          PlcTag(name: 'SimOut', path: 'SimOut', dataType: 'INT16', value: 7, ioType: 'SimulatedOutput'),
          PlcTag(
            name: 'Tank',
            path: 'Tank',
            dataType: 'VesselType',
            value: {'Level': 11},
            ioType: 'Internal',
          ),
        ],
      );

  group('BacnetMap.autoGenerate', () {
    test(
        'scalar leaves in TAG ORDER: BOOL -> BV instances 0,1,..; other '
        'numerics -> AV instances 0,1,..; STRING skipped', () {
      final p = buildProject();
      final map = BacnetMap.autoGenerate(p);
      final byTag = {for (final e in map.entries) e.tag: e};

      expect(byTag.containsKey('Name1'), isFalse, reason: 'STRING is skipped entirely');

      expect(byTag['Flag1']!.objectType, kBacnetMapTypeBv);
      expect(byTag['Flag1']!.instance, 0);
      expect(byTag['Flag2']!.objectType, kBacnetMapTypeBv);
      expect(byTag['Flag2']!.instance, 1, reason: 'BV instances assigned in tag order');

      expect(byTag['Word1']!.objectType, kBacnetMapTypeAv);
      expect(byTag['Word1']!.instance, 0);
      expect(byTag['Dint1']!.objectType, kBacnetMapTypeAv);
      expect(byTag['Dint1']!.instance, 1);
      expect(byTag['Lint1']!.objectType, kBacnetMapTypeAv);
      expect(byTag['Lint1']!.instance, 2);
      expect(byTag['Real1']!.objectType, kBacnetMapTypeAv);
      expect(byTag['Real1']!.instance, 3);
      expect(byTag['RoTag']!.instance, 4);
      expect(byTag['SimOut']!.instance, 5);
      expect(byTag['Tank.Level']!.objectType, kBacnetMapTypeAv);
      expect(byTag['Tank.Level']!.instance, 6, reason: 'AV instances assigned independently of BV, in tag order');
    });

    test('access defaults come from the shared write-gate helper (defaultsExternallyWritable)', () {
      final p = buildProject();
      final map = BacnetMap.autoGenerate(p);
      final byTag = {for (final e in map.entries) e.tag: e};

      expect(byTag['Word1']!.access, 'ReadWrite');
      expect(byTag['RoTag']!.access, 'ReadOnly', reason: "the tag's own access is ReadOnly");
      expect(byTag['SimOut']!.access, 'ReadOnly', reason: 'SimulatedOutput defaults to non-writable');
      expect(byTag['Tank.Level']!.access, 'ReadWrite');
    });

    test('the reserved System tag defaults to ReadOnly by NAME', () {
      final p = PlcProject(
        id: 'bacnet_map_system',
        name: 'System Test',
        controllerName: 'PLC',
        programs: [],
        tasks: [],
        hmis: [],
        structDefs: [
          PlcStructDef(name: 'SystemType', fields: [
            StructFieldDef(name: 'Cmd', dataType: 'INT16', defaultValue: 0),
          ]),
        ],
        tags: [
          // Own access deliberately ReadWrite: isolates the NAME-based rule.
          PlcTag(
            name: 'System',
            path: 'System',
            dataType: 'SystemType',
            value: {'Cmd': 0},
            ioType: 'Internal',
            access: 'ReadWrite',
          ),
        ],
      );
      final map = BacnetMap.autoGenerate(p);
      final entry = map.entries.singleWhere((e) => e.tag == 'System.Cmd');
      expect(entry.access, 'ReadOnly');
    });
  });

  group('BacnetMap JSON round-trip', () {
    test('entries round-trip through toJson/fromJson', () {
      final map = BacnetMap(entries: [
        BacnetMapEntry(tag: 'Word1', objectType: kBacnetMapTypeAv, instance: 0, access: 'ReadWrite'),
        BacnetMapEntry(tag: 'Flag1', objectType: kBacnetMapTypeBv, instance: 0, access: 'ReadOnly'),
      ]);
      final decoded = BacnetMap.fromJson(map.toJson());
      expect(decoded.entries.length, 2);
      expect(decoded.entries[0].tag, 'Word1');
      expect(decoded.entries[0].objectType, kBacnetMapTypeAv);
      expect(decoded.entries[0].instance, 0);
      expect(decoded.entries[0].access, 'ReadWrite');
      expect(decoded.entries[1].tag, 'Flag1');
      expect(decoded.entries[1].objectType, kBacnetMapTypeBv);
      expect(decoded.entries[1].access, 'ReadOnly');
    });

    test('a missing access key in JSON defaults to ReadWrite', () {
      final decoded = BacnetMap.fromJson({
        'entries': [
          {'tag': 'Word1', 'object_type': kBacnetMapTypeAv, 'instance': 0},
        ],
      });
      expect(decoded.entries.single.access, 'ReadWrite');
    });

    test('a missing/non-list entries key loads as empty (additive persistence)', () {
      expect(BacnetMap.fromJson({}).entries, isEmpty);
      expect(BacnetMap.fromJson({'entries': 'not a list'}).entries, isEmpty);
    });
  });
}
