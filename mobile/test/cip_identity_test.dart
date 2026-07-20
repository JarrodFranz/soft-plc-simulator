import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_identity.dart';

void main() {
  test('Identity Get Attributes All packs the identity struct little-endian', () {
    final resp = buildIdentityGetAttributesAllResponse(kCipServiceGetAttributesAll);
    expect(resp.generalStatus, kCipStatusSuccess);
    final d = resp.data;
    expect(ByteData.sublistView(d, 0, 2).getUint16(0, Endian.little), 0); // Vendor ID
    expect(ByteData.sublistView(d, 2, 4).getUint16(0, Endian.little), 0x000E); // Device Type
    expect(ByteData.sublistView(d, 4, 6).getUint16(0, Endian.little), 0x0001); // Product Code
    expect(d[6], 1); // Revision major
    expect(d[7], 1); // Revision minor
    expect(ByteData.sublistView(d, 8, 10).getUint16(0, Endian.little), 0x0000); // Status
    expect(ByteData.sublistView(d, 10, 14).getUint32(0, Endian.little), 1); // Serial
    expect(d[14], 'Soft PLC Simulator'.length); // SHORT_STRING length
    expect(String.fromCharCodes(d.sublist(15, 15 + 'Soft PLC Simulator'.length)), 'Soft PLC Simulator');
  });

  test('isIdentityObjectPath recognizes class 0x01', () {
    expect(isIdentityObjectPath([CipPathSegment.classId(kCipIdentityObjectClassId), CipPathSegment.instanceId(1)]), isTrue);
    expect(isIdentityObjectPath([CipPathSegment.classId(0x6B)]), isFalse);
  });

  test('Program Name Get Attributes All packs the controller name as a Logix STRING (u16 len + ascii)', () {
    final resp = buildProgramNameGetAttributesAllResponse(kCipServiceGetAttributesAll, 'PLC_E2E');
    expect(resp.generalStatus, kCipStatusSuccess);
    final d = resp.data;
    expect(ByteData.sublistView(d, 0, 2).getUint16(0, Endian.little), 'PLC_E2E'.length);
    expect(String.fromCharCodes(d.sublist(2, 2 + 'PLC_E2E'.length)), 'PLC_E2E');
    expect(d.length, 2 + 'PLC_E2E'.length); // the STRING is the WHOLE reply, nothing trailing.
  });

  test('isProgramNameObjectPath recognizes class 0x64', () {
    expect(isProgramNameObjectPath([CipPathSegment.classId(kCipProgramNameObjectClassId), CipPathSegment.instanceId(1)]), isTrue);
    expect(isProgramNameObjectPath([CipPathSegment.classId(kCipIdentityObjectClassId)]), isFalse);
  });
}
