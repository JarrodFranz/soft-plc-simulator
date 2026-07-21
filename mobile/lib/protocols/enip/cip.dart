// CIP (Common Industrial Protocol) messaging codec — pure Dart, no dart:io /
// Flutter imports. Implements the CIP request/response envelope, EPATH
// segment parsing/building (including the ANSI Extended Symbol segment that
// carries a tag's symbolic name), and the CIP data-type codec that maps the
// app's tag types onto CIP wire types, per public CIP specification
// material. This layer sits ABOVE the EtherNet/IP encapsulation layer
// (`enip_encap.dart`): a CIP request/response is a payload carried inside a
// CPF item, not a wrapper around one, so this file does not import
// `enip_encap.dart` and knows nothing about sessions, CPF, or sockets.
//
// Wire reference:
//  - CIP request: `service` u8, `pathWords` u8 (EPATH length in **16-bit
//    words**, not bytes), then that many `pathWords * 2` bytes of EPATH,
//    then any remaining bytes are service-specific request data.
//  - CIP response: `service | 0x80` u8, a reserved `0x00` u8, `generalStatus`
//    u8, `additionalStatusWords` u8 (always 0 — this codec never emits
//    additional status), then any service-specific reply data.
//  - EPATH segments used here:
//     * ANSI Extended Symbol: `0x91`, `nameLen` u8, `nameLen` ASCII bytes,
//       then **one 0x00 pad byte if `nameLen` is odd**. This keeps every
//       segment an even number of bytes, which matters because the
//       enclosing request's path length is expressed in 16-bit *words* —
//       an odd-byte segment would corrupt that count.
//     * Logical (Class/Instance/Attribute), 8-bit format: segment byte
//       (`0x20` class / `0x24` instance / `0x30` attribute) + one value
//       byte.
//     * Logical (Class/Instance), 16-bit extended format: segment byte
//       (`0x21` class / `0x25` instance) + one reserved `0x00` pad byte +
//       a little-endian u16 value. (Attribute has no 16-bit form here —
//       out of scope per this layer's brief.)
//  - Data types: `BOOL 0xC1`, `INT 0xC3` (16-bit), `DINT 0xC4` (32-bit),
//    `LINT 0xC5` (64-bit), `REAL 0xCA` (IEEE-754 **single**-precision,
//    32-bit). The app's `FLOAT64` tag type is a 64-bit Dart `double`;
//    encoding it as CIP `REAL` is a **narrowing** conversion to single
//    precision, and decoding widens back to `double` — round-tripping a
//    value through it is lossy, by design of the wire type. `STRING` has no
//    CIP type mapping in this version: a symbolic CIP string is a
//    structured type requiring the Template object, which is deferred.
//
// Non-throwing contract: `parseCipRequest`, `parseEpath`, and
// `decodeCipValue` are fed arbitrary bytes off the wire (via later layers)
// and must never throw on malformed, truncated, or hostile input — they
// return `null` instead, mirroring `enip_encap.dart`'s convention.
library cip;

import 'dart:convert';
import 'dart:typed_data';

// --- CIP service codes -------------------------------------------------

/// Read Tag Service — reads a symbolic tag's value(s) by EPATH.
const int kCipServiceReadTag = 0x4C;

/// Write Tag Service — writes a symbolic tag's value(s) by EPATH.
const int kCipServiceWriteTag = 0x4D;

/// Get Instance Attribute List — enumerates a class's instances and the
/// requested attributes of each. Used here only against the Symbol Object
/// (class 0x6B) to serve a Logix-style client's tag-directory upload.
const int kCipServiceGetInstanceAttributeList = 0x55;

// --- CIP general status codes -------------------------------------------

const int kCipStatusSuccess = 0x00;

/// "Partial Transfer" — a Get Instance Attribute List reply that could not
/// fit every remaining instance in one reply; the client re-requests from
/// the last returned instance id + 1 until a success (0x00) completes it.
const int kCipStatusPartialTransfer = 0x06;

/// "Connection failure" — used by the Connection Manager (`cip_connection.dart`
/// — Forward Open/Forward Close) both for a Forward Open that cannot be
/// honored and for a Forward Close that does not match any open connection.
/// `cip.dart`'s own Read/Write Tag services never need this status; it is
/// consolidated here (moved from `cip_connection.dart`, which previously
/// defined it locally) purely so every CIP general-status code lives in one
/// place. NOT a service code — see the "FOOTGUN" note on
/// [kCipServiceMultipleServicePacket] below, which shares this same literal
/// byte value in an entirely different namespace.
const int kCipStatusConnectionFailure = 0x01;

const int kCipStatusPathSegmentError = 0x04;
const int kCipStatusPathDestinationUnknown = 0x05;
const int kCipStatusServiceNotSupported = 0x08;

/// "Invalid Attribute Value" — used by the tag-write service
/// (`cip_tags.dart`) when a Write Tag request's wire type code doesn't match
/// the target tag's actual CIP type. Consolidated here (moved from
/// `cip_tags.dart`, which previously defined it locally) alongside the rest
/// of the general-status block.
const int kCipStatusInvalidAttributeValue = 0x09;

const int kCipStatusEmbeddedListError = 0x0A;
const int kCipStatusPrivilegeViolation = 0x0F;

/// "Reply data too large" — the standard CIP general status a target returns
/// for an item whose reply would not fit the size the client negotiated.
/// Used by the Multiple Service Packet handler (`cip_tags.dart`) when a
/// connected batch's embedded responses would overrun the Forward Open T->O
/// connection size: the over-budget items carry THIS status instead of the
/// batch emitting a frame larger than the connection the client agreed to.
const int kCipStatusReplyDataTooLarge = 0x11;

const int kCipStatusNotEnoughData = 0x13;

/// "Attribute Not Supported" — a Get Attribute List (0x03) per-attribute status
/// for an attribute this object does not implement (e.g. any attribute of the
/// proprietary Rockwell class 0xAC). Reported per-attribute inside a
/// well-formed reply, never as a blanket service failure.
const int kCipStatusAttributeNotSupported = 0x14;
const int kCipStatusEmbeddedServiceError = 0x1E;

// --- CIP service codes (continued) --------------------------------------
//
// FOOTGUN WARNING: [kCipStatusEmbeddedListError] (0x0A, a GENERAL STATUS
// code, in the block above) and [kCipServiceMultipleServicePacket] (0x0A,
// a SERVICE code, immediately below) share the identical literal byte value
// 0x0A in TWO DIFFERENT namespaces — one appears in a CIP response's
// `generalStatus` byte, the other in a CIP request's `service` byte. Both
// are used inside the SAME function (`_multipleServicePacket` in
// `cip_tags.dart`), which reads `kCipServiceMultipleServicePacket` to
// recognize the outer request and can return `kCipStatusEmbeddedListError`
// as that same request's reply status. Never conflate the two: check which
// field (request `service` vs. response `generalStatus`) you are comparing
// against before reusing either constant.
//
/// Multiple Service Packet service code — batches embedded Read/Write Tag
/// requests into one round trip. Consolidated here (moved from
/// `cip_tags.dart`, which previously defined it locally because Task 2's
/// scope was limited to the Read/Write Tag service codes above).
const int kCipServiceMultipleServicePacket = 0x0A;

/// Get Attributes All — returns an object instance's attributes as one
/// packed structure. Served here for the Identity Object and the Program
/// Name Object (both read at connect by a Logix-style client).
const int kCipServiceGetAttributesAll = 0x01;

/// Get Attribute List — returns a client-chosen SUBSET of an object instance's
/// attributes, each tagged with its own per-attribute status. A Logix-style
/// SCADA driver (e.g. Ignition's Allen-Bradley Logix driver) uses this to read
/// the Identity object and to probe the proprietary Rockwell class 0xAC for
/// symbol/template change detection at connect/browse time.
const int kCipServiceGetAttributeList = 0x03;

/// Unconnected Send — a Connection Manager (class 0x06) service that wraps
/// (encapsulates) another CIP request plus a route path, so an UNCONNECTED
/// (UCMM) originator can reach a target across a routing hop without opening a
/// connection. pycomm3's `LogixDriver` sends `get_plc_info`/`get_plc_name`
/// this way (`unconnected_send=True`). This host is the end device, so it
/// treats 0x52 as a TRANSPARENT wrapper: it unwraps the embedded request,
/// dispatches it, and returns the embedded reply verbatim (Unconnected Send
/// adds no reply wrapper of its own). NOT the same namespace as a general
/// status — this is a request `service` byte.
const int kCipServiceUnconnectedSend = 0x52;

// --- CIP object class ids (served objects) -------------------------------

/// Symbol Object — the controller tag directory a Logix-style client uploads.
const int kCipSymbolObjectClassId = 0x6B;

/// Identity Object — vendor/product/revision/serial a Logix-style client
/// reads at connect (via Get Attributes All) before uploading tags.
const int kCipIdentityObjectClassId = 0x01;

/// Connection Manager — the object (instance 1) that owns Forward Open/Close
/// and the Unconnected Send ([kCipServiceUnconnectedSend]) service. An
/// Unconnected Send request's path must address it.
const int kCipConnectionManagerClassId = 0x06;

/// A proprietary, undocumented Rockwell object a Logix SCADA driver (e.g.
/// Ignition's Allen-Bradley Logix driver) probes via Get Attribute List (0x03)
/// for symbol/template CHANGE DETECTION at connect/browse time. Its real
/// semantics are not publicly specified; this host answers a best-effort STABLE
/// placeholder (its tag directory is static, so "nothing changed" is honest) so
/// such a client may proceed to the Symbol Object browse. No vendor is
/// impersonated. See `cip_tags.dart`'s `_getAttributeList`.
const int kCipRockwellChangeDetectClassId = 0xAC;

/// Program Name Object — a Logix-style client reads the controller/program
/// name from this class (Get Attributes All → a Logix STRING) at connect
/// (pycomm3's `get_plc_name`), after the Identity read and before the tag
/// upload. See `cip_identity.dart` for the honest, deterministic value.
const int kCipProgramNameObjectClassId = 0x64;

// --- CIP elementary data-type codes -------------------------------------

const int kCipTypeBool = 0xC1;
const int kCipTypeInt = 0xC3; // 16-bit signed integer.
const int kCipTypeDint = 0xC4; // 32-bit signed integer.
const int kCipTypeLint = 0xC5; // 64-bit signed integer.
const int kCipTypeReal = 0xCA; // IEEE-754 single-precision float.

// --- EPATH segment type bytes --------------------------------------------

const int _kSegAnsiExtendedSymbol = 0x91;
const int _kSegClass8 = 0x20;
const int _kSegClass16 = 0x21;
const int _kSegInstance8 = 0x24;
const int _kSegInstance16 = 0x25;
const int _kSegAttribute8 = 0x30;

/// Discriminates which kind of EPATH segment a [CipPathSegment] represents.
enum CipPathSegmentKind { symbolName, classId, instanceId, attributeId }

/// A single EPATH segment: either an ANSI Extended Symbol (a tag or tag
/// member name) or a logical Class/Instance/Attribute segment.
///
/// Use the named factory matching the segment kind you need; `name` is set
/// only for [CipPathSegmentKind.symbolName], `id` only for the logical
/// segment kinds. Two segments compare equal (`==`) when their kind and
/// payload match, which keeps round-trip tests concise.
class CipPathSegment {
  final CipPathSegmentKind kind;
  final String? name;
  final int? id;

  const CipPathSegment._(this.kind, this.name, this.id);

  /// An ANSI Extended Symbol segment carrying a tag or tag-member [name].
  factory CipPathSegment.symbol(String name) => CipPathSegment._(CipPathSegmentKind.symbolName, name, null);

  /// A logical Class segment (8-bit form if `id <= 0xFF`, else the 16-bit
  /// extended form).
  factory CipPathSegment.classId(int id) => CipPathSegment._(CipPathSegmentKind.classId, null, id);

  /// A logical Instance segment (8-bit form if `id <= 0xFF`, else the
  /// 16-bit extended form).
  factory CipPathSegment.instanceId(int id) => CipPathSegment._(CipPathSegmentKind.instanceId, null, id);

  /// A logical Attribute segment (8-bit form only).
  factory CipPathSegment.attributeId(int id) => CipPathSegment._(CipPathSegmentKind.attributeId, null, id);

  @override
  bool operator ==(Object other) =>
      other is CipPathSegment && other.kind == kind && other.name == name && other.id == id;

  @override
  int get hashCode => Object.hash(kind, name, id);

  @override
  String toString() {
    switch (kind) {
      case CipPathSegmentKind.symbolName:
        return 'CipPathSegment.symbol($name)';
      case CipPathSegmentKind.classId:
        return 'CipPathSegment.classId($id)';
      case CipPathSegmentKind.instanceId:
        return 'CipPathSegment.instanceId($id)';
      case CipPathSegmentKind.attributeId:
        return 'CipPathSegment.attributeId($id)';
    }
  }
}

/// A decoded CIP request: the `service` code, the EPATH as an ordered list
/// of [CipPathSegment]s, and any remaining service-specific request `data`.
class CipRequest {
  final int service;
  final List<CipPathSegment> path;
  final Uint8List data;

  CipRequest({required this.service, required this.path, required this.data});
}

/// A CIP response to be serialized with [buildCipResponse]: the *request's*
/// `service` code (the reply bit is set by [buildCipResponse], not here),
/// the `generalStatus`, and any reply `data`.
class CipResponse {
  final int service;
  final int generalStatus;
  final Uint8List data;

  CipResponse({required this.service, required this.generalStatus, required this.data});
}

// --- EPATH -----------------------------------------------------------------

/// Parses an EPATH of exactly `wordLen * 2` bytes from the front of [data].
/// Returns `null` (never throws) if [data] is shorter than that byte count,
/// if a segment is truncated or unrecognized, or if the segments do not
/// exactly consume all `wordLen * 2` bytes.
///
/// Recognizes the ANSI Extended Symbol segment (`0x91`) and the logical
/// Class/Instance (8-bit and 16-bit extended) and Attribute (8-bit only)
/// segments. Any other segment type byte is treated as malformed input for
/// this codec, since this may be fed arbitrary bytes off the wire.
List<CipPathSegment>? parseEpath(Uint8List data, int wordLen) {
  if (wordLen < 0) {
    return null;
  }
  final byteLen = wordLen * 2;
  if (data.length < byteLen) {
    return null;
  }
  final segments = <CipPathSegment>[];
  var offset = 0;
  while (offset < byteLen) {
    final segType = data[offset];
    if (segType == _kSegAnsiExtendedSymbol) {
      if (offset + 2 > byteLen) {
        return null;
      }
      final nameLen = data[offset + 1];
      final nameStart = offset + 2;
      final nameEnd = nameStart + nameLen;
      if (nameEnd > byteLen) {
        return null;
      }
      String name;
      try {
        name = ascii.decode(data.sublist(nameStart, nameEnd));
      } on FormatException {
        return null;
      }
      offset = nameEnd;
      if (nameLen.isOdd) {
        if (offset + 1 > byteLen) {
          return null;
        }
        offset += 1; // Skip the mandatory pad byte.
      }
      segments.add(CipPathSegment.symbol(name));
    } else if (segType == _kSegClass8 || segType == _kSegInstance8) {
      if (offset + 2 > byteLen) {
        return null;
      }
      final value = data[offset + 1];
      segments.add(segType == _kSegClass8 ? CipPathSegment.classId(value) : CipPathSegment.instanceId(value));
      offset += 2;
    } else if (segType == _kSegClass16 || segType == _kSegInstance16) {
      if (offset + 4 > byteLen) {
        return null;
      }
      final value = ByteData.sublistView(data, offset + 2, offset + 4).getUint16(0, Endian.little);
      segments.add(segType == _kSegClass16 ? CipPathSegment.classId(value) : CipPathSegment.instanceId(value));
      offset += 4;
    } else if (segType == _kSegAttribute8) {
      if (offset + 2 > byteLen) {
        return null;
      }
      segments.add(CipPathSegment.attributeId(data[offset + 1]));
      offset += 2;
    } else {
      return null;
    }
  }
  if (offset != byteLen) {
    return null;
  }
  return segments;
}

/// Builds the raw EPATH bytes for [path]. Every emitted segment is an even
/// number of bytes (the ANSI Extended Symbol segment pads odd-length names
/// with a trailing `0x00`; logical segments are inherently 2 or 4 bytes),
/// so the total length is always expressible as a whole number of 16-bit
/// words, as the enclosing request/response requires.
///
/// A symbol name longer than 255 bytes (the `nameLen` field is a u8) is
/// truncated to its first 255 ASCII bytes. Non-ASCII characters in a name
/// are replaced with `?` rather than thrown on, since this is a build (not
/// parse) function but still should not crash on odd input.
Uint8List buildEpath(List<CipPathSegment> path) {
  final out = <int>[];
  for (final seg in path) {
    switch (seg.kind) {
      case CipPathSegmentKind.symbolName:
        var name = seg.name ?? '';
        if (name.length > 0xFF) {
          name = name.substring(0, 0xFF);
        }
        final nameBytes = Uint8List.fromList(
          [for (final unit in name.codeUnits) unit <= 0x7F ? unit : 0x3F], // 0x3F = '?'
        );
        out.add(_kSegAnsiExtendedSymbol);
        out.add(nameBytes.length);
        out.addAll(nameBytes);
        if (nameBytes.length.isOdd) {
          out.add(0x00);
        }
        break;
      case CipPathSegmentKind.classId:
        _writeLogicalSegment(out, seg.id ?? 0, _kSegClass8, _kSegClass16);
        break;
      case CipPathSegmentKind.instanceId:
        _writeLogicalSegment(out, seg.id ?? 0, _kSegInstance8, _kSegInstance16);
        break;
      case CipPathSegmentKind.attributeId:
        out.add(_kSegAttribute8);
        out.add((seg.id ?? 0) & 0xFF);
        break;
    }
  }
  return Uint8List.fromList(out);
}

void _writeLogicalSegment(List<int> out, int value, int shortSeg, int extendedSeg) {
  if (value >= 0 && value <= 0xFF) {
    out.add(shortSeg);
    out.add(value & 0xFF);
  } else {
    out.add(extendedSeg);
    out.add(0x00); // Reserved pad byte before the 16-bit value.
    final wordBytes = ByteData(2)..setUint16(0, value & 0xFFFF, Endian.little);
    out.addAll(wordBytes.buffer.asUint8List());
  }
}

// --- CIP request / response --------------------------------------------

/// Parses a CIP request: `service` u8, `pathWords` u8, `pathWords * 2`
/// bytes of EPATH, then any remaining bytes as service data. Returns `null`
/// (never throws) if the buffer is too short for the declared path length
/// or the EPATH itself is malformed — this may be fed arbitrary bytes off
/// the wire.
CipRequest? parseCipRequest(Uint8List frame) {
  if (frame.length < 2) {
    return null;
  }
  final service = frame[0];
  final pathWords = frame[1];
  final pathByteLen = pathWords * 2;
  const pathStart = 2;
  final pathEnd = pathStart + pathByteLen;
  if (frame.length < pathEnd) {
    return null;
  }
  final path = parseEpath(frame.sublist(pathStart), pathWords);
  if (path == null) {
    return null;
  }
  final data = Uint8List.fromList(frame.sublist(pathEnd));
  return CipRequest(service: service, path: path, data: data);
}

/// Builds a CIP response: `service | 0x80` u8, a reserved `0x00` u8,
/// `generalStatus` u8, `additionalStatusWords` u8 (always `0x00` — this
/// codec never emits additional status words), then [CipResponse.data]
/// verbatim.
Uint8List buildCipResponse(CipResponse response) {
  final out = Uint8List(4 + response.data.length);
  out[0] = (response.service | 0x80) & 0xFF;
  out[1] = 0x00;
  out[2] = response.generalStatus & 0xFF;
  out[3] = 0x00;
  out.setRange(4, 4 + response.data.length, response.data);
  return out;
}

// --- CIP data-type mapping and codec -------------------------------------

/// Maps an app tag type name to its CIP wire type code, or `null` if the
/// type has no CIP mapping in this version (currently just `STRING`, whose
/// CIP representation is a structured type requiring the Template object —
/// deferred to a later version) or is unrecognized.
int? cipTypeForTagType(String tagType) {
  switch (tagType) {
    case 'BOOL':
      return kCipTypeBool;
    case 'INT16':
      return kCipTypeInt;
    case 'INT32':
      return kCipTypeDint;
    case 'INT64':
      return kCipTypeLint;
    case 'FLOAT64':
      return kCipTypeReal;
    default:
      return null;
  }
}

/// Encodes [value] to the wire bytes for CIP type [typeCode]. Returns
/// `null` if [typeCode] is unrecognized or [value] is not the Dart type
/// that type expects (`bool` for `BOOL`, `int` for `INT`/`DINT`/`LINT`,
/// `num` for `REAL`).
///
/// `REAL` (0xCA) is IEEE-754 **single** precision (4 bytes). The app's
/// `FLOAT64` tag values are 64-bit Dart `double`s, so encoding one as
/// `REAL` is a **narrowing** conversion — precision beyond what a 32-bit
/// float can represent is lost. This is inherent to the CIP wire type, not
/// a bug; callers surfacing this to users should say so.
Uint8List? encodeCipValue(int typeCode, dynamic value) {
  try {
    switch (typeCode) {
      case kCipTypeBool:
        if (value is! bool) {
          return null;
        }
        return Uint8List.fromList([value ? 0xFF : 0x00]);
      case kCipTypeInt:
        if (value is! int) {
          return null;
        }
        final out = Uint8List(2);
        ByteData.sublistView(out).setInt16(0, value, Endian.little);
        return out;
      case kCipTypeDint:
        if (value is! int) {
          return null;
        }
        final out = Uint8List(4);
        ByteData.sublistView(out).setInt32(0, value, Endian.little);
        return out;
      case kCipTypeLint:
        if (value is! int) {
          return null;
        }
        final out = Uint8List(8);
        ByteData.sublistView(out).setInt64(0, value, Endian.little);
        return out;
      case kCipTypeReal:
        double doubleValue;
        if (value is double) {
          doubleValue = value;
        } else if (value is int) {
          doubleValue = value.toDouble();
        } else {
          return null;
        }
        final out = Uint8List(4);
        ByteData.sublistView(out).setFloat32(0, doubleValue, Endian.little);
        return out;
      default:
        return null;
    }
  } on Object {
    // Defensive: e.g. an int value out of range for the target width. This
    // function is not on the hard "must never throw" list, but there is no
    // reason to let a RangeError escape when returning null is just as
    // informative to the caller.
    return null;
  }
}

/// Decodes wire bytes [data] as CIP type [typeCode]. Returns `null` (never
/// throws) if [typeCode] is unrecognized or [data] is shorter than that
/// type's fixed wire width — this may be fed arbitrary bytes off the wire.
///
/// `REAL` (0xCA) is decoded as IEEE-754 single precision and **widened** to
/// a Dart `double`; the result should be compared with a tolerance
/// (`closeTo`), not exact equality, against any original `FLOAT64` value it
/// came from, since the original encoding step was narrowing.
dynamic decodeCipValue(int typeCode, Uint8List data) {
  switch (typeCode) {
    case kCipTypeBool:
      if (data.isEmpty) {
        return null;
      }
      return data[0] != 0x00;
    case kCipTypeInt:
      if (data.length < 2) {
        return null;
      }
      return ByteData.sublistView(data, 0, 2).getInt16(0, Endian.little);
    case kCipTypeDint:
      if (data.length < 4) {
        return null;
      }
      return ByteData.sublistView(data, 0, 4).getInt32(0, Endian.little);
    case kCipTypeLint:
      if (data.length < 8) {
        return null;
      }
      return ByteData.sublistView(data, 0, 8).getInt64(0, Endian.little);
    case kCipTypeReal:
      if (data.length < 4) {
        return null;
      }
      return ByteData.sublistView(data, 0, 4).getFloat32(0, Endian.little);
    default:
      return null;
  }
}
