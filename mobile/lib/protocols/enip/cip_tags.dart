// CIP tag services — pure Dart, no dart:io / Flutter imports. Implements
// the three CIP services this in-app EtherNet/IP host answers over
// symbolic/named tag addressing: Read Tag (0x4C), Write Tag (0x4D), and the
// Multiple Service Packet (0x0A), which batches embedded Read/Write Tag
// requests into one round trip. Sits ABOVE the CIP messaging layer
// (`cip.dart`) and the `CipMap` exposure model (`models/cip_map.dart`):
// this file resolves a wire symbol name to a project tag path via
// `models/tag_resolver.dart` — the same resolver the other protocol layers
// (OPC UA, Modbus, DNP3, MQTT) use — and never invents a parallel
// resolution mechanism.
//
// Exposure and write-safety rules (mirrors the OPC UA precedent at
// `protocols/opcua/opcua_services.dart`'s `_writeAttribute`):
//  - A tag not present in the project OR present but not in the `CipMap`
//    both return general status 0x05 (Path Destination Unknown) — a
//    lookup miss on the map is checked first, so "unexposed" is
//    indistinguishable from "does not exist".
//  - A write to a `CipMap` entry whose `access` is `'ReadOnly'` is refused
//    with 0x0F (Privilege Violation); the tag is left unchanged.
//  - A write to a FORCED tag is refused with 0x0F, exactly like the OPC UA
//    write path: this is a deliberate, VISIBLE refusal, unlike the logic
//    engines, which skip forced tags silently. An external protocol write
//    must never appear to succeed while having no effect.
//
// Multiple Service Packet (0x0A) wire layout: the request path must be the
// Message Router object (class 0x02, instance 0x01); the data is a service
// count (u16), then that many u16 offsets — each measured from the START OF
// THE REQUEST DATA (byte 0 = the count field itself), per CIP Vol 1 / Rockwell
// 1756-PM020, so the first embedded request's offset is `2 + count*2` (past the
// count field and the offset list) — followed by the embedded CIP requests
// themselves. The reply mirrors that shape: count (u16), offsets (u16, same
// from-the-start-of-the-reply-data convention) into the reply's own data, then
// the embedded CIP *responses* (each built exactly like a normal CIP response,
// via `buildCipResponse` — the same 4-byte header + data shape).
// Critically, one embedded request failing (an unexposed tag, a malformed
// embedded request, whatever) only sets THAT embedded response's own
// status — it never fails the whole batch. The outer 0x0A response's own
// `generalStatus` only turns non-success if the *envelope itself* (the
// count/offset header) fails to parse.
//
// This file uses two constants defined in `cip.dart` (consolidated there
// alongside the rest of the CIP status/service codes — see that file's doc
// comment for the full history and the 0x0A footgun warning):
//  - `kCipServiceMultipleServicePacket` (0x0A), this service's code.
//  - `kCipStatusInvalidAttributeValue` (0x09), the standard CIP general
//    status for "the supplied attribute value is invalid for its type" —
//    used here for a Write Tag whose wire type code doesn't match the
//    target tag's actual CIP type.
//
// Non-throwing contract: `dispatchCipService` is fed a `CipRequest` already
// parsed off the wire by `cip.dart`, but its `data` payload has NOT been
// further validated — this function must never throw on truncated or
// hostile service data; it returns a `CipResponse` carrying a non-zero
// general status instead, mirroring `cip.dart`'s and `enip_encap.dart`'s
// convention.
library cip_tags;

import 'dart:typed_data';

import '../../models/cip_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import '../../models/tag_write_gate.dart';
import 'cip.dart';
import 'cip_identity.dart';
import 'cip_symbol.dart';

/// The Message Router object identity (class 0x02, instance 0x01) that a
/// Multiple Service Packet request's path must address.
const int _kMessageRouterClassId = 0x02;
const int _kMessageRouterInstanceId = 0x01;

/// The reply-size cap applied to a Symbol Object browse arriving over an
/// UNCONNECTED (UCMM / SendRRData) send, which has no negotiated connection
/// size. Kept comfortably within a single UCMM reply so the browse paginates
/// (status 0x06) rather than emitting an oversized frame; a Logix client
/// re-requests from the last instance id + 1. Connected sends use the
/// negotiated `responseBudget` instead.
const int kCipUcmmBrowseReplyCap = 480;

/// The minimum on-wire cost, in bytes, of ONE embedded item in a Multiple
/// Service Packet reply: its 2-byte reply-offset-list entry plus the 4-byte
/// `buildCipResponse` header of a data-less (error) response body. This is the
/// amount reserved per still-to-come item when budgeting a connected batch
/// against the negotiated connection size — the reply's item count must equal
/// the request's, so every remaining item needs at least this much room even
/// if it can only carry an error status. Mirrors `kS7DataItemHeaderLen`'s role
/// in `s7_services.dart`'s Read Var budget.
const int kCipMspItemHeaderLen = 6;

/// The fixed, non-per-item overhead of a Multiple Service Packet reply: the
/// 2-byte service-count field plus the 4-byte outer `buildCipResponse` header
/// that wraps the whole reply. The per-item budget subtracts this from the
/// connection size before charging items.
const int _kCipMspReplyFixedOverhead = 6;

/// The hard cap on how deeply embedded requests may be re-dispatched back
/// through [dispatchCipService]. Two services re-dispatch: Unconnected Send
/// (0x52) unwraps and re-dispatches its embedded request, and Multiple Service
/// Packet (0x0A) re-dispatches each of its embedded requests — and 0x0A may
/// itself carry a 0x52 (and vice-versa), so the `0x52 <-> 0x0A` cycle can
/// otherwise recurse once per nesting level, bounded only by the ~64 KB frame
/// cap (thousands of levels), each level `sublist`-copying its embedded slice —
/// a resource-exhaustion vector. A [depth] counter threaded through both
/// re-dispatch sites hard-bounds this regardless of frame size: before routing
/// to EITHER recursive service, a request at or beyond this depth is refused
/// with an error status instead of recursing. Legitimate real-client nesting is
/// at most ~2 levels (an Unconnected Send wrapping a Multiple Service Packet
/// wrapping leaf reads), so 8 sits far above any legit depth while still being a
/// trivial constant bound. It must be > 1 so a legitimate 0x52-wrapping-MSP
/// batch is not broken.
const int kMaxEmbeddedDispatchDepth = 8;

/// Dispatches a parsed [CipRequest] against [project]'s tags, exposed
/// through [map], and returns the [CipResponse] to send back. Handles Read
/// Tag (0x4C), Write Tag (0x4D), and the Multiple Service Packet (0x0A); any
/// other service code returns 0x08 (Service Not Supported). Never throws.
///
/// [responseBudget] is the negotiated Forward Open **T->O connection size**
/// (bytes) when this request arrives over a CONNECTED send (`SendUnitData`),
/// or `null` for an UNCONNECTED (UCMM / `SendRRData`) send, which has no
/// negotiated size and is therefore unbounded. It bounds only the Multiple
/// Service Packet reply: a batch whose embedded responses would overrun the
/// connection size the client agreed to has its over-budget items answered
/// with 0x11 (Reply Data Too Large) rather than emitting an oversized frame.
/// A batch that fits the budget — and every non-MSP service — is byte-
/// identical whether or not a budget is supplied.
///
/// [depth] is the embedded re-dispatch recursion depth (0 for a request off the
/// wire; incremented at each of the two re-dispatch sites — see
/// [kMaxEmbeddedDispatchDepth]). It is additive: existing callers keep the
/// default 0. A request routed to either recursive service (Unconnected Send /
/// Multiple Service Packet) at or beyond [kMaxEmbeddedDispatchDepth] is refused
/// with an error status instead of recursing.
CipResponse dispatchCipService(PlcProject project, CipMap map, CipRequest req, {int? responseBudget, int depth = 0}) {
  try {
    switch (req.service) {
      case kCipServiceReadTag:
        return _readTag(project, map, req);
      case kCipServiceWriteTag:
        return _writeTag(project, map, req);
      case kCipServiceMultipleServicePacket:
        if (depth >= kMaxEmbeddedDispatchDepth) {
          return _errorResponse(req.service, kCipStatusServiceNotSupported);
        }
        return _multipleServicePacket(project, map, req, responseBudget, depth);
      case kCipServiceGetInstanceAttributeList:
        return _symbolBrowse(project, map, req, responseBudget);
      case kCipServiceGetAttributesAll:
        if (isIdentityObjectPath(req.path)) {
          return buildIdentityGetAttributesAllResponse(req.service);
        }
        if (isProgramNameObjectPath(req.path)) {
          return buildProgramNameGetAttributesAllResponse(req.service, project.controllerName);
        }
        return _errorResponse(req.service, kCipStatusServiceNotSupported);
      case kCipServiceGetAttributeList:
        return _getAttributeList(project, map, req);
      case kCipServiceUnconnectedSend:
        if (depth >= kMaxEmbeddedDispatchDepth) {
          return _errorResponse(req.service, kCipStatusServiceNotSupported);
        }
        return _unconnectedSend(project, map, req, depth);
      default:
        return _errorResponse(req.service, kCipStatusServiceNotSupported);
    }
  } on Object {
    // Defensive backstop: no code path above is expected to throw, but this
    // function is ultimately fed wire-derived data and must never let an
    // unexpected exception escape to the socket host.
    return _errorResponse(req.service, kCipStatusServiceNotSupported);
  }
}

CipResponse _errorResponse(int service, int status) =>
    CipResponse(service: service, generalStatus: status, data: Uint8List(0));

// --- Symbol Object browse (0x55, Get Instance Attribute List) -------------

/// Routes a Get Instance Attribute List (0x55) to the Symbol Object browse
/// codec (`cip_symbol.dart`). Only the Symbol Object (class 0x6B) is served;
/// 0x55 addressed to any other class stays 0x08 (Service Not Supported). On a
/// CONNECTED send [responseBudget] is the negotiated T->O connection size that
/// bounds the reply; on an UNCONNECTED (UCMM) send it is null, and a fixed
/// [kCipUcmmBrowseReplyCap] is used so the browse still paginates (status 0x06)
/// rather than emitting an oversized frame. Never throws.
CipResponse _symbolBrowse(PlcProject project, CipMap map, CipRequest req, int? responseBudget) {
  if (!isSymbolObjectPath(req.path)) {
    // Get Instance Attribute List is only served for the Symbol Object here.
    return _errorResponse(req.service, kCipStatusServiceNotSupported);
  }
  final parsed = parseGetInstanceAttrListRequest(req);
  if (parsed == null) {
    return _errorResponse(req.service, kCipStatusEmbeddedListError);
  }
  final budget = responseBudget ?? kCipUcmmBrowseReplyCap;
  return buildSymbolInstanceListResponse(project, map, parsed, replyBudget: budget);
}

// --- Get Attribute List (0x03) --------------------------------------------

/// Parses a Get Attribute List (0x03) request's chosen attribute ids: count
/// (u16) then that many attribute ids (u16 each). Returns `null` if malformed.
/// Never throws.
List<int>? _parseGetAttributeListRequest(Uint8List data) {
  if (data.length < 2) {
    return null;
  }
  final count = _readU16(data, 0);
  final end = 2 + count * 2;
  if (end > data.length) {
    return null;
  }
  final ids = <int>[];
  for (var i = 0; i < count; i++) {
    ids.add(_readU16(data, 2 + i * 2));
  }
  return ids;
}

/// Builds a Get Attribute List (0x03) reply: count (u16), then for each
/// requested attribute id, `attribute_id` (u16) + per-attribute `status` (u16)
/// + the attribute's data bytes iff its status is success. [attributeBytes]
/// returns an attribute's wire bytes, or `null` if this object does not
/// implement it — reported per-attribute as 0x14 (Attribute Not Supported), not
/// as a blanket service failure. The overall service status is 0x00 (a
/// well-formed list reply always parses); individual attribute failures live in
/// the body, per CIP Get Attribute List semantics.
CipResponse _buildGetAttributeListResponse(
  int service,
  List<int> attributeIds,
  Uint8List? Function(int attrId) attributeBytes,
) {
  final out = BytesBuilder();
  out.add((ByteData(2)..setUint16(0, attributeIds.length, Endian.little)).buffer.asUint8List());
  for (final id in attributeIds) {
    out.add((ByteData(2)..setUint16(0, id, Endian.little)).buffer.asUint8List());
    final bytes = attributeBytes(id);
    final status = bytes == null ? kCipStatusAttributeNotSupported : kCipStatusSuccess;
    out.add((ByteData(2)..setUint16(0, status, Endian.little)).buffer.asUint8List());
    if (bytes != null) {
      out.add(bytes);
    }
  }
  return CipResponse(service: service, generalStatus: kCipStatusSuccess, data: out.toBytes());
}

/// A deterministic 32-bit fingerprint of the exposed tag directory (the same
/// listable symbols the Symbol Object browse enumerates) plus the count of
/// them. FNV-1a over each listable entry's `name:typeCode;` — stable while the
/// directory is unchanged, and it changes iff a browsed tag is added, removed,
/// renamed, or re-typed. Deterministic (no clock/random). Never throws.
({int count, int hash}) _symbolDirectoryFingerprint(PlcProject project, CipMap map) {
  var count = 0;
  var hash = 0x811C9DC5; // FNV-1a 32-bit offset basis.
  void mix(int byte) {
    hash = (hash ^ (byte & 0xFF)) & 0xFFFFFFFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }

  for (final entry in map.entries) {
    final dataType = dataTypeOfPath(project, entry.tagName);
    final typeCode = dataType == null ? null : cipTypeForTagType(dataType);
    if (typeCode == null) {
      continue; // not listable (STRING / unresolved) — mirrors the Symbol browse.
    }
    count++;
    for (final u in entry.tagName.codeUnits) {
      mix(u);
    }
    mix(0x3A); // ':'
    mix(typeCode);
    mix(0x3B); // ';'
  }
  return (count: count, hash: hash);
}

/// The wire bytes of a class-0xAC change-detection attribute, at the widths
/// Rockwell's Logix Data Access manual (1756-PM020, class 0xAC) documents:
///   attr 1 (INT, 2B) symbol count · attr 2 (INT, 2B) template count (none
///   here) · attr 3/4 (DINT, 4B) directory hash · attr 10 (DINT, 4B) a second
///   hash. A Logix SCADA driver reads {1,2,3,4,10} and re-browses iff any
///   changes. These carry this host's OWN stable, deterministic values — not a
///   real controller's data — so a static directory reads identically every
///   time. `null` for any other attribute id (→ per-attribute Not Supported).
Uint8List? _changeDetectAttributeBytes(int attrId, int hash, int count) {
  Uint8List u16(int v) => (ByteData(2)..setUint16(0, v & 0xFFFF, Endian.little)).buffer.asUint8List();
  Uint8List u32(int v) => (ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little)).buffer.asUint8List();
  switch (attrId) {
    case 1:
      return u16(count); // number of symbols (INT).
    case 2:
      return u16(0); // number of templates/structures — this host exposes none.
    case 3:
    case 4:
      return u32(hash); // directory change hash (DINT).
    case 10:
      return u32(hash ^ 0xFFFFFFFF); // a distinct-but-stable second hash (DINT).
    default:
      return null;
  }
}

/// Answers a Get Attribute List (0x03). Identity Object (class 0x01) → the
/// requested standard attributes' honest values. Rockwell change-detection
/// class 0xAC → the documented attributes {1,2,3,4,10} at their real widths,
/// carrying this host's OWN stable directory fingerprint so a Logix SCADA
/// driver (e.g. Ignition) can complete its change-detection check and proceed
/// to the Symbol Object browse. No vendor is impersonated (Vendor ID stays 0).
/// Any other class → a well-formed reply marking each requested attribute
/// Not-Supported (0x14), never a blanket 0x08. Never throws.
CipResponse _getAttributeList(PlcProject project, CipMap map, CipRequest req) {
  final ids = _parseGetAttributeListRequest(req.data);
  if (ids == null) {
    return _errorResponse(req.service, kCipStatusNotEnoughData);
  }
  if (isIdentityObjectPath(req.path)) {
    return _buildGetAttributeListResponse(req.service, ids, identityAttributeBytes);
  }
  if (_targetClassId(req.path) == kCipRockwellChangeDetectClassId) {
    final dir = _symbolDirectoryFingerprint(project, map);
    return _buildGetAttributeListResponse(
        req.service, ids, (id) => _changeDetectAttributeBytes(id, dir.hash, dir.count));
  }
  return _buildGetAttributeListResponse(req.service, ids, (_) => null);
}

// --- Unconnected Send (0x52) ----------------------------------------------

/// Unwraps a CIP Unconnected Send (0x52) addressed to the Connection Manager
/// (class 0x06) and re-dispatches the embedded request TRANSPARENTLY, returning
/// the embedded service's response verbatim (Unconnected Send adds no reply
/// wrapper of its own — a real Logix target returns the embedded reply
/// directly). pycomm3's `LogixDriver` sends `get_plc_info`/`get_plc_name` this
/// way (`unconnected_send=True`).
///
/// Request data layout (matches pycomm3's `wrap_unconnected_send`):
///   priority/tick u8, timeout_ticks u8, embedded-message size u16,
///   that many embedded-request bytes, one 0x00 pad byte iff the size is odd,
///   then route-path size u8 (words) + reserved u8 + route-path words.
/// Only the embedded message is needed here; the route path is ignored because
/// this host is the end device. Never throws — a malformed wrapper returns a
/// non-success [CipResponse], and the embedded dispatch runs through the same
/// never-throwing [dispatchCipService]. The embedded request is dispatched as
/// UCMM (no negotiated `responseBudget`). [depth] is threaded from
/// [dispatchCipService] and forwarded (incremented) to the embedded re-dispatch
/// so the `0x52 <-> 0x0A` recursion cycle is hard-bounded — see
/// [kMaxEmbeddedDispatchDepth].
CipResponse _unconnectedSend(PlcProject project, CipMap map, CipRequest req, int depth) {
  final path = req.path;
  final isConnMgrPath = path.isNotEmpty &&
      path[0].kind == CipPathSegmentKind.classId &&
      path[0].id == kCipConnectionManagerClassId;
  if (!isConnMgrPath) {
    return _errorResponse(req.service, kCipStatusPathSegmentError);
  }
  final data = req.data;
  // Need at least priority(1) + timeout(1) + size(2) before the embedded bytes.
  if (data.length < 4) {
    return _errorResponse(req.service, kCipStatusNotEnoughData);
  }
  final msgLen = _readU16(data, 2);
  const embeddedStart = 4;
  final embeddedEnd = embeddedStart + msgLen;
  if (embeddedEnd > data.length) {
    return _errorResponse(req.service, kCipStatusNotEnoughData);
  }
  final embeddedBytes = Uint8List.sublistView(data, embeddedStart, embeddedEnd);
  final embeddedReq = parseCipRequest(embeddedBytes);
  if (embeddedReq == null) {
    return _errorResponse(req.service, kCipStatusEmbeddedServiceError);
  }
  // Reject a DIRECT nested Unconnected Send (0x52-inside-0x52) here, cheaply, at
  // exactly one level — a real Logix target never nests Unconnected Send. This
  // is subsumed by the [kMaxEmbeddedDispatchDepth] counter that bounds the
  // broader `0x52 <-> 0x0A` re-dispatch cycle (an embedded 0x0A can itself carry
  // a 0x52, and vice-versa), but is kept as a fast, obvious guard for the common
  // direct case; the two do not conflict.
  if (embeddedReq.service == kCipServiceUnconnectedSend) {
    return _errorResponse(req.service, kCipStatusServiceNotSupported);
  }
  // Transparent unwrap: the embedded service's own response IS the reply. The
  // embedded dispatch is charged one level of recursion depth so the
  // `0x52 <-> 0x0A` cycle is hard-bounded.
  return dispatchCipService(project, map, embeddedReq, depth: depth + 1);
}

// --- Diagnostics ----------------------------------------------------------

String _hexByte(int v) => '0x${(v & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase()}';

/// The target class id of a CIP request's path (its first logical Class
/// segment), or `null` if the path leads with something else (e.g. a symbolic
/// tag name). Diagnostics only; never throws.
int? _targetClassId(List<CipPathSegment> path) {
  if (path.isNotEmpty && path[0].kind == CipPathSegmentKind.classId) {
    return path[0].id;
  }
  return null;
}

/// The embedded CIP request carried by an Unconnected Send (0x52), or `null`
/// if [req] is not a well-formed Unconnected Send. Diagnostics/introspection
/// only — the dispatch path parses its own copy. Never throws.
CipRequest? unconnectedSendEmbeddedRequest(CipRequest req) {
  if (req.service != kCipServiceUnconnectedSend) {
    return null;
  }
  final data = req.data;
  if (data.length < 4) {
    return null;
  }
  final msgLen = _readU16(data, 2);
  const embeddedStart = 4;
  final embeddedEnd = embeddedStart + msgLen;
  if (embeddedEnd > data.length) {
    return null;
  }
  return parseCipRequest(Uint8List.sublistView(data, embeddedStart, embeddedEnd));
}

/// A short, human-readable description of what a CIP request targets, for the
/// in-app Logs: its service code and target class, and — for an Unconnected
/// Send (0x52) — the EMBEDDED service and class it wraps (what a routing client
/// like a SCADA Logix driver is actually asking for, which the bare 0x52 code
/// hides). Never throws.
String describeCipRequest(CipRequest req) {
  String describe(int service, List<CipPathSegment> path, Uint8List data) {
    final cls = _targetClassId(path);
    var s = cls == null
        ? 'service ${_hexByte(service)}'
        : 'service ${_hexByte(service)} to class ${_hexByte(cls)}';
    if (service == kCipServiceGetAttributeList) {
      final ids = _parseGetAttributeListRequest(data);
      if (ids != null) {
        s += ' requesting attrs [${ids.map(_hexByte).join(', ')}]';
      }
    }
    return s;
  }

  if (req.service != kCipServiceUnconnectedSend) {
    return describe(req.service, req.path, req.data);
  }
  final embedded = unconnectedSendEmbeddedRequest(req);
  if (embedded == null) {
    return 'Unconnected Send (0x52) wrapping an unparseable embedded request';
  }
  return 'Unconnected Send (0x52) wrapping ${describe(embedded.service, embedded.path, embedded.data)}';
}

/// Joins a path's ANSI Extended Symbol segments into a dotted resolver path
/// (e.g. `Tank.Level`). Returns `null` if [path] is empty or contains any
/// non-symbol segment — Read/Write Tag only ever address tags this way.
String? _tagNameFromPath(List<CipPathSegment> path) {
  if (path.isEmpty) {
    return null;
  }
  final names = <String>[];
  for (final seg in path) {
    if (seg.kind != CipPathSegmentKind.symbolName) {
      return null;
    }
    final name = seg.name;
    if (name == null || name.isEmpty) {
      return null;
    }
    names.add(name);
  }
  return names.join('.');
}

CipMapEntry? _findMapEntry(CipMap map, String tagName) {
  for (final e in map.entries) {
    if (e.tagName == tagName) {
      return e;
    }
  }
  return null;
}

int _readU16(Uint8List data, int offset) =>
    ByteData.sublistView(data, offset, offset + 2).getUint16(0, Endian.little);

Uint8List _writeU16(int value) {
  final out = Uint8List(2);
  ByteData.sublistView(out).setUint16(0, value & 0xFFFF, Endian.little);
  return out;
}

// --- Read Tag (0x4C) -----------------------------------------------------

/// Read Tag request data: element count (u16). v1 exposes only scalar
/// leaves (composite/array tags are pre-expanded into one `CipMap` entry
/// per scalar leaf by `CipMap.autoPopulate`), so there is never more than
/// one element to return; the count is tolerated but not otherwise acted
/// on. Reply data: type code (u16) + the packed value.
CipResponse _readTag(PlcProject project, CipMap map, CipRequest req) {
  final tagName = _tagNameFromPath(req.path);
  if (tagName == null) {
    return _errorResponse(req.service, kCipStatusPathSegmentError);
  }
  // Map lookup first: a tag absent from the CipMap is indistinguishable
  // from a tag that doesn't exist in the project at all.
  if (_findMapEntry(map, tagName) == null) {
    return _errorResponse(req.service, kCipStatusPathDestinationUnknown);
  }
  final dataType = dataTypeOfPath(project, tagName);
  if (dataType == null) {
    return _errorResponse(req.service, kCipStatusPathDestinationUnknown);
  }
  final typeCode = cipTypeForTagType(dataType);
  if (typeCode == null) {
    // e.g. a stale map entry pointing at a STRING tag — no CIP wire type.
    return _errorResponse(req.service, kCipStatusPathDestinationUnknown);
  }
  final value = readPath(project, tagName);
  final encoded = encodeCipValue(typeCode, value);
  if (encoded == null) {
    return _errorResponse(req.service, kCipStatusInvalidAttributeValue);
  }
  final data = Uint8List(2 + encoded.length);
  data.setRange(0, 2, _writeU16(typeCode));
  data.setRange(2, data.length, encoded);
  return CipResponse(service: req.service, generalStatus: kCipStatusSuccess, data: data);
}

// --- Write Tag (0x4D) ------------------------------------------------------

/// Write Tag request data: type code (u16) + element count (u16) + value
/// bytes. v1 supports only a single scalar element per entry (see
/// `_readTag`); the element count is tolerated but not otherwise acted on.
CipResponse _writeTag(PlcProject project, CipMap map, CipRequest req) {
  final tagName = _tagNameFromPath(req.path);
  if (tagName == null) {
    return _errorResponse(req.service, kCipStatusPathSegmentError);
  }
  final entry = _findMapEntry(map, tagName);
  if (entry == null) {
    return _errorResponse(req.service, kCipStatusPathDestinationUnknown);
  }
  if (entry.access == 'ReadOnly') {
    return _errorResponse(req.service, kCipStatusPrivilegeViolation);
  }
  // Write-time hard backstop (protocol-hardening workstream, Task 2): the
  // CipMap entry above is a MUTABLE map that a hand-edit could re-target at
  // the reserved System tag (or leave writable against a tag whose OWN
  // `access` has since become 'ReadOnly'). `isExternallyWritable` re-checks
  // the underlying tag itself, independent of whatever this entry claims —
  // this is a hard, non-overridable rule, never a replacement for the
  // per-entry check above.
  if (!isExternallyWritable(project, tagName)) {
    return _errorResponse(req.service, kCipStatusPrivilegeViolation);
  }
  final dataType = dataTypeOfPath(project, tagName);
  if (dataType == null) {
    return _errorResponse(req.service, kCipStatusPathDestinationUnknown);
  }
  final typeCode = cipTypeForTagType(dataType);
  if (typeCode == null) {
    return _errorResponse(req.service, kCipStatusPathDestinationUnknown);
  }

  // Force-aware write: a forced root tag REFUSES an external write visibly
  // (0x0F) rather than silently discarding it — see file header and
  // `opcua_services.dart`'s `_writeAttribute` for the identical precedent.
  // `rootTagOf` returns the tag whose `name` is the leaf path's FIRST
  // SEGMENT — unlike OPC UA's `_findRootTag`, which only ever returns an
  // exact-name match, `rootTagOf` also returns the root for a write to a
  // MEMBER beneath it (e.g. `tagName == 'Tank.Level'` resolves `root.name`
  // to `'Tank'`). A forced root must refuse writes to every path beneath
  // it, not just a write to the bare root name itself — otherwise a write
  // to `Tank.Level` would silently bypass the force refusal that a write to
  // `Tank` itself would have been given. There is deliberately no
  // `root.name == tagName` equality check here (unlike the OPC UA
  // precedent, where that comparison is a harmless tautology).
  final root = rootTagOf(project, tagName);
  if (root != null && root.isForced) {
    return _errorResponse(req.service, kCipStatusPrivilegeViolation);
  }

  final data = req.data;
  if (data.length < 4) {
    return _errorResponse(req.service, kCipStatusNotEnoughData);
  }
  final requestedTypeCode = _readU16(data, 0);
  if (requestedTypeCode != typeCode) {
    return _errorResponse(req.service, kCipStatusInvalidAttributeValue);
  }
  final valueBytes = Uint8List.sublistView(data, 4);
  final decoded = decodeCipValue(typeCode, valueBytes);
  if (decoded == null) {
    return _errorResponse(req.service, kCipStatusNotEnoughData);
  }
  writePath(project, tagName, decoded);
  return CipResponse(service: req.service, generalStatus: kCipStatusSuccess, data: Uint8List(0));
}

// --- Multiple Service Packet (0x0A) ---------------------------------------

/// See file header for the wire layout. Never fails the whole batch because
/// of one bad embedded request — a malformed embedded request or an
/// embedded service returning a non-zero status only affects that request's
/// own response entry.
CipResponse _multipleServicePacket(PlcProject project, CipMap map, CipRequest req, int? responseBudget, int depth) {
  final path = req.path;
  final isRouterPath = path.length == 2 &&
      path[0].kind == CipPathSegmentKind.classId &&
      path[0].id == _kMessageRouterClassId &&
      path[1].kind == CipPathSegmentKind.instanceId &&
      path[1].id == _kMessageRouterInstanceId;
  if (!isRouterPath) {
    return _errorResponse(req.service, kCipStatusPathSegmentError);
  }

  final data = req.data;
  if (data.length < 2) {
    return _errorResponse(req.service, kCipStatusEmbeddedListError);
  }
  final count = _readU16(data, 0);
  const offsetListStart = 2;
  final offsetsEnd = offsetListStart + count * 2;
  if (offsetsEnd > data.length) {
    return _errorResponse(req.service, kCipStatusEmbeddedListError);
  }

  final offsets = <int>[];
  for (var i = 0; i < count; i++) {
    offsets.add(_readU16(data, offsetListStart + i * 2));
  }

  final responses = <CipResponse>[];
  for (var i = 0; i < count; i++) {
    // Offsets are from the START OF THE REQUEST DATA (byte 0 = the Number of
    // Services field), per CIP Vol 1 / Rockwell 1756-PM020 — NOT from the byte
    // after the count. A valid embedded request therefore begins at or after
    // `offsetsEnd` (past the count field + the offset list).
    final start = offsets[i];
    final end = i + 1 < count ? offsets[i + 1] : data.length;
    if (start < offsetsEnd || start > data.length || end < start || end > data.length) {
      // Malformed embedded offset: this item alone fails; the batch does
      // not. Service byte 0x00 is a placeholder — the request could never
      // be parsed well enough to know its real service code.
      responses.add(_errorResponse(0x00, kCipStatusEmbeddedServiceError));
      continue;
    }
    final embeddedBytes = Uint8List.sublistView(data, start, end);
    final embeddedReq = parseCipRequest(embeddedBytes);
    if (embeddedReq == null) {
      responses.add(_errorResponse(0x00, kCipStatusEmbeddedServiceError));
      continue;
    }
    // Each embedded dispatch is charged one level of recursion depth: an
    // embedded request may itself be a 0x52/0x0A, so this bounds the
    // `0x52 <-> 0x0A` cycle via [kMaxEmbeddedDispatchDepth].
    responses.add(dispatchCipService(project, map, embeddedReq, depth: depth + 1));
  }

  // Build the embedded response bodies. On a CONNECTED send `responseBudget`
  // is the Forward Open T->O connection size (bytes) the client negotiated;
  // the batch reply must not exceed it. The budget mirrors the S7 Read Var
  // fix (`s7_services.dart buildReadVarResponse`): each item's on-wire cost is
  // charged at admission, and `remainingItems * kCipMspItemHeaderLen` is
  // reserved for the mandatory items still to come — the reply's item count
  // must equal the request's, so no item can simply be dropped. An item that
  // does not fit is answered with 0x11 (Reply Data Too Large), a header-only
  // error body, rather than an oversized frame. On an UNCONNECTED (UCMM) send
  // `responseBudget` is null and every body is emitted verbatim — unbounded
  // and byte-identical to a batch that fits its budget.
  final bodies = <Uint8List>[];
  if (responseBudget == null) {
    for (final r in responses) {
      bodies.add(buildCipResponse(r));
    }
  } else {
    // The finished CIP response is `2 (count field) + offset list + bodies`
    // wrapped in `buildCipResponse`'s 4-byte header, so the fixed overhead the
    // per-item budget must leave room for is those 6 bytes; each item then
    // costs its 2-byte reply offset entry plus its body (`kCipMspItemHeaderLen`
    // is that minimum, a header-only error item).
    final maxItemBytes = responseBudget - _kCipMspReplyFixedOverhead;
    var used = 0;
    for (var i = 0; i < responses.length; i++) {
      final reserved = (responses.length - i - 1) * kCipMspItemHeaderLen;
      final remaining = maxItemBytes - used - reserved;
      var body = buildCipResponse(responses[i]);
      final itemCost = 2 + body.length;
      if (itemCost > remaining) {
        body = buildCipResponse(CipResponse(
          service: responses[i].service,
          generalStatus: kCipStatusReplyDataTooLarge,
          data: Uint8List(0),
        ));
        used += kCipMspItemHeaderLen;
      } else {
        used += itemCost;
      }
      bodies.add(body);
    }
  }
  // Reply offsets are from the START OF THE REPLY DATA (byte 0 = the Number of
  // Service Replies field), per CIP Vol 1 / Rockwell 1756-PM020. The embedded
  // bodies begin right after the count field (2) + the offset list (count * 2),
  // so the first body's offset is `2 + count * 2`, NOT `count * 2`.
  final bodyStart = 2 + count * 2;
  final replyOffsets = <int>[];
  var pos = bodyStart;
  for (final body in bodies) {
    replyOffsets.add(pos);
    pos += body.length;
  }

  // Guard: offsets are serialized through `_writeU16` (masks to 16 bits). If the
  // reply — or any offset — would exceed 0xFFFF, a wrapped offset silently
  // corrupts the framing; fail the whole batch instead. `pos` is the reply-data
  // size; the emitted CIP response wraps it in `buildCipResponse`'s 4-byte
  // header, so bound the full frame (`pos + 4`).
  if (pos + 4 > 0xFFFF || replyOffsets.any((o) => o > 0xFFFF)) {
    return _errorResponse(req.service, kCipStatusEmbeddedListError);
  }

  final replyData = Uint8List(pos);
  replyData.setRange(0, 2, _writeU16(count));
  for (var i = 0; i < count; i++) {
    replyData.setRange(2 + i * 2, 2 + i * 2 + 2, _writeU16(replyOffsets[i]));
  }
  var writeCursor = bodyStart;
  for (final body in bodies) {
    replyData.setRange(writeCursor, writeCursor + body.length, body);
    writeCursor += body.length;
  }

  return CipResponse(service: req.service, generalStatus: kCipStatusSuccess, data: replyData);
}
