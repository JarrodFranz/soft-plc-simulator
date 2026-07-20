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
//      instance id (u32), then each requested attribute in order:
//        attr 1 (symbol name): u16 byte-length + that many ASCII bytes.
//        attr 2 (symbol type): u16 elementary CIP type code.
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

/// The fixed per-instance overhead (bytes) besides the name payload: 4-byte
/// instance id + 2-byte name-length field + 2-byte type field. Used to
/// budget each instance before admitting it.
const int _kSymbolInstanceFixedBytes = 8;

/// Builds the Symbol Object Get Instance Attribute List reply for [map]'s
/// entries (each a flat atomic symbol), starting at
/// [parsed].startInstance and honoring [parsed].attributeIds (attr 1 name,
/// attr 2 type). Instance id = 1-based index over the LISTABLE entries (an
/// entry with no CIP type is skipped and consumes no id). Emits instances
/// until the next would exceed [replyBudget], then sets status 0x06;
/// otherwise 0x00. Never throws.
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
    final nameBytes = _asciiBytes(sym.name);
    final cost = _kSymbolInstanceFixedBytes + nameBytes.length;
    if (out.length + cost > replyBudget) {
      partial = true;
      break;
    }
    final idBytes = ByteData(4)..setUint32(0, sym.id, Endian.little);
    out.add(idBytes.buffer.asUint8List());
    if (parsed.attributeIds.contains(kCipSymbolAttrName)) {
      final lenBytes = ByteData(2)..setUint16(0, nameBytes.length, Endian.little);
      out.add(lenBytes.buffer.asUint8List());
      out.add(nameBytes);
    }
    if (parsed.attributeIds.contains(kCipSymbolAttrType)) {
      final typeBytes = ByteData(2)..setUint16(0, sym.typeCode, Endian.little);
      out.add(typeBytes.buffer.asUint8List());
    }
  }
  return CipResponse(
    service: kCipServiceGetInstanceAttributeList,
    generalStatus: partial ? kCipStatusPartialTransfer : kCipStatusSuccess,
    data: out.toBytes(),
  );
}

/// ASCII bytes for [name], non-ASCII replaced with '?', truncated to 0xFFFF
/// (the u16 length field's max). Never throws.
Uint8List _asciiBytes(String name) {
  final capped = name.length > 0xFFFF ? name.substring(0, 0xFFFF) : name;
  return Uint8List.fromList([for (final u in capped.codeUnits) u <= 0x7F ? u : 0x3F]);
}
