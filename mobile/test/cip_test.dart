// Byte-exact fixtures for the CIP messaging codec
// (mobile/lib/protocols/enip/cip.dart): request/response envelopes, EPATH
// segment parsing/building (including the ANSI Extended Symbol segment used
// for symbolic (named) tag addressing, including member paths), and the CIP data-type codec.
// Verified against public CIP specification material.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';

Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  group('parseCipRequest', () {
    test('parses a hand-built Read Tag request (symbol path "Motor_Run")', () {
      // "Motor_Run" is 9 bytes (odd) -> ANSI Extended Symbol segment is
      // 0x91, 0x09, 9 name bytes, 1 pad byte = 12 bytes = 6 words.
      final nameBytes = 'Motor_Run'.codeUnits;
      expect(nameBytes.length, 9);
      final pathBytes = _u8([0x91, 0x09, ...nameBytes, 0x00]);
      expect(pathBytes.length, 12);
      expect(pathBytes.length.isEven, isTrue);

      final requestBytes = _u8([
        0x4C, // service = Read Tag Service
        0x06, // pathWords = 6 (12 bytes / 2)
        ...pathBytes,
        0x01, 0x00, // service data: element count = 1, LE
      ]);

      final request = parseCipRequest(requestBytes);
      expect(request, isNotNull);
      expect(request!.service, 0x4C);
      expect(request.path.length, 1);
      expect(request.path[0], CipPathSegment.symbol('Motor_Run'));
      expect(request.data, [0x01, 0x00]);
    });

    test('returns null on truncated input (declared pathWords exceeds available bytes)', () {
      final requestBytes = _u8([
        0x4C, // service
        0x06, // pathWords = 6 (needs 12 path bytes)
        0x91, 0x09, // only 2 path bytes actually present
      ]);
      expect(parseCipRequest(requestBytes), isNull);
    });

    test('returns null on an empty buffer', () {
      expect(parseCipRequest(Uint8List(0)), isNull);
    });

    test('returns null on a single-byte buffer (missing pathWords)', () {
      expect(parseCipRequest(_u8([0x4C])), isNull);
    });
  });

  group('EPATH — ANSI Extended Symbol segment', () {
    test('odd-length (9-char) name round-trips through buildEpath/parseEpath and occupies an even byte count', () {
      final segments = [CipPathSegment.symbol('Motor_Run')];
      final built = buildEpath(segments);

      expect(built.length, 12); // 0x91 + len + 9 name bytes + 1 pad byte
      expect(built.length.isEven, isTrue);
      expect(built[0], 0x91);
      expect(built[1], 9);
      expect(built[11], 0x00); // explicit pad byte

      final wordLen = built.length ~/ 2;
      final parsed = parseEpath(built, wordLen);
      expect(parsed, isNotNull);
      expect(parsed!.length, 1);
      expect(parsed[0], CipPathSegment.symbol('Motor_Run'));
    });

    test('even-length name has no pad byte', () {
      final segments = [CipPathSegment.symbol('Tank')]; // 4 chars, even
      final built = buildEpath(segments);
      expect(built.length, 6); // 0x91 + len + 4 name bytes, no pad
      expect(built.length.isEven, isTrue);

      final parsed = parseEpath(built, built.length ~/ 2);
      expect(parsed, isNotNull);
      expect(parsed![0], CipPathSegment.symbol('Tank'));
    });

    test('multi-segment member path ("Tank.Level") parses to two ordered symbol segments', () {
      final segments = [CipPathSegment.symbol('Tank'), CipPathSegment.symbol('Level')];
      final built = buildEpath(segments);

      final parsed = parseEpath(built, built.length ~/ 2);
      expect(parsed, isNotNull);
      expect(parsed!.length, 2);
      expect(parsed[0], CipPathSegment.symbol('Tank'));
      expect(parsed[1], CipPathSegment.symbol('Level'));
    });

    test('class/instance/attribute logical segments round-trip (8-bit form)', () {
      final segments = [
        CipPathSegment.classId(0x8C),
        CipPathSegment.instanceId(0x01),
        CipPathSegment.attributeId(0x03),
      ];
      final built = buildEpath(segments);
      expect(built, [0x20, 0x8C, 0x24, 0x01, 0x30, 0x03]);

      final parsed = parseEpath(built, built.length ~/ 2);
      expect(parsed, isNotNull);
      expect(parsed, segments);
    });

    test('class/instance logical segments round-trip (16-bit extended form)', () {
      final segments = [CipPathSegment.classId(0x1234), CipPathSegment.instanceId(0xABCD)];
      final built = buildEpath(segments);

      final parsed = parseEpath(built, built.length ~/ 2);
      expect(parsed, isNotNull);
      expect(parsed, segments);
    });

    test('parseEpath returns null on truncated input (declared wordLen exceeds available bytes)', () {
      final built = _u8([0x91, 0x09, ...'Motor_Run'.codeUnits, 0x00]);
      // Ask for one more word than is actually present.
      expect(parseEpath(built, (built.length ~/ 2) + 1), isNull);
    });

    test('parseEpath returns null on an unrecognized segment type', () {
      expect(parseEpath(_u8([0xFF, 0x00]), 1), isNull);
    });

    test('parseEpath returns null on an empty buffer with nonzero wordLen', () {
      expect(parseEpath(Uint8List(0), 1), isNull);
    });

    test('parseEpath returns null (no throw) when segment nameLen overruns the path region', () {
      // Construct a buffer where the outer bulk length check (data.length >= byteLen)
      // passes, but a segment's inner nameLen field claims more bytes than remain
      // within the path boundary. The buffer is exactly 4 bytes; wordLen=2 means
      // 4 bytes total path, so the outer check passes. But the symbol segment
      // has 0x91 (ANSI Extended Symbol), 0xFF (nameLen=255), followed by 2 data
      // bytes. The inner check should catch that nameLen (255) far exceeds what
      // remains in the path region (only 2 bytes left after the header).
      final buffer = _u8([0x91, 0xFF, 0x41, 0x42]);
      expect(buffer.length, 4);
      expect(parseEpath(buffer, 2), isNull);
    });
  });

  group('CIP response', () {
    test('buildCipResponse sets service | 0x80 and the general status, and appends data verbatim', () {
      final resp = CipResponse(service: 0x4C, generalStatus: kCipStatusSuccess, data: _u8([0xAA, 0xBB, 0xCC]));
      final built = buildCipResponse(resp);

      expect(built.length, 4 + 3);
      expect(built[0], 0x4C | 0x80);
      expect(built[1], 0x00); // reserved
      expect(built[2], kCipStatusSuccess);
      expect(built[3], 0x00); // additional status words = 0
      expect(built.sublist(4), [0xAA, 0xBB, 0xCC]);
    });

    test('buildCipResponse reflects a non-success general status (privilege violation)', () {
      final resp = CipResponse(service: 0x4D, generalStatus: kCipStatusPrivilegeViolation, data: Uint8List(0));
      final built = buildCipResponse(resp);

      expect(built, [0x4D | 0x80, 0x00, kCipStatusPrivilegeViolation, 0x00]);
    });
  });

  group('cipTypeForTagType', () {
    test('maps all six app tag types', () {
      expect(cipTypeForTagType('BOOL'), kCipTypeBool);
      expect(cipTypeForTagType('INT16'), kCipTypeInt);
      expect(cipTypeForTagType('INT32'), kCipTypeDint);
      expect(cipTypeForTagType('INT64'), kCipTypeLint);
      expect(cipTypeForTagType('FLOAT64'), kCipTypeReal);
      expect(cipTypeForTagType('STRING'), isNull);
    });

    test('returns null for an unknown tag type', () {
      expect(cipTypeForTagType('NOT_A_TYPE'), isNull);
    });
  });

  group('encodeCipValue / decodeCipValue round-trips', () {
    test('BOOL', () {
      final encodedTrue = encodeCipValue(kCipTypeBool, true);
      expect(encodedTrue, isNotNull);
      expect(decodeCipValue(kCipTypeBool, encodedTrue!), true);

      final encodedFalse = encodeCipValue(kCipTypeBool, false);
      expect(encodedFalse, isNotNull);
      expect(decodeCipValue(kCipTypeBool, encodedFalse!), false);
    });

    test('INT (INT16)', () {
      final encoded = encodeCipValue(kCipTypeInt, -1234);
      expect(encoded, isNotNull);
      expect(encoded!.length, 2);
      expect(decodeCipValue(kCipTypeInt, encoded), -1234);
    });

    test('DINT (INT32)', () {
      final encoded = encodeCipValue(kCipTypeDint, -123456789);
      expect(encoded, isNotNull);
      expect(encoded!.length, 4);
      expect(decodeCipValue(kCipTypeDint, encoded), -123456789);
    });

    test('LINT (INT64)', () {
      final encoded = encodeCipValue(kCipTypeLint, -1234567890123);
      expect(encoded, isNotNull);
      expect(encoded!.length, 8);
      expect(decodeCipValue(kCipTypeLint, encoded), -1234567890123);
    });

    test('REAL narrows a double to single precision (FLOAT64 -> CIP REAL 0xCA)', () {
      const value = 3.14159265358979; // full double precision
      final encoded = encodeCipValue(kCipTypeReal, value);
      expect(encoded, isNotNull);
      expect(encoded!.length, 4); // single-precision (4 bytes), not 8

      final decoded = decodeCipValue(kCipTypeReal, encoded);
      expect(decoded, isA<double>());
      // Narrowed through IEEE-754 single precision, so not exactly equal to
      // the original double -- assert within single-precision tolerance.
      expect(decoded as double, closeTo(value, 1e-6));
      expect(decoded, isNot(equals(value)));
    });

    test('decodeCipValue returns null for wrong-length input rather than throwing', () {
      expect(decodeCipValue(kCipTypeBool, Uint8List(0)), isNull);
      expect(decodeCipValue(kCipTypeInt, Uint8List(1)), isNull);
      expect(decodeCipValue(kCipTypeDint, Uint8List(3)), isNull);
      expect(decodeCipValue(kCipTypeLint, Uint8List(7)), isNull);
      expect(decodeCipValue(kCipTypeReal, Uint8List(2)), isNull);
    });

    test('decodeCipValue returns null for an unrecognized type code', () {
      expect(decodeCipValue(0xFF, _u8([0x01])), isNull);
    });

    test('encodeCipValue returns null for a value of the wrong Dart type', () {
      expect(encodeCipValue(kCipTypeBool, 1), isNull);
      expect(encodeCipValue(kCipTypeInt, 'nope'), isNull);
      expect(encodeCipValue(kCipTypeReal, true), isNull);
    });
  });
}
