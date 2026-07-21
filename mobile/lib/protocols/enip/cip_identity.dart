// CIP connect-time controller-info objects — pure Dart, no dart:io / Flutter.
// Serves the two Get Attributes All reads a Logix-style client performs at
// connect (pycomm3 LogixDriver.open()'s get_plc_info + get_plc_name, Ignition's
// driver) BEFORE it uploads the tag directory (see cip_symbol.dart):
//
//  - Identity Object (class 0x01): vendor/product/revision/serial/name.
//  - Program Name Object (class 0x64): the controller/program name, returned
//    as a Logix STRING (u16 length + ascii) — the honest project controller
//    name, no impersonation.
//
// Also builds the ListIdentity (encapsulation 0x63) item, which wraps the same
// identity fields for pre-session discovery.
//
// The reported identity is an HONEST self-description of the simulator: a
// reserved Vendor ID (0 — claims no real vendor), Device Type "Programmable
// Logic Controller", a fixed serial (determinism), product name
// "Soft PLC Simulator". It impersonates no real product.
//
// Identity Get Attributes All reply layout (little-endian): Vendor ID u16,
// Device Type u16, Product Code u16, Revision major u8 + minor u8, Status u16,
// Serial u32, Product Name SHORT_STRING (u8 len + ascii).
library cip_identity;

import 'dart:typed_data';

import 'cip.dart';

const int kIdentityVendorId = 0;
const int kIdentityDeviceType = 0x000E; // Programmable Logic Controller.
const int kIdentityProductCode = 0x0001;
const int kIdentityRevisionMajor = 1;
const int kIdentityRevisionMinor = 1;
const int kIdentityStatus = 0x0000;
const int kIdentitySerialNumber = 0x00000001;
const String kIdentityProductName = 'Soft PLC Simulator';

/// True iff [path]'s first segment is the Identity Object class.
bool isIdentityObjectPath(List<CipPathSegment> path) =>
    path.isNotEmpty &&
    path[0].kind == CipPathSegmentKind.classId &&
    path[0].id == kCipIdentityObjectClassId;

/// True iff [path]'s first segment is the Program Name Object class.
bool isProgramNameObjectPath(List<CipPathSegment> path) =>
    path.isNotEmpty &&
    path[0].kind == CipPathSegmentKind.classId &&
    path[0].id == kCipProgramNameObjectClassId;

/// The Program Name Object Get Attributes All reply: the whole reply data is a
/// single Logix `STRING` — a u16 byte-length followed by that many
/// ISO-8859-1/ASCII bytes — exactly what pycomm3's `get_plc_name`
/// (`data_type=STRING`) decodes. [name] is the honest project controller name;
/// non-ASCII bytes are replaced with '?', and it is truncated to 0xFFFF bytes
/// (the u16 length field's max). Never throws.
CipResponse buildProgramNameGetAttributesAllResponse(int requestService, String name) {
  final capped = name.length > 0xFFFF ? name.substring(0, 0xFFFF) : name;
  final nameBytes = Uint8List.fromList(
    [for (final u in capped.codeUnits) u <= 0x7F ? u : 0x3F],
  );
  final out = BytesBuilder();
  final lenField = ByteData(2)..setUint16(0, nameBytes.length, Endian.little);
  out.add(lenField.buffer.asUint8List());
  out.add(nameBytes);
  return CipResponse(service: requestService, generalStatus: kCipStatusSuccess, data: out.toBytes());
}

/// The packed Identity attribute struct (shared by Get Attributes All and the
/// ListIdentity item body).
Uint8List _identityStruct() {
  final nameBytes = Uint8List.fromList(
    [for (final u in kIdentityProductName.codeUnits) u <= 0x7F ? u : 0x3F],
  );
  final out = BytesBuilder();
  final head = ByteData(14)
    ..setUint16(0, kIdentityVendorId, Endian.little)
    ..setUint16(2, kIdentityDeviceType, Endian.little)
    ..setUint16(4, kIdentityProductCode, Endian.little)
    ..setUint8(6, kIdentityRevisionMajor)
    ..setUint8(7, kIdentityRevisionMinor)
    ..setUint16(8, kIdentityStatus, Endian.little)
    ..setUint32(10, kIdentitySerialNumber, Endian.little);
  out.add(head.buffer.asUint8List());
  out.addByte(nameBytes.length);
  out.add(nameBytes);
  return out.toBytes();
}

/// The Identity Object Get Attributes All reply.
CipResponse buildIdentityGetAttributesAllResponse(int requestService) =>
    CipResponse(service: requestService, generalStatus: kCipStatusSuccess, data: _identityStruct());

/// The little-endian wire bytes of a single standard Identity Object attribute
/// ([attrId] 1..7), or `null` if this simulator does not serve that attribute
/// id. Used by Get Attribute List (0x03) to answer a client-chosen subset. The
/// values are the same honest, non-impersonating identity as
/// [buildIdentityGetAttributesAllResponse]. Never throws.
///   1 Vendor ID (UINT) · 2 Device Type (UINT) · 3 Product Code (UINT) ·
///   4 Revision (USINT major + USINT minor) · 5 Status (WORD) ·
///   6 Serial Number (UDINT) · 7 Product Name (SHORT_STRING).
Uint8List? identityAttributeBytes(int attrId) {
  switch (attrId) {
    case 1:
      return (ByteData(2)..setUint16(0, kIdentityVendorId, Endian.little)).buffer.asUint8List();
    case 2:
      return (ByteData(2)..setUint16(0, kIdentityDeviceType, Endian.little)).buffer.asUint8List();
    case 3:
      return (ByteData(2)..setUint16(0, kIdentityProductCode, Endian.little)).buffer.asUint8List();
    case 4:
      return Uint8List.fromList([kIdentityRevisionMajor & 0xFF, kIdentityRevisionMinor & 0xFF]);
    case 5:
      return (ByteData(2)..setUint16(0, kIdentityStatus, Endian.little)).buffer.asUint8List();
    case 6:
      return (ByteData(4)..setUint32(0, kIdentitySerialNumber, Endian.little)).buffer.asUint8List();
    case 7:
      final nameBytes = Uint8List.fromList(
        [for (final u in kIdentityProductName.codeUnits) u <= 0x7F ? u : 0x3F],
      );
      return (BytesBuilder()..addByte(nameBytes.length)..add(nameBytes)).toBytes();
    default:
      return null;
  }
}

/// The ListIdentity CPF item body (encapsulation command 0x63). Layout:
/// item type u16 (0x000C), item length u16, encap protocol version u16 (1),
/// socket address (16 bytes, zeroed — the client already knows the socket it
/// connected on), then the identity struct, then a device state u8 (0xFF =
/// unknown/not-applicable for a soft device).
Uint8List buildListIdentityItem() {
  final id = _identityStruct();
  final body = BytesBuilder();
  final ver = ByteData(2)..setUint16(0, 1, Endian.little);
  body.add(ver.buffer.asUint8List());
  body.add(Uint8List(16)); // socket address, zeroed.
  body.add(id);
  body.addByte(0xFF); // device state.
  final payload = body.toBytes();
  final out = BytesBuilder();
  final hdr = ByteData(4)
    ..setUint16(0, 0x000C, Endian.little) // CPF item type: ListIdentity response.
    ..setUint16(2, payload.length, Endian.little);
  out.add(hdr.buffer.asUint8List());
  out.add(payload);
  return out.toBytes();
}
