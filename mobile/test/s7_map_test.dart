// Tests for the per-project S7Map tag<->area/offset model (S7comm
// workstream, Task 4).
//
// Mirrors mobile/test/cip_map_test.dart's auto-population coverage
// (SimulatedOutput / explicit ReadOnly access -> ReadOnly, everything else
// ReadWrite, STRING skipped) and adds the thing no other protocol map has:
// BYTE OFFSET packing with natural alignment inside DB1.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/s7_map.dart';

void main() {
  PlcProject buildProject() => PlcProject(
        id: 's7_proj',
        name: 'S7 Project',
        controllerName: 'PLC_S7',
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

  S7MapEntry entryFor(S7Map m, String tag) =>
      m.entries.firstWhere((e) => e.tag == tag);

  group('S7Map.autoGenerate', () {
    test('packs into DB1 with natural alignment and bit-packed BOOLs', () {
      final m = S7Map.autoGenerate(buildProject());
      for (final e in m.entries) {
        expect(e.area, 'DB');
        expect(e.dbNumber, 1);
      }

      // Two BOOLs share byte 0 at bits 0 and 1.
      expect(entryFor(m, 'Flag1').byteOffset, 0);
      expect(entryFor(m, 'Flag1').bitOffset, 0);
      expect(entryFor(m, 'Flag2').byteOffset, 0);
      expect(entryFor(m, 'Flag2').bitOffset, 1);

      // INT16 -> 2-byte aligned. The partially used bit byte (0) is closed,
      // leaving the cursor at 1, which rounds up to 2.
      expect(entryFor(m, 'Count').byteOffset, 2);
      expect(entryFor(m, 'Count').bitOffset, 0);

      // INT32 -> 4-byte aligned.
      expect(entryFor(m, 'Big').byteOffset, 4);

      // FLOAT64 -> REAL, 4 bytes wide, 4-byte aligned.
      expect(entryFor(m, 'Level').byteOffset, 8);

      // INT64 -> LINT, 8 bytes wide, on a 4-byte boundary.
      expect(entryFor(m, 'Huge').byteOffset, 12);

      // Next BOOL starts a fresh byte after the LINT ends at 20.
      expect(entryFor(m, 'Motor_Run').byteOffset, 20);
      expect(entryFor(m, 'Motor_Run').bitOffset, 0);

      // Then an INT16, 2-byte aligned after closing byte 20.
      expect(entryFor(m, 'Locked').byteOffset, 22);
    });

    test('assigns non-overlapping byte/bit spans', () {
      final m = S7Map.autoGenerate(buildProject());
      final used = <String>{};
      for (final e in m.entries) {
        final width = S7Map.widthBytesForType(
          _typeOfFixtureTag(e.tag),
        );
        if (_typeOfFixtureTag(e.tag) == 'BOOL') {
          final key = 'b${e.byteOffset}.${e.bitOffset}';
          expect(used.contains(key), isFalse, reason: 'overlap at $key');
          used.add(key);
        } else {
          for (var i = 0; i < width!; i++) {
            final key = 'B${e.byteOffset + i}';
            expect(used.contains(key), isFalse, reason: 'overlap at $key');
            used.add(key);
          }
        }
      }
    });

    test('marks SimulatedOutput and explicit ReadOnly tags as ReadOnly', () {
      final m = S7Map.autoGenerate(buildProject());
      expect(entryFor(m, 'Flag1').access, 'ReadWrite');
      expect(entryFor(m, 'Count').access, 'ReadWrite');
      expect(entryFor(m, 'Motor_Run').access, 'ReadOnly');
      expect(entryFor(m, 'Locked').access, 'ReadOnly');
    });

    test('marks the reserved System tag ReadOnly', () {
      final p = buildProject();
      p.tags.add(PlcTag(
        name: 'System',
        path: 'System',
        dataType: 'SYSTEM',
        value: {'ScanCount': 0, 'Running': false},
        ioType: 'Internal',
        access: 'ReadOnly',
      ));
      final m = S7Map.autoGenerate(p);
      final sysEntries = m.entries.where((e) => e.tag.startsWith('System.'));
      expect(sysEntries, isNotEmpty);
      for (final e in sysEntries) {
        expect(e.access, 'ReadOnly');
      }
    });

    test('skips STRING leaves entirely', () {
      final m = S7Map.autoGenerate(buildProject());
      expect(m.entries.any((e) => e.tag == 'Batch_Id'), isFalse);
    });
  });

  group('S7Map JSON', () {
    test('round-trips through toJson/fromJson', () {
      final m = S7Map(entries: [
        S7MapEntry(
          tag: 'Tank.Level',
          area: 'DB',
          dbNumber: 7,
          byteOffset: 12,
          bitOffset: 0,
          access: 'ReadOnly',
        ),
        S7MapEntry(
          tag: 'Flag',
          area: 'M',
          dbNumber: 0,
          byteOffset: 3,
          bitOffset: 5,
        ),
      ]);
      final back = S7Map.fromJson(m.toJson());
      expect(back.entries.length, 2);
      expect(back.entries[0].tag, 'Tank.Level');
      expect(back.entries[0].area, 'DB');
      expect(back.entries[0].dbNumber, 7);
      expect(back.entries[0].byteOffset, 12);
      expect(back.entries[0].bitOffset, 0);
      expect(back.entries[0].access, 'ReadOnly');
      expect(back.entries[1].area, 'M');
      expect(back.entries[1].bitOffset, 5);
      expect(back.entries[1].access, 'ReadWrite');
    });

    test('an entry with no access key defaults to ReadWrite', () {
      final e = S7MapEntry.fromJson({
        'tag': 'X',
        'area': 'DB',
        'db_number': 1,
        'byte_offset': 4,
        'bit_offset': 0,
      });
      expect(e.access, 'ReadWrite');
    });

    test('an empty/absent entries list yields an empty map (never throws)', () {
      expect(S7Map.fromJson(<String, dynamic>{}).entries, isEmpty);
      expect(S7Map.fromJson({'entries': 'nonsense'}).entries, isEmpty);
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
