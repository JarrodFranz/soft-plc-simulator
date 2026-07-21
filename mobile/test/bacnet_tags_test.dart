// Byte-exact fixtures for the BACnet primitive tag codec
// (mobile/lib/protocols/bacnet/bacnet_tags.dart) — application-tagged and
// context-tagged primitive values, plus opening/closing constructed tags.
//
// THE TAG-STRUCTURE TRAP: a build -> parse round trip through our OWN codec
// proves nothing here — a symmetric bug (e.g. length-prefix off-by-one, or
// swapped tag-number/class-bit nibbles) cancels out and passes silently.
// Every fixture below asserts literal hand-built octets in BOTH directions:
// encode-and-compare-bytes, and separately decode-hand-built-bytes-and-check
// fields. None of these tests feed an encoder's own output into the decoder
// as the only check.
//
// DEVIATION NOTE (see task-1-report.md for the full write-up): the plan's
// worked example for the 40-bit Protocol_Services_Supported bitstring
// (`0x85 0x06 0x00 0x00 0x0B 0x02 0x00 0x20`) is internally inconsistent with
// the plan's OWN stated bit-numbering formula ("Bit N = bit 7-(N%8) of byte
// N/8"): applying that formula to bits 12/14/15 correctly yields byte1 =
// 0x0B (matches the worked example), but applying it to bits 26/34 yields
// byte3 = 0x20 and byte4 = 0x20 (byte2 untouched) — not the worked example's
// byte2 = 0x02 / byte3 = 0x00. Per the plan's WIRE-DETAIL CAVEAT, the
// self-consistent, independently-verifiable rule governs; this fixture uses
// the FORMULA-derived bytes (`0x85 0x06 0x00 0x00 0x0B 0x00 0x20 0x20`), not
// the worked example's literal digits, and flags this prominently for
// verification against the real Python client in Task 3.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_tags.dart';

void main() {
  group('application tag encode — literal bytes', () {
    test('Null -> 0x00', () {
      expect(encodeAppNull(), equals(Uint8List.fromList([0x00])));
    });

    test('Boolean false -> 0x10, true -> 0x11', () {
      expect(encodeAppBoolean(false), equals(Uint8List.fromList([0x10])));
      expect(encodeAppBoolean(true), equals(Uint8List.fromList([0x11])));
    });

    test('Unsigned 5 -> 0x21 0x05 (minimal 1 octet)', () {
      expect(encodeAppUnsigned(5), equals(Uint8List.fromList([0x21, 0x05])));
    });

    test('Unsigned 260 -> 0x22 0x01 0x04 (minimal 2 octets, BE)', () {
      expect(encodeAppUnsigned(260), equals(Uint8List.fromList([0x22, 0x01, 0x04])));
    });

    test('Signed -1 -> 0x31 0xFF', () {
      expect(encodeAppSigned(-1), equals(Uint8List.fromList([0x31, 0xFF])));
    });

    test('Real 12.5 -> 0x44 0x41 0x48 0x00 0x00 (BE float32)', () {
      expect(encodeAppReal(12.5), equals(Uint8List.fromList([0x44, 0x41, 0x48, 0x00, 0x00])));
    });

    test('CharacterString "Hi" -> 0x73 0x00 0x48 0x69 (short form, charset 0x00)', () {
      expect(encodeAppCharString('Hi'), equals(Uint8List.fromList([0x73, 0x00, 0x48, 0x69])));
    });

    test('CharacterString "Hello" -> 0x75 0x06 0x00 ... (extended length form, content len 6 >= 5)', () {
      expect(
        encodeAppCharString('Hello'),
        equals(Uint8List.fromList([0x75, 0x06, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F])),
      );
    });

    test('BitString 4-bit all-false -> 0x82 0x04 0x00 (unused count 4, one zero data byte)', () {
      expect(encodeAppBitString(4, <int>{}), equals(Uint8List.fromList([0x82, 0x04, 0x00])));
    });

    test(
      'BitString 40-bit Protocol_Services_Supported bits 12/14/15/26/34 '
      '-> 0x85 0x06 0x00 0x00 0x0B 0x00 0x20 0x20 (formula-derived; see DEVIATION NOTE above)',
      () {
        expect(
          encodeAppBitString(40, <int>{12, 14, 15, 26, 34}),
          equals(Uint8List.fromList([0x85, 0x06, 0x00, 0x00, 0x0B, 0x00, 0x20, 0x20])),
        );
      },
    );

    test('Enumerated 0 -> 0x91 0x00', () {
      expect(encodeAppEnumerated(0), equals(Uint8List.fromList([0x91, 0x00])));
    });

    test('ObjectIdentifier analog-value(2) instance 0 -> 0xC4 0x00 0x80 0x00 0x00', () {
      expect(encodeAppObjectId(2, 0), equals(Uint8List.fromList([0xC4, 0x00, 0x80, 0x00, 0x00])));
    });

    test('ObjectIdentifier device(8) instance 3056 -> 0xC4 0x02 0x00 0x0B 0xF0', () {
      expect(encodeAppObjectId(8, 3056), equals(Uint8List.fromList([0xC4, 0x02, 0x00, 0x0B, 0xF0])));
    });
  });

  group('application tag decode — hand-built bytes, never only round-trip', () {
    test('decodes Null from a fresh literal buffer', () {
      final reader = BacnetTagReader(Uint8List.fromList([0x00]));
      final tag = reader.readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 0);
      expect(tag.isContext, isFalse);
      expect(tag.isOpening, isFalse);
      expect(tag.isClosing, isFalse);
      expect(tag.content, isEmpty);
      expect(reader.done, isTrue);
    });

    test('decodes Boolean false and true from fresh literal buffers', () {
      final falseTag = BacnetTagReader(Uint8List.fromList([0x10])).readTag();
      final trueTag = BacnetTagReader(Uint8List.fromList([0x11])).readTag();
      expect(falseTag!.asBoolean(), isFalse);
      expect(trueTag!.asBoolean(), isTrue);
    });

    test('decodes Unsigned 5 from 0x21 0x05', () {
      final reader = BacnetTagReader(Uint8List.fromList([0x21, 0x05]));
      final tag = reader.readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 2);
      expect(tag.isContext, isFalse);
      expect(tag.content, equals(Uint8List.fromList([0x05])));
      expect(tag.asUnsigned(), 5);
      expect(reader.done, isTrue);
    });

    test('decodes Unsigned 260 from 0x22 0x01 0x04', () {
      final tag = BacnetTagReader(Uint8List.fromList([0x22, 0x01, 0x04])).readTag();
      expect(tag!.asUnsigned(), 260);
    });

    test('decodes Signed -1 content from 0x31 0xFF (manual two\'s-complement check)', () {
      final tag = BacnetTagReader(Uint8List.fromList([0x31, 0xFF])).readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 3);
      expect(tag.content, equals(Uint8List.fromList([0xFF])));
      // Manual two's-complement interpretation of the single content byte.
      final raw = tag.content[0];
      final signedValue = raw >= 0x80 ? raw - 0x100 : raw;
      expect(signedValue, -1);
    });

    test('decodes Real 12.5 from 0x44 0x41 0x48 0x00 0x00', () {
      final tag = BacnetTagReader(Uint8List.fromList([0x44, 0x41, 0x48, 0x00, 0x00])).readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 4);
      expect(tag.asReal(), 12.5);
    });

    test('decodes CharacterString "Hi" from 0x73 0x00 0x48 0x69', () {
      final tag = BacnetTagReader(Uint8List.fromList([0x73, 0x00, 0x48, 0x69])).readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 7);
      expect(tag.content[0], 0x00); // charset byte: UTF-8
      expect(utf8.decode(tag.content.sublist(1)), 'Hi');
    });

    test('decodes extended-length CharacterString "Hello" from 0x75 0x06 0x00 ...', () {
      final tag = BacnetTagReader(
        Uint8List.fromList([0x75, 0x06, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F]),
      ).readTag();
      expect(tag, isNotNull);
      expect(tag!.content.length, 6);
      expect(tag.content[0], 0x00);
      expect(utf8.decode(tag.content.sublist(1)), 'Hello');
    });

    test('decodes 4-bit all-false BitString content from 0x82 0x04 0x00', () {
      final tag = BacnetTagReader(Uint8List.fromList([0x82, 0x04, 0x00])).readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 8);
      expect(tag.content, equals(Uint8List.fromList([0x04, 0x00])));
    });

    test(
      'decodes the 40-bit Protocol_Services_Supported BitString content '
      '(formula-derived bytes; see DEVIATION NOTE above)',
      () {
        final tag = BacnetTagReader(
          Uint8List.fromList([0x85, 0x06, 0x00, 0x00, 0x0B, 0x00, 0x20, 0x20]),
        ).readTag();
        expect(tag, isNotNull);
        expect(
          tag!.content,
          equals(Uint8List.fromList([0x00, 0x00, 0x0B, 0x00, 0x20, 0x20])),
        );
        // Unused-bit count is the first content octet.
        expect(tag.content[0], 0x00);
      },
    );

    test('decodes Enumerated 0 from 0x91 0x00', () {
      final tag = BacnetTagReader(Uint8List.fromList([0x91, 0x00])).readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 9);
      expect(tag.asEnumerated(), 0);
    });

    test('decodes ObjectIdentifier analog-value(2) instance 0 from 0xC4 0x00 0x80 0x00 0x00', () {
      final tag = BacnetTagReader(Uint8List.fromList([0xC4, 0x00, 0x80, 0x00, 0x00])).readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 12);
      expect(tag.asObjectId(), (2, 0));
    });

    test('decodes ObjectIdentifier device(8) instance 3056 from 0xC4 0x02 0x00 0x0B 0xF0', () {
      final tag = BacnetTagReader(Uint8List.fromList([0xC4, 0x02, 0x00, 0x0B, 0xF0])).readTag();
      expect(tag, isNotNull);
      expect(tag!.asObjectId(), (8, 3056));
    });
  });

  group('context tags — encode and decode, literal bytes', () {
    test('encodeContextObjectId(0, analog-value(2), 0) -> 0x0C 0x00 0x80 0x00 0x00', () {
      expect(
        encodeContextObjectId(0, 2, 0),
        equals(Uint8List.fromList([0x0C, 0x00, 0x80, 0x00, 0x00])),
      );
    });

    test('decodes context-0 ObjectIdentifier from a fresh literal 0x0C 0x00 0x80 0x00 0x00', () {
      final tag = BacnetTagReader(Uint8List.fromList([0x0C, 0x00, 0x80, 0x00, 0x00])).readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 0);
      expect(tag.isContext, isTrue);
      expect(tag.asObjectId(), (2, 0));
    });

    test('encodeContextUnsigned(1, 5) -> 0x19 0x05', () {
      expect(encodeContextUnsigned(1, 5), equals(Uint8List.fromList([0x19, 0x05])));
    });

    test('decodes context-1 Unsigned(1 byte) from a fresh literal 0x19 0x05', () {
      final tag = BacnetTagReader(Uint8List.fromList([0x19, 0x05])).readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 1);
      expect(tag.isContext, isTrue);
      expect(tag.asUnsigned(), 5);
    });

    test('encodeContextEnumerated(1, 3) -> 0x19 0x03', () {
      expect(encodeContextEnumerated(1, 3), equals(Uint8List.fromList([0x19, 0x03])));
    });
  });

  group('opening / closing constructed tags', () {
    test('openingTag(3) -> 0x3E, closingTag(3) -> 0x3F', () {
      expect(openingTag(3), equals(Uint8List.fromList([0x3E])));
      expect(closingTag(3), equals(Uint8List.fromList([0x3F])));
    });

    test('openingTag(0) -> 0x0E, closingTag(0) -> 0x0F', () {
      expect(openingTag(0), equals(Uint8List.fromList([0x0E])));
      expect(closingTag(0), equals(Uint8List.fromList([0x0F])));
    });

    test('reader decodes an opening then closing tag pair from a fresh literal buffer', () {
      final reader = BacnetTagReader(Uint8List.fromList([0x3E, 0x3F]));
      final open = reader.readTag();
      expect(open, isNotNull);
      expect(open!.tagNumber, 3);
      expect(open.isContext, isTrue);
      expect(open.isOpening, isTrue);
      expect(open.isClosing, isFalse);
      expect(open.content, isEmpty);

      final close = reader.readTag();
      expect(close, isNotNull);
      expect(close!.tagNumber, 3);
      expect(close.isContext, isTrue);
      expect(close.isOpening, isFalse);
      expect(close.isClosing, isTrue);
      expect(close.content, isEmpty);

      expect(reader.done, isTrue);
    });
  });

  group('BacnetTagReader — cursor state', () {
    test('position advances by the exact number of bytes consumed per tag', () {
      final reader = BacnetTagReader(Uint8List.fromList([0x00, 0x21, 0x05]));
      expect(reader.position, 0);
      reader.readTag(); // Null: 1 byte
      expect(reader.position, 1);
      reader.readTag(); // Unsigned 5: 2 bytes
      expect(reader.position, 3);
      expect(reader.done, isTrue);
    });

    test('accepts a non-zero start offset', () {
      final buffer = Uint8List.fromList([0xFF, 0xFF, 0x00]);
      final reader = BacnetTagReader(buffer, 2);
      expect(reader.position, 2);
      final tag = reader.readTag();
      expect(tag, isNotNull);
      expect(tag!.tagNumber, 0);
      expect(reader.done, isTrue);
    });

    test('done is true and readTag is null on an empty buffer, no throw', () {
      final reader = BacnetTagReader(Uint8List(0));
      expect(reader.done, isTrue);
      expect(() => reader.readTag(), returnsNormally);
      expect(reader.readTag(), isNull);
    });
  });

  group('BacnetTagReader — truncated/hostile content never throws', () {
    test('Unsigned tag claiming 2 content bytes with only 1 present -> null, no throw', () {
      final reader = BacnetTagReader(Uint8List.fromList([0x22, 0x01]));
      expect(() => reader.readTag(), returnsNormally);
      expect(reader.readTag(), isNull);
    });

    test('extended-length tag (lvt=5) with no length byte following -> null, no throw', () {
      final reader = BacnetTagReader(Uint8List.fromList([0x75]));
      expect(() => reader.readTag(), returnsNormally);
      expect(reader.readTag(), isNull);
    });

    test('extended-length tag with length byte but truncated content -> null, no throw', () {
      // Claims length 6 (as for "Hello") but only 3 content bytes follow.
      final reader = BacnetTagReader(Uint8List.fromList([0x75, 0x06, 0x00, 0x48, 0x65]));
      expect(() => reader.readTag(), returnsNormally);
      expect(reader.readTag(), isNull);
    });

    test('extended context tag number (>=15) missing its extra tag-number byte -> null, no throw', () {
      final reader = BacnetTagReader(Uint8List.fromList([0xFE]));
      expect(() => reader.readTag(), returnsNormally);
      expect(reader.readTag(), isNull);
    });

    test('typed helpers return null (never throw) on mismatched/short content', () {
      final wrongLenReal = BacnetDecodedTag(
        tagNumber: 4,
        isContext: false,
        isOpening: false,
        isClosing: false,
        content: Uint8List.fromList([0x00, 0x00]), // Real needs exactly 4 bytes
      );
      expect(() => wrongLenReal.asReal(), returnsNormally);
      expect(wrongLenReal.asReal(), isNull);

      final emptyUnsigned = BacnetDecodedTag(
        tagNumber: 2,
        isContext: false,
        isOpening: false,
        isClosing: false,
        content: Uint8List(0),
      );
      expect(() => emptyUnsigned.asUnsigned(), returnsNormally);
      expect(emptyUnsigned.asUnsigned(), isNull);

      final wrongLenObjectId = BacnetDecodedTag(
        tagNumber: 12,
        isContext: false,
        isOpening: false,
        isClosing: false,
        content: Uint8List.fromList([0x00, 0x00, 0x00]), // ObjectId needs exactly 4 bytes
      );
      expect(() => wrongLenObjectId.asObjectId(), returnsNormally);
      expect(wrongLenObjectId.asObjectId(), isNull);

      final emptyBoolean = BacnetDecodedTag(
        tagNumber: 1,
        isContext: false,
        isOpening: false,
        isClosing: false,
        content: Uint8List(0),
      );
      expect(() => emptyBoolean.asBoolean(), returnsNormally);
      expect(emptyBoolean.asBoolean(), isNull);
    });
  });
}
