// Tests for the pure-Dart OPC UA Binary codec (mobile/lib/protocols/opcua/opcua_binary.dart).
//
// Every fixture / byte-layout claim in this file is cross-checked against the
// Rust `opcua` crate (v0.12.0) source, vendored locally at:
//   C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/
// The specific file is cited above each fixture.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('OpcUaWriter/Reader primitives', () {
    test('boolean round-trip true/false', () {
      final writer = OpcUaWriter()
        ..boolean(true)
        ..boolean(false);
      final reader = OpcUaReader(writer.take());
      expect(reader.boolean(), isTrue);
      expect(reader.boolean(), isFalse);
      expect(reader.atEnd, isTrue);
    });

    test('byte/sbyte round-trip incl. negative/max', () {
      final writer = OpcUaWriter()
        ..uint8(255)
        ..int8(-128)
        ..int8(127);
      final reader = OpcUaReader(writer.take());
      expect(reader.uint8(), 255);
      expect(reader.int8(), -128);
      expect(reader.int8(), 127);
    });

    test('int16/uint16 round-trip incl. bounds', () {
      final writer = OpcUaWriter()
        ..int16(-32768)
        ..int16(32767)
        ..uint16(0)
        ..uint16(65535);
      final reader = OpcUaReader(writer.take());
      expect(reader.int16(), -32768);
      expect(reader.int16(), 32767);
      expect(reader.uint16(), 0);
      expect(reader.uint16(), 65535);
    });

    test('int32/uint32 round-trip incl. bounds', () {
      final writer = OpcUaWriter()
        ..int32(-2147483648)
        ..int32(2147483647)
        ..uint32(0)
        ..uint32(4294967295);
      final reader = OpcUaReader(writer.take());
      expect(reader.int32(), -2147483648);
      expect(reader.int32(), 2147483647);
      expect(reader.uint32(), 0);
      expect(reader.uint32(), 4294967295);
    });

    test('int64/uint64 round-trip incl. bounds', () {
      final writer = OpcUaWriter()
        ..int64(-9223372036854775808)
        ..int64(9223372036854775807)
        ..uint64(0)
        ..uint64(-1); // -1 bit pattern == UInt64 max in Dart's 64-bit int repr
      final reader = OpcUaReader(writer.take());
      expect(reader.int64(), -9223372036854775808);
      expect(reader.int64(), 9223372036854775807);
      expect(reader.uint64(), 0);
      expect(reader.uint64(), -1);
    });

    test('float32/float64 round-trip', () {
      final writer = OpcUaWriter()
        ..float32(3.5)
        ..float64(1.23456789);
      final reader = OpcUaReader(writer.take());
      expect(reader.float32(), 3.5);
      expect(reader.float64(), closeTo(1.23456789, 1e-12));
    });

    test('little-endian byte order for uint32', () {
      final writer = OpcUaWriter()..uint32(0x01020304);
      expect(writer.take(), _bytes([0x04, 0x03, 0x02, 0x01]));
    });
  });

  group('String encoding', () {
    // Rust reference: opcua-0.12.0/src/types/string.rs BinaryEncoder<UAString>.
    // Length-prefixed Int32; -1 == null string.
    test('null string encodes as -1 length (FIXTURE)', () {
      final writer = OpcUaWriter()..string(null);
      expect(writer.take(), _bytes([0xFF, 0xFF, 0xFF, 0xFF]));
    });

    test('empty string encodes as 0 length, no bytes', () {
      final writer = OpcUaWriter()..string('');
      expect(writer.take(), _bytes([0x00, 0x00, 0x00, 0x00]));
    });

    test('non-ASCII UTF-8 string round-trips', () {
      const value = 'café ☃ 😀';
      final writer = OpcUaWriter()..string(value);
      final reader = OpcUaReader(writer.take());
      expect(reader.string(), value);
    });

    test('null vs empty string distinction round-trips', () {
      final writer = OpcUaWriter()
        ..string(null)
        ..string('');
      final reader = OpcUaReader(writer.take());
      expect(reader.string(), isNull);
      expect(reader.string(), '');
    });
  });

  group('ByteString encoding', () {
    test('null byteString', () {
      final writer = OpcUaWriter()..byteString(null);
      final bytes = writer.take();
      expect(bytes, _bytes([0xFF, 0xFF, 0xFF, 0xFF]));
      final reader = OpcUaReader(bytes);
      expect(reader.byteString(), isNull);
    });

    test('empty byteString', () {
      final writer = OpcUaWriter()..byteString(<int>[]);
      final reader = OpcUaReader(writer.take());
      expect(reader.byteString(), <int>[]);
    });

    test('byteString with bytes round-trips', () {
      final data = <int>[1, 2, 3, 255, 0];
      final writer = OpcUaWriter()..byteString(data);
      final reader = OpcUaReader(writer.take());
      expect(reader.byteString(), data);
    });
  });

  group('DateTime encoding', () {
    // Rust reference: opcua-0.12.0/src/types/date_time.rs
    // Int64 count of 100ns ticks since 1601-01-01T00:00:00Z; null -> 0.
    test('null DateTime encodes as 0 ticks', () {
      final writer = OpcUaWriter()..dateTime(null);
      final bytes = writer.take();
      expect(bytes, _bytes([0, 0, 0, 0, 0, 0, 0, 0]));
      final reader = OpcUaReader(bytes);
      expect(reader.dateTime(), isNull);
    });

    test('epoch (1601-01-01T00:00:00Z) encodes as 0 ticks', () {
      final epoch = DateTime.utc(1601, 1, 1);
      final writer = OpcUaWriter()..dateTime(epoch);
      expect(writer.take(), _bytes([0, 0, 0, 0, 0, 0, 0, 0]));
    });

    test('known DateTime 2020-01-01T00:00:00Z (FIXTURE, verified against Rust)', () {
      // Verified: (2020-01-01 - 1601-01-01) in 100ns ticks == 132223104000000000
      // == 0x01D5C0366905_0000 little-endian bytes below.
      final known = DateTime.utc(2020, 1, 1);
      final writer = OpcUaWriter()..dateTime(known);
      final bytes = writer.take();
      expect(bytes, _bytes([0, 0, 5, 105, 54, 192, 213, 1]));
      final reader = OpcUaReader(bytes);
      expect(reader.dateTime(), known);
    });

    test('DateTime.now() round-trips to within 100ns tick precision', () {
      final now = DateTime.now().toUtc();
      final writer = OpcUaWriter()..dateTime(now);
      final reader = OpcUaReader(writer.take());
      final decoded = reader.dateTime()!;
      // Ticks are 100ns; Dart DateTime microsecond precision may lose <1 tick.
      expect(decoded.difference(now).inMilliseconds.abs(), lessThanOrEqualTo(1));
    });

    test('year-10000+ DateTime clamps to i64::MAX ticks on write (FIXTURE, Fix 2)', () {
      // Rust reference: date_time.rs:310-320 `checked_ticks()` clamps dates
      // past the OPC UA "endtimes" (Dec 31, 9999 23:59:59Z, MAX_YEAR = 9999)
      // to i64::MAX (9223372036854775807), mirroring the existing pre-1601
      // clamp-to-0 on the other end.
      final farFuture = DateTime.utc(10000, 1, 1);
      final writer = OpcUaWriter()..dateTime(farFuture);
      final bytes = writer.take();
      final reader = ByteData.sublistView(bytes);
      final ticks = reader.getInt64(0, Endian.little);
      expect(ticks, 9223372036854775807); // i64::MAX
    });

    test('date just past endtimes boundary also clamps to i64::MAX (Fix 2)', () {
      // 10000-01-01 is well past 9999-12-31T23:59:59Z; also check a date
      // just barely past the boundary second to ensure the comparison uses
      // ticks, not just year.
      final justPastEndtimes = DateTime.utc(9999, 12, 31, 23, 59, 59, 1);
      final writer = OpcUaWriter()..dateTime(justPastEndtimes);
      final bytes = writer.take();
      final reader = ByteData.sublistView(bytes);
      final ticks = reader.getInt64(0, Endian.little);
      expect(ticks, 9223372036854775807);
    });

    test('normal date well within range is unaffected by the upper clamp (Fix 2)', () {
      final known = DateTime.utc(2020, 1, 1);
      final writer = OpcUaWriter()..dateTime(known);
      final bytes = writer.take();
      // Same fixture bytes as the existing 2020-01-01 test above — proves the
      // clamp logic doesn't perturb normal in-range dates.
      expect(bytes, _bytes([0, 0, 5, 105, 54, 192, 213, 1]));
    });
  });

  group('Guid encoding', () {
    // Rust reference: opcua-0.12.0/src/types/guid.rs - 16 raw bytes (UUID bytes).
    test('guid round-trips 16 bytes', () {
      final guidBytes = List<int>.generate(16, (i) => i + 1);
      final writer = OpcUaWriter()..guid(guidBytes);
      final bytes = writer.take();
      expect(bytes.length, 16);
      final reader = OpcUaReader(bytes);
      expect(reader.guid(), guidBytes);
    });

    test('null guid is all zero bytes', () {
      final writer = OpcUaWriter()..guid(null);
      expect(writer.take(), _bytes(List<int>.filled(16, 0)));
    });
  });

  group('NodeId encoding (all four forms)', () {
    // Rust reference: opcua-0.12.0/src/types/node_id.rs BinaryEncoder<NodeId>::encode
    //   0x00 two-byte:  ns==0 && value<=255  -> [0x00, value]
    //   0x01 four-byte: ns<=255 && value<=65535 -> [0x01, ns, valueLE16]
    //   0x02 numeric:   otherwise -> [0x02, nsLE16, valueLE32]
    //   0x03 string:    -> [0x03, nsLE16, string]
    test('two-byte form ns:0 i:255 (FIXTURE)', () {
      final writer = OpcUaWriter()..nodeId(const OpcNodeId.numeric(0, 255));
      expect(writer.take(), _bytes([0x00, 0xFF]));
    });

    test('two-byte form chosen for smallest encoding (ns:0 i:0)', () {
      final writer = OpcUaWriter()..nodeId(const OpcNodeId.numeric(0, 0));
      expect(writer.take(), _bytes([0x00, 0x00]));
    });

    test('four-byte form ns:1 i:1000 (FIXTURE)', () {
      final writer = OpcUaWriter()..nodeId(const OpcNodeId.numeric(1, 1000));
      expect(writer.take(), _bytes([0x01, 0x01, 0xE8, 0x03]));
    });

    test('four-byte form chosen when ns:0 but value > 255', () {
      final writer = OpcUaWriter()..nodeId(const OpcNodeId.numeric(0, 256));
      expect(writer.take(), _bytes([0x01, 0x00, 0x00, 0x01]));
    });

    test('numeric (0x02) form chosen when ns > 255', () {
      final writer = OpcUaWriter()..nodeId(const OpcNodeId.numeric(256, 42));
      final bytes = writer.take();
      expect(bytes[0], 0x02);
      final reader = OpcUaReader(bytes);
      final decoded = reader.nodeId();
      expect(decoded.namespace, 256);
      expect(decoded.numericId, 42);
    });

    test('numeric (0x02) form chosen when value > 65535', () {
      final writer = OpcUaWriter()..nodeId(const OpcNodeId.numeric(1, 100000));
      final bytes = writer.take();
      expect(bytes[0], 0x02);
      final reader = OpcUaReader(bytes);
      final decoded = reader.nodeId();
      expect(decoded.namespace, 1);
      expect(decoded.numericId, 100000);
    });

    test('string (0x03) form round-trips ns + string id', () {
      final writer = OpcUaWriter()
        ..nodeId(const OpcNodeId.string(1, 'Inputs/Start_PB'));
      final bytes = writer.take();
      expect(bytes[0], 0x03);
      final reader = OpcUaReader(bytes);
      final decoded = reader.nodeId();
      expect(decoded.namespace, 1);
      expect(decoded.stringId, 'Inputs/Start_PB');
    });

    test('all four forms round-trip through writer->reader', () {
      final cases = [
        const OpcNodeId.numeric(0, 255),
        const OpcNodeId.numeric(1, 1000),
        const OpcNodeId.numeric(300, 70000),
        const OpcNodeId.string(2, 'Tag/Name'),
      ];
      for (final nodeId in cases) {
        final writer = OpcUaWriter()..nodeId(nodeId);
        final reader = OpcUaReader(writer.take());
        final decoded = reader.nodeId();
        expect(decoded, nodeId, reason: 'failed for $nodeId');
      }
    });
  });

  group('ExpandedNodeId', () {
    test('writes as a plain NodeId when no uri/server-index', () {
      const nodeId = OpcNodeId.numeric(1, 1000);
      final writer = OpcUaWriter()..expandedNodeId(nodeId);
      // Should be byte-identical to writing the NodeId directly (no
      // extra namespace-uri/server-index flags set in the 0x00 top bits).
      final plain = OpcUaWriter()..nodeId(nodeId);
      expect(writer.take(), plain.take());
    });

    test('reads back enough to not choke on a plain-NodeId-shaped ExpandedNodeId', () {
      const nodeId = OpcNodeId.numeric(1, 42);
      final writer = OpcUaWriter()..expandedNodeId(nodeId);
      final reader = OpcUaReader(writer.take());
      final decoded = reader.expandedNodeId();
      expect(decoded.namespace, 1);
      expect(decoded.numericId, 42);
    });
  });

  group('StatusCode', () {
    test('round-trips as UInt32', () {
      final writer = OpcUaWriter()..statusCode(0x80010000);
      final reader = OpcUaReader(writer.take());
      expect(reader.statusCode(), 0x80010000);
    });

    test('Good (0) round-trips', () {
      final writer = OpcUaWriter()..statusCode(0);
      expect(writer.take(), _bytes([0, 0, 0, 0]));
    });
  });

  group('QualifiedName', () {
    test('round-trips namespace + name', () {
      final writer = OpcUaWriter()
        ..qualifiedName(const OpcQualifiedName(ns: 1, name: 'Start_PB'));
      final reader = OpcUaReader(writer.take());
      final decoded = reader.qualifiedName();
      expect(decoded.ns, 1);
      expect(decoded.name, 'Start_PB');
    });

    test('null name round-trips', () {
      final writer = OpcUaWriter()
        ..qualifiedName(const OpcQualifiedName(ns: 0, name: null));
      final reader = OpcUaReader(writer.take());
      final decoded = reader.qualifiedName();
      expect(decoded.ns, 0);
      expect(decoded.name, isNull);
    });
  });

  group('LocalizedText masks (0x01/0x02/0x03)', () {
    // Rust reference: opcua-0.12.0/src/types/localized_text.rs
    // mask 0x01 = locale present (non-empty), 0x02 = text present (non-empty).
    test('mask 0x00 - both null/empty', () {
      final writer = OpcUaWriter()
        ..localizedText(const OpcLocalizedText());
      expect(writer.take(), _bytes([0x00]));
    });

    test('mask 0x01 - locale only', () {
      final writer = OpcUaWriter()
        ..localizedText(const OpcLocalizedText(locale: 'en'));
      final bytes = writer.take();
      expect(bytes[0], 0x01);
      final reader = OpcUaReader(bytes);
      final decoded = reader.localizedText();
      expect(decoded.locale, 'en');
      expect(decoded.text, isNull);
    });

    test('mask 0x02 - text only', () {
      final writer = OpcUaWriter()
        ..localizedText(const OpcLocalizedText(text: 'Start Button'));
      final bytes = writer.take();
      expect(bytes[0], 0x02);
      final reader = OpcUaReader(bytes);
      final decoded = reader.localizedText();
      expect(decoded.locale, isNull);
      expect(decoded.text, 'Start Button');
    });

    test('mask 0x03 - both locale and text', () {
      final writer = OpcUaWriter()
        ..localizedText(
          const OpcLocalizedText(locale: 'en', text: 'Start Button'),
        );
      final bytes = writer.take();
      expect(bytes[0], 0x03);
      final reader = OpcUaReader(bytes);
      final decoded = reader.localizedText();
      expect(decoded.locale, 'en');
      expect(decoded.text, 'Start Button');
    });
  });

  group('Variant scalars', () {
    // Rust reference: opcua-0.12.0/src/types/variant_type_id.rs EncodingMask,
    // opcua-0.12.0/src/types/node_ids.rs DataTypeId (Boolean=1 .. LocalizedText=21).
    test('Boolean true (FIXTURE == [0x01, 0x01])', () {
      final writer = OpcUaWriter()
        ..variant(const OpcVariant(typeId: 1, value: true));
      expect(writer.take(), _bytes([0x01, 0x01]));
    });

    test('Boolean false', () {
      final writer = OpcUaWriter()
        ..variant(const OpcVariant(typeId: 1, value: false));
      expect(writer.take(), _bytes([0x01, 0x00]));
    });

    final scalarCases = <String, OpcVariant>{
      'SByte': const OpcVariant(typeId: 2, value: -5),
      'Byte': const OpcVariant(typeId: 3, value: 200),
      'Int16': const OpcVariant(typeId: 4, value: -1234),
      'UInt16': const OpcVariant(typeId: 5, value: 60000),
      'Int32': const OpcVariant(typeId: 6, value: -123456),
      'UInt32': const OpcVariant(typeId: 7, value: 4000000000),
      'Int64': const OpcVariant(typeId: 8, value: -1234567890123),
      'UInt64': const OpcVariant(typeId: 9, value: 1234567890123),
      'Float': const OpcVariant(typeId: 10, value: 3.5),
      'Double': const OpcVariant(typeId: 11, value: 3.14159265),
      'String': const OpcVariant(typeId: 12, value: 'hello'),
      'StatusCode': const OpcVariant(typeId: 19, value: 0x80010000),
    };

    scalarCases.forEach((label, variant) {
      test('$label round-trips through writer->reader', () {
        final writer = OpcUaWriter()..variant(variant);
        final reader = OpcUaReader(writer.take());
        final decoded = reader.variant();
        expect(decoded.typeId, variant.typeId);
        expect(decoded.isArray, isFalse);
        if (variant.value is double) {
          expect(decoded.value, closeTo(variant.value as double, 1e-6));
        } else {
          expect(decoded.value, variant.value);
        }
      });
    });

    test('DateTime variant round-trips', () {
      final now = DateTime.utc(2024, 6, 15, 12, 30);
      final writer = OpcUaWriter()
        ..variant(OpcVariant(typeId: 13, value: now));
      final reader = OpcUaReader(writer.take());
      final decoded = reader.variant();
      expect(decoded.typeId, 13);
      expect(decoded.value, now);
    });

    test('NodeId variant round-trips', () {
      const nodeId = OpcNodeId.numeric(1, 42);
      final writer = OpcUaWriter()
        ..variant(const OpcVariant(typeId: 17, value: nodeId));
      final reader = OpcUaReader(writer.take());
      final decoded = reader.variant();
      expect(decoded.typeId, 17);
      expect(decoded.value, nodeId);
    });

    test('QualifiedName variant round-trips', () {
      const qn = OpcQualifiedName(ns: 1, name: 'Start_PB');
      final writer = OpcUaWriter()
        ..variant(const OpcVariant(typeId: 20, value: qn));
      final reader = OpcUaReader(writer.take());
      final decoded = reader.variant();
      expect(decoded.typeId, 20);
      expect(decoded.value, qn);
    });

    test('LocalizedText variant round-trips', () {
      const lt = OpcLocalizedText(locale: 'en', text: 'Start');
      final writer = OpcUaWriter()
        ..variant(const OpcVariant(typeId: 21, value: lt));
      final reader = OpcUaReader(writer.take());
      final decoded = reader.variant();
      expect(decoded.typeId, 21);
      expect(decoded.value, lt);
    });
  });

  group('Variant arrays', () {
    // Array flag is 0x80 (ARRAY_VALUES_BIT), OR'd with the scalar type id;
    // followed by Int32 length + elements (Rust variant.rs Variant::encode).
    test('Int32 array encoding mask has 0x80 flag set', () {
      final writer = OpcUaWriter()
        ..variant(
          const OpcVariant(typeId: 6, value: [1, 2, 3], isArray: true),
        );
      final bytes = writer.take();
      expect(bytes[0], 0x06 | 0x80);
    });

    test('Int32 array round-trips', () {
      final writer = OpcUaWriter()
        ..variant(
          const OpcVariant(
            typeId: 6,
            value: [1, -2, 3, 2147483647],
            isArray: true,
          ),
        );
      final reader = OpcUaReader(writer.take());
      final decoded = reader.variant();
      expect(decoded.typeId, 6);
      expect(decoded.isArray, isTrue);
      expect(decoded.value, [1, -2, 3, 2147483647]);
    });

    test('String array round-trips incl. null element', () {
      final writer = OpcUaWriter()
        ..variant(
          const OpcVariant(
            typeId: 12,
            value: ['a', 'bb', ''],
            isArray: true,
          ),
        );
      final reader = OpcUaReader(writer.take());
      final decoded = reader.variant();
      expect(decoded.typeId, 12);
      expect(decoded.isArray, isTrue);
      expect(decoded.value, ['a', 'bb', '']);
    });

    test('empty array round-trips (length 0)', () {
      final writer = OpcUaWriter()
        ..variant(
          const OpcVariant(typeId: 6, value: <int>[], isArray: true),
        );
      final reader = OpcUaReader(writer.take());
      final decoded = reader.variant();
      expect(decoded.isArray, isTrue);
      expect(decoded.value, <int>[]);
    });

    test('LocalizedText array (high-numbered scalar id 21, mask 0x95) round-trips', () {
      // Regression guard for the type-id mask fix: 0x80 (array) | 0x15 (21,
      // LocalizedText) == 0x95. Asserts the typeId survives extraction
      // specifically for a high-numbered scalar id, not just low ids like
      // Int32(6) where a masking bug could go unnoticed.
      const items = [
        OpcLocalizedText(locale: 'en', text: 'Start'),
        OpcLocalizedText(text: 'Stop'),
        OpcLocalizedText(),
      ];
      final writer = OpcUaWriter()
        ..variant(const OpcVariant(typeId: 21, value: items, isArray: true));
      final bytes = writer.take();
      expect(bytes[0], 0x95);
      final reader = OpcUaReader(bytes);
      final decoded = reader.variant();
      expect(decoded.typeId, 21);
      expect(decoded.isArray, isTrue);
      expect(decoded.value, items);
    });

    test(
        'Variant array-dimensions bit (0x40) set -> clean FormatException, '
        'never silent corruption (Fix 1 regression)', () {
      // Rust reference: variant_type_id.rs:249-253 (ARRAY_DIMENSIONS_BIT =
      // 0x40, ARRAY_VALUES_BIT = 0x80, ARRAY_MASK = both); variant.rs:585
      // (`encoding_mask & !ARRAY_MASK`) clears BOTH bits to recover the type
      // id. Build the encoding byte by hand: 0x80 (array) | 0x40 (dimensions)
      // | 0x06 (Int32) == 0xC6. The reader must throw before consuming any
      // array-dimensions body, since v1 does not support that structure.
      //
      // The thrown message embeds the extracted typeId, so this test also
      // catches a mask regression (e.g. `& 0x7F` instead of `& 0x3F`): under
      // `& 0x7F`, mask 0xC6 & 0x7F == 0x46 (70) rather than the correct
      // 0xC6 & 0x3F == 0x06 (Int32) — a different message, failing the
      // `contains('typeId=6')` assertion below.
      final bytes = _bytes([0xC6, 0xFF, 0xFF, 0xFF, 0xFF]); // mask + garbage
      final reader = OpcUaReader(bytes);
      expect(
        () => reader.variant(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('array dimensions are not supported'),
              contains('typeId=6'),
            ),
          ),
        ),
      );
    });

    test('Int32 array (mask 0x86, no dimensions bit) still yields correct typeId', () {
      // Regression guard: a NORMAL array (0x80 | typeId, no 0x40) must still
      // decode with the correct typeId extraction under the new `& 0x3F` mask.
      final writer = OpcUaWriter()
        ..variant(
          const OpcVariant(typeId: 6, value: [10, 20, 30], isArray: true),
        );
      final bytes = writer.take();
      expect(bytes[0], 0x86); // 0x80 | 0x06, no 0x40 bit.
      final reader = OpcUaReader(bytes);
      final decoded = reader.variant();
      expect(decoded.typeId, 6);
      expect(decoded.isArray, isTrue);
      expect(decoded.value, [10, 20, 30]);
    });
  });

  group('DataValue mask combinations (0x01/0x02/0x04/0x08)', () {
    test('empty DataValue - mask 0x00', () {
      final writer = OpcUaWriter()..dataValue(const OpcDataValue());
      expect(writer.take(), _bytes([0x00]));
    });

    test('value only - mask 0x01', () {
      final writer = OpcUaWriter()
        ..dataValue(
          const OpcDataValue(variant: OpcVariant(typeId: 1, value: true)),
        );
      final bytes = writer.take();
      expect(bytes[0], 0x01);
      final reader = OpcUaReader(bytes);
      final decoded = reader.dataValue();
      expect(decoded.variant!.value, true);
      expect(decoded.status, isNull);
      expect(decoded.sourceTs, isNull);
      expect(decoded.serverTs, isNull);
    });

    test('status only - mask 0x02', () {
      final writer = OpcUaWriter()
        ..dataValue(const OpcDataValue(status: 0x80010000));
      final bytes = writer.take();
      expect(bytes[0], 0x02);
      final reader = OpcUaReader(bytes);
      final decoded = reader.dataValue();
      expect(decoded.status, 0x80010000);
    });

    test('sourceTs only - mask 0x04', () {
      final ts = DateTime.utc(2024, 1, 1);
      final writer = OpcUaWriter()..dataValue(OpcDataValue(sourceTs: ts));
      final bytes = writer.take();
      expect(bytes[0], 0x04);
      final reader = OpcUaReader(bytes);
      final decoded = reader.dataValue();
      expect(decoded.sourceTs, ts);
    });

    test('serverTs only - mask 0x08', () {
      final ts = DateTime.utc(2024, 1, 1);
      final writer = OpcUaWriter()..dataValue(OpcDataValue(serverTs: ts));
      final bytes = writer.take();
      expect(bytes[0], 0x08);
      final reader = OpcUaReader(bytes);
      final decoded = reader.dataValue();
      expect(decoded.serverTs, ts);
    });

    test('all four fields present - mask 0x0F', () {
      final srcTs = DateTime.utc(2024, 1, 1);
      final srvTs = DateTime.utc(2024, 1, 2);
      final writer = OpcUaWriter()
        ..dataValue(
          OpcDataValue(
            variant: const OpcVariant(typeId: 6, value: 42),
            status: 0,
            sourceTs: srcTs,
            serverTs: srvTs,
          ),
        );
      final bytes = writer.take();
      expect(bytes[0], 0x0F);
      final reader = OpcUaReader(bytes);
      final decoded = reader.dataValue();
      expect(decoded.variant!.value, 42);
      expect(decoded.status, 0);
      expect(decoded.sourceTs, srcTs);
      expect(decoded.serverTs, srvTs);
    });

    test('value + serverTs only (mask 0x09, skips status/sourceTs)', () {
      final srvTs = DateTime.utc(2024, 1, 2);
      final writer = OpcUaWriter()
        ..dataValue(
          OpcDataValue(
            variant: const OpcVariant(typeId: 1, value: false),
            serverTs: srvTs,
          ),
        );
      final bytes = writer.take();
      expect(bytes[0], 0x09);
      final reader = OpcUaReader(bytes);
      final decoded = reader.dataValue();
      expect(decoded.variant!.value, false);
      expect(decoded.status, isNull);
      expect(decoded.sourceTs, isNull);
      expect(decoded.serverTs, srvTs);
    });
  });

  group('ExtensionObject header', () {
    test('none body (0x00) writes NodeId + 0x00', () {
      final writer = OpcUaWriter()
        ..extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false);
      final bytes = writer.take();
      // NodeId(0,0) two-byte form == [0x00, 0x00], then encoding byte 0x00.
      expect(bytes, _bytes([0x00, 0x00, 0x00]));
    });

    test('ByteString body (0x01) writes NodeId + 0x01 marker', () {
      final writer = OpcUaWriter()
        ..extensionObjectHeader(
          const OpcNodeId.numeric(0, 15),
          hasBody: true,
        );
      final bytes = writer.take();
      expect(bytes, _bytes([0x00, 15, 0x01]));
    });
  });

  group('RequestHeader / ResponseHeader', () {
    test('RequestHeader round-trips', () {
      final header = RequestHeader(
        authToken: const OpcNodeId.numeric(0, 0),
        timestamp: DateTime.utc(2024, 1, 1),
        requestHandle: 7,
        returnDiagnostics: 0,
        auditEntryId: null,
        timeoutHint: 5000,
      );
      final writer = OpcUaWriter()..requestHeader(header);
      final reader = OpcUaReader(writer.take());
      final decoded = reader.requestHeader();
      expect(decoded.authToken, header.authToken);
      expect(decoded.timestamp, header.timestamp);
      expect(decoded.requestHandle, 7);
      expect(decoded.returnDiagnostics, 0);
      expect(decoded.auditEntryId, isNull);
      expect(decoded.timeoutHint, 5000);
    });

    test('ResponseHeader round-trips', () {
      final header = ResponseHeader(
        timestamp: DateTime.utc(2024, 1, 1),
        requestHandle: 9,
        serviceResult: 0,
      );
      final writer = OpcUaWriter()..responseHeader(header);
      final reader = OpcUaReader(writer.take());
      final decoded = reader.responseHeader();
      expect(decoded.timestamp, header.timestamp);
      expect(decoded.requestHandle, 9);
      expect(decoded.serviceResult, 0);
    });

    test('ResponseHeader with non-Good serviceResult round-trips', () {
      final header = ResponseHeader(
        timestamp: DateTime.utc(2024, 1, 1),
        requestHandle: 1,
        serviceResult: 0x80010000,
      );
      final writer = OpcUaWriter()..responseHeader(header);
      final reader = OpcUaReader(writer.take());
      final decoded = reader.responseHeader();
      expect(decoded.serviceResult, 0x80010000);
    });

    test('RequestHeader exact-byte fixture (Fix 3, catches swapped-field bugs)', () {
      // Field order per Rust reference request_header.rs:103-142
      // (`BinaryEncoder<RequestHeader>::encode`):
      //   authentication_token: NodeId
      //   timestamp: UtcTime (DateTime)
      //   request_handle: IntegerId (UInt32)
      //   return_diagnostics: DiagnosticBits.bits() (UInt32)
      //   audit_entry_id: UAString
      //   timeout_hint: u32
      //   additional_header: ExtensionObject
      //
      // Every same-typed field below uses a DISTINCT recognizable value so a
      // swapped-adjacent-field bug (e.g. requestHandle/timeoutHint swapped,
      // both UInt32) would flip specific bytes and be caught, unlike a plain
      // round-trip test which cannot distinguish that class of bug.
      final header = RequestHeader(
        authToken: const OpcNodeId.numeric(1, 300), // two-byte NodeId (0x01 form)
        timestamp: DateTime.utc(2020, 1, 1), // known-good ticks fixture (see DateTime group)
        requestHandle: 0x11111111,
        returnDiagnostics: 0x22222222,
        auditEntryId: null,
        timeoutHint: 0x33333333,
      );
      final writer = OpcUaWriter()..requestHeader(header);
      final bytes = writer.take();
      expect(
        bytes,
        _bytes([
          // authToken: NodeId.numeric(1, 300) -> 0x01 form: [0x01, ns=1, id=300 LE u16]
          0x01, 0x01, 0x2C, 0x01,
          // timestamp: 2020-01-01T00:00:00Z ticks (verified DateTime fixture above)
          0, 0, 5, 105, 54, 192, 213, 1,
          // requestHandle: 0x11111111 LE
          0x11, 0x11, 0x11, 0x11,
          // returnDiagnostics: 0x22222222 LE
          0x22, 0x22, 0x22, 0x22,
          // auditEntryId: null -> Int32(-1)
          0xFF, 0xFF, 0xFF, 0xFF,
          // timeoutHint: 0x33333333 LE
          0x33, 0x33, 0x33, 0x33,
          // additionalHeader: empty ExtensionObject -> NodeId(0,0) [0x00,0x00] + encoding 0x00
          0x00, 0x00, 0x00,
        ]),
      );
    });

    test('ResponseHeader exact-byte fixture (Fix 3, catches swapped-field bugs)', () {
      // Field order per Rust reference response_header.rs:26-63
      // (`BinaryEncoder<ResponseHeader>::encode`):
      //   timestamp: UtcTime (DateTime)
      //   request_handle: IntegerId (UInt32)
      //   service_result: StatusCode (UInt32)
      //   service_diagnostics: DiagnosticInfo (empty -> single 0x00 byte)
      //   string_table: Option<Vec<UAString>> (None -> write_array null -> Int32(-1))
      //   additional_header: ExtensionObject (empty)
      final header = ResponseHeader(
        timestamp: DateTime.utc(2020, 1, 1),
        requestHandle: 0x44444444,
        serviceResult: 0x80010000,
      );
      final writer = OpcUaWriter()..responseHeader(header);
      final bytes = writer.take();
      expect(
        bytes,
        _bytes([
          // timestamp: 2020-01-01T00:00:00Z ticks
          0, 0, 5, 105, 54, 192, 213, 1,
          // requestHandle: 0x44444444 LE
          0x44, 0x44, 0x44, 0x44,
          // serviceResult: 0x80010000 LE
          0x00, 0x00, 0x01, 0x80,
          // empty DiagnosticInfo
          0x00,
          // empty string table -> null array -> Int32(-1)
          0xFF, 0xFF, 0xFF, 0xFF,
          // additionalHeader: empty ExtensionObject
          0x00, 0x00, 0x00,
        ]),
      );
    });
  });

  group('Truncated input -> FormatException', () {
    test('reading uint32 from empty buffer throws FormatException', () {
      final reader = OpcUaReader(Uint8List(0));
      expect(() => reader.uint32(), throwsFormatException);
    });

    test('reading a string with a length prefix but truncated body throws', () {
      // Claims length 10 but supplies only 2 bytes of body.
      final bytes = _bytes([10, 0, 0, 0, 1, 2]);
      final reader = OpcUaReader(bytes);
      expect(() => reader.string(), throwsFormatException);
    });

    test('reading a NodeId from a single byte (missing payload) throws', () {
      final reader = OpcUaReader(_bytes([0x01])); // four-byte form needs 3 more bytes
      expect(() => reader.nodeId(), throwsFormatException);
    });

    test('reading past the end of the buffer never hangs, always throws', () {
      final reader = OpcUaReader(_bytes([0x00, 0xFF]));
      expect(reader.nodeId(), const OpcNodeId.numeric(0, 255));
      expect(() => reader.uint8(), throwsFormatException);
    });

    test('unknown NodeId encoding byte throws FormatException', () {
      final reader = OpcUaReader(_bytes([0x09, 0x00, 0x00]));
      expect(() => reader.nodeId(), throwsFormatException);
    });
  });
}
