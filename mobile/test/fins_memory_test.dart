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
