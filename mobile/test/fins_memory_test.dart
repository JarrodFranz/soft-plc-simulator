// Byte-exact fixtures for the FINS Memory Area Read/Write item codec
// (mobile/lib/protocols/fins/fins_memory.dart) — the layer that parses/builds
// the `text` payload carried inside a FinsFrame (see fins_frame.dart) for the
// Memory Area Read (0x0101) and Memory Area Write (0x0102) commands.
//
// CRITICAL: FINS multi-byte fields are BIG-ENDIAN. The most recently added
// protocol in this repo (EtherNet/IP, protocols/enip/) is little-endian —
// do not pattern-match it into this codec. A pure build -> parse round trip
// CANNOT catch an endianness bug (it cancels out perfectly even when fully
// broken), so the word-address fixture below uses two bytes that DIFFER
// (0x00, 0x64 -> 100) so a little-endian implementation fails instead of
// silently passing.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_memory.dart';

void main() {
  group('command + area code constants', () {
    test('carry their documented literal values', () {
      expect(kFinsCmdMemAreaRead, 0x0101);
      expect(kFinsCmdMemAreaWrite, 0x0102);
      expect(kFinsAreaDM, 0x82);
      expect(kFinsAreaCIO, 0xB0);
      expect(kFinsAreaWR, 0xB1);
      expect(kFinsAreaHR, 0xB2);
    });
  });

  group('parseMemAreaReadItem', () {
    test('decodes a hand-built 6-byte DM-area item, exact fields, '
        'wordAddress from two DIFFERING bytes (0x00,0x64 -> 100, NOT 0x6400)', () {
      final text = Uint8List.fromList([
        0x82, // area code: DM
        0x00, 0x64, // word address = 0x0064 = 100
        0x00, // bit
        0x00, 0x05, // number of items = 5
      ]);

      final item = parseMemAreaReadItem(text);
      expect(item, isNotNull);
      expect(item!.areaCode, kFinsAreaDM);
      expect(item.wordAddress, 100);
      expect(item.wordAddress, isNot(0x6400));
      expect(item.bitOffset, 0);
      expect(item.count, 5);
    });

    test('returns null for a text shorter than the 6-byte item spec, no throw', () {
      final tooShort = Uint8List.fromList([0x82, 0x00, 0x64, 0x00, 0x00]); // 5 bytes
      expect(() => parseMemAreaReadItem(tooShort), returnsNormally);
      expect(parseMemAreaReadItem(tooShort), isNull);

      final empty = Uint8List(0);
      expect(() => parseMemAreaReadItem(empty), returnsNormally);
      expect(parseMemAreaReadItem(empty), isNull);
    });

    test('accepts extra trailing bytes beyond the 6-byte item spec (ignored)', () {
      final text = Uint8List.fromList([0xB0, 0x00, 0x0A, 0x00, 0x00, 0x01, 0xFF, 0xFF]);
      final item = parseMemAreaReadItem(text);
      expect(item, isNotNull);
      expect(item!.areaCode, kFinsAreaCIO);
      expect(item.wordAddress, 10);
      expect(item.count, 1);
    });
  });

  group('parseMemAreaWriteItem', () {
    test('decodes a DM-area item spec plus 2 trailing write words, exact bytes', () {
      final text = Uint8List.fromList([
        0x82, // area code: DM
        0x00, 0x64, // word address = 100
        0x00, // bit
        0x00, 0x02, // number of items = 2
        0x12, 0x34, // write word 1
        0x00, 0x64, // write word 2 (differing bytes canary)
      ]);

      final result = parseMemAreaWriteItem(text);
      expect(result, isNotNull);
      expect(result!.item.areaCode, kFinsAreaDM);
      expect(result.item.wordAddress, 100);
      expect(result.item.bitOffset, 0);
      expect(result.item.count, 2);
      expect(result.writeData, equals(Uint8List.fromList([0x12, 0x34, 0x00, 0x64])));
    });

    test('returns null when the declared word count does not match the trailing bytes', () {
      final text = Uint8List.fromList([
        0x82, 0x00, 0x64, 0x00, 0x00, 0x02, // declares 2 words = 4 bytes
        0x12, 0x34, // only 1 word (2 bytes) present
      ]);
      expect(() => parseMemAreaWriteItem(text), returnsNormally);
      expect(parseMemAreaWriteItem(text), isNull);
    });

    test('returns null for a text shorter than the 6-byte item spec, no throw', () {
      final tooShort = Uint8List.fromList([0x82, 0x00, 0x64, 0x00, 0x00]); // 5 bytes
      expect(() => parseMemAreaWriteItem(tooShort), returnsNormally);
      expect(parseMemAreaWriteItem(tooShort), isNull);
    });

    test('accepts a zero-count write item with no trailing write words', () {
      final text = Uint8List.fromList([0x82, 0x00, 0x64, 0x00, 0x00, 0x00]);
      final result = parseMemAreaWriteItem(text);
      expect(result, isNotNull);
      expect(result!.item.count, 0);
      expect(result.writeData, equals(Uint8List(0)));
    });
  });

  group('bit-area codes + parseMemAreaWriteBitItem', () {
    test('bit-area constants carry their documented literal values', () {
      expect(kFinsAreaDMBit, 0x02);
      expect(kFinsAreaCIOBit, 0x30);
      expect(kFinsAreaWRBit, 0x31);
      expect(kFinsAreaHRBit, 0x32);
    });

    test('isFinsBitArea separates bit codes from word codes', () {
      for (final code in [kFinsAreaDMBit, kFinsAreaCIOBit, kFinsAreaWRBit, kFinsAreaHRBit]) {
        expect(isFinsBitArea(code), isTrue, reason: 'bit code 0x${code.toRadixString(16)}');
      }
      for (final code in [kFinsAreaDM, kFinsAreaCIO, kFinsAreaWR, kFinsAreaHR, 0x00, 0xFF]) {
        expect(isFinsBitArea(code), isFalse, reason: 'non-bit code 0x${code.toRadixString(16)}');
      }
    });

    test('finsWordAreaForBitArea maps every bit code to its word code, null otherwise', () {
      expect(finsWordAreaForBitArea(kFinsAreaDMBit), kFinsAreaDM);
      expect(finsWordAreaForBitArea(kFinsAreaCIOBit), kFinsAreaCIO);
      expect(finsWordAreaForBitArea(kFinsAreaWRBit), kFinsAreaWR);
      expect(finsWordAreaForBitArea(kFinsAreaHRBit), kFinsAreaHR);
      expect(finsWordAreaForBitArea(kFinsAreaDM), isNull);
      expect(finsWordAreaForBitArea(0x00), isNull);
    });

    // The exact 13-byte `text` of the 19-byte datagram Ignition's Omron FINS
    // driver sends for a single-Boolean write (observed 2026-07-21): 6-byte
    // item spec (DM BIT area, word 0, bit 0, count 1) + ONE data byte.
    test('decodes the Ignition single-bit DM write (1 byte per bit)', () {
      final text = Uint8List.fromList([0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01]);
      final result = parseMemAreaWriteBitItem(text);
      expect(result, isNotNull);
      expect(result!.item.areaCode, kFinsAreaDMBit);
      expect(result.item.wordAddress, 0);
      expect(result.item.bitOffset, 0);
      expect(result.item.count, 1);
      expect(result.writeData, equals(Uint8List.fromList([0x01])));
    });

    test('decodes a multi-bit write starting mid-word', () {
      // CIO bit area, word 0x0064, bit 5, count 3, bits [1, 0, 1].
      final text = Uint8List.fromList([0x30, 0x00, 0x64, 0x05, 0x00, 0x03, 0x01, 0x00, 0x01]);
      final result = parseMemAreaWriteBitItem(text);
      expect(result, isNotNull);
      expect(result!.item.areaCode, kFinsAreaCIOBit);
      expect(result.item.wordAddress, 0x64);
      expect(result.item.bitOffset, 5);
      expect(result.item.count, 3);
      expect(result.writeData, equals(Uint8List.fromList([0x01, 0x00, 0x01])));
    });

    test('returns null when the declared bit count does not match the trailing bytes', () {
      // Count says 2 bits but only 1 data byte follows — and vice versa.
      final tooFew = Uint8List.fromList([0x02, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01]);
      expect(parseMemAreaWriteBitItem(tooFew), isNull);
      final tooMany = Uint8List.fromList([0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00]);
      expect(parseMemAreaWriteBitItem(tooMany), isNull);
    });

    test('returns null for a text shorter than the 6-byte item spec, no throw', () {
      final tooShort = Uint8List.fromList([0x02, 0x00, 0x00, 0x00, 0x00]);
      expect(() => parseMemAreaWriteBitItem(tooShort), returnsNormally);
      expect(parseMemAreaWriteBitItem(tooShort), isNull);
    });

    // A word-area write of 1 word (2 data bytes) must NOT parse as a bit
    // write (count 1 would demand exactly 1 data byte) — and the Ignition
    // bit write must NOT parse as a word write (count 1 demands 2 bytes).
    // The dispatcher relies on this disjointness when it routes by area code.
    test('bit and word write layouts are mutually exclusive for the same count', () {
      final wordWrite = Uint8List.fromList([0x82, 0x00, 0x00, 0x00, 0x00, 0x01, 0xAB, 0xCD]);
      expect(parseMemAreaWriteBitItem(wordWrite), isNull);
      final bitWrite = Uint8List.fromList([0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01]);
      expect(parseMemAreaWriteItem(bitWrite), isNull);
    });
  });

  group('buildMemReadResponseData', () {
    test('round-trips a known big-endian word array against literal bytes', () {
      final words = Uint8List.fromList([0x00, 0x64, 0xAB, 0xCD]); // words: 100, 0xABCD
      final data = buildMemReadResponseData(words);
      expect(data, equals(Uint8List.fromList([0x00, 0x64, 0xAB, 0xCD])));
      expect(data, isNot(equals(Uint8List.fromList([0x64, 0x00, 0xCD, 0xAB]))));
    });

    test('handles empty input', () {
      final data = buildMemReadResponseData(Uint8List(0));
      expect(data, equals(Uint8List(0)));
    });
  });
}
