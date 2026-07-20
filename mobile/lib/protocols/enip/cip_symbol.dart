// CIP Symbol Object (class 0x6B) browse codec — pure Dart, no dart:io /
// Flutter. Serves Get Instance Attribute List (0x55) so a Logix-style client
// (pycomm3 LogixDriver, Ignition's AB Logix driver) uploads the tag
// directory at connect. Every exposed tag is an atomic scalar leaf (see
// models/cip_map.dart), so each CipMap entry is one flat atomic Symbol
// instance — no Template Object (class 0x6C) is involved. Sits ABOVE the CIP
// messaging layer (cip.dart) and reuses the same tag resolver the Read/Write
// Tag services use.
//
// Wire layout (Get Instance Attribute List over class 0x6B):
//  - Request path: logical Class 0x6B, then optionally Instance <start>.
//  - Request data: attribute-count (u16) + that many attribute ids (u16).
//  - Reply data: per returned instance, in ascending id order from <start>:
//      instance id (u32), then each REQUESTED attribute, emitted in ascending
//      attribute-id order (the order a Logix client both asks for and parses):
//        attr 1 (symbol name): u16 byte-length + that many ASCII bytes.
//        attr 2 (symbol type): u16 elementary CIP type code — bit 15 clear
//          marks the symbol ATOMIC (low byte = the CIP type code), so a Logix
//          client never fetches a Template Object (class 0x6C) for it.
//        attr 3 (symbol address): u32 — 0; a soft simulator has no address.
//        attr 5 (symbol object address): u32 — 0.
//        attr 6 (software control): u32 — BASE_TAG_BIT set, so the client
//          marks the symbol a BASE tag (not an alias).
//        attr 8 (array dimensions): three u32s — all 0 (every symbol is a
//          scalar leaf; see models/cip_map.dart).
//    pycomm3's LogixDriver.get_tag_list() requests {1,2,3,5,6,8}; the Task-2
//    generic-messaging browse requests only {1,2}. Each is served by emitting
//    exactly the requested attributes, so both clients stay byte-in-sync.
//  - Status: 0x00 when the last instance fit; 0x06 (Partial Transfer) when
//    instances remain — the client re-requests from lastReturnedId + 1.
//
// Non-throwing contract: parse/build are fed wire-derived data and must never
// throw; parse returns null, build returns an error-status CipResponse.
library cip_symbol;

import 'dart:typed_data';

import '../../models/cip_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'cip.dart';

/// The Symbol Object attribute ids this codec can emit.
const int kCipSymbolAttrName = 1;
const int kCipSymbolAttrType = 2;

/// Attr 3: symbol address (UDINT). A soft simulator has no physical memory
/// address per tag, so this is 0 — a Logix client stores it verbatim.
const int kCipSymbolAttrAddress = 3;

/// Attr 5: symbol object address (UDINT). Same rationale as attr 3 — 0.
const int kCipSymbolAttrObjectAddress = 5;

/// Attr 6: software control flags (UDINT). [_kSymbolBaseTagBit] is set so a
/// Logix client marks the symbol a BASE tag rather than an alias.
const int kCipSymbolAttrSoftwareControl = 6;

/// Attr 8: array dimensions — three UDINTs. Every exposed symbol is a scalar
/// leaf, so all three dimensions are 0.
const int kCipSymbolAttrArrayDims = 8;

/// The BASE_TAG_BIT a Logix client reads out of attr 6 (software control) to
/// tell a base tag from an alias. Mirrors pycomm3's `BASE_TAG_BIT` (1 << 26).
const int _kSymbolBaseTagBit = 1 << 26;

/// The attributes this codec can serve, in the ascending order a Logix client
/// both requests and parses them.
const List<int> _kEmittableAttrsAscending = [
  kCipSymbolAttrName,
  kCipSymbolAttrType,
  kCipSymbolAttrAddress,
  kCipSymbolAttrObjectAddress,
  kCipSymbolAttrSoftwareControl,
  kCipSymbolAttrArrayDims,
];

/// A parsed Get Instance Attribute List request: the instance to start
/// enumerating from, and the ordered attribute ids the client asked for.
class GetInstanceAttrListRequest {
  final int startInstance;
  final List<int> attributeIds;
  const GetInstanceAttrListRequest({required this.startInstance, required this.attributeIds});
}

/// True iff [path]'s first segment is the Symbol Object class.
bool isSymbolObjectPath(List<CipPathSegment> path) =>
    path.isNotEmpty &&
    path[0].kind == CipPathSegmentKind.classId &&
    path[0].id == kCipSymbolObjectClassId;

/// Parses a Get Instance Attribute List [req]. The start instance is the
/// path's Instance segment value (0 if the path has no instance segment);
/// the attribute id list is `count` (u16) then that many u16 ids. Returns
/// `null` (never throws) on malformed input.
GetInstanceAttrListRequest? parseGetInstanceAttrListRequest(CipRequest req) {
  var startInstance = 0;
  for (final seg in req.path) {
    if (seg.kind == CipPathSegmentKind.instanceId) {
      startInstance = seg.id ?? 0;
    }
  }
  final data = req.data;
  if (data.length < 2) {
    return null;
  }
  final count = ByteData.sublistView(data, 0, 2).getUint16(0, Endian.little);
  final idsEnd = 2 + count * 2;
  if (idsEnd > data.length) {
    return null;
  }
  final ids = <int>[];
  for (var i = 0; i < count; i++) {
    ids.add(ByteData.sublistView(data, 2 + i * 2, 4 + i * 2).getUint16(0, Endian.little));
  }
  return GetInstanceAttrListRequest(startInstance: startInstance, attributeIds: ids);
}

/// Builds the Symbol Object Get Instance Attribute List reply for [map]'s
/// entries (each a flat atomic symbol), starting at
/// [parsed].startInstance and honoring [parsed].attributeIds (attrs 1, 2, 3,
/// 5, 6, 8 — see [_kEmittableAttrsAscending]). Instance id = 1-based index
/// over the LISTABLE entries (an entry with no CIP type is skipped and
/// consumes no id). Emits instances until the next would exceed [replyBudget],
/// then sets status 0x06; otherwise 0x00. Never throws.
CipResponse buildSymbolInstanceListResponse(
  PlcProject project,
  CipMap map,
  GetInstanceAttrListRequest parsed, {
  required int replyBudget,
}) {
  // Number the listable entries 1..N, skipping entries with no CIP type.
  final listable = <({int id, String name, int typeCode})>[];
  var nextId = 1;
  for (final entry in map.entries) {
    final dataType = dataTypeOfPath(project, entry.tagName);
    final typeCode = dataType == null ? null : cipTypeForTagType(dataType);
    if (typeCode == null) {
      continue; // stale STRING / unresolved entry: not listable, no id burned.
    }
    listable.add((id: nextId, name: entry.tagName, typeCode: typeCode));
    nextId++;
  }

  final out = BytesBuilder();
  var partial = false;
  for (final sym in listable) {
    if (sym.id < parsed.startInstance) {
      continue; // already delivered in an earlier page.
    }
    // Build this instance's full block first, then admit it whole — the
    // budget check must match the bytes actually emitted, so the block is
    // measured, not estimated.
    final block = _encodeInstance(sym.id, sym.name, sym.typeCode, parsed.attributeIds);
    if (out.length + block.length > replyBudget) {
      partial = true;
      break;
    }
    out.add(block);
  }
  return CipResponse(
    service: kCipServiceGetInstanceAttributeList,
    generalStatus: partial ? kCipStatusPartialTransfer : kCipStatusSuccess,
    data: out.toBytes(),
  );
}

/// Encodes ONE Symbol instance block: the instance [id] (u32) followed by
/// each requested attribute in ascending attribute-id order (see
/// [_kEmittableAttrsAscending]). Only attributes present in [attributeIds]
/// are emitted, so a client asking for {1,2} and one asking for {1,2,3,5,6,8}
/// each get exactly what they parse. Never throws.
Uint8List _encodeInstance(int id, String name, int typeCode, List<int> attributeIds) {
  final b = BytesBuilder();
  b.add((ByteData(4)..setUint32(0, id, Endian.little)).buffer.asUint8List());
  for (final attr in _kEmittableAttrsAscending) {
    if (!attributeIds.contains(attr)) {
      continue;
    }
    switch (attr) {
      case kCipSymbolAttrName:
        final nameBytes = _asciiBytes(name);
        b.add((ByteData(2)..setUint16(0, nameBytes.length, Endian.little)).buffer.asUint8List());
        b.add(nameBytes);
        break;
      case kCipSymbolAttrType:
        b.add((ByteData(2)..setUint16(0, typeCode, Endian.little)).buffer.asUint8List());
        break;
      case kCipSymbolAttrAddress:
      case kCipSymbolAttrObjectAddress:
        b.add(Uint8List(4)); // UDINT 0.
        break;
      case kCipSymbolAttrSoftwareControl:
        b.add((ByteData(4)..setUint32(0, _kSymbolBaseTagBit, Endian.little)).buffer.asUint8List());
        break;
      case kCipSymbolAttrArrayDims:
        b.add(Uint8List(12)); // three UDINT zeros — scalar, no dimensions.
        break;
    }
  }
  return b.toBytes();
}

/// ASCII bytes for [name], non-ASCII replaced with '?', truncated to 0xFFFF
/// (the u16 length field's max). Never throws.
Uint8List _asciiBytes(String name) {
  final capped = name.length > 0xFFFF ? name.substring(0, 0xFFFF) : name;
  return Uint8List.fromList([for (final u in capped.codeUnits) u <= 0x7F ? u : 0x3F]);
}
