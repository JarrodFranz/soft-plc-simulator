// Tests for the Modbus register-file handler
// (mobile/lib/protocols/modbus/modbus_pdu.dart's `ModbusServer`) against a
// live project + `ModbusMap`. Requests/responses are built/decoded via the
// Task 1 codec helpers (encodeInt32/encodeFloat64/encodeReadRegistersResponse/
// etc.) — no hand-rolled hex beyond the raw request PDUs under test.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/modbus/modbus_pdu.dart';

PlcProject _buildProject() {
  return PlcProject(
    id: 'x',
    name: 'X',
    controllerName: 'C',
    structDefs: const [],
    programs: const [],
    tasks: const [],
    hmis: const [],
    tags: [
      PlcTag(name: 'Coil0', path: 'Coil0', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'Discrete0', path: 'Discrete0', dataType: 'BOOL', value: true, ioType: 'SimulatedOutput'),
      PlcTag(name: 'Hold16', path: 'Hold16', dataType: 'INT16', value: 0, ioType: 'Internal'),
      PlcTag(name: 'Hold32', path: 'Hold32', dataType: 'INT32', value: 0, ioType: 'Internal'),
      PlcTag(name: 'InFloat', path: 'InFloat', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput'),
      PlcTag(name: 'RoHold', path: 'RoHold', dataType: 'INT16', value: 42, ioType: 'SimulatedOutput'),
    ],
    protocols: ProtocolSettings(
      modbus: ModbusProtocolConfig(
        enabled: true,
        map: ModbusMap(entries: [
          ModbusMapEntry(tag: 'Coil0', table: 'coil', address: 0, access: 'ReadWrite'),
          ModbusMapEntry(tag: 'Discrete0', table: 'discrete', address: 0, access: 'ReadOnly'),
          ModbusMapEntry(tag: 'Hold16', table: 'holding', address: 0, access: 'ReadWrite'),
          ModbusMapEntry(tag: 'Hold32', table: 'holding', address: 1, access: 'ReadWrite'),
          ModbusMapEntry(tag: 'InFloat', table: 'input', address: 0, access: 'ReadOnly'),
          ModbusMapEntry(tag: 'RoHold', table: 'holding', address: 10, access: 'ReadOnly'),
        ]),
      ),
    ),
  );
}

ModbusFrame _req(Uint8List pdu, {int transactionId = 1, int unitId = 1}) =>
    ModbusFrame(transactionId: transactionId, unitId: unitId, pdu: pdu);

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  late PlcProject project;
  late ModbusServer server;

  setUp(() {
    project = _buildProject();
    server = ModbusServer(projectProvider: () => project);
  });

  test('FC03 read holding [0,3) returns INT16 then live INT32 words', () {
    writePath(project, 'Hold16', 100);
    writePath(project, 'Hold32', 123456);
    final resp = server.handle(_req(_bytes([0x03, 0x00, 0x00, 0x00, 0x03])));
    final expected = encodeReadRegistersResponse(0x03, [100, ...encodeInt32(123456)]);
    expect(resp, expected);
  });

  test('FC04 read input [0,4) returns a live FLOAT64 across its 4 registers', () {
    writePath(project, 'InFloat', 2.5);
    final resp = server.handle(_req(_bytes([0x04, 0x00, 0x00, 0x00, 0x04])));
    final expected = encodeReadRegistersResponse(0x04, encodeFloat64(2.5));
    expect(resp, expected);
  });

  test('FC02 read discrete returns the live bool tag', () {
    final resp = server.handle(_req(_bytes([0x02, 0x00, 0x00, 0x00, 0x01])));
    expect(resp, encodeReadBitsResponse(0x02, [true]));
  });

  test('reads 0-fill unmapped gaps within a legal range', () {
    // Holding address 20 has no map entry.
    final resp = server.handle(_req(_bytes([0x03, 0x00, 0x14, 0x00, 0x01])));
    expect(resp, encodeReadRegistersResponse(0x03, [0]));
  });

  test('FC06 write holding 0 updates the INT16 tag via readPath', () {
    final req = _bytes([0x06, 0x00, 0x00, 0x00, 0x37]); // value 55
    final resp = server.handle(_req(req));
    expect(resp, req); // normal echo
    expect(readPath(project, 'Hold16'), 55);
  });

  test('FC05 write coil 0 ON sets the bool tag', () {
    final req = _bytes([0x05, 0x00, 0x00, 0xFF, 0x00]);
    final resp = server.handle(_req(req));
    expect(resp, req);
    expect(readPath(project, 'Coil0'), true);
  });

  test('FC05 with a value other than 0xFF00/0x0000 -> illegal data value', () {
    final resp = server.handle(_req(_bytes([0x05, 0x00, 0x00, 0x12, 0x34])));
    expect(resp, encodeExceptionResponse(0x05, ModbusEx.illegalDataValue));
  });

  test('write to an unmapped coil address -> illegal data address', () {
    final resp = server.handle(_req(_bytes([0x05, 0x00, 0x05, 0xFF, 0x00])));
    expect(resp, encodeExceptionResponse(0x05, ModbusEx.illegalDataAddress));
  });

  test('write to a ReadOnly-mapped holding address -> illegal data address', () {
    final resp = server.handle(_req(_bytes([0x06, 0x00, 0x0A, 0x00, 0x01])));
    expect(resp, encodeExceptionResponse(0x06, ModbusEx.illegalDataAddress));
    expect(readPath(project, 'RoHold'), 42); // unchanged
  });

  test('write a forced tag: value unchanged but normal echo returned', () {
    final tag = project.tags.firstWhere((t) => t.name == 'Coil0');
    tag.isForced = true;
    tag.forcedValue = false;
    final req = _bytes([0x05, 0x00, 0x00, 0xFF, 0x00]);
    final resp = server.handle(_req(req));
    expect(resp, req); // still echoes success
    expect(readPath(project, 'Coil0'), false); // write silently skipped
  });

  test('FC06 to holding address 1 (part of the multi-register INT32) -> illegal data value', () {
    final resp = server.handle(_req(_bytes([0x06, 0x00, 0x01, 0x00, 0x01])));
    expect(resp, encodeExceptionResponse(0x06, ModbusEx.illegalDataValue));
  });

  test('FC03 with quantity 0 -> illegal data value', () {
    final resp = server.handle(_req(_bytes([0x03, 0x00, 0x00, 0x00, 0x00])));
    expect(resp, encodeExceptionResponse(0x03, ModbusEx.illegalDataValue));
  });

  test('FC03 with quantity 126 (over the 125 register cap) -> illegal data value', () {
    final resp = server.handle(_req(_bytes([0x03, 0x00, 0x00, 0x00, 0x7E])));
    expect(resp, encodeExceptionResponse(0x03, ModbusEx.illegalDataValue));
  });

  test('FC01 with quantity 2001 (over the 2000 coil cap) -> illegal data value', () {
    final resp = server.handle(_req(_bytes([0x01, 0x00, 0x00, 0x07, 0xD1])));
    expect(resp, encodeExceptionResponse(0x01, ModbusEx.illegalDataValue));
  });

  test('FC0F writes multiple coils atomically when all addresses are mapped+writable', () {
    // Only Coil0 (address 0) is mapped in this project; write qty=1 starting there.
    final req = _bytes([0x0F, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01]);
    final resp = server.handle(_req(req));
    expect(resp, _bytes([0x0F, 0x00, 0x00, 0x00, 0x01]));
    expect(readPath(project, 'Coil0'), true);
  });

  test('FC0F touching an unmapped coil address -> illegal data address, no partial write', () {
    final req = _bytes([0x0F, 0x00, 0x00, 0x00, 0x02, 0x01, 0x03]); // addr 0 (mapped) + addr 1 (unmapped)
    final resp = server.handle(_req(req));
    expect(resp, encodeExceptionResponse(0x0F, ModbusEx.illegalDataAddress));
    expect(readPath(project, 'Coil0'), false); // untouched — request rejected atomically
  });

  test('FC16 covering exactly the INT32 tag\'s full 2-register span writes it', () {
    final regs = encodeInt32(-42); // [hi, lo]
    final req = _bytes([
      0x10, 0x00, 0x01, 0x00, 0x02, 0x04, //
      (regs[0] >> 8) & 0xFF, regs[0] & 0xFF,
      (regs[1] >> 8) & 0xFF, regs[1] & 0xFF,
    ]);
    final resp = server.handle(_req(req));
    expect(resp, _bytes([0x10, 0x00, 0x01, 0x00, 0x02]));
    expect(readPath(project, 'Hold32'), -42);
  });

  test('FC16 partially overlapping the INT32 tag\'s span -> illegal data value', () {
    // Range [1,2) only covers the hi word of the 2-register Hold32 entry.
    final req = _bytes([0x10, 0x00, 0x01, 0x00, 0x01, 0x02, 0x00, 0x00]);
    final resp = server.handle(_req(req));
    expect(resp, encodeExceptionResponse(0x10, ModbusEx.illegalDataValue));
  });

  test('unsupported function code -> illegal function', () {
    final resp = server.handle(_req(_bytes([0x07])));
    expect(resp, encodeExceptionResponse(0x07, ModbusEx.illegalFunction));
  });

  test('handle never throws on a garbage-short PDU', () {
    final resp = server.handle(_req(_bytes([0x03, 0x00])));
    expect(resp, encodeExceptionResponse(0x03, ModbusEx.serverFailure));
  });

  group('wordSwap register order (server-level)', () {
    test('wordSwap=true: FC03 read of the INT32 tag returns low-word-first registers', () {
      project.protocols!.modbus!.wordSwap = true;
      writePath(project, 'Hold32', 123456);
      final resp = server.handle(_req(_bytes([0x03, 0x00, 0x01, 0x00, 0x02])))!;
      final expected = encodeReadRegistersResponse(0x03, encodeInt32(123456, wordSwap: true));
      expect(resp, expected);
      // Sanity: differs from the default (non-swapped) encoding.
      expect(resp, isNot(encodeReadRegistersResponse(0x03, encodeInt32(123456))));
    });

    test('wordSwap=true: FC16 write of word-swapped registers decodes back to the correct INT32', () {
      project.protocols!.modbus!.wordSwap = true;
      final regs = encodeInt32(-42, wordSwap: true); // [lo, hi]
      final req = _bytes([
        0x10, 0x00, 0x01, 0x00, 0x02, 0x04, //
        (regs[0] >> 8) & 0xFF, regs[0] & 0xFF,
        (regs[1] >> 8) & 0xFF, regs[1] & 0xFF,
      ]);
      final resp = server.handle(_req(req));
      expect(resp, _bytes([0x10, 0x00, 0x01, 0x00, 0x02]));
      expect(readPath(project, 'Hold32'), -42);
    });

    test('wordSwap=true: FC04 read of the FLOAT64 tag returns reversed registers', () {
      project.protocols!.modbus!.wordSwap = true;
      writePath(project, 'InFloat', 2.5);
      final resp = server.handle(_req(_bytes([0x04, 0x00, 0x00, 0x00, 0x04])));
      final expected = encodeReadRegistersResponse(0x04, encodeFloat64(2.5, wordSwap: true));
      expect(resp, expected);
    });

    test('wordSwap=false (default): behavior is byte-identical to before this feature', () {
      writePath(project, 'Hold32', 123456);
      final resp = server.handle(_req(_bytes([0x03, 0x00, 0x01, 0x00, 0x02])));
      final expected = encodeReadRegistersResponse(0x03, encodeInt32(123456));
      expect(resp, expected);
    });
  });

  group('byteSwap register order (server-level)', () {
    test('byteSwap=true: FC03 read of the INT32 tag returns byte-swapped registers ("BADC")', () {
      project.protocols!.modbus!.byteSwap = true;
      writePath(project, 'Hold32', 123456);
      final resp = server.handle(_req(_bytes([0x03, 0x00, 0x01, 0x00, 0x02])))!;
      final expected = encodeReadRegistersResponse(0x03, encodeInt32(123456, byteSwap: true));
      expect(resp, expected);
      // Sanity: differs from the default (unswapped) encoding.
      expect(resp, isNot(encodeReadRegistersResponse(0x03, encodeInt32(123456))));
    });

    test('byteSwap=true + wordSwap=true: FC03 read of the INT32 tag returns "DCBA" registers', () {
      project.protocols!.modbus!.wordSwap = true;
      project.protocols!.modbus!.byteSwap = true;
      writePath(project, 'Hold32', 123456);
      final resp = server.handle(_req(_bytes([0x03, 0x00, 0x01, 0x00, 0x02])))!;
      final expected =
          encodeReadRegistersResponse(0x03, encodeInt32(123456, wordSwap: true, byteSwap: true));
      expect(resp, expected);
    });

    test('byteSwap=true: FC16 write of byte-swapped registers decodes back to the correct INT32', () {
      project.protocols!.modbus!.byteSwap = true;
      final regs = encodeInt32(-42, byteSwap: true); // [swap(hi), swap(lo)]
      final req = _bytes([
        0x10, 0x00, 0x01, 0x00, 0x02, 0x04, //
        (regs[0] >> 8) & 0xFF, regs[0] & 0xFF,
        (regs[1] >> 8) & 0xFF, regs[1] & 0xFF,
      ]);
      final resp = server.handle(_req(req));
      expect(resp, _bytes([0x10, 0x00, 0x01, 0x00, 0x02]));
      expect(readPath(project, 'Hold32'), -42);
    });

    test('byteSwap=true: FC04 read of the FLOAT64 tag returns byte-swapped registers', () {
      project.protocols!.modbus!.byteSwap = true;
      writePath(project, 'InFloat', 2.5);
      final resp = server.handle(_req(_bytes([0x04, 0x00, 0x00, 0x00, 0x04])));
      final expected = encodeReadRegistersResponse(0x04, encodeFloat64(2.5, byteSwap: true));
      expect(resp, expected);
    });

    test('byteSwap=true: FC06 single-register write decodes byte-swapped INT16', () {
      project.protocols!.modbus!.byteSwap = true;
      final reg = encodeInt16(55, byteSwap: true)[0]; // byte-swapped register for value 55
      final req = _bytes([0x06, 0x00, 0x00, (reg >> 8) & 0xFF, reg & 0xFF]);
      final resp = server.handle(_req(req));
      expect(resp, req); // normal echo
      expect(readPath(project, 'Hold16'), 55);
    });

    test('byteSwap=false (default): behavior is byte-identical to before this feature', () {
      writePath(project, 'Hold32', 123456);
      final resp = server.handle(_req(_bytes([0x03, 0x00, 0x01, 0x00, 0x02])));
      final expected = encodeReadRegistersResponse(0x03, encodeInt32(123456));
      expect(resp, expected);
    });
  });

  group('unitId filtering (server-level)', () {
    test('unitId=255 (default, "any"): serves requests regardless of the request unit id', () {
      final resp1 = server.handle(_req(_bytes([0x03, 0x00, 0x00, 0x00, 0x01]), unitId: 1));
      final resp42 = server.handle(_req(_bytes([0x03, 0x00, 0x00, 0x00, 0x01]), unitId: 42));
      expect(resp1, isNotNull);
      expect(resp42, isNotNull);
      expect(resp1, resp42);
    });

    test('unitId configured to 5: a matching request unit id is served', () {
      project.protocols!.modbus!.unitId = 5;
      final resp = server.handle(_req(_bytes([0x03, 0x00, 0x00, 0x00, 0x01]), unitId: 5));
      expect(resp, isNotNull);
    });

    test('unitId configured to 5: a mismatched, non-broadcast request unit id gets no response', () {
      project.protocols!.modbus!.unitId = 5;
      final resp = server.handle(_req(_bytes([0x03, 0x00, 0x00, 0x00, 0x01]), unitId: 7));
      expect(resp, isNull);
    });

    test('unitId configured to 5: broadcast (unit id 0) is still answered', () {
      project.protocols!.modbus!.unitId = 5;
      final resp = server.handle(_req(_bytes([0x03, 0x00, 0x00, 0x00, 0x01]), unitId: 0));
      expect(resp, isNotNull);
    });
  });
}
