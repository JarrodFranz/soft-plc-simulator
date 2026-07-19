// Tests for the shared write-gate predicates (protocol-hardening
// workstream, Task 1).
//
// `defaultsExternallyWritable` is the auto-generation default (unifies the
// six protocol maps' read-only rules). `isExternallyWritable` is the
// write-time hard backstop Task 2 wires into the seven write gates. The
// two deliberately differ by exactly one clause: `isExternallyWritable`
// does NOT check `ioType`, so a `SimulatedOutput` tag stays overridable via
// its map entry — that carve-out is the point of this file's two most
// important tests, below.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_write_gate.dart';

void main() {
  PlcProject buildProject(List<PlcTag> tags) => PlcProject(
        id: 'gate_proj',
        name: 'Gate Project',
        controllerName: 'PLC_GATE',
        structDefs: const [],
        programs: const [],
        tasks: const [],
        hmis: const [],
        tags: tags,
      );

  group('defaultsExternallyWritable', () {
    test('false for a System root', () {
      final p = buildProject([
        PlcTag(name: 'System', path: 'System', dataType: 'SYSTEM', value: 0, ioType: 'Internal'),
      ]);
      expect(defaultsExternallyWritable(p, 'System'), isFalse);
    });

    test('false for a SimulatedOutput root', () {
      final p = buildProject([
        PlcTag(name: 'Motor_Run', path: 'Motor_Run', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput'),
      ]);
      expect(defaultsExternallyWritable(p, 'Motor_Run'), isFalse);
    });

    test("false for an access=='ReadOnly' root", () {
      final p = buildProject([
        PlcTag(name: 'Locked', path: 'Locked', dataType: 'INT16', value: 5, ioType: 'Internal', access: 'ReadOnly'),
      ]);
      expect(defaultsExternallyWritable(p, 'Locked'), isFalse);
    });

    test('true for a plain Internal ReadWrite root', () {
      final p = buildProject([
        PlcTag(name: 'Setpoint', path: 'Setpoint', dataType: 'INT32', value: 0, ioType: 'Internal'),
      ]);
      expect(defaultsExternallyWritable(p, 'Setpoint'), isTrue);
    });

    test('false for an unknown path (null root)', () {
      final p = buildProject(const []);
      expect(defaultsExternallyWritable(p, 'Nonexistent'), isFalse);
    });

    test('a member path (Tank.Level) is judged by the root Tank', () {
      final p = buildProject([
        PlcTag(
          name: 'Tank',
          path: 'Tank',
          dataType: 'TankDUT',
          value: {'Level': 0.0},
          ioType: 'SimulatedOutput',
        ),
      ]);
      expect(defaultsExternallyWritable(p, 'Tank.Level'), isFalse);
    });
  });

  group('isExternallyWritable', () {
    test('false for System even when the tag\'s own access is ReadWrite (the hard rule)', () {
      final p = buildProject([
        PlcTag(name: 'System', path: 'System', dataType: 'SYSTEM', value: 0, ioType: 'Internal', access: 'ReadWrite'),
      ]);
      expect(isExternallyWritable(p, 'System'), isFalse);
    });

    test("false for an access=='ReadOnly' root", () {
      final p = buildProject([
        PlcTag(name: 'Locked', path: 'Locked', dataType: 'INT16', value: 5, ioType: 'Internal', access: 'ReadOnly'),
      ]);
      expect(isExternallyWritable(p, 'Locked'), isFalse);
    });

    test('true for a SimulatedOutput root whose access is ReadWrite (the deliberate-override carve-out)', () {
      final p = buildProject([
        PlcTag(
          name: 'Motor_Run',
          path: 'Motor_Run',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          access: 'ReadWrite',
        ),
      ]);
      expect(isExternallyWritable(p, 'Motor_Run'), isTrue);
    });

    test('false for an unknown path (null root)', () {
      final p = buildProject(const []);
      expect(isExternallyWritable(p, 'Nonexistent'), isFalse);
    });

    test('a member path (Tank.Level) is judged by the root Tank', () {
      final p = buildProject([
        PlcTag(
          name: 'Tank',
          path: 'Tank',
          dataType: 'TankDUT',
          value: {'Level': 0.0},
          ioType: 'SimulatedOutput',
          access: 'ReadWrite',
        ),
      ]);
      // ioType is not checked by isExternallyWritable, so a SimulatedOutput
      // root's member stays writable (the override carve-out).
      expect(isExternallyWritable(p, 'Tank.Level'), isTrue);
    });
  });
}
