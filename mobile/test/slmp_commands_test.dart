// Byte-exact fixtures for the SLMP 3E Batch Read/Write command codec
// (mobile/lib/protocols/slmp/slmp_commands.dart) — the layer that parses/
// builds the command-data payload carried inside an SlmpFrame.data (see
// slmp_frame.dart) for the Batch Read (0x0401) and Batch Write (0x1401)
// word commands. This file does not touch the fixed routing header or the
// command/subcommand envelope itself — that is slmp_frame.dart's job.
//
// CRITICAL: SLMP is LITTLE-ENDIAN throughout, including the 3-byte device
// number. The two area protocols built immediately before this one in this
// repo — S7comm (protocols/s7/) and Omron FINS (protocols/fins/) — are both
// BIG-ENDIAN. Do not pattern-match an `Endian.big` from either neighbouring
// file into this one. A pure build -> parse round trip CANNOT catch an
// endianness bug (it cancels out perfectly even when fully broken), so the
// device-number fixture below uses bytes that DIFFER across positions
// (0x00, 0x01, 0x00 -> 256, NOT a big-endian misread) so a big-endian
// implementation fails instead of silently passing.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_commands.dart';

void main() {
  group('command/subcommand + device code constants', () {
    test('carry their documented literal values', () {
      expect(kSlmpCmdBatchReadWord, 0x0401);
      expect(kSlmpCmdBatchWriteWord, 0x1401);
      expect(kSlmpSubcmdWord, 0x0000);
      expect(kSlmpSubcmdBit, 0x0001);
      expect(kSlmpDevD, 0xA8);
      expect(kSlmpDevM, 0x90);
      expect(kSlmpDevW, 0xB4);
      expect(kSlmpDevR, 0xAF);
    });
  });

  group('parseBatchReadRequest', () {
    test('decodes a hand-built 6-byte device spec, exact fields, '
        'deviceNumber 0x64,0x00,0x00 (LE) -> 100', () {
      final data = Uint8List.fromList([
        0x64, 0x00, 0x00, // device number = 100 (LE)
        0xA8, // device code: D
        0x05, 0x00, // point count = 5 (LE)
      ]);

      final spec = parseBatchReadRequest(data);
      expect(spec, isNotNull);
      expect(spec!.deviceNumber, 100);
      expect(spec.deviceCode, kSlmpDevD);
      expect(spec.pointCount, 5);
    });

    test('decodes deviceNumber from three FULLY ASYMMETRIC bytes: '
        '0x01,0x02,0x03 (LE) -> 0x030201 = 197121, catches byte-swap bugs', () {
      final data = Uint8List.fromList([
        0x01, 0x02, 0x03, // device number = 0x030201 = 197121 (LE)
        0x90, // device code: M
        0x01, 0x00, // point count = 1
      ]);

      final spec = parseBatchReadRequest(data);
      expect(spec, isNotNull);
      expect(spec!.deviceNumber, 197121);
      expect(spec.deviceNumber, isNot(0x010203)); // canary: full byte reversal (big-endian) would give 66051
      expect(spec.deviceCode, kSlmpDevM);
    });

    test('returns null for command data shorter than the 6-byte device spec, no throw', () {
      final tooShort = Uint8List.fromList([0x64, 0x00, 0x00, 0xA8, 0x05]); // 5 bytes
      expect(() => parseBatchReadRequest(tooShort), returnsNormally);
      expect(parseBatchReadRequest(tooShort), isNull);

      final empty = Uint8List(0);
      expect(() => parseBatchReadRequest(empty), returnsNormally);
      expect(parseBatchReadRequest(empty), isNull);
    });

    test('accepts extra trailing bytes beyond the 6-byte device spec (ignored)', () {
      final data = Uint8List.fromList([0x0A, 0x00, 0x00, 0xB4, 0x02, 0x00, 0xFF, 0xFF]);
      final spec = parseBatchReadRequest(data);
      expect(spec, isNotNull);
      expect(spec!.deviceNumber, 10);
      expect(spec.deviceCode, kSlmpDevW);
      expect(spec.pointCount, 2);
    });
  });

  group('parseBatchWriteRequest', () {
    test('decodes a device spec plus 2 trailing write words, exact bytes', () {
      final data = Uint8List.fromList([
        0x64, 0x00, 0x00, // device number = 100
        0xA8, // device code: D
        0x02, 0x00, // point count = 2
        0x34, 0x12, // write word 1
        0x00, 0x01, // write word 2 (differing bytes canary)
      ]);

      final result = parseBatchWriteRequest(data);
      expect(result, isNotNull);
      expect(result!.spec.deviceNumber, 100);
      expect(result.spec.deviceCode, kSlmpDevD);
      expect(result.spec.pointCount, 2);
      expect(result.writeData, equals(Uint8List.fromList([0x34, 0x12, 0x00, 0x01])));
    });

    test('returns null (BEFORE any slice) when a write declares 2 points '
        'but carries only 1 word of data — bounds check, not a crash', () {
      final data = Uint8List.fromList([
        0x64, 0x00, 0x00, 0xA8, // device spec
        0x02, 0x00, // declares 2 points = 4 bytes
        0x34, 0x12, // only 1 word (2 bytes) present
      ]);
      expect(() => parseBatchWriteRequest(data), returnsNormally);
      expect(parseBatchWriteRequest(data), isNull);
    });

    test('returns null for command data shorter than the 6-byte device spec, no throw', () {
      final tooShort = Uint8List.fromList([0x64, 0x00, 0x00, 0xA8, 0x02]); // 5 bytes
      expect(() => parseBatchWriteRequest(tooShort), returnsNormally);
      expect(parseBatchWriteRequest(tooShort), isNull);
    });

    test('accepts a zero-point write item with no trailing write words', () {
      final data = Uint8List.fromList([0x64, 0x00, 0x00, 0xA8, 0x00, 0x00]);
      final result = parseBatchWriteRequest(data);
      expect(result, isNotNull);
      expect(result!.spec.pointCount, 0);
      expect(result.writeData, equals(Uint8List(0)));
    });
  });

  group('buildBatchReadResponseData', () {
    test('round-trips known little-endian words against literal bytes', () {
      final words = Uint8List.fromList([0x64, 0x00, 0xCD, 0xAB]); // words: 100, 0xABCD
      final data = buildBatchReadResponseData(words);
      expect(data, equals(Uint8List.fromList([0x64, 0x00, 0xCD, 0xAB])));
      expect(data, isNot(equals(Uint8List.fromList([0x00, 0x64, 0xAB, 0xCD]))));
    });

    test('handles empty input', () {
      final data = buildBatchReadResponseData(Uint8List(0));
      expect(data, equals(Uint8List(0)));
    });
  });
}
