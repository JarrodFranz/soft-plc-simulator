// Pure Sparkplug B protobuf `Payload`/`Metric` encoder — no dart:io /
// Flutter imports, only `dart:typed_data`. Hand-rolls the protobuf wire
// format for the Eclipse Tahu `sparkplug_b.proto` `Payload` message (the
// subset this app publishes: timestamp, seq, and a flat list of metrics with
// scalar values) so the later publisher task (NBIRTH/NDATA/NDEATH/NCMD) can
// build frames without a protoc-generated dependency.
//
// Protobuf wire reference: every field is a tag byte `(fieldNumber << 3) |
// wireType` followed by its value, where wireType 0 = varint, 1 = 64-bit
// fixed, 2 = length-delimited (strings/bytes/submessages carry an extra
// varint length prefix before their bytes).
//
// `Payload` fields used here: 1 `timestamp` (uint64 varint), 2 `metrics`
// (repeated message, length-delimited), 3 `seq` (uint64 varint).
// `Metric` fields used here: 1 `name` (string, only sent on NBIRTH-style
// metrics — omitted whenever `name` is null to save bytes on NDATA), 2
// `alias` (uint64 varint, omitted when null), 4 `datatype` (uint32 varint),
// and exactly one value field chosen by `datatype`: 5 `int_value` (uint32
// varint) for Int8/Int16/Int32, 6 `long_value` (uint64 varint) for UInt64
// (used for the `bdSeq` metric), 8 `double_value` (64-bit, written
// little-endian via `ByteData.setFloat64(..., Endian.little)`), 9
// `boolean_value` (varint 0/1) for Boolean, 10 `string_value` (string) for
// String. Metric field 3 (`timestamp`) is intentionally not emitted by this
// encoder — every metric here is stamped only via the enclosing Payload's
// timestamp — so there's no per-metric timestamp field to wire up.
//
// Signed ints in an unsigned wire field: `int_value` is wire-typed as a
// uint32 varint, so a negative Int8/Int16/Int32 (e.g. Int16 -5) cannot be
// varint-encoded directly (Dart's `_writeVarint` here only ever emits
// non-negative values). Instead, per Sparkplug/Tahu convention, a negative
// value is first reinterpreted as its same-width unsigned twin — Int16 -5
// becomes 65531 (-5 + 0x10000), Int32 -5 becomes 4294967291 (-5 +
// 0x100000000) — and *that* non-negative number is varint-encoded. The
// test-only decoder reverses this by checking the datatype's sign bit and
// subtracting the width back out.
//
// dart2js-safety: every varint produced/consumed by this codec is
// non-negative (timestamps, seq, alias, datatype, the unsigned-reinterpreted
// int_value, and long_value/bdSeq), so the simple 7-bit-group loop below is
// sufficient and `setInt64`/`getInt64` (unimplemented on dart2js) are never
// needed. `bdSeq` is a small birth/death rebirth counter — it increments by
// one per NBIRTH — so across any realistic device uptime it stays far below
// 2^53, the largest integer dart2js's double-backed `int` can represent
// exactly; `long_value` for it is therefore just another non-negative
// varint, not a true 64-bit field. `double_value` is the one genuinely
// 64-bit field, and it goes through `ByteData.setFloat64`, which dart2js
// implements correctly (only the integer accessors are unsupported).
library mqtt_sparkplug;

import 'dart:typed_data';

/// Sparkplug B `Metric.datatype` values used by this encoder (subset of the
/// full Tahu enum — only the datatypes this app's tag model ever produces).
class SparkplugDatatype {
  static const int int8 = 1;
  static const int int16 = 2;
  static const int int32 = 3;
  static const int int64 = 4;
  static const int uint64 = 8;
  static const int float = 9;
  static const int double_ = 10;
  static const int boolean = 11;
  static const int string = 12;

  const SparkplugDatatype._();

  /// Maps this app's internal tag data-type tags (`BOOL`, `INT16`, `INT32`,
  /// `FLOAT64`) to the Sparkplug B datatype constant used on the wire.
  static int forTag(String dataType) {
    switch (dataType) {
      case 'BOOL':
        return boolean;
      case 'INT16':
        return int16;
      case 'INT32':
        return int32;
      case 'FLOAT64':
        return double_;
      default:
        throw ArgumentError.value(dataType, 'dataType', 'unsupported tag datatype');
    }
  }
}

/// One Sparkplug B `Metric`: `name` is present only on NBIRTH-style metric
/// definitions (omitted thereafter and referenced by `alias` instead),
/// `alias` is the numeric handle used on NDATA/NCMD, `datatype` is one of
/// the `SparkplugDatatype` constants, and `value` is the Dart value to
/// encode for that datatype (`bool` for Boolean, `int` for Int8/16/32/UInt64,
/// `double` for Double, `String` for String).
class SparkplugMetric {
  final String? name;
  final int? alias;
  final int datatype;
  final Object value;

  const SparkplugMetric({
    this.name,
    this.alias,
    required this.datatype,
    required this.value,
  });
}

/// A Sparkplug B `Payload`: `timestampMs` and `seq` are the message's own
/// varint fields; `metrics` is the repeated submessage list.
class SparkplugPayload {
  final int timestampMs;
  final int seq;
  final List<SparkplugMetric> metrics;

  const SparkplugPayload({
    required this.timestampMs,
    required this.seq,
    required this.metrics,
  });
}

/// Sparkplug B's 0-255 message sequence counter (`seq`). Every NBIRTH resets
/// it to 0 via [reset]; every subsequent NDATA/NDEATH/NBIRTH call to [next]
/// returns the current value and advances it, wrapping 255 back to 0.
class SparkplugSeq {
  int _value = 0;

  /// Returns the current seq value and advances the counter, wrapping
  /// 255 -> 0.
  int next() {
    final int v = _value;
    _value = (_value + 1) % 256;
    return v;
  }

  /// Resets the counter to 0 (call when sending a fresh NBIRTH).
  void reset() {
    _value = 0;
  }
}

/// Sparkplug B's `bdSeq` (birth/death sequence) bookkeeping counter: a
/// monotonically increasing UInt64 metric included in every NBIRTH/NDEATH
/// pair so subscribers can tell rebirths apart. Unlike [SparkplugSeq] it
/// does not wrap at 256 — see the dart2js-safety note above for why an
/// unbounded increment here is still safe.
class SparkplugBdSeq {
  int _value = 0;

  /// Current bdSeq value (unchanged by reading it).
  int get value => _value;

  /// Advances bdSeq by one (call on each new NBIRTH) and returns the new
  /// value.
  int next() {
    _value += 1;
    return _value;
  }
}

/// Encodes [payload] as a Sparkplug B protobuf `Payload` message.
Uint8List encodePayload(SparkplugPayload payload) {
  final BytesBuilder out = BytesBuilder();
  _writeTag(out, 1, _wireVarint);
  _writeVarint(out, payload.timestampMs);
  for (final SparkplugMetric metric in payload.metrics) {
    final Uint8List metricBytes = encodeMetric(metric);
    _writeTag(out, 2, _wireLengthDelimited);
    _writeVarint(out, metricBytes.length);
    out.add(metricBytes);
  }
  _writeTag(out, 3, _wireVarint);
  _writeVarint(out, payload.seq);
  return out.toBytes();
}

/// Encodes a single [metric] as a Sparkplug B protobuf `Metric` submessage
/// (the bytes nested inside a Payload's field-2 length-delimited entry).
Uint8List encodeMetric(SparkplugMetric metric) {
  final BytesBuilder out = BytesBuilder();
  if (metric.name != null) {
    _writeTag(out, 1, _wireLengthDelimited);
    final Uint8List nameBytes = _utf8Encode(metric.name!);
    _writeVarint(out, nameBytes.length);
    out.add(nameBytes);
  }
  if (metric.alias != null) {
    _writeTag(out, 2, _wireVarint);
    _writeVarint(out, metric.alias!);
  }
  _writeTag(out, 4, _wireVarint);
  _writeVarint(out, metric.datatype);
  _writeMetricValue(out, metric.datatype, metric.value);
  return out.toBytes();
}

void _writeMetricValue(BytesBuilder out, int datatype, Object value) {
  switch (datatype) {
    case SparkplugDatatype.int8:
    case SparkplugDatatype.int16:
    case SparkplugDatatype.int32:
      _writeTag(out, 5, _wireVarint);
      _writeVarint(out, _toUnsignedWireInt(datatype, value as int));
      break;
    case SparkplugDatatype.int64:
    case SparkplugDatatype.uint64:
      _writeTag(out, 6, _wireVarint);
      _writeVarint(out, value as int);
      break;
    case SparkplugDatatype.double_:
      _writeTag(out, 8, _wire64Bit);
      final ByteData bd = ByteData(8);
      bd.setFloat64(0, (value as num).toDouble(), Endian.little);
      out.add(bd.buffer.asUint8List());
      break;
    case SparkplugDatatype.boolean:
      _writeTag(out, 9, _wireVarint);
      _writeVarint(out, (value as bool) ? 1 : 0);
      break;
    case SparkplugDatatype.string:
      _writeTag(out, 10, _wireLengthDelimited);
      final Uint8List strBytes = _utf8Encode(value as String);
      _writeVarint(out, strBytes.length);
      out.add(strBytes);
      break;
    default:
      throw ArgumentError.value(datatype, 'datatype', 'unsupported Sparkplug datatype');
  }
}

/// Reinterprets a signed Int8/Int16/Int32 [value] as its same-width unsigned
/// twin so it can ride in the uint32 `int_value` wire field (see the
/// file-level doc comment for why: the wire field itself is unsigned).
/// Non-negative values pass through unchanged.
int _toUnsignedWireInt(int datatype, int value) {
  if (value >= 0) {
    return value;
  }
  switch (datatype) {
    case SparkplugDatatype.int8:
      return value + 0x100;
    case SparkplugDatatype.int16:
      return value + 0x10000;
    case SparkplugDatatype.int32:
    default:
      return value + 0x100000000;
  }
}

const int _wireVarint = 0;
const int _wire64Bit = 1;
const int _wireLengthDelimited = 2;

void _writeTag(BytesBuilder out, int fieldNumber, int wireType) {
  _writeVarint(out, (fieldNumber << 3) | wireType);
}

/// Writes [value] as a protobuf base-128 varint (7 data bits per byte, LSB
/// group first, high bit set on every byte but the last). Every call site in
/// this file passes a non-negative value (see the dart2js-safety note above).
void _writeVarint(BytesBuilder out, int value) {
  int v = value;
  while (true) {
    final int byte = v & 0x7F;
    v = (v - byte) ~/ 128;
    if (v == 0) {
      out.addByte(byte);
      break;
    }
    out.addByte(byte | 0x80);
  }
}

/// Hand-rolled UTF-8 encoder over Unicode code points (`String.runes`
/// already assembles UTF-16 surrogate pairs into single code points), so no
/// `dart:convert` import is needed for this pure-Dart codec.
Uint8List _utf8Encode(String value) {
  final BytesBuilder out = BytesBuilder();
  for (final int codePoint in value.runes) {
    if (codePoint <= 0x7F) {
      out.addByte(codePoint);
    } else if (codePoint <= 0x7FF) {
      out.addByte(0xC0 | (codePoint >> 6));
      out.addByte(0x80 | (codePoint & 0x3F));
    } else if (codePoint <= 0xFFFF) {
      out.addByte(0xE0 | (codePoint >> 12));
      out.addByte(0x80 | ((codePoint >> 6) & 0x3F));
      out.addByte(0x80 | (codePoint & 0x3F));
    } else {
      out.addByte(0xF0 | (codePoint >> 18));
      out.addByte(0x80 | ((codePoint >> 12) & 0x3F));
      out.addByte(0x80 | ((codePoint >> 6) & 0x3F));
      out.addByte(0x80 | (codePoint & 0x3F));
    }
  }
  return out.toBytes();
}
