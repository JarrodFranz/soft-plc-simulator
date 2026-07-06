// OPC UA Binary encoding (OPC UA Part 6, §5.2) — pure Dart, no dart:io / Flutter
// imports. Used by the in-app OPC UA server (ADR-010: in-app protocol hosting).
//
// Every byte-layout decision here is cross-checked against the Rust `opcua`
// crate (v0.12.0), vendored locally at:
//   C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/
// Specific files cited inline next to the relevant encoder/decoder.
//
// All multi-byte integers are little-endian.
library opcua_binary;

import 'dart:convert';
import 'dart:typed_data';

/// A NodeId: namespace index + a numeric or string identifier.
///
/// Wire encodings (node_id.rs `BinaryEncoder<NodeId>`):
///   0x00 two-byte:  ns==0 && numeric<=255   -> [0x00, id]
///   0x01 four-byte: ns<=255 && numeric<=65535 -> [0x01, ns(u8), id(u16 LE)]
///   0x02 numeric:   otherwise (numeric)     -> [0x02, ns(u16 LE), id(u32 LE)]
///   0x03 string:                            -> [0x03, ns(u16 LE), string]
/// The writer always chooses the smallest applicable encoding.
class OpcNodeId {
  final int namespace;
  final int? numericId;
  final String? stringId;

  const OpcNodeId.numeric(this.namespace, int id)
      : numericId = id,
        stringId = null;

  const OpcNodeId.string(this.namespace, this.stringId) : numericId = null;

  bool get isNumeric => numericId != null;
  bool get isString => stringId != null;

  @override
  bool operator ==(Object other) =>
      other is OpcNodeId &&
      other.namespace == namespace &&
      other.numericId == numericId &&
      other.stringId == stringId;

  @override
  int get hashCode => Object.hash(namespace, numericId, stringId);

  @override
  String toString() => isNumeric
      ? 'OpcNodeId(ns:$namespace, i:$numericId)'
      : 'OpcNodeId(ns:$namespace, s:$stringId)';
}

/// A qualified name: namespace index + a (possibly null) name string.
class OpcQualifiedName {
  final int ns;
  final String? name;

  const OpcQualifiedName({required this.ns, this.name});

  @override
  bool operator ==(Object other) =>
      other is OpcQualifiedName && other.ns == ns && other.name == name;

  @override
  int get hashCode => Object.hash(ns, name);

  @override
  String toString() => 'OpcQualifiedName(ns:$ns, name:$name)';
}

/// LocalizedText: an optional locale + optional text. Encoding mask
/// (localized_text.rs): 0x01 = locale present (non-empty), 0x02 = text
/// present (non-empty).
class OpcLocalizedText {
  final String? locale;
  final String? text;

  const OpcLocalizedText({this.locale, this.text});

  @override
  bool operator ==(Object other) =>
      other is OpcLocalizedText && other.locale == locale && other.text == text;

  @override
  int get hashCode => Object.hash(locale, text);

  @override
  String toString() => 'OpcLocalizedText(locale:$locale, text:$text)';
}

/// A Variant: a typed value, optionally an array.
///
/// Scalar type ids (node_ids.rs `DataTypeId`, verified against the Rust
/// source): Boolean 1, SByte 2, Byte 3, Int16 4, UInt16 5, Int32 6, UInt32 7,
/// Int64 8, UInt64 9, Float 10, Double 11, String 12, DateTime 13,
/// StatusCode 19, NodeId 17, QualifiedName 20, LocalizedText 21.
/// Arrays: the top bit 0x80 (variant_type_id.rs `ARRAY_VALUES_BIT`) is OR'd
/// into the encoding mask, followed by an Int32 length + elements.
class OpcVariant {
  final int typeId;
  final Object? value;
  final bool isArray;

  const OpcVariant({
    required this.typeId,
    required this.value,
    this.isArray = false,
  });

  @override
  bool operator ==(Object other) {
    if (other is! OpcVariant) return false;
    if (other.typeId != typeId || other.isArray != isArray) return false;
    if (isArray) {
      final a = value as List;
      final b = other.value as List;
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return other.value == value;
  }

  @override
  int get hashCode => Object.hash(typeId, isArray, value is List ? null : value);

  @override
  String toString() => 'OpcVariant(typeId:$typeId, isArray:$isArray, value:$value)';
}

/// DataValue: variant + status + source/server timestamps, all optional.
/// Encoding mask bits (data_value.rs `DataValueFlags`):
///   0x01 HAS_VALUE, 0x02 HAS_STATUS, 0x04 HAS_SOURCE_TIMESTAMP,
///   0x08 HAS_SERVER_TIMESTAMP. (Picoseconds sub-fields are not used here.)
class OpcDataValue {
  final OpcVariant? variant;
  final int? status;
  final DateTime? sourceTs;
  final DateTime? serverTs;

  const OpcDataValue({this.variant, this.status, this.sourceTs, this.serverTs});
}

/// RequestHeader (request_header.rs): authToken NodeId, timestamp DateTime,
/// requestHandle UInt32, returnDiagnostics UInt32, auditEntryId String,
/// timeoutHint UInt32, additionalHeader = empty ExtensionObject.
class RequestHeader {
  final OpcNodeId authToken;
  final DateTime? timestamp;
  final int requestHandle;
  final int returnDiagnostics;
  final String? auditEntryId;
  final int timeoutHint;

  const RequestHeader({
    required this.authToken,
    required this.timestamp,
    required this.requestHandle,
    this.returnDiagnostics = 0,
    this.auditEntryId,
    this.timeoutHint = 0,
  });
}

/// ResponseHeader (response_header.rs): timestamp, requestHandle,
/// serviceResult StatusCode, empty DiagnosticInfo (single 0x00 byte), empty
/// string table (-1 length, i.e. null array — see encoding.rs `write_array`),
/// empty ExtensionObject.
class ResponseHeader {
  final DateTime? timestamp;
  final int requestHandle;
  final int serviceResult;

  const ResponseHeader({
    required this.timestamp,
    required this.requestHandle,
    this.serviceResult = 0,
  });
}

/// The OPC UA epoch: 1601-01-01T00:00:00Z. DateTime ticks are the count of
/// 100ns intervals since this instant (date_time.rs). 0 ticks == null.
final DateTime _opcUaEpoch = DateTime.utc(1601, 1, 1);

/// The OPC UA "endtimes": Dec 31, 9999 23:59:59Z (date_time.rs
/// `endtimes_chrono()`, MAX_YEAR = 9999). Dates at or beyond this instant
/// clamp to `i64::MAX` ticks on write (date_time.rs `checked_ticks()`).
final DateTime _opcUaEndtimes = DateTime.utc(9999, 12, 31, 23, 59, 59);

/// Ticks corresponding to [_opcUaEndtimes], for the `> endtimes_ticks()`
/// comparison mirrored from Rust's `checked_ticks()`.
final int _opcUaEndtimesTicks =
    _opcUaEndtimes.difference(_opcUaEpoch).inMicroseconds * 10;

/// i64::MAX (0x7FFFFFFFFFFFFFFF). The raw decimal literal
/// `9223372036854775807` and the hex literal `0x7FFFFFFFFFFFFFFF` are both
/// rejected by dart2js at compile time ("can't be represented exactly in
/// JavaScript"). A previous version of this constant used `(1 << 63) - 1`,
/// which *compiles* under dart2js but is a silent runtime correctness bug
/// there: dart2js implements `<<` with JavaScript's 32-bit bitwise
/// semantics, so `1 << 63` evaluates to `-1` at runtime on the web (verified
/// via `dart compile js` + `node`), making the whole expression `-2`, not
/// i64::MAX. `(0x7FFFFFFF << 32) | 0xFFFFFFFF` compiles under dart2js too,
/// and — unlike the previous form — is exact on the native 64-bit VM (the
/// only platform that ever evaluates this constant; OPC UA hosting is
/// native-only, see date_time.rs `checked_ticks()` callers below). It is
/// still not exact on dart2js at runtime (32-bit `<<` truncates the high
/// word there), but that no longer matters since it was never correct on
/// dart2js in either form and this codec path never executes on web.
const int _int64Max = (0x7FFFFFFF << 32) | 0xFFFFFFFF;

int _dateTimeToTicks(DateTime? dt) {
  if (dt == null) return 0;
  final utc = dt.isUtc ? dt : dt.toUtc();
  final micros = utc.difference(_opcUaEpoch).inMicroseconds;
  if (micros <= 0) return 0;
  final ticks = micros * 10; // 1 microsecond == 10 ticks of 100ns.
  // Mirror Rust's checked_ticks(): clamp dates past the OPC UA endtimes
  // (9999-12-31T23:59:59Z) to i64::MAX rather than overflowing/wrapping.
  if (ticks > _opcUaEndtimesTicks) return _int64Max;
  return ticks;
}

DateTime? _ticksToDateTime(int ticks) {
  if (ticks == 0) return null;
  final micros = ticks ~/ 10;
  return _opcUaEpoch.add(Duration(microseconds: micros));
}

/// Growable little-endian binary writer for OPC UA Binary encoding.
class OpcUaWriter {
  final BytesBuilder _builder = BytesBuilder(copy: true);

  void boolean(bool value) => uint8(value ? 1 : 0);

  void uint8(int value) {
    _builder.addByte(value & 0xFF);
  }

  void int8(int value) {
    uint8(value & 0xFF);
  }

  void uint16(int value) {
    final b = ByteData(2)..setUint16(0, value, Endian.little);
    _builder.add(b.buffer.asUint8List());
  }

  void int16(int value) {
    final b = ByteData(2)..setInt16(0, value, Endian.little);
    _builder.add(b.buffer.asUint8List());
  }

  void uint32(int value) {
    final b = ByteData(4)..setUint32(0, value, Endian.little);
    _builder.add(b.buffer.asUint8List());
  }

  void int32(int value) {
    final b = ByteData(4)..setInt32(0, value, Endian.little);
    _builder.add(b.buffer.asUint8List());
  }

  // uint64/int64 are hand-rolled as two little-endian 32-bit halves via
  // setUint32 rather than ByteData.setUint64/setInt64: dart2js does not
  // implement the 64-bit accessors at all and throws `Unsupported
  // operation: Int64 accessor not supported by dart2js` at runtime (the web
  // build still *compiles* since this is a runtime-only failure — verified
  // via `dart compile js` + node). setUint32 is fully supported on both
  // native and dart2js. On the native 64-bit VM this decomposition is exact
  // and byte-identical to setUint64/setInt64 for every representable value,
  // including negative int64s (two's-complement bit pattern is preserved
  // by `& 0xFFFFFFFF` / `>> 32` on Dart's 64-bit native int).
  // On dart2js, Dart's bitwise operators truncate to 32 bits, so values
  // outside +-2^31 lose their high bits here; that is an accepted
  // limitation (not a crash) because this codec never executes on web today
  // (OPC UA hosting requires ServerSocket, which the browser sandbox does
  // not provide).
  void uint64(int value) {
    final lo = value & 0xFFFFFFFF;
    final hi = (value >> 32) & 0xFFFFFFFF;
    final b = ByteData(8)
      ..setUint32(0, lo, Endian.little)
      ..setUint32(4, hi, Endian.little);
    _builder.add(b.buffer.asUint8List());
  }

  void int64(int value) {
    final lo = value & 0xFFFFFFFF;
    final hi = (value >> 32) & 0xFFFFFFFF;
    final b = ByteData(8)
      ..setUint32(0, lo, Endian.little)
      ..setUint32(4, hi, Endian.little);
    _builder.add(b.buffer.asUint8List());
  }

  void float32(double value) {
    final b = ByteData(4)..setFloat32(0, value, Endian.little);
    _builder.add(b.buffer.asUint8List());
  }

  void float64(double value) {
    final b = ByteData(8)..setFloat64(0, value, Endian.little);
    _builder.add(b.buffer.asUint8List());
  }

  /// String: Int32 length (-1 == null) + UTF-8 bytes. (string.rs)
  void string(String? value) {
    if (value == null) {
      int32(-1);
      return;
    }
    final bytes = utf8.encode(value);
    int32(bytes.length);
    _builder.add(bytes);
  }

  /// ByteString: Int32 length (-1 == null) + raw bytes. (byte_string.rs)
  void byteString(List<int>? value) {
    if (value == null) {
      int32(-1);
      return;
    }
    int32(value.length);
    _builder.add(Uint8List.fromList(value));
  }

  /// DateTime: Int64 ticks since 1601-01-01T00:00:00Z; null -> 0. (date_time.rs)
  void dateTime(DateTime? value) {
    int64(_dateTimeToTicks(value));
  }

  /// Guid: 16 raw bytes; null -> 16 zero bytes. (guid.rs)
  void guid(List<int>? value) {
    if (value == null) {
      _builder.add(Uint8List(16));
      return;
    }
    if (value.length != 16) {
      throw ArgumentError('Guid must be exactly 16 bytes, got ${value.length}');
    }
    _builder.add(Uint8List.fromList(value));
  }

  /// NodeId: writer chooses the smallest of the four encodings. (node_id.rs)
  void nodeId(OpcNodeId id) {
    if (id.isString) {
      uint8(0x03);
      uint16(id.namespace);
      string(id.stringId);
      return;
    }
    final value = id.numericId!;
    if (id.namespace == 0 && value <= 255) {
      uint8(0x00);
      uint8(value);
    } else if (id.namespace <= 255 && value <= 65535) {
      uint8(0x01);
      uint8(id.namespace);
      uint16(value);
    } else {
      uint8(0x02);
      uint16(id.namespace);
      uint32(value);
    }
  }

  /// ExpandedNodeId: written as a plain NodeId when there's no namespace uri
  /// or server index (v1 never sets those flag bits — expanded_node_id.rs
  /// encodes the same as NodeId plus optional trailing fields gated by the
  /// top two bits of the encoding byte, which we never set).
  void expandedNodeId(OpcNodeId id) => nodeId(id);

  /// StatusCode: UInt32.
  void statusCode(int value) => uint32(value);

  /// QualifiedName: UInt16 namespace index + String name. (qualified_name.rs)
  void qualifiedName(OpcQualifiedName value) {
    uint16(value.ns);
    string(value.name);
  }

  /// LocalizedText: 1-byte mask (0x01 locale, 0x02 text) + present fields.
  /// (localized_text.rs)
  void localizedText(OpcLocalizedText value) {
    final hasLocale = value.locale != null && value.locale!.isNotEmpty;
    final hasText = value.text != null && value.text!.isNotEmpty;
    var mask = 0;
    if (hasLocale) mask |= 0x01;
    if (hasText) mask |= 0x02;
    uint8(mask);
    if (hasLocale) string(value.locale);
    if (hasText) string(value.text);
  }

  /// Variant: 1-byte encoding mask (type id, | 0x80 if array) + payload.
  /// (variant.rs)
  void variant(OpcVariant v) {
    final mask = v.typeId | (v.isArray ? 0x80 : 0x00);
    uint8(mask);
    if (v.isArray) {
      final list = v.value as List;
      int32(list.length);
      for (final element in list) {
        _writeVariantScalar(v.typeId, element);
      }
    } else {
      _writeVariantScalar(v.typeId, v.value);
    }
  }

  void _writeVariantScalar(int typeId, Object? value) {
    switch (typeId) {
      case 1: // Boolean
        boolean(value as bool);
        break;
      case 2: // SByte
        int8(value as int);
        break;
      case 3: // Byte
        uint8(value as int);
        break;
      case 4: // Int16
        int16(value as int);
        break;
      case 5: // UInt16
        uint16(value as int);
        break;
      case 6: // Int32
        int32(value as int);
        break;
      case 7: // UInt32
        uint32(value as int);
        break;
      case 8: // Int64
        int64(value as int);
        break;
      case 9: // UInt64
        uint64(value as int);
        break;
      case 10: // Float
        float32((value as num).toDouble());
        break;
      case 11: // Double
        float64((value as num).toDouble());
        break;
      case 12: // String
        string(value as String?);
        break;
      case 13: // DateTime
        dateTime(value as DateTime?);
        break;
      case 14: // Guid
        guid(value as List<int>?);
        break;
      case 15: // ByteString
        byteString(value as List<int>?);
        break;
      case 17: // NodeId
        nodeId(value as OpcNodeId);
        break;
      case 18: // ExpandedNodeId
        expandedNodeId(value as OpcNodeId);
        break;
      case 19: // StatusCode
        statusCode(value as int);
        break;
      case 20: // QualifiedName
        qualifiedName(value as OpcQualifiedName);
        break;
      case 21: // LocalizedText
        localizedText(value as OpcLocalizedText);
        break;
      default:
        throw ArgumentError('Unsupported Variant type id $typeId');
    }
  }

  /// DataValue: 1-byte mask (0x01 value, 0x02 status, 0x04 sourceTs,
  /// 0x08 serverTs) + present fields, in that order. (data_value.rs)
  void dataValue(OpcDataValue value) {
    var mask = 0;
    if (value.variant != null) mask |= 0x01;
    if (value.status != null) mask |= 0x02;
    if (value.sourceTs != null) mask |= 0x04;
    if (value.serverTs != null) mask |= 0x08;
    uint8(mask);
    if (value.variant != null) variant(value.variant!);
    if (value.status != null) statusCode(value.status!);
    if (value.sourceTs != null) dateTime(value.sourceTs);
    if (value.serverTs != null) dateTime(value.serverTs);
  }

  /// ExtensionObject header: NodeId typeId + 1-byte encoding
  /// (0x00 none, 0x01 ByteString body). The body bytes themselves (if any)
  /// are written by the caller immediately after this call.
  /// (extension_object.rs)
  void extensionObjectHeader(OpcNodeId typeId, {required bool hasBody}) {
    nodeId(typeId);
    uint8(hasBody ? 0x01 : 0x00);
  }

  /// DiagnosticInfo: writes the empty (all-fields-absent) 0x00 form.
  /// (diagnostic_info.rs `DiagnosticInfo::null()`)
  void emptyDiagnosticInfo() => uint8(0x00);

  /// RequestHeader (request_header.rs): authToken NodeId, timestamp
  /// DateTime, requestHandle UInt32, returnDiagnostics UInt32,
  /// auditEntryId String, timeoutHint UInt32, additionalHeader = empty
  /// ExtensionObject.
  void requestHeader(RequestHeader header) {
    nodeId(header.authToken);
    dateTime(header.timestamp);
    uint32(header.requestHandle);
    uint32(header.returnDiagnostics);
    string(header.auditEntryId);
    uint32(header.timeoutHint);
    extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false);
  }

  /// ResponseHeader (response_header.rs): timestamp, requestHandle,
  /// serviceResult StatusCode, empty DiagnosticInfo (0x00), empty string
  /// table (-1 length / null array), empty ExtensionObject.
  void responseHeader(ResponseHeader header) {
    dateTime(header.timestamp);
    uint32(header.requestHandle);
    statusCode(header.serviceResult);
    emptyDiagnosticInfo();
    int32(-1); // null string table (encoding.rs `write_array` None case).
    extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false);
  }

  Uint8List take() => _builder.takeBytes();
}

/// Bounds-checked little-endian binary reader for OPC UA Binary decoding.
/// Throws [FormatException] on truncated/malformed input — never hangs,
/// never crashes with an unrelated exception. Callers (the transport /
/// session layer) catch this at the connection boundary.
class OpcUaReader {
  final Uint8List _data;
  int _offset = 0;

  OpcUaReader(this._data);

  bool get atEnd => _offset >= _data.length;

  int get remaining => _data.length - _offset;

  void _ensure(int count) {
    if (_offset + count > _data.length) {
      throw FormatException(
        'OPC UA Binary: truncated input, need $count bytes at offset '
        '$_offset but only ${_data.length - _offset} remain',
      );
    }
  }

  bool boolean() => uint8() != 0;

  int uint8() {
    _ensure(1);
    return _data[_offset++];
  }

  int int8() {
    final v = uint8();
    return v >= 0x80 ? v - 0x100 : v;
  }

  int uint16() {
    _ensure(2);
    final v = ByteData.sublistView(_data, _offset, _offset + 2)
        .getUint16(0, Endian.little);
    _offset += 2;
    return v;
  }

  int int16() {
    _ensure(2);
    final v = ByteData.sublistView(_data, _offset, _offset + 2)
        .getInt16(0, Endian.little);
    _offset += 2;
    return v;
  }

  int uint32() {
    _ensure(4);
    final v = ByteData.sublistView(_data, _offset, _offset + 4)
        .getUint32(0, Endian.little);
    _offset += 4;
    return v;
  }

  int int32() {
    _ensure(4);
    final v = ByteData.sublistView(_data, _offset, _offset + 4)
        .getInt32(0, Endian.little);
    _offset += 4;
    return v;
  }

  // uint64/int64 are hand-rolled as two little-endian 32-bit halves via
  // getUint32 rather than ByteData.getUint64/getInt64 — see the matching
  // comment on OpcUaWriter.uint64/int64 for why (dart2js throws
  // `Unsupported operation` on the 64-bit accessors at runtime). On the
  // native 64-bit VM, reconstructing as `(hi << 32) | lo` reproduces the
  // exact signed two's-complement value for both int64 and uint64 (e.g.
  // lo=hi=0xFFFFFFFF -> -1, matching the original getUint64/getInt64
  // behavior where values above 2^63-1 read back as negative — Dart has no
  // unsigned 64-bit int type, so that quirk is preserved intentionally).
  int uint64() {
    _ensure(8);
    final view = ByteData.sublistView(_data, _offset, _offset + 8);
    final lo = view.getUint32(0, Endian.little);
    final hi = view.getUint32(4, Endian.little);
    _offset += 8;
    return (hi << 32) | lo;
  }

  int int64() {
    _ensure(8);
    final view = ByteData.sublistView(_data, _offset, _offset + 8);
    final lo = view.getUint32(0, Endian.little);
    final hi = view.getUint32(4, Endian.little);
    _offset += 8;
    return (hi << 32) | lo;
  }

  double float32() {
    _ensure(4);
    final v = ByteData.sublistView(_data, _offset, _offset + 4)
        .getFloat32(0, Endian.little);
    _offset += 4;
    return v;
  }

  double float64() {
    _ensure(8);
    final v = ByteData.sublistView(_data, _offset, _offset + 8)
        .getFloat64(0, Endian.little);
    _offset += 8;
    return v;
  }

  /// String: Int32 length (-1 == null) + UTF-8 bytes.
  String? string() {
    final len = int32();
    if (len == -1) return null;
    if (len < -1) {
      throw FormatException('OPC UA Binary: negative string length $len');
    }
    _ensure(len);
    final bytes = _data.sublist(_offset, _offset + len);
    _offset += len;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('OPC UA Binary: string is not valid UTF-8');
    }
  }

  /// ByteString: Int32 length (-1 == null) + raw bytes.
  List<int>? byteString() {
    final len = int32();
    if (len == -1) return null;
    if (len < -1) {
      throw FormatException('OPC UA Binary: negative byteString length $len');
    }
    _ensure(len);
    final bytes = _data.sublist(_offset, _offset + len);
    _offset += len;
    return bytes;
  }

  /// DateTime: Int64 ticks since 1601-01-01T00:00:00Z; 0 -> null.
  DateTime? dateTime() => _ticksToDateTime(int64());

  /// Guid: 16 raw bytes.
  List<int> guid() {
    _ensure(16);
    final bytes = _data.sublist(_offset, _offset + 16);
    _offset += 16;
    return bytes;
  }

  /// NodeId: reads whichever of the four encodings the byte indicates.
  OpcNodeId nodeId() {
    final form = uint8();
    switch (form) {
      case 0x00:
        return OpcNodeId.numeric(0, uint8());
      case 0x01:
        final ns = uint8();
        return OpcNodeId.numeric(ns, uint16());
      case 0x02:
        final ns = uint16();
        return OpcNodeId.numeric(ns, uint32());
      case 0x03:
        final ns = uint16();
        return OpcNodeId.string(ns, string());
      default:
        throw FormatException('OPC UA Binary: unrecognized NodeId form 0x${form.toRadixString(16)}');
    }
  }

  /// ExpandedNodeId: reads a NodeId form, ignoring the (unused-by-us)
  /// namespace-uri/server-index bits that would be layered on top per spec
  /// — sufficient so the reader never chokes on server-authored frames.
  OpcNodeId expandedNodeId() => nodeId();

  int statusCode() => uint32();

  OpcQualifiedName qualifiedName() {
    final ns = uint16();
    final name = string();
    return OpcQualifiedName(ns: ns, name: name);
  }

  OpcLocalizedText localizedText() {
    final mask = uint8();
    final locale = (mask & 0x01) != 0 ? string() : null;
    final text = (mask & 0x02) != 0 ? string() : null;
    return OpcLocalizedText(locale: locale, text: text);
  }

  OpcVariant variant() {
    final mask = uint8();
    final isArray = (mask & 0x80) != 0;
    // Rust reference: variant_type_id.rs:249-253 defines
    // ARRAY_DIMENSIONS_BIT = 0x40, ARRAY_VALUES_BIT = 0x80,
    // ARRAY_MASK = ARRAY_DIMENSIONS_BIT | ARRAY_VALUES_BIT (0xC0); variant.rs:585
    // computes the element type id as `encoding_mask & !ARRAY_MASK`, i.e. both
    // high bits must be cleared, not just 0x80. Using `& 0x7F` here would fold
    // a set ArrayDimensionsBit (0x40) into the type id, silently corrupting it.
    final typeId = mask & 0x3F;
    if ((mask & 0x40) != 0) {
      // v1 scope: array dimensions (multi-dimensional arrays) are not
      // supported. Reject cleanly rather than silently mis-parsing.
      throw FormatException(
        'OPC UA Binary: Variant array dimensions are not supported '
        '(typeId=$typeId)',
      );
    }
    if (isArray) {
      final length = int32();
      if (length < -1) {
        throw FormatException('OPC UA Binary: invalid Variant array length $length');
      }
      final list = <Object?>[];
      final count = length <= 0 ? 0 : length;
      for (var i = 0; i < count; i++) {
        list.add(_readVariantScalar(typeId));
      }
      return OpcVariant(typeId: typeId, value: list, isArray: true);
    }
    return OpcVariant(typeId: typeId, value: _readVariantScalar(typeId));
  }

  Object? _readVariantScalar(int typeId) {
    switch (typeId) {
      case 0:
        return null; // Empty
      case 1:
        return boolean();
      case 2:
        return int8();
      case 3:
        return uint8();
      case 4:
        return int16();
      case 5:
        return uint16();
      case 6:
        return int32();
      case 7:
        return uint32();
      case 8:
        return int64();
      case 9:
        return uint64();
      case 10:
        return float32();
      case 11:
        return float64();
      case 12:
        return string();
      case 13:
        return dateTime();
      case 14:
        return guid();
      case 15:
        return byteString();
      case 17:
        return nodeId();
      case 18:
        return expandedNodeId();
      case 19:
        return statusCode();
      case 20:
        return qualifiedName();
      case 21:
        return localizedText();
      default:
        throw FormatException('OPC UA Binary: unsupported Variant type id $typeId');
    }
  }

  OpcDataValue dataValue() {
    final mask = uint8();
    final v = (mask & 0x01) != 0 ? variant() : null;
    final status = (mask & 0x02) != 0 ? statusCode() : null;
    final sourceTs = (mask & 0x04) != 0 ? dateTime() : null;
    final serverTs = (mask & 0x08) != 0 ? dateTime() : null;
    return OpcDataValue(
      variant: v,
      status: status,
      sourceTs: sourceTs,
      serverTs: serverTs,
    );
  }

  /// Reads the ExtensionObject header (NodeId typeId + encoding byte).
  /// Returns the typeId; the caller inspects [lastExtensionObjectHasBody]
  /// to know whether a ByteString body follows.
  bool _lastExtensionObjectHasBody = false;
  bool get lastExtensionObjectHasBody => _lastExtensionObjectHasBody;

  OpcNodeId extensionObjectHeader() {
    final typeId = nodeId();
    final encoding = uint8();
    if (encoding != 0x00 && encoding != 0x01) {
      throw FormatException('OPC UA Binary: unrecognized ExtensionObject encoding 0x${encoding.toRadixString(16)}');
    }
    _lastExtensionObjectHasBody = encoding == 0x01;
    return typeId;
  }

  /// Skips an empty (0x00) DiagnosticInfo on read. Does not support the
  /// non-empty form (unused in v1 — servers always answer with the null form).
  void skipEmptyDiagnosticInfo() {
    final mask = uint8();
    if (mask != 0x00) {
      throw FormatException('OPC UA Binary: non-empty DiagnosticInfo not supported (mask 0x${mask.toRadixString(16)})');
    }
  }

  RequestHeader requestHeader() {
    final authToken = nodeId();
    final timestamp = dateTime();
    final requestHandle = uint32();
    final returnDiagnostics = uint32();
    final auditEntryId = string();
    final timeoutHint = uint32();
    extensionObjectHeader();
    if (lastExtensionObjectHasBody) {
      // Not expected in v1, but drain a ByteString body if present so the
      // stream position stays consistent.
      byteString();
    }
    return RequestHeader(
      authToken: authToken,
      timestamp: timestamp,
      requestHandle: requestHandle,
      returnDiagnostics: returnDiagnostics,
      auditEntryId: auditEntryId,
      timeoutHint: timeoutHint,
    );
  }

  ResponseHeader responseHeader() {
    final timestamp = dateTime();
    final requestHandle = uint32();
    final serviceResult = statusCode();
    skipEmptyDiagnosticInfo();
    final stringTableLen = int32();
    if (stringTableLen > 0) {
      for (var i = 0; i < stringTableLen; i++) {
        string();
      }
    } else if (stringTableLen < -1) {
      throw FormatException('OPC UA Binary: invalid string table length $stringTableLen');
    }
    extensionObjectHeader();
    if (lastExtensionObjectHasBody) {
      byteString();
    }
    return ResponseHeader(
      timestamp: timestamp,
      requestHandle: requestHandle,
      serviceResult: serviceResult,
    );
  }
}
