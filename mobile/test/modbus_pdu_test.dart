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

  group('word-order (wordSwap) register codecs', () {
    test('wordSwap=false (default) leaves the byte-exact hi-word-first fixtures unchanged', () {
      expect(encodeInt32(0x0001E240), [0x0001, 0xE240]);
      expect(encodeInt32(0x0001E240, wordSwap: false), [0x0001, 0xE240]);
      const value = 3.14159265358979;
      expect(encodeFloat64(value), encodeFloat64(value, wordSwap: false));
    });

    test('wordSwap=true reverses INT32 register order (low word first, "CDAB")', () {
      // 0x12345678 -> hi-word-first regs [0x1234, 0x5678]; word-swapped -> [0x5678, 0x1234].
      final normal = encodeInt32(0x12345678);
      expect(normal, [0x1234, 0x5678]);
      final swapped = encodeInt32(0x12345678, wordSwap: true);
      expect(swapped, [0x5678, 0x1234]);
    });

    test('wordSwap=true INT32 round-trips through encode/decode', () {
      for (final value in [0x12345678, -1, -123456, 0]) {
        final regs = encodeInt32(value, wordSwap: true);
        expect(decodeInt32(regs, wordSwap: true), value);
      }
    });

    test('decoding word-swapped registers WITHOUT wordSwap set produces the wrong value', () {
      // Sanity check that the flag actually matters — decoding swapped
      // registers as if they were normal-order must NOT silently agree.
      final swapped = encodeInt32(0x12345678, wordSwap: true);
      expect(decodeInt32(swapped), isNot(0x12345678));
      expect(decodeInt32(swapped, wordSwap: true), 0x12345678);
    });

    test('wordSwap=true reverses all 4 FLOAT64 registers', () {
      const value = 3.14159265358979;
      final normal = encodeFloat64(value);
      final swapped = encodeFloat64(value, wordSwap: true);
      expect(swapped, normal.reversed.toList());
    });

    test('wordSwap=true FLOAT64 round-trips through encode/decode', () {
      for (final value in [3.14159265358979, 0.0, -2.5]) {
        final regs = encodeFloat64(value, wordSwap: true);
        expect(decodeFloat64(regs, wordSwap: true), value);
      }
    });
  });

  group('byte-order (byteSwap) register codecs — four Modbus orderings', () {
    // 0x12345678 -> hi-word-first regs [0x1234, 0x5678] (registers "AB" "CD").
    const value = 0x12345678;

    test('ABCD: both wordSwap and byteSwap false (existing default fixture unchanged)', () {
      final regs = encodeInt32(value);
      expect(regs, [0x1234, 0x5678]);
      expect(encodeInt32(value, wordSwap: false, byteSwap: false), [0x1234, 0x5678]);
      expect(decodeInt32(regs), value);
    });

    test('CDAB: wordSwap=true, byteSwap=false (existing wordSwap-only fixture unchanged)', () {
      final regs = encodeInt32(value, wordSwap: true);
      expect(regs, [0x5678, 0x1234]);
      expect(encodeInt32(value, wordSwap: true, byteSwap: false), [0x5678, 0x1234]);
      expect(decodeInt32(regs, wordSwap: true), value);
    });

    test('BADC: wordSwap=false, byteSwap=true', () {
      final regs = encodeInt32(value, byteSwap: true);
      expect(regs, [0x3412, 0x7856]);
      expect(decodeInt32(regs, byteSwap: true), value);
    });

    test('DCBA: wordSwap=true, byteSwap=true', () {
      final regs = encodeInt32(value, wordSwap: true, byteSwap: true);
      expect(regs, [0x7856, 0x3412]);
      expect(decodeInt32(regs, wordSwap: true, byteSwap: true), value);
    });

    test('byteSwap=true round-trips INT32 through encode/decode for several values', () {
      for (final v in [0x12345678, -1, -123456, 0]) {
        for (final ws in [false, true]) {
          final regs = encodeInt32(v, wordSwap: ws, byteSwap: true);
          expect(decodeInt32(regs, wordSwap: ws, byteSwap: true), v);
        }
      }
    });

    test('byteSwap=true swaps the bytes of a single INT16 register', () {
      // 1234 = 0x04D2 -> big-endian register 0x04D2; byte-swapped -> 0xD204.
      final normal = encodeInt16(1234);
      expect(normal, [0x04D2]);
      final swapped = encodeInt16(1234, byteSwap: true);
      expect(swapped, [0xD204]);
      expect(decodeInt16(swapped, byteSwap: true), 1234);
    });

    test('byteSwap=true INT16 round-trips positive and negative values', () {
      for (final v in [1234, -1, 0, 32767, -32768]) {
        final regs = encodeInt16(v, byteSwap: true);
        expect(decodeInt16(regs, byteSwap: true), v);
      }
    });

    test('byteSwap=true swaps the bytes of every FLOAT64 register (word order unchanged)', () {
      const v = 3.14159265358979;
      final normal = encodeFloat64(v);
      final swapped = encodeFloat64(v, byteSwap: true);
      expect(swapped.length, 4);
      for (var i = 0; i < 4; i++) {
        final n = normal[i];
        final expectedSwapped = ((n & 0xFF) << 8) | ((n >> 8) & 0xFF);
        expect(swapped[i], expectedSwapped);
      }
      expect(decodeFloat64(swapped, byteSwap: true), v);
    });

    test('byteSwap=true combined with wordSwap FLOAT64 round-trips through encode/decode', () {
      for (final v in [3.14159265358979, 0.0, -2.5]) {
        for (final ws in [false, true]) {
          final regs = encodeFloat64(v, wordSwap: ws, byteSwap: true);
          expect(decodeFloat64(regs, wordSwap: ws, byteSwap: true), v);
        }
      }
    });

    test('decoding byte-swapped registers WITHOUT byteSwap set produces the wrong value', () {
      final swapped = encodeInt32(value, byteSwap: true);
      expect(decodeInt32(swapped), isNot(value));
      expect(decodeInt32(swapped, byteSwap: true), value);
    });
  });
}
