// CIP Identity Object (class 0x01) — pure Dart, no dart:io / Flutter. Serves
// Get Attributes All (0x01) so a Logix-style client's connect-time
// controller-info read (pycomm3 LogixDriver.open()'s get_plc_info, Ignition's
// driver) succeeds and proceeds to upload the tag directory (see
// cip_symbol.dart). Also builds the ListIdentity (encapsulation 0x63) item.
//
// The reported identity is an HONEST self-description of the simulator: a
// reserved Vendor ID (0 — claims no real vendor), Device Type "Programmable
// Logic Controller", a fixed serial (determinism), product name
// "Soft PLC Simulator". It impersonates no real product.
//
// Get Attributes All reply layout (little-endian): Vendor ID u16, Device Type
// u16, Product Code u16, Revision major u8 + minor u8, Status u16, Serial u32,
// Product Name SHORT_STRING (u8 len + ascii).
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
