// Byte-exact fixtures for the Modbus MBAP + PDU codec
// (mobile/lib/protocols/modbus/modbus_pdu.dart). No hand-rolled server logic
// here — just the pure wire-format encode/decode helpers, verified against
// the Modbus Application Protocol v1.1b3 spec's function-code layouts.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/modbus/modbus_pdu.dart';

void main() {
  group('MBAP', () {
    test('parseMbap decodes a known FC03 request frame', () {
      final frame = Uint8List.fromList(
          [0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x01, 0x03, 0x00, 0x00, 0x00, 0x02]);
      final f = parseMbap(frame);
      expect(f, isNotNull);
      expect(f!.transactionId, 1);
      expect(f.unitId, 1);
      expect(f.pdu, [0x03, 0x00, 0x00, 0x00, 0x02]);
    });

    test('buildMbap wraps a PDU with the matching header', () {
      final pdu = Uint8List.fromList([0x03, 0x04, 0x12, 0x34, 0x56, 0x78]);
      final frame = buildMbap(7, 1, pdu);
      expect(frame, [0x00, 0x07, 0x00, 0x00, 0x00, 0x07, 0x01, 0x03, 0x04, 0x12, 0x34, 0x56, 0x78]);
    });

    test('parseMbap rejects a non-zero protocolId', () {
      final frame = Uint8List.fromList(
          [0x00, 0x01, 0x00, 0x01, 0x00, 0x06, 0x01, 0x03, 0x00, 0x00, 0x00, 0x02]);
      expect(parseMbap(frame), isNull);
    });

    test('parseMbap returns null on a truncated frame (header only)', () {
      expect(parseMbap(Uint8List.fromList([0x00, 0x01, 0x00, 0x00, 0x00])), isNull);
    });

    test('parseMbap returns null when the length field promises more bytes than present', () {
      final frame = Uint8List.fromList([0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x01, 0x03]);
      expect(parseMbap(frame), isNull);
    });
  });

  group('PDU response encoders', () {
    test('encodeReadRegistersResponse builds an exact FC03 response', () {
      final pdu = encodeReadRegistersResponse(0x03, [0x1234, 0x5678]);
      expect(pdu, [0x03, 0x04, 0x12, 0x34, 0x56, 0x78]);
    });

    test('encodeReadBitsResponse packs coils LSB-first', () {
      final pdu = encodeReadBitsResponse(0x01, [true, false, true]);
      expect(pdu, [0x01, 0x01, 0x05]);
    });

    test('encodeReadBitsResponse spans multiple bytes for >8 coils', () {
      // 9 coils, only the last one set -> byte0 = 0x00, byte1 = 0x01.
      final bits = List<bool>.filled(9, false);
      bits[8] = true;
      final pdu = encodeReadBitsResponse(0x02, bits);
      expect(pdu, [0x02, 0x02, 0x00, 0x01]);
    });

    test('encodeExceptionResponse sets the high bit of the function code', () {
      final pdu = encodeExceptionResponse(0x03, ModbusEx.illegalDataAddress);
      expect(pdu, [0x83, 0x02]);
    });
  });

  group('scalar register codecs', () {
    test('INT32 encodes hi-word-first', () {
      expect(encodeInt32(0x0001E240), [0x0001, 0xE240]);
    });

    test('INT32 round-trips positive and negative values', () {
      expect(decodeInt32(encodeInt32(0x0001E240)), 0x0001E240);
      expect(decodeInt32(encodeInt32(-1)), -1);
      expect(decodeInt32(encodeInt32(-123456)), -123456);
    });

    test('INT16 round-trips positive and negative values', () {
      expect(decodeInt16(encodeInt16(1234)), 1234);
      expect(decodeInt16(encodeInt16(-1)), -1);
    });

    test('FLOAT64 round-trips through 4 registers', () {
      const value = 3.14159265358979;
      final regs = encodeFloat64(value);
      expect(regs.length, 4);
      expect(decodeFloat64(regs), value);
    });

    test('FLOAT64 round-trips zero and negative values', () {
      expect(decodeFloat64(encodeFloat64(0.0)), 0.0);
      expect(decodeFloat64(encodeFloat64(-2.5)), -2.5);
    });
  });
}
