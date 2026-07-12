// DNP3 Application Layer codec (WS26 DNP3 outstation, Task 3) — pure Dart,
// no dart:io / Flutter imports. Implements the application-fragment header
// (APP_CONTROL + FUNCTION_CODE [+ IIN for responses]), the object-header
// group/variation/qualifier/range encoding, encoders for the static objects
// an outstation reports in responses, and decoders for the control objects
// an outstation receives in write requests.
//
// Wire reference (IEEE 1815 Application Layer):
//  - Request fragment:  APP_CONTROL(1) FUNCTION_CODE(1) [object headers...]
//  - Response fragment: APP_CONTROL(1) FUNCTION_CODE(1)=0x81 IIN(2) [objects...]
//  - APP_CONTROL: FIR(bit7,0x80) FIN(bit6,0x40) CON(bit5,0x20) UNS(bit4,0x10)
//    SEQUENCE(bits0-3, 4 bits). This bit layout is specific to the
//    APPLICATION layer and differs from the TRANSPORT segment header (see
//    `dnp3_transport.dart`), which uses FIN=bit7/FIR=bit6 and a 6-bit
//    sequence (bits 0-5) — the two "FIR/FIN/sequence" ideas are independent
//    framing mechanisms at different layers, and even swap which of
//    FIR/FIN gets the higher bit position.
//  - IIN (Internal Indications): 2 octets, IIN1 transmitted first then IIN2.
//    This codec packs them into one `int` the same way every other
//    multi-byte DNP3 field on the wire is little-endian: `iin1` occupies the
//    low byte (bits 0-7, transmitted first) and `iin2` the high byte (bits
//    8-15, transmitted second) — see [packIin]/[unpackIin].
//  - Object header: GROUP(1) VARIATION(1) QUALIFIER(1), then a range field
//    whose shape depends on QUALIFIER: `0x00` 1-byte start+stop, `0x01`
//    2-byte (LE) start+stop, `0x06` no range (all points), `0x17` 1-byte
//    count then a 1-byte index prefix before each object, `0x28` 2-byte (LE)
//    count then a 2-byte (LE) index prefix before each object.
//  - Static object payloads (all little-endian): g1v2 (Binary Input w/
//    flags) = 1 flags byte (bit7 = point STATE, bits0-6 = quality flags).
//    g10v2 (Binary Output status) = 1 flags byte, same layout as g1v2.
//    g30v1 (Analog Input 32-bit w/ flags) = 1 flags byte + int32 LE. g30v5
//    (Analog Input float w/ flags) = 1 flags byte + float32 LE. g40v1/g40v3
//    (Analog Output status) = 1 flags byte + int32/float32 LE, same shape as
//    g30v1/g30v5 but for the AO point type.
//  - Control object payloads: g12v1 (CROB) = control code(1) count(1)
//    on-time u32 LE(4) off-time u32 LE(4) status(1) = 11 bytes/point. g41v1
//    (Analog Output Block, 32-bit) = int32 LE(4) + status(1) = 5 bytes/point.
//    g41v3 (Analog Output Block, float) = float32 LE(4) + status(1) = 5
//    bytes/point.
//
// dart2js-safety note: every 32-bit field (int32, float32, and the CROB
// on/off-time u32 values) is read/written exclusively through `ByteData`'s
// built-in accessors (`getInt32`/`setInt32`/`getFloat32`/`setFloat32`/
// `getUint32`/`setUint32`, all with `Endian.little`) rather than hand-rolled
// `<<`/`>>`/`&` bit-shifting — raw bitwise ops on values that could set bit
// 31 are a silent-corruption trap under dart2js (JS bitwise ops are 32-bit
// *signed*), which is exactly the trap `modbus_pdu.dart` and `opcua_binary
// .dart` document and avoid the same way. `getInt64`/`setInt64` are never
// used (dart2js does not implement them at all). Only 8/16-bit fields (the
// object header's group/variation/qualifier/start/stop/count/index-prefix
// fields) use plain byte masks/shifts, mirroring `dnp3_link.dart`.
//
// Every parser in this file guards its input length before reading and
// returns `null` on anything malformed or short; nothing here ever throws.
library dnp3_app;

import 'dart:typed_data';

// --- Function codes ---------------------------------------------------------

/// DNP3 Application Layer function codes relevant to a v1 outstation.
class DnpFunc {
  static const int confirm = 0;
  static const int read = 1;
  static const int select = 3;
  static const int operate = 4;
  static const int directOperate = 5;
  static const int enableUnsolicited = 20;
  static const int disableUnsolicited = 21;
  static const int response = 129; // 0x81
  static const int unsolicitedResponse = 130; // 0x82
}

// --- IIN (Internal Indications) ---------------------------------------------

/// IIN1 (first-transmitted IIN octet) bit constants.
class DnpIin1 {
  /// Bit 1 (0x02): one or more Class 1 events are buffered, awaiting a poll.
  static const int class1Events = 0x02;

  /// Bit 2 (0x04): one or more Class 2 events are buffered, awaiting a poll.
  static const int class2Events = 0x04;

  /// Bit 3 (0x08): one or more Class 3 events are buffered, awaiting a poll.
  static const int class3Events = 0x08;

  /// Bit 7 (0x80): the outstation has restarted since this bit was last
  /// cleared by the master.
  static const int deviceRestart = 0x80;
}

/// IIN2 (second-transmitted IIN octet) bit constants.
class DnpIin2 {
  /// Bit 0 (0x01): the requested function code is not supported.
  static const int noFuncCodeSupport = 0x01;

  /// Bit 1 (0x02): one or more requested objects are not supported/unknown.
  static const int objectUnknown = 0x02;

  /// Bit 2 (0x04): a qualifier/range/parameter in the request was invalid.
  static const int parameterError = 0x04;

  /// Bit 3 (0x08): the event buffer overflowed and one or more events were
  /// discarded before the master could poll/confirm them.
  static const int eventBufferOverflow = 0x08;
}

/// Packs [iin1] and [iin2] into the single 16-bit value this codec's
/// `buildAppResponse`/`DnpAppRequest` use to represent IIN: `iin1` in the low
/// byte (transmitted first on the wire), `iin2` in the high byte
/// (transmitted second) — the same little-endian convention as every other
/// multi-byte DNP3 field.
int packIin(int iin1, int iin2) => (iin1 & 0xFF) | ((iin2 & 0xFF) << 8);

/// Splits a packed IIN value (see [packIin]) back into its `(iin1, iin2)`
/// octets.
({int iin1, int iin2}) unpackIin(int iin) => (iin1: iin & 0xFF, iin2: (iin >> 8) & 0xFF);

// --- Object header qualifiers ------------------------------------------------

/// Object-header qualifier codes this codec understands.
class DnpQualifier {
  /// 1-byte start index + 1-byte stop index.
  static const int range8 = 0x00;

  /// 2-byte (LE) start index + 2-byte (LE) stop index.
  static const int range16 = 0x01;

  /// No range field: "all points" of the given group/variation.
  static const int allPoints = 0x06;

  /// 1-byte count, then a 1-byte index prefix before each object.
  static const int indexPrefix8 = 0x17;

  /// 2-byte (LE) count, then a 2-byte (LE) index prefix before each object.
  static const int indexPrefix16 = 0x28;
}

/// A decoded (or to-be-encoded) DNP3 object header: group/variation/
/// qualifier plus whichever range fields that qualifier carries, and — when
/// parsed out of a fragment by [parseAppRequest] for a data-bearing function
/// code — the per-point [indices] and concatenated raw [objectData] bytes
/// (index-prefix bytes are stripped out of `objectData`; they live in
/// [indices] instead, one entry per point in the same order).
class DnpObjectHeader {
  final int group;
  final int variation;
  final int qualifier;

  /// Set for [DnpQualifier.range8]/[DnpQualifier.range16].
  final int? start;
  final int? stop;

  /// Set for [DnpQualifier.indexPrefix8]/[DnpQualifier.indexPrefix16].
  final int? count;

  /// Per-point indices, populated when [parseAppRequest] resolves this
  /// header's per-point data (empty for a header-only read-request object,
  /// or before this header has been resolved against fragment data).
  final List<int> indices;

  /// Concatenated per-point payload bytes (index prefixes stripped), empty
  /// when this header carries no data (e.g. a READ request's object list).
  final Uint8List objectData;

  DnpObjectHeader({
    required this.group,
    required this.variation,
    required this.qualifier,
    this.start,
    this.stop,
    this.count,
    List<int>? indices,
    Uint8List? objectData,
  })  : indices = indices ?? const <int>[],
        objectData = objectData ?? Uint8List(0);
}

/// Builds the bytes for one object header: `GROUP VARIATION QUALIFIER` plus
/// the range field [qualifier] calls for. Missing range/count arguments for
/// a qualifier that needs them default to 0 rather than throwing. An
/// unrecognized [qualifier] still emits the 3 fixed bytes with no range
/// field (best-effort, never throws) — [decodeObjectHeader] will reject such
/// a header as unsupported on the way back in.
Uint8List encodeObjectHeader({
  required int group,
  required int variation,
  required int qualifier,
  int? start,
  int? stop,
  int? count,
}) {
  final out = BytesBuilder();
  out.addByte(group & 0xFF);
  out.addByte(variation & 0xFF);
  out.addByte(qualifier & 0xFF);
  switch (qualifier) {
    case DnpQualifier.range8:
      out.addByte((start ?? 0) & 0xFF);
      out.addByte((stop ?? 0) & 0xFF);
      break;
    case DnpQualifier.range16:
      out.add(_u16LeBytes(start ?? 0));
      out.add(_u16LeBytes(stop ?? 0));
      break;
    case DnpQualifier.allPoints:
      break;
    case DnpQualifier.indexPrefix8:
      out.addByte((count ?? 0) & 0xFF);
      break;
    case DnpQualifier.indexPrefix16:
      out.add(_u16LeBytes(count ?? 0));
      break;
    default:
      break;
  }
  return out.toBytes();
}

/// Decodes one object header (group/variation/qualifier + its range field)
/// starting at [offset] in [data]. Returns the parsed [DnpObjectHeader]
/// (with `indices`/`objectData` still empty — range-qualifier point data, if
/// any, is resolved by [parseAppRequest]) together with the absolute offset
/// of the byte immediately following the header, or `null` if [data] is too
/// short or [qualifier] is unrecognized.
({DnpObjectHeader header, int nextOffset})? decodeObjectHeader(Uint8List data, int offset) {
  if (offset < 0 || offset + 3 > data.length) {
    return null;
  }
  final group = data[offset];
  final variation = data[offset + 1];
  final qualifier = data[offset + 2];
  var pos = offset + 3;
  int? start;
  int? stop;
  int? count;

  switch (qualifier) {
    case DnpQualifier.range8:
      if (pos + 2 > data.length) return null;
      start = data[pos];
      stop = data[pos + 1];
      pos += 2;
      break;
    case DnpQualifier.range16:
      if (pos + 4 > data.length) return null;
      start = _u16Le(data, pos);
      stop = _u16Le(data, pos + 2);
      pos += 4;
      break;
    case DnpQualifier.allPoints:
      break;
    case DnpQualifier.indexPrefix8:
      if (pos + 1 > data.length) return null;
      count = data[pos];
      pos += 1;
      break;
    case DnpQualifier.indexPrefix16:
      if (pos + 2 > data.length) return null;
      count = _u16Le(data, pos);
      pos += 2;
      break;
    default:
      return null; // Unsupported qualifier.
  }

  final header = DnpObjectHeader(
    group: group,
    variation: variation,
    qualifier: qualifier,
    start: start,
    stop: stop,
    count: count,
  );
  return (header: header, nextOffset: pos);
}

/// Per-point wire size (bytes) of the group/variation combinations this
/// codec knows how to carry data for. Returns `null` for anything else —
/// callers use that to bail out of consuming a data-bearing object's payload
/// rather than guess a length.
int? _pointSize(int group, int variation) {
  switch ((group, variation)) {
    case (1, 2): // Binary Input w/ flags
      return 1;
    case (10, 2): // Binary Output status
      return 1;
    case (30, 1): // Analog Input 32-bit w/ flags
      return 5;
    case (30, 5): // Analog Input float w/ flags
      return 5;
    case (40, 1): // Analog Output status, 32-bit
      return 5;
    case (40, 3): // Analog Output status, float
      return 5;
    case (12, 1): // CROB
      return 11;
    case (41, 1): // Analog Output Block, 32-bit
      return 5;
    case (41, 3): // Analog Output Block, float
      return 5;
    default:
      return null;
  }
}

// --- Request fragment parsing ------------------------------------------------

/// A parsed application-layer REQUEST fragment.
class DnpAppRequest {
  final int appControl;
  final int functionCode;
  final List<DnpObjectHeader> objects;

  /// The raw bytes of the fragment after APP_CONTROL and FUNCTION_CODE (i.e.
  /// the whole object-header section, unparsed) — handy for logging/replay
  /// even though [objects] already gives structured access to it.
  final Uint8List rawObjectData;

  DnpAppRequest({
    required this.appControl,
    required this.functionCode,
    required this.objects,
    required this.rawObjectData,
  });

  bool get fir => (appControl & 0x80) != 0;
  bool get fin => (appControl & 0x40) != 0;
  bool get con => (appControl & 0x20) != 0;
  bool get uns => (appControl & 0x10) != 0;
  int get seq => appControl & 0x0F;
}

/// Parses a complete application-layer request fragment: `APP_CONTROL(1)
/// FUNCTION_CODE(1)` followed by zero or more object headers.
///
/// [DnpFunc.read] requests never carry per-object data (a read only names
/// which objects/ranges are wanted), so their object headers are parsed
/// header-only. Every other function code is assumed to carry one payload
/// per named point (as SELECT/OPERATE/DIRECT_OPERATE control writes and
/// RESPONSE fragments do); the payload length is resolved via [_pointSize]
/// for the header's group/variation, and consumed either across the header's
/// start..stop range (qualifiers `0x00`/`0x01`) or once per index-prefixed
/// object (qualifiers `0x17`/`0x28`).
///
/// Returns `null` — never throws — on a too-short fragment, an unrecognized
/// qualifier, a group/variation this codec has no known point size for (when
/// data is expected), or any range/count that would run past the end of
/// [frag].
DnpAppRequest? parseAppRequest(Uint8List frag) {
  if (frag.length < 2) {
    return null;
  }
  final appControl = frag[0];
  final functionCode = frag[1];
  final isReadLike = functionCode == DnpFunc.read;

  final objects = <DnpObjectHeader>[];
  var offset = 2;

  while (offset < frag.length) {
    final decoded = decodeObjectHeader(frag, offset);
    if (decoded == null) {
      return null;
    }
    final h = decoded.header;
    var pos = decoded.nextOffset;

    if (isReadLike || h.qualifier == DnpQualifier.allPoints) {
      // Read requests, and "all points" objects in any request, carry no
      // per-point payload in this codec's scope.
      objects.add(h);
      offset = pos;
      continue;
    }

    final size = _pointSize(h.group, h.variation);
    if (size == null) {
      return null; // Data expected but this group/variation isn't known.
    }

    if (h.qualifier == DnpQualifier.range8 || h.qualifier == DnpQualifier.range16) {
      final start = h.start!;
      final stop = h.stop!;
      final count = stop - start + 1;
      if (count <= 0) {
        return null;
      }
      final dataLen = count * size;
      if (pos + dataLen > frag.length) {
        return null;
      }
      final objData = Uint8List.fromList(frag.sublist(pos, pos + dataLen));
      final indices = List<int>.generate(count, (i) => start + i);
      objects.add(DnpObjectHeader(
        group: h.group,
        variation: h.variation,
        qualifier: h.qualifier,
        start: start,
        stop: stop,
        indices: indices,
        objectData: objData,
      ));
      offset = pos + dataLen;
    } else if (h.qualifier == DnpQualifier.indexPrefix8 || h.qualifier == DnpQualifier.indexPrefix16) {
      final count = h.count!;
      final idxSize = h.qualifier == DnpQualifier.indexPrefix8 ? 1 : 2;
      final indices = <int>[];
      final dataBuilder = BytesBuilder();
      for (var i = 0; i < count; i++) {
        if (pos + idxSize > frag.length) {
          return null;
        }
        final idx = idxSize == 1 ? frag[pos] : _u16Le(frag, pos);
        pos += idxSize;
        if (pos + size > frag.length) {
          return null;
        }
        indices.add(idx);
        dataBuilder.add(frag.sublist(pos, pos + size));
        pos += size;
      }
      objects.add(DnpObjectHeader(
        group: h.group,
        variation: h.variation,
        qualifier: h.qualifier,
        count: count,
        indices: indices,
        objectData: dataBuilder.toBytes(),
      ));
      offset = pos;
    } else {
      return null; // Unsupported qualifier for a data-bearing function code.
    }
  }

  return DnpAppRequest(
    appControl: appControl,
    functionCode: functionCode,
    objects: objects,
    rawObjectData: Uint8List.fromList(frag.sublist(2)),
  );
}

/// Builds a complete application-layer RESPONSE fragment: `APP_CONTROL(1)
/// FUNCTION_CODE(1)=0x81 IIN(2, little-endian per [packIin]) [objectData]`.
/// UNS is always 0 for this builder (unsolicited responses are out of scope
/// for a v1 outstation's basic response path).
Uint8List buildAppResponse({
  required int seq,
  required bool fir,
  required bool fin,
  required bool con,
  required int iin,
  required Uint8List objectData,
}) {
  final appControl = (fir ? 0x80 : 0) | (fin ? 0x40 : 0) | (con ? 0x20 : 0) | (seq & 0x0F);
  final out = BytesBuilder();
  out.addByte(appControl);
  out.addByte(DnpFunc.response & 0xFF);
  out.addByte(iin & 0xFF); // IIN1, transmitted first.
  out.addByte((iin >> 8) & 0xFF); // IIN2, transmitted second.
  out.add(objectData);
  return out.toBytes();
}

// --- Flags byte constants ----------------------------------------------------

/// Quality-flags bit constants shared by (or specific to) the static object
/// flags bytes. Bits 0-4 (ONLINE/RESTART/COMM_LOST/REMOTE_FORCED/
/// LOCAL_FORCED) mean the same thing for every point type; bit 5 and bit 6
/// are point-type-specific (binary: CHATTER_FILTER / reserved; analog:
/// OVER_RANGE / REFERENCE_ERR); bit 7 is the point STATE for binary points
/// only (analog points carry their value in a separate field, so bit 7 is
/// simply reserved/unused there).
class DnpFlags {
  static const int online = 0x01;
  static const int restart = 0x02;
  static const int commLost = 0x04;
  static const int remoteForced = 0x08;
  static const int localForced = 0x10;

  /// Binary Input/Output bit 5.
  static const int chatterFilter = 0x20;

  /// Analog Input/Output bit 5.
  static const int overRange = 0x20;

  /// Analog Input/Output bit 6.
  static const int referenceErr = 0x40;

  /// Binary Input/Output bit 7: the point's boolean value/state.
  static const int state = 0x80;
}

// --- Static object encoders (outstation -> master, in RESPONSE fragments) --

/// Encodes a g1v2 (Binary Input w/ flags) point: 1 byte = [flags] (bits 0-6
/// — combine [DnpFlags] constants, e.g. `DnpFlags.online`) with bit 7 set
/// from [value].
Uint8List encodeG1V2({required bool value, int flags = 0}) {
  final byte = (flags & 0x7F) | (value ? DnpFlags.state : 0);
  return Uint8List.fromList([byte & 0xFF]);
}

/// Encodes a g10v2 (Binary Output status) point — same 1-byte flags+state
/// layout as [encodeG1V2].
Uint8List encodeG10V2({required bool value, int flags = 0}) {
  return encodeG1V2(value: value, flags: flags);
}

/// Encodes a g30v1 (Analog Input, 32-bit w/ flags) point: 1 flags byte
/// followed by [value] as a little-endian signed int32.
Uint8List encodeG30V1({required int value, int flags = 0}) {
  final bd = ByteData(5);
  bd.setUint8(0, flags & 0xFF);
  bd.setInt32(1, value, Endian.little);
  return bd.buffer.asUint8List();
}

/// Encodes a g30v5 (Analog Input, float w/ flags) point: 1 flags byte
/// followed by [value] as a little-endian float32.
Uint8List encodeG30V5({required double value, int flags = 0}) {
  final bd = ByteData(5);
  bd.setUint8(0, flags & 0xFF);
  bd.setFloat32(1, value, Endian.little);
  return bd.buffer.asUint8List();
}

/// Encodes a g40v1 (Analog Output status, 32-bit) point — same shape as
/// [encodeG30V1] but for the AO point type.
Uint8List encodeG40V1({required int value, int flags = 0}) {
  return encodeG30V1(value: value, flags: flags);
}

/// Encodes a g40v3 (Analog Output status, float) point — same shape as
/// [encodeG30V5] but for the AO point type.
Uint8List encodeG40V3({required double value, int flags = 0}) {
  return encodeG30V5(value: value, flags: flags);
}

// --- Event object encoders + 48-bit time (outstation -> master, unsolicited
// responses and event-class reads) ------------------------------------------

/// Writes [timeMs] (ms since 1970-01-01 UTC) as a 48-bit little-endian
/// integer at [offset] in [bd]. dart2js-safe: the split uses arithmetic
/// (`%`/`~/` on 2^32), never a `>> 32` bit-shift (JS bitwise ops truncate to
/// 32 bits) and never setInt64 (unimplemented under dart2js).
void _setDnpTime48(ByteData bd, int offset, int timeMs) {
  final t = timeMs < 0 ? 0 : timeMs;
  final low = t % 0x100000000; // low 32 bits
  final high = t ~/ 0x100000000; // bits 32..47
  bd.setUint32(offset, low, Endian.little);
  bd.setUint16(offset + 4, high & 0xFFFF, Endian.little);
}

/// Reads a 48-bit little-endian DNP3 timestamp at [offset]. Test/parse helper.
int getDnpTime48(Uint8List data, int offset) {
  final bd = ByteData.sublistView(data, offset, offset + 6);
  final low = bd.getUint32(0, Endian.little);
  final high = bd.getUint16(4, Endian.little);
  return high * 0x100000000 + low;
}

/// Encodes a g2v2 (Binary Input Event with absolute time) object: 1 flags
/// byte (bit 7 = STATE from [value], bits 0-6 from [flags]) + 48-bit LE time.
Uint8List encodeG2V2({required bool value, required int flags, required int timeMs}) {
  final bd = ByteData(7);
  bd.setUint8(0, (flags & 0x7F) | (value ? DnpFlags.state : 0));
  _setDnpTime48(bd, 1, timeMs);
  return bd.buffer.asUint8List();
}

/// Encodes a g32v3 (Analog Input Event, 32-bit with time) object: 1 flags
/// byte + int32 LE [value] + 48-bit LE time.
Uint8List encodeG32V3({required int value, required int flags, required int timeMs}) {
  final bd = ByteData(11);
  bd.setUint8(0, flags & 0xFF);
  bd.setInt32(1, value, Endian.little);
  _setDnpTime48(bd, 5, timeMs);
  return bd.buffer.asUint8List();
}

/// Encodes a g32v7 (Analog Input Event, single-precision float with time)
/// object: 1 flags byte + float32 LE [value] + 48-bit LE time.
Uint8List encodeG32V7({required double value, required int flags, required int timeMs}) {
  final bd = ByteData(11);
  bd.setUint8(0, flags & 0xFF);
  bd.setFloat32(1, value, Endian.little);
  _setDnpTime48(bd, 5, timeMs);
  return bd.buffer.asUint8List();
}

/// Encodes a g11v2 (Binary Output Event with time) point. The per-point
/// payload is byte-identical to g2v2 (Binary Input Event) — flags(1, bit 7 =
/// state) + 48-bit LE time; only the object-header group number (11 vs 2)
/// distinguishes them on the wire, which the caller sets.
Uint8List encodeG11V2({required bool value, required int flags, required int timeMs}) =>
    encodeG2V2(value: value, flags: flags, timeMs: timeMs);

/// Encodes a g42v3 (Analog Output Event, 32-bit with time) point — payload
/// byte-identical to g32v3 (Analog Input Event); group 42 vs 32 distinguishes.
Uint8List encodeG42V3({required int value, required int flags, required int timeMs}) =>
    encodeG32V3(value: value, flags: flags, timeMs: timeMs);

/// Encodes a g42v7 (Analog Output Event, single-float with time) point —
/// payload byte-identical to g32v7; group 42 vs 32 distinguishes.
Uint8List encodeG42V7({required double value, required int flags, required int timeMs}) =>
    encodeG32V7(value: value, flags: flags, timeMs: timeMs);

/// Maps a g60 (Class Objects) variation to its DNP3 event class: v1 = Class 0
/// (static), v2 = Class 1, v3 = Class 2, v4 = Class 3. Returns `null` for any
/// other variation.
int? dnpClassOfG60Variation(int variation) {
  switch (variation) {
    case 1:
      return 0;
    case 2:
      return 1;
    case 3:
      return 2;
    case 4:
      return 3;
    default:
      return null;
  }
}

/// Builds an UNSOLICITED RESPONSE fragment (function code 130): app control
/// FIR|FIN|CON|UNS|seq, then IIN(2, LE per [packIin]), then [objectData]. The
/// UNS bit marks this as unsolicited and CON requests the master's CONFIRM.
Uint8List buildUnsolicitedResponse({
  required int seq,
  required int iin,
  required Uint8List objectData,
}) {
  final appControl = 0x80 | 0x40 | 0x20 | 0x10 | (seq & 0x0F); // FIR|FIN|CON|UNS
  final out = BytesBuilder();
  out.addByte(appControl);
  out.addByte(DnpFunc.unsolicitedResponse & 0xFF);
  out.addByte(iin & 0xFF);
  out.addByte((iin >> 8) & 0xFF);
  out.add(objectData);
  return out.toBytes();
}

// --- Control object codecs (master -> outstation, in write requests) -------

/// CROB (g12v1) control-code values (IEEE 1815 Table: Control Relay Output
/// Block control code, "operation type" sub-field).
class DnpControlCode {
  static const int nul = 0;
  static const int pulseOn = 1;
  static const int pulseOff = 2;
  static const int latchOn = 3;
  static const int latchOff = 4;
}

/// A decoded g12v1 Control Relay Output Block (CROB).
class DnpCrob {
  final int controlCode;
  final int count;
  final int onTimeMs;
  final int offTimeMs;
  final int status;

  DnpCrob({
    required this.controlCode,
    required this.count,
    required this.onTimeMs,
    required this.offTimeMs,
    required this.status,
  });
}

/// Decodes an 11-byte g12v1 CROB starting at [offset] in [data]: control
/// code(1) count(1) on-time u32 LE(4) off-time u32 LE(4) status(1). Returns
/// `null` if [data] is too short.
DnpCrob? decodeCrob(Uint8List data, [int offset = 0]) {
  if (offset < 0 || offset + 11 > data.length) {
    return null;
  }
  final bd = ByteData.sublistView(data, offset, offset + 11);
  return DnpCrob(
    controlCode: bd.getUint8(0),
    count: bd.getUint8(1),
    onTimeMs: bd.getUint32(2, Endian.little),
    offTimeMs: bd.getUint32(6, Endian.little),
    status: bd.getUint8(10),
  );
}

/// Encodes a g12v1 CROB — the counterpart to [decodeCrob], for building the
/// object an outstation echoes back in a SELECT/OPERATE/DIRECT_OPERATE
/// response.
Uint8List encodeCrob({
  required int controlCode,
  required int count,
  required int onTimeMs,
  required int offTimeMs,
  required int status,
}) {
  final bd = ByteData(11);
  bd.setUint8(0, controlCode & 0xFF);
  bd.setUint8(1, count & 0xFF);
  bd.setUint32(2, onTimeMs, Endian.little);
  bd.setUint32(6, offTimeMs, Endian.little);
  bd.setUint8(10, status & 0xFF);
  return bd.buffer.asUint8List();
}

/// Decodes a 5-byte g41v1 Analog Output Block (32-bit): int32 LE(4) +
/// status(1). Returns `null` if [data] is too short.
({int value, int status})? decodeAnalogOutputInt(Uint8List data, [int offset = 0]) {
  if (offset < 0 || offset + 5 > data.length) {
    return null;
  }
  final bd = ByteData.sublistView(data, offset, offset + 5);
  return (value: bd.getInt32(0, Endian.little), status: bd.getUint8(4));
}

/// Decodes a 5-byte g41v3 Analog Output Block (float): float32 LE(4) +
/// status(1). Returns `null` if [data] is too short.
({double value, int status})? decodeAnalogOutputFloat(Uint8List data, [int offset = 0]) {
  if (offset < 0 || offset + 5 > data.length) {
    return null;
  }
  final bd = ByteData.sublistView(data, offset, offset + 5);
  return (value: bd.getFloat32(0, Endian.little), status: bd.getUint8(4));
}

/// Encodes a g41v1 Analog Output Block (32-bit) — the counterpart to
/// [decodeAnalogOutputInt].
Uint8List encodeAnalogOutputInt({required int value, required int status}) {
  final bd = ByteData(5);
  bd.setInt32(0, value, Endian.little);
  bd.setUint8(4, status & 0xFF);
  return bd.buffer.asUint8List();
}

/// Encodes a g41v3 Analog Output Block (float) — the counterpart to
/// [decodeAnalogOutputFloat].
Uint8List encodeAnalogOutputFloat({required double value, required int status}) {
  final bd = ByteData(5);
  bd.setFloat32(0, value, Endian.little);
  bd.setUint8(4, status & 0xFF);
  return bd.buffer.asUint8List();
}

// --- Byte helpers ------------------------------------------------------------

int _u16Le(Uint8List data, int offset) => data[offset] | (data[offset + 1] << 8);

Uint8List _u16LeBytes(int value) => Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]);
