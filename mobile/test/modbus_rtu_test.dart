import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/modbus/modbus_rtu.dart';

Uint8List _b(List<int> v) => Uint8List.fromList(v);

void main() {
  test('crc16Modbus matches the CRC catalogue check value', () {
    // CRC-16/MODBUS check value for the ASCII string "123456789" is 0x4B37.
    final data = _b('123456789'.codeUnits);
    expect(crc16Modbus(data), 0x4B37);
  });

  test('buildRtu appends CRC low byte first and parseRtu round-trips', () {
    final pdu = _b([0x03, 0x00, 0x00, 0x00, 0x01]); // read 1 holding register
    final frame = buildRtu(0x11, pdu);
    expect(frame.length, 1 + pdu.length + 2);
    expect(frame[0], 0x11);
    final crc = crc16Modbus(_b(frame.sublist(0, frame.length - 2)));
    expect(frame[frame.length - 2], crc & 0xFF, reason: 'CRC low byte first');
    expect(frame[frame.length - 1], (crc >> 8) & 0xFF);

    final parsed = parseRtu(frame);
    expect(parsed, isNotNull);
    expect(parsed!.unitId, 0x11);
    expect(parsed.pdu, pdu);
    expect(parsed.transactionId, 0, reason: 'RTU has no transaction id');
  });

  test('parseRtu rejects a corrupted CRC and a truncated frame', () {
    final frame = buildRtu(0x01, _b([0x03, 0x00, 0x00, 0x00, 0x01]));
    final bad = Uint8List.fromList(frame)..[frame.length - 1] ^= 0xFF;
    expect(parseRtu(bad), isNull);
    expect(parseRtu(_b(frame.sublist(0, 3))), isNull);
  });

  test('rtuRequestLength: fixed-size function codes are 8 bytes total', () {
    for (final fc in [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]) {
      expect(rtuRequestLength(_b([0x01, fc])), 8, reason: 'fc 0x${fc.toRadixString(16)}');
    }
  });

  test('rtuRequestLength: 0x0F/0x10 need byteCount, then 9 + byteCount', () {
    // unit, fc, addrHi, addrLo, qtyHi, qtyLo, byteCount
    expect(rtuRequestLength(_b([0x01, 0x10, 0x00, 0x00, 0x00, 0x02])), isNull,
        reason: 'byteCount not buffered yet');
    expect(rtuRequestLength(_b([0x01, 0x10, 0x00, 0x00, 0x00, 0x02, 0x04])), 13,
        reason: '9 + byteCount(4)');
    expect(rtuRequestLength(_b([0x01, 0x0F, 0x00, 0x00, 0x00, 0x08, 0x01])), 10);
  });

  test('rtuRequestLength: null while undecidable, -1 for unsupported fc', () {
    expect(rtuRequestLength(_b([0x01])), isNull, reason: 'no function code yet');
    expect(rtuRequestLength(_b([])), isNull);
    expect(rtuRequestLength(_b([0x01, 0x63])), -1, reason: 'unsupported fc');
  });
}
