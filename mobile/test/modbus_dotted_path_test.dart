// Dotted-path (struct member) type + force resolution for the Modbus
// register-file handler (mobile/lib/protocols/modbus/modbus_pdu.dart).
//
// Regression coverage for Task 3 of the "Protocol Interop Fixes" workstream:
// a hand-added map entry whose `tag` is a dotted struct-member path (e.g.
// `Motor.Speed`) previously resolved its data type by matching the path
// against top-level tag NAMES only, silently falling back to INT16 (wrong
// register width) and never matching a forced ROOT tag (force check missed
// entirely). `_tagDataType`/`_findRootTag`/`_isForcedSkip` now resolve
// through the full path via `tag_resolver.dart`'s field-def walk.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/modbus/modbus_pdu.dart';

PlcProject _motorProject({bool forced = false}) {
  final project = PlcProject(
    id: 'proj_modbus_dotted',
    name: 'Modbus Dotted Path Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'Motor',
        path: 'Motor',
        dataType: 'MotorType',
        value: {'Speed': 12345},
        ioType: 'Internal',
        isForced: forced,
      ),
    ],
    structDefs: [
      PlcStructDef(name: 'MotorType', fields: [
        StructFieldDef(name: 'Speed', dataType: 'INT32', defaultValue: 0),
      ]),
    ],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings(
    modbus: ModbusProtocolConfig(
      map: ModbusMap(entries: [
        ModbusMapEntry(tag: 'Motor.Speed', table: 'holding', address: 0, access: 'ReadWrite'),
      ]),
    ),
  );
  return project;
}

Uint8List _readHoldingRequest(int start, int qty) {
  return Uint8List.fromList([
    0x03,
    (start >> 8) & 0xFF, start & 0xFF,
    (qty >> 8) & 0xFF, qty & 0xFF,
  ]);
}

Uint8List _writeMultipleRegistersRequest(int start, List<int> registers) {
  final out = BytesBuilder();
  out.addByte(0x10);
  out.addByte((start >> 8) & 0xFF);
  out.addByte(start & 0xFF);
  out.addByte((registers.length >> 8) & 0xFF);
  out.addByte(registers.length & 0xFF);
  out.addByte(registers.length * 2);
  for (final r in registers) {
    out.addByte((r >> 8) & 0xFF);
    out.addByte(r & 0xFF);
  }
  return out.toBytes();
}

void main() {
  group('dotted-path type resolution (FC03 read)', () {
    test('a dotted INT32 struct-member entry decodes to the correct value at the correct width', () {
      final project = _motorProject();
      final server = ModbusServer(projectProvider: () => project);

      final resp = server.handle(ModbusFrame(
        transactionId: 1,
        unitId: 1,
        pdu: _readHoldingRequest(0, 2),
      ));

      // fc(1) + byteCount(1) + 2 registers(4 bytes) = 6 bytes total.
      expect(resp[0], 0x03);
      expect(resp[1], 4); // byte count for 2 registers
      final regs = [
        (resp[2] << 8) | resp[3],
        (resp[4] << 8) | resp[5],
      ];
      // Would decode as INT16 (only the first register, dropping the high
      // word) if the width/type fallback bug were still present.
      expect(decodeInt32(regs), 12345);
    });
  });

  group('root-force resolution for a dotted path (FC10 write)', () {
    // Scalar-guard regression: a forced COMPOSITE root (`Motor.value` is a
    // Map) is only reachable via a project persisted by an OLD build, before
    // forcing was gated to scalar tags. `readPath`'s force overlay in
    // `tag_resolver.dart` already ignores non-scalar forces, so Modbus must
    // match — otherwise a stale `isForced: true` on a struct tag would
    // silently block writes to its members here while reads sail through
    // unforced, an asymmetry between the read and write paths.
    test('forcing a COMPOSITE root tag does NOT skip a write to one of its members (scalar guard)', () {
      final project = _motorProject(forced: true);
      // Simulate legacy data: a composite (Map-valued) root tag persisted
      // with isForced true from before forcing was gated to scalars.
      expect(project.tags.first.value, isA<Map>());
      expect(project.tags.first.isForced, isTrue);
      final server = ModbusServer(projectProvider: () => project);

      final newRegs = encodeInt32(99999);
      final resp = server.handle(ModbusFrame(
        transactionId: 2,
        unitId: 1,
        pdu: _writeMultipleRegistersRequest(0, newRegs),
      ));

      // Success echo: fc (no exception bit) + start + qty, no exception code.
      expect(resp[0], 0x10);
      expect(resp.length, 5);
      expect(resp[0] & 0x80, 0);

      // The write must have been APPLIED — a forced composite root must not
      // block writes to its scalar members.
      final motor = project.tags.first;
      expect((motor.value as Map)['Speed'], 99999);
    });

    test('sanity: the SAME write applies normally when the root tag is NOT forced', () {
      final project = _motorProject(forced: false);
      final server = ModbusServer(projectProvider: () => project);

      final newRegs = encodeInt32(99999);
      final resp = server.handle(ModbusFrame(
        transactionId: 3,
        unitId: 1,
        pdu: _writeMultipleRegistersRequest(0, newRegs),
      ));

      expect(resp[0], 0x10);
      final motor = project.tags.first;
      expect((motor.value as Map)['Speed'], 99999);
    });
  });
}
