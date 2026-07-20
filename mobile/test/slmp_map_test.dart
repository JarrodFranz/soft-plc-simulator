// Tests for the per-project SlmpMap tag<->device/address model (SLMP
// workstream, Task 4).
//
// Mirrors mobile/test/fins_map_test.dart, but SLMP addresses by DEVICE (D/M/W/R)
// + a device number (the "address"), not by a memory-area name + word offset:
// `SimulatedOutput` / explicit ReadOnly access -> ReadOnly, everything else
// ReadWrite, STRING skipped, and tags packed into the D (data register) device
// with word alignment (a 16-bit word holds up to 16 bit-packed BOOLs, a 32-bit
// value spans two words).

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/slmp_map.dart';

void main() {
  PlcProject buildProject() => PlcProject(
        id: 'slmp_proj',
        name: 'SLMP Project',
        controllerName: 'PLC_SLMP',
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
        tags: [
          PlcTag(
            name: 'Flag1',
            path: 'Inputs/Flag1',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedInput',
          ),
          PlcTag(
            name: 'Flag2',
            path: 'Inputs/Flag2',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedInput',
          ),
          PlcTag(
            name: 'Count',
            path: 'Internal/Count',
            dataType: 'INT16',
            value: 0,
            ioType: 'Internal',
          ),
          PlcTag(
            name: 'Big',
            path: 'Internal/Big',
            dataType: 'INT32',
            value: 0,
            ioType: 'Internal',
          ),
          PlcTag(
            name: 'Level',
            path: 'Internal/Level',
            dataType: 'FLOAT64',
            value: 0.0,
            ioType: 'Internal',
          ),
          PlcTag(
            name: 'Huge',
            path: 'Internal/Huge',
            dataType: 'INT64',
            value: 0,
            ioType: 'Internal',
          ),
          // Skipped entirely: STRING.
          PlcTag(
            name: 'Batch_Id',
            path: 'Internal/Batch_Id',
            dataType: 'STRING',
            value: '',
            ioType: 'Internal',
          ),
          // ReadOnly by ioType.
          PlcTag(
            name: 'Motor_Run',
            path: 'Outputs/Motor_Run',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedOutput',
          ),
          // ReadOnly by explicit tag access.
          PlcTag(
            name: 'Locked',
            path: 'Internal/Locked',
            dataType: 'INT16',
            value: 5,
            ioType: 'Internal',
            access: 'ReadOnly',
          ),
        ],
      );

  SlmpMapEntry entryFor(SlmpMap m, String tag) =>
      m.entries.firstWhere((e) => e.tag == tag);

  group('SlmpMap.autoGenerate', () {
    test('packs into the D device with word packing and bit-packed BOOLs', () {
      final m = SlmpMap.autoGenerate(buildProject());
      for (final e in m.entries) {
        expect(e.device, kSlmpDeviceNameD);
      }

      // Two BOOLs share address 0 at bits 0 and 1.
      expect(entryFor(m, 'Flag1').address, 0);
      expect(entryFor(m, 'Flag1').bitOffset, 0);
      expect(entryFor(m, 'Flag2').address, 0);
      expect(entryFor(m, 'Flag2').bitOffset, 1);

      // INT16 -> 1 word. The partially used bit word (0) is closed, so the
      // cursor advances to address 1.
      expect(entryFor(m, 'Count').address, 1);
      expect(entryFor(m, 'Count').bitOffset, 0);

      // INT32 -> 2 words, at address 2.
      expect(entryFor(m, 'Big').address, 2);

      // FLOAT64 -> REAL, 2 words, at address 4.
      expect(entryFor(m, 'Level').address, 4);

      // INT64 -> 4 words, at address 6.
      expect(entryFor(m, 'Huge').address, 6);

      // Next BOOL starts a fresh word after the 64-bit value ends at address 10.
      expect(entryFor(m, 'Motor_Run').address, 10);
      expect(entryFor(m, 'Motor_Run').bitOffset, 0);

      // Then an INT16, one word after closing address 10.
      expect(entryFor(m, 'Locked').address, 11);
    });

    test('assigns non-overlapping word/bit spans', () {
      final m = SlmpMap.autoGenerate(buildProject());
      final used = <String>{};
      for (final e in m.entries) {
        final type = _typeOfFixtureTag(e.tag);
        if (type == 'BOOL') {
          final key = 'w${e.address}.${e.bitOffset}';
          expect(used.contains(key), isFalse, reason: 'overlap at $key');
          used.add(key);
        } else {
          final width = SlmpMap.widthWordsForType(type)!;
          for (var i = 0; i < width; i++) {
            final key = 'W${e.address + i}';
            expect(used.contains(key), isFalse, reason: 'overlap at $key');
            used.add(key);
          }
        }
      }
    });

    test('marks SimulatedOutput and explicit ReadOnly tags as ReadOnly', () {
      final m = SlmpMap.autoGenerate(buildProject());
      expect(entryFor(m, 'Flag1').access, 'ReadWrite');
      expect(entryFor(m, 'Count').access, 'ReadWrite');
      expect(entryFor(m, 'Motor_Run').access, 'ReadOnly');
      expect(entryFor(m, 'Locked').access, 'ReadOnly');
    });

    test('marks the reserved System tag ReadOnly by name, even if its own access is left at the default ReadWrite', () {
      final p = buildProject();
      p.tags.add(PlcTag(
        name: 'System',
        path: 'System',
        dataType: 'SYSTEM',
        value: {'ScanCount': 0, 'Running': false},
        ioType: 'Internal',
        // access intentionally left at its default 'ReadWrite', to prove the
        // name-based rule -- not the access field -- is what forces ReadOnly.
      ));
      final m = SlmpMap.autoGenerate(p);
      final sysEntries = m.entries.where((e) => e.tag.startsWith('System.'));
      expect(sysEntries, isNotEmpty);
      for (final e in sysEntries) {
        expect(e.access, 'ReadOnly');
      }
    });

    test('skips STRING leaves entirely', () {
      final m = SlmpMap.autoGenerate(buildProject());
      expect(m.entries.any((e) => e.tag == 'Batch_Id'), isFalse);
    });
  });

  group('SlmpMap JSON', () {
    test('round-trips through toJson/fromJson', () {
      final m = SlmpMap(entries: [
        SlmpMapEntry(
          tag: 'Tank.Level',
          device: kSlmpDeviceNameD,
          address: 12,
          bitOffset: 0,
          access: 'ReadOnly',
        ),
        SlmpMapEntry(
          tag: 'Flag',
          device: kSlmpDeviceNameM,
          address: 3,
          bitOffset: 5,
        ),
      ]);
      final back = SlmpMap.fromJson(m.toJson());
      expect(back.entries.length, 2);
      expect(back.entries[0].tag, 'Tank.Level');
      expect(back.entries[0].device, kSlmpDeviceNameD);
      expect(back.entries[0].address, 12);
      expect(back.entries[0].bitOffset, 0);
      expect(back.entries[0].access, 'ReadOnly');
      expect(back.entries[1].device, kSlmpDeviceNameM);
      expect(back.entries[1].bitOffset, 5);
      expect(back.entries[1].access, 'ReadWrite');
    });

    test('an entry with no access key defaults to ReadWrite', () {
      final e = SlmpMapEntry.fromJson({
        'tag': 'X',
        'device': kSlmpDeviceNameD,
        'address': 4,
        'bit_offset': 0,
      });
      expect(e.access, 'ReadWrite');
    });

    test('an empty/absent entries list yields an empty map (never throws)', () {
      expect(SlmpMap.fromJson(<String, dynamic>{}).entries, isEmpty);
      expect(SlmpMap.fromJson({'entries': 'nonsense'}).entries, isEmpty);
    });
  });
}

/// Data type of a fixture tag by its auto-generated entry tag path.
String _typeOfFixtureTag(String tag) {
  switch (tag) {
    case 'Flag1':
    case 'Flag2':
    case 'Motor_Run':
      return 'BOOL';
    case 'Count':
    case 'Locked':
      return 'INT16';
    case 'Big':
      return 'INT32';
    case 'Level':
      return 'FLOAT64';
    case 'Huge':
      return 'INT64';
    default:
      return 'BOOL';
  }
}
