// Byte-exact fixture + round-trip tests for the pure Sparkplug B protobuf
// Payload/Metric encoder (mobile/lib/protocols/mqtt/mqtt_sparkplug.dart).
//
// The production file only encodes (per the task brief: "production only
// ENCODES; the decoder is test-only"), so `decodePayload`/`decodeMetric`
// below are hand-rolled *here*, purely so these tests can assert round-trips
// without depending on a second implementation of the encoder's own logic
// for the fixture check (the first test asserts exact bytes independent of
// any decoder).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_sparkplug.dart';

void main() {
  group('encodePayload — byte-exact NBIRTH-style fixture', () {
    test('Payload{timestamp:0, seq:0, metrics:[Metric A alias=1 Boolean=true]}', () {
      const SparkplugPayload payload = SparkplugPayload(
        timestampMs: 0,
        seq: 0,
        metrics: <SparkplugMetric>[
          SparkplugMetric(
            name: 'A',
            alias: 1,
            datatype: SparkplugDatatype.boolean,
            value: true,
          ),
        ],
      );

      final Uint8List bytes = encodePayload(payload);

      // Metric submessage (encoded independently for field-order/length
      // sanity, then reused as part of the full expected Payload bytes).
      // Field numbers per the corrected Tahu spec numbering (boolean_value
      // is field 14, NOT field 9 -- field 9 is the spec's `properties`
      // metadata field):
      //   0x0A 0x01 0x41       name field 1, len=1, 'A' (0x41)
      //   0x10 0x01            alias field 2, value=1
      //   0x20 0x0B            datatype field 4, value=11 (Boolean)
      //   0x70 0x01            boolean_value field 14, value=1 (true)
      //     tag byte derivation: (fieldNumber << 3) | wireType
      //                        = (14 << 3) | 0 = 112 = 0x70
      // -> 9 bytes total (unchanged length -- only the tag byte's field
      // number component changed, from field 9 (0x48 = (9<<3)|0) to field 14
      // (0x70 = (14<<3)|0)), so Payload's field-2 metric entry is:
      //   0x12 0x09 <9 bytes above>
      final Uint8List metricBytes = encodeMetric(payload.metrics.single);
      expect(
        metricBytes,
        Uint8List.fromList(<int>[0x0A, 0x01, 0x41, 0x10, 0x01, 0x20, 0x0B, 0x70, 0x01]),
      );
      expect(metricBytes.length, 9);

      final Uint8List expected = Uint8List.fromList(<int>[
        0x08, 0x00, // Payload field 1 (timestamp) = 0
        0x12, 0x09, // Payload field 2 (metrics), length-delimited, len=9
        0x0A, 0x01, 0x41, // metric field 1 (name) = "A"
        0x10, 0x01, // metric field 2 (alias) = 1
        0x20, 0x0B, // metric field 4 (datatype) = 11 (Boolean)
        0x70, 0x01, // metric field 14 (boolean_value) = true (was field 9 -- the bug)
        0x18, 0x00, // Payload field 3 (seq) = 0
      ]);
      expect(bytes, expected);
    });
  });

  group('round-trip every datatype through decodePayload(encodePayload(x))', () {
    SparkplugPayload roundTrip(SparkplugMetric metric) {
      final SparkplugPayload sent = SparkplugPayload(timestampMs: 1000, seq: 5, metrics: <SparkplugMetric>[metric]);
      return decodePayload(encodePayload(sent));
    }

    test('Boolean true', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'flag', alias: 2, datatype: SparkplugDatatype.boolean, value: true),
      );
      expect(got.timestampMs, 1000);
      expect(got.seq, 5);
      final SparkplugMetric m = got.metrics.single;
      expect(m.name, 'flag');
      expect(m.alias, 2);
      expect(m.datatype, SparkplugDatatype.boolean);
      expect(m.value, true);
    });

    test('Boolean false', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'flag', alias: 2, datatype: SparkplugDatatype.boolean, value: false),
      );
      expect(got.metrics.single.value, false);
    });

    test('Int16 negative (-5) via the unsigned int_value wire field', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'i16', alias: 3, datatype: SparkplugDatatype.int16, value: -5),
      );
      final SparkplugMetric m = got.metrics.single;
      expect(m.datatype, SparkplugDatatype.int16);
      expect(m.value, -5);
    });

    test('Int16 positive round-trips unchanged', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'i16p', alias: 4, datatype: SparkplugDatatype.int16, value: 1234),
      );
      expect(got.metrics.single.value, 1234);
    });

    test('Int32 (70000)', () {
      const SparkplugMetric metric = SparkplugMetric(
        name: 'i32',
        alias: 5,
        datatype: SparkplugDatatype.int32,
        value: 70000,
      );
      final SparkplugPayload got = roundTrip(metric);
      final SparkplugMetric m = got.metrics.single;
      expect(m.datatype, SparkplugDatatype.int32);
      expect(m.value, 70000);

      // Byte-exact re-check (regression guard): this non-negative fixture's
      // varint PAYLOAD bytes (0xF0, 0xA2, 0x04 for 70000) are unaffected by
      // either the _writeVarint termination fix (>>> 7 behaves identically
      // to the old ~/ 128 for non-negative values) OR the field-number fix
      // below -- only the tag byte's field-number component changes, from
      // field 5 (0x28 = (5<<3)|0) to the corrected field 10
      // (0x50 = (10<<3)|0) -- field 5 is really the Tahu spec's
      // `is_historical` metadata field, not a value field.
      final Uint8List metricBytes = encodeMetric(metric);
      expect(
        metricBytes,
        Uint8List.fromList(<int>[
          0x0A, 0x03, 0x69, 0x33, 0x32, // name field 1, len=3, "i32"
          0x10, 0x05, // alias field 2 = 5
          0x20, 0x03, // datatype field 4 = 3 (Int32)
          0x50, 0xF0, 0xA2, 0x04, // int_value field 10 = 70000 (unsigned-reinterpreted, unchanged; was field 5 -- the bug)
        ]),
      );
    });

    test('Int32 negative (-5)', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'i32n', alias: 6, datatype: SparkplugDatatype.int32, value: -5),
      );
      expect(got.metrics.single.value, -5);
    });

    test('Int64 negative (-5) terminates and round-trips', () {
      // Regression test for the latent _writeVarint non-termination bug:
      // before the fix, `_writeVarint` used `(v - byte) ~/ 128`, which for
      // any negative `v` converges to -1 and loops forever emitting 0xFF
      // bytes, hanging the encoder. This test's mere completion (within the
      // test runner's default timeout) demonstrates termination; the
      // assertion below additionally proves the emitted bytes decode back
      // to the exact original signed value.
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'i64n', alias: 10, datatype: SparkplugDatatype.int64, value: -5),
      );
      final SparkplugMetric m = got.metrics.single;
      expect(m.datatype, SparkplugDatatype.int64);
      expect(m.value, -5);
    });

    test('Int64 positive (70000) round-trips unchanged', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'i64p', alias: 11, datatype: SparkplugDatatype.int64, value: 70000),
      );
      final SparkplugMetric m = got.metrics.single;
      expect(m.datatype, SparkplugDatatype.int64);
      expect(m.value, 70000);
    });

    test('Int64 large negative round-trips (-9223372036854775808, Int64.min)', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(
          name: 'i64min',
          alias: 12,
          datatype: SparkplugDatatype.int64,
          value: -9223372036854775808,
        ),
      );
      expect(got.metrics.single.value, -9223372036854775808);
    });

    test('Double (3.5)', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'd', alias: 7, datatype: SparkplugDatatype.double_, value: 3.5),
      );
      final SparkplugMetric m = got.metrics.single;
      expect(m.datatype, SparkplugDatatype.double_);
      expect(m.value, 3.5);
    });

    test('UInt64 bdSeq via long_value', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(name: 'bdSeq', datatype: SparkplugDatatype.uint64, value: 42),
      );
      final SparkplugMetric m = got.metrics.single;
      expect(m.name, 'bdSeq');
      expect(m.alias, isNull);
      expect(m.datatype, SparkplugDatatype.uint64);
      expect(m.value, 42);
    });

    test('metric without name (NDATA-style, alias-only)', () {
      final SparkplugPayload got = roundTrip(
        const SparkplugMetric(alias: 9, datatype: SparkplugDatatype.boolean, value: true),
      );
      final SparkplugMetric m = got.metrics.single;
      expect(m.name, isNull);
      expect(m.alias, 9);
      expect(m.value, true);
    });

    test('multiple metrics in one Payload', () {
      const SparkplugPayload sent = SparkplugPayload(
        timestampMs: 123,
        seq: 7,
        metrics: <SparkplugMetric>[
          SparkplugMetric(name: 'a', alias: 1, datatype: SparkplugDatatype.boolean, value: true),
          SparkplugMetric(name: 'b', alias: 2, datatype: SparkplugDatatype.int32, value: 70000),
        ],
      );
      final SparkplugPayload got = decodePayload(encodePayload(sent));
      expect(got.metrics, hasLength(2));
      expect(got.metrics[0].name, 'a');
      expect(got.metrics[1].name, 'b');
      expect(got.metrics[1].value, 70000);
    });
  });

  group('SparkplugDatatype.forTag', () {
    test('maps this app\'s tag datatypes to Sparkplug B datatype constants', () {
      expect(SparkplugDatatype.forTag('BOOL'), SparkplugDatatype.boolean);
      expect(SparkplugDatatype.forTag('INT16'), SparkplugDatatype.int16);
      expect(SparkplugDatatype.forTag('INT32'), SparkplugDatatype.int32);
      expect(SparkplugDatatype.forTag('FLOAT64'), SparkplugDatatype.double_);
    });

    test('throws on an unrecognized tag datatype', () {
      expect(() => SparkplugDatatype.forTag('NOPE'), throwsArgumentError);
    });
  });

  group('SparkplugSeq', () {
    test('starts at 0 (NBIRTH uses seq 0)', () {
      final SparkplugSeq seq = SparkplugSeq();
      expect(seq.next(), 0);
    });

    test('increments and rolls 255 -> 0', () {
      final SparkplugSeq seq = SparkplugSeq();
      int last = -1;
      for (int i = 0; i < 255; i++) {
        last = seq.next();
      }
      expect(last, 254);
      expect(seq.next(), 255);
      expect(seq.next(), 0);
    });

    test('reset() returns the counter to 0', () {
      final SparkplugSeq seq = SparkplugSeq();
      seq.next();
      seq.next();
      seq.reset();
      expect(seq.next(), 0);
    });
  });

  group('SparkplugBdSeq', () {
    test('starts at 0 and increments monotonically', () {
      final SparkplugBdSeq bdSeq = SparkplugBdSeq();
      expect(bdSeq.value, 0);
      expect(bdSeq.next(), 1);
      expect(bdSeq.next(), 2);
      expect(bdSeq.value, 2);
    });
  });
}

// ---------------------------------------------------------------------------
// Test-only Sparkplug B decoder. Mirrors the wire format documented at the
// top of mqtt_sparkplug.dart, including the same-width unsigned<->signed
// reinterpretation `int_value` requires for negative Int8/Int16/Int32.
// Never shipped in production code — see the file-level comment above.
// ---------------------------------------------------------------------------

class _Varint {
  final int value;
  final int nextPos;
  const _Varint(this.value, this.nextPos);
}

_Varint _readVarint(Uint8List data, int pos) {
  int result = 0;
  int shiftMultiplier = 1;
  int p = pos;
  while (true) {
    final int b = data[p];
    result += (b & 0x7F) * shiftMultiplier;
    p += 1;
    if ((b & 0x80) == 0) {
      break;
    }
    shiftMultiplier *= 128;
  }
  return _Varint(result, p);
}

String _utf8Decode(Uint8List bytes) {
  final List<int> codePoints = <int>[];
  int i = 0;
  while (i < bytes.length) {
    final int b0 = bytes[i];
    if (b0 <= 0x7F) {
      codePoints.add(b0);
      i += 1;
    } else if (b0 & 0xE0 == 0xC0) {
      codePoints.add(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if (b0 & 0xF0 == 0xE0) {
      codePoints.add(((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
      i += 3;
    } else {
      codePoints.add(
        ((b0 & 0x07) << 18) |
            ((bytes[i + 1] & 0x3F) << 12) |
            ((bytes[i + 2] & 0x3F) << 6) |
            (bytes[i + 3] & 0x3F),
      );
      i += 4;
    }
  }
  return String.fromCharCodes(codePoints);
}

/// Reverses [_toUnsignedWireInt]'s reinterpretation: given the raw
/// non-negative varint read off `int_value` and the metric's declared
/// datatype, sign-extends back to the original signed value.
int _fromUnsignedWireInt(int datatype, int raw) {
  switch (datatype) {
    case SparkplugDatatype.int8:
      return raw >= 0x80 ? raw - 0x100 : raw;
    case SparkplugDatatype.int16:
      return raw >= 0x8000 ? raw - 0x10000 : raw;
    case SparkplugDatatype.int32:
      return raw >= 0x80000000 ? raw - 0x100000000 : raw;
    default:
      return raw;
  }
}

SparkplugMetric decodeMetric(Uint8List data) {
  String? name;
  int? alias;
  int datatype = -1;
  Object? value;
  int pos = 0;
  while (pos < data.length) {
    final _Varint tagVarint = _readVarint(data, pos);
    final int tag = tagVarint.value;
    pos = tagVarint.nextPos;
    final int fieldNumber = tag >> 3;
    final int wireType = tag & 0x7;
    switch (fieldNumber) {
      case 1: // name (string)
        final _Varint len = _readVarint(data, pos);
        pos = len.nextPos;
        name = _utf8Decode(Uint8List.sublistView(data, pos, pos + len.value));
        pos += len.value;
        break;
      case 2: // alias (varint)
        final _Varint v = _readVarint(data, pos);
        alias = v.value;
        pos = v.nextPos;
        break;
      case 3: // per-metric timestamp (varint) — not used by this app; skip
        final _Varint v = _readVarint(data, pos);
        pos = v.nextPos;
        break;
      case 4: // datatype (varint)
        final _Varint v = _readVarint(data, pos);
        datatype = v.value;
        pos = v.nextPos;
        break;
      case 10: // int_value (varint, unsigned-reinterpreted)
        final _Varint v = _readVarint(data, pos);
        value = _fromUnsignedWireInt(datatype, v.value);
        pos = v.nextPos;
        break;
      case 11: // long_value (varint)
        final _Varint v = _readVarint(data, pos);
        value = v.value;
        pos = v.nextPos;
        break;
      case 13: // double_value (64-bit little-endian)
        final ByteData bd = ByteData.sublistView(data, pos, pos + 8);
        value = bd.getFloat64(0, Endian.little);
        pos += 8;
        break;
      case 14: // boolean_value (varint 0/1)
        final _Varint v = _readVarint(data, pos);
        value = v.value != 0;
        pos = v.nextPos;
        break;
      case 15: // string_value (string)
        final _Varint len = _readVarint(data, pos);
        pos = len.nextPos;
        value = _utf8Decode(Uint8List.sublistView(data, pos, pos + len.value));
        pos += len.value;
        break;
      default:
        throw StateError('unexpected metric field $fieldNumber (wireType $wireType)');
    }
  }
  return SparkplugMetric(name: name, alias: alias, datatype: datatype, value: value!);
}

SparkplugPayload decodePayload(Uint8List data) {
  int timestampMs = 0;
  int seq = 0;
  final List<SparkplugMetric> metrics = <SparkplugMetric>[];
  int pos = 0;
  while (pos < data.length) {
    final _Varint tagVarint = _readVarint(data, pos);
    final int tag = tagVarint.value;
    pos = tagVarint.nextPos;
    final int fieldNumber = tag >> 3;
    switch (fieldNumber) {
      case 1: // timestamp (varint)
        final _Varint v = _readVarint(data, pos);
        timestampMs = v.value;
        pos = v.nextPos;
        break;
      case 2: // metrics (length-delimited submessage)
        final _Varint len = _readVarint(data, pos);
        pos = len.nextPos;
        metrics.add(decodeMetric(Uint8List.sublistView(data, pos, pos + len.value)));
        pos += len.value;
        break;
      case 3: // seq (varint)
        final _Varint v = _readVarint(data, pos);
        seq = v.value;
        pos = v.nextPos;
        break;
      default:
        throw StateError('unexpected Payload field $fieldNumber');
    }
  }
  return SparkplugPayload(timestampMs: timestampMs, seq: seq, metrics: metrics);
}
