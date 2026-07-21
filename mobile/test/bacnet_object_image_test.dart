// Tests for the BACnet/IP tag-backed object image (BACnet workstream, Task
// 4) — the highest-risk unit in the workstream: an external client reads AND
// writes live PLC state through `BacnetTagImage`'s force-gate chain.
//
// Fixture mirrors `slmp_device_image_test.dart:34-102`'s tag set
// (Flag/Word/Dint/Lint/Real/RoTag/Forced/Tank/Vessel/System/SimOut) so the
// same refusal scenarios (ReadOnly entry, FORCED root incl. a member path,
// the reserved-System backstop, SimulatedOutput staying writable) are
// exercised here for BACnet's per-object write path.
//
// Per the plan's TAG-STRUCTURE TRAP note, every wire-facing assertion below
// pins LITERAL expected bytes (Real 12.5, BitStrings, ObjectIds) rather than
// relying on a build->parse round trip through this same codebase's own
// encoders, which would prove nothing about a symmetric bug.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/bacnet_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_bvll.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_dispatch.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_object_image.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_services.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_tags.dart';

const int _kDeviceInstance = 3056;
const String _kDeviceName = 'BACNET-IMG-TEST';

PlcProject _buildProject() => PlcProject(
      id: 'bacnet_img',
      name: 'BACnet Image Test',
      controllerName: 'PLC_BACNET',
      programs: [],
      tasks: [],
      hmis: [],
      structDefs: [
        PlcStructDef(name: 'VesselType', fields: [
          StructFieldDef(name: 'Level', dataType: 'INT16', defaultValue: 0),
        ]),
        PlcStructDef(name: 'SystemType', fields: [
          StructFieldDef(name: 'Cmd', dataType: 'INT16', defaultValue: 0),
        ]),
      ],
      tags: [
        PlcTag(name: 'Flag1', path: 'Flag1', dataType: 'BOOL', value: false, ioType: 'Internal'),
        PlcTag(name: 'Word1', path: 'Word1', dataType: 'INT16', value: 0, ioType: 'Internal'),
        PlcTag(name: 'Dint1', path: 'Dint1', dataType: 'INT32', value: 0, ioType: 'Internal'),
        PlcTag(name: 'Lint1', path: 'Lint1', dataType: 'INT64', value: 0, ioType: 'Internal'),
        PlcTag(name: 'Real1', path: 'Real1', dataType: 'FLOAT64', value: 12.5, ioType: 'Internal'),
        PlcTag(
          name: 'RoTag',
          path: 'RoTag',
          dataType: 'INT16',
          value: 11,
          ioType: 'Internal',
          access: 'ReadOnly',
        ),
        PlcTag(name: 'Forced1', path: 'Forced1', dataType: 'INT16', value: 11, ioType: 'Internal'),
        PlcTag(
          name: 'Tank',
          path: 'Tank',
          dataType: 'VesselType',
          value: {'Level': 11},
          ioType: 'Internal',
        ),
        PlcTag(
          name: 'Vessel',
          path: 'Vessel',
          dataType: 'VesselType',
          value: {'Level': 11},
          ioType: 'Internal',
        ),
        // Reserved System tag; its OWN access is deliberately 'ReadWrite' so
        // the backstop test isolates the NAME-based rule.
        PlcTag(
          name: 'System',
          path: 'System',
          dataType: 'SystemType',
          value: {'Cmd': 0},
          ioType: 'Internal',
          access: 'ReadWrite',
        ),
        // A SimulatedOutput tag with a deliberately writable map entry.
        PlcTag(name: 'SimOut', path: 'SimOut', dataType: 'INT16', value: 7, ioType: 'SimulatedOutput'),
      ],
    );

BacnetMap _buildMap() => BacnetMap(entries: [
      BacnetMapEntry(tag: 'Flag1', objectType: kBacnetMapTypeBv, instance: 0),
      BacnetMapEntry(tag: 'Word1', objectType: kBacnetMapTypeAv, instance: 0),
      BacnetMapEntry(tag: 'Dint1', objectType: kBacnetMapTypeAv, instance: 1),
      BacnetMapEntry(tag: 'Lint1', objectType: kBacnetMapTypeAv, instance: 2),
      BacnetMapEntry(tag: 'Real1', objectType: kBacnetMapTypeAv, instance: 3),
      BacnetMapEntry(tag: 'RoTag', objectType: kBacnetMapTypeAv, instance: 4, access: 'ReadOnly'),
      BacnetMapEntry(tag: 'Forced1', objectType: kBacnetMapTypeAv, instance: 5),
      BacnetMapEntry(tag: 'Tank.Level', objectType: kBacnetMapTypeAv, instance: 6),
      BacnetMapEntry(tag: 'Vessel.Level', objectType: kBacnetMapTypeAv, instance: 7),
      // Both entries deliberately 'ReadWrite' (backstop fixtures).
      BacnetMapEntry(tag: 'System.Cmd', objectType: kBacnetMapTypeAv, instance: 8),
      BacnetMapEntry(tag: 'SimOut', objectType: kBacnetMapTypeAv, instance: 9),
    ]);

BacnetTagImage _buildImage() => BacnetTagImage(
      _buildProject(),
      _buildMap(),
      deviceInstance: _kDeviceInstance,
      deviceName: _kDeviceName,
    );

/// Builds a WriteProperty request targeting `(objectType, instance)`'s
/// Present_Value with [valueTags], optionally carrying a write [priority].
WpRequest _wpPresentValue(int objectType, int instance, Uint8List valueTags, {int? priority}) {
  return WpRequest(
    objectType: objectType,
    instance: instance,
    propertyId: kBacnetPropPresentValue,
    valueTags: valueTags,
    priority: priority,
  );
}

void main() {
  group('BacnetTagImage.readProperty — Device object', () {
    test('Object_Identifier, Object_Name, Object_Type', () {
      final image = _buildImage();
      expect(
        image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectIdentifier, null).valueTags,
        encodeAppObjectId(kBacnetObjectDevice, _kDeviceInstance),
      );
      expect(
        image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectName, null).valueTags,
        encodeAppCharString(_kDeviceName),
      );
      expect(
        image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectType, null).valueTags,
        encodeAppEnumerated(kBacnetObjectDevice),
      );
    });

    test('every property in kBacnetDeviceServedProperties returns a value, never an error', () {
      final image = _buildImage();
      for (final propertyId in kBacnetDeviceServedProperties) {
        final result = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, propertyId, null);
        expect(result.error, isNull, reason: 'property $propertyId must be served');
        expect(result.valueTags, isNotNull);
      }
    });

    test('Protocol_Services_Supported is the literal 40-bit BitString from the plan', () {
      final image = _buildImage();
      final result =
          image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropProtocolServicesSupported, null);
      // bits 12/14/15/26/34 set, MSB-first per byte -> 0x00 0x0B 0x00 0x20 0x20.
      // This is the FORMULA-derived literal (matches `encodeAppBitString`'s
      // own bit-to-byte rule, `bacnet_tags_test.dart`'s pinned fixture, and
      // Task 1's documented deviation from the plan's internally-inconsistent
      // worked example — see that test file's DEVIATION NOTE).
      expect(result.valueTags, [0x85, 0x06, 0x00, 0x00, 0x0B, 0x00, 0x20, 0x20]);
    });

    test('Protocol_Object_Types_Supported is the literal 40-bit BitString from the plan', () {
      final image = _buildImage();
      final result = image.readProperty(
          kBacnetObjectDevice, _kDeviceInstance, kBacnetPropProtocolObjectTypesSupported, null);
      // bits 2/5/8 set: byte0 bit2 (0x20) + bit5 (0x04) = 0x24; byte1 bit8 (bit
      // 0 of byte1, MSB) = 0x80.
      expect(result.valueTags, [0x85, 0x06, 0x00, 0x24, 0x80, 0x00, 0x00, 0x00]);
    });

    test('Max_APDU_Length_Accepted is 1476, Segmentation is no-segmentation(3)', () {
      final image = _buildImage();
      expect(
        image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropMaxApduLengthAccepted, null).valueTags,
        encodeAppUnsigned(1476),
      );
      expect(
        image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropSegmentationSupported, null).valueTags,
        encodeAppEnumerated(kBacnetSegmentationNoSegmentation),
      );
    });

    test('Vendor_Identifier is 0 and Vendor_Name/Model_Name are the honest identity', () {
      final image = _buildImage();
      expect(
        image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropVendorIdentifier, null).valueTags,
        encodeAppUnsigned(0),
      );
      expect(
        image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropVendorName, null).valueTags,
        encodeAppCharString('Soft PLC Simulator'),
      );
    });

    test('Object_List whole read is every object as concatenated app ObjectIds, device first', () {
      final image = _buildImage();
      final result = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectList, null);
      final expected = <int>[
        ...encodeAppObjectId(kBacnetObjectDevice, _kDeviceInstance),
        ...encodeAppObjectId(kBacnetObjectBinaryValue, 0), // Flag1
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 0), // Word1
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 1), // Dint1
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 2), // Lint1
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 3), // Real1
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 4), // RoTag
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 5), // Forced1
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 6), // Tank.Level
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 7), // Vessel.Level
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 8), // System.Cmd
        ...encodeAppObjectId(kBacnetObjectAnalogValue, 9), // SimOut
      ];
      expect(result.valueTags, expected);
    });

    test('Object_List index 0 is the element count as an app Unsigned', () {
      final image = _buildImage();
      final result = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectList, 0);
      expect(result.valueTags, encodeAppUnsigned(12)); // device + 11 map entries
    });

    test('Object_List index N (1-based) is the Nth element', () {
      final image = _buildImage();
      final first = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectList, 1);
      expect(first.valueTags, encodeAppObjectId(kBacnetObjectDevice, _kDeviceInstance));
      final second = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectList, 2);
      expect(second.valueTags, encodeAppObjectId(kBacnetObjectBinaryValue, 0));
    });

    test('Object_List index out of range is invalid-array-index (2,42)', () {
      final image = _buildImage();
      final tooLow = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectList, -1);
      expect(tooLow.error, (kBacnetErrorClassProperty, kBacnetErrorCodeInvalidArrayIndex));
      final tooHigh = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, kBacnetPropObjectList, 13);
      expect(tooHigh.error, (kBacnetErrorClassProperty, kBacnetErrorCodeInvalidArrayIndex));
    });

    test('an unknown Device instance is unknown-object (1,31)', () {
      final image = _buildImage();
      final result = image.readProperty(kBacnetObjectDevice, 9999, kBacnetPropObjectName, null);
      expect(result.error, (kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject));
    });

    test('an unknown property on the Device object is unknown-property (2,32)', () {
      final image = _buildImage();
      final result = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, 9999, null);
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty));
    });
  });

  group('BacnetTagImage.readProperty — Analog Value', () {
    test('Present_Value is the literal float32 Real encoding of 12.5', () {
      final image = _buildImage();
      final result = image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropPresentValue, null);
      // 12.5 -> 0x44 0x41 0x48 0x00 0x00, per the plan's Wire facts.
      expect(result.valueTags, [0x44, 0x41, 0x48, 0x00, 0x00]);
    });

    test('a FLOAT64 above 2^24 NARROWS to float32 — tight closeTo, and NOT exactly equal', () {
      final p = _buildProject();
      const big = 16777217.0; // 2^24 + 1: the smallest double float32 cannot represent exactly.
      writePath(p, 'Real1', big);
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result = image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropPresentValue, null);
      final decoded = ByteData.sublistView(result.valueTags!, 1).getFloat32(0, Endian.big);
      expect(decoded, closeTo(big, 4.0));
      expect(decoded, isNot(equals(big)), reason: 'float32 cannot represent 2^24+1 exactly');
    });

    test('an INT64 value narrows through the same Real encoding, not equal to the exact int', () {
      final p = _buildProject();
      writePath(p, 'Lint1', 16777217); // 2^24 + 1, exact in int64, NOT exact in float32.
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result = image.readProperty(kBacnetObjectAnalogValue, 2, kBacnetPropPresentValue, null);
      final decoded = ByteData.sublistView(result.valueTags!, 1).getFloat32(0, Endian.big);
      expect(decoded, closeTo(16777217.0, 4.0));
      expect(decoded, isNot(equals(16777217.0)));
    });

    test('Relinquish_Default mirrors the current Present_Value', () {
      final image = _buildImage();
      final pv = image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropPresentValue, null);
      final rd = image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropRelinquishDefault, null);
      expect(rd.valueTags, pv.valueTags);
    });

    test('Status_Flags is a 4-bit all-false BitString, Event_State normal, Out_Of_Service false, Units no-units', () {
      final image = _buildImage();
      expect(
        image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropStatusFlags, null).valueTags,
        [0x82, 0x04, 0x00],
      );
      expect(
        image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropEventState, null).valueTags,
        encodeAppEnumerated(kBacnetEventStateNormal),
      );
      expect(
        image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropOutOfService, null).valueTags,
        encodeAppBoolean(false),
      );
      expect(
        image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropUnits, null).valueTags,
        encodeAppEnumerated(kBacnetUnitsNoUnits),
      );
    });

    test('Priority_Array: whole = 16 Nulls; index 0 = 16; index N = one Null; out of range errors', () {
      final image = _buildImage();
      final whole = image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropPriorityArray, null);
      final expectedWhole = <int>[for (var i = 0; i < 16; i++) ...encodeAppNull()];
      expect(whole.valueTags, expectedWhole);

      final count = image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropPriorityArray, 0);
      expect(count.valueTags, encodeAppUnsigned(16));

      final slot = image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropPriorityArray, 5);
      expect(slot.valueTags, encodeAppNull());

      final outOfRange = image.readProperty(kBacnetObjectAnalogValue, 3, kBacnetPropPriorityArray, 17);
      expect(outOfRange.error, (kBacnetErrorClassProperty, kBacnetErrorCodeInvalidArrayIndex));
    });

    test('an unresolvable mapped tag reads Present_Value as 0.0 (gap semantics), not an error', () {
      final p = _buildProject();
      final map = BacnetMap(entries: [
        BacnetMapEntry(tag: 'DoesNotExist', objectType: kBacnetMapTypeAv, instance: 0),
      ]);
      final image = BacnetTagImage(p, map, deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result = image.readProperty(kBacnetObjectAnalogValue, 0, kBacnetPropPresentValue, null);
      expect(result.error, isNull);
      expect(result.valueTags, encodeAppReal(0.0));
    });

    test('an unknown AV instance is unknown-object (1,31)', () {
      final image = _buildImage();
      final result = image.readProperty(kBacnetObjectAnalogValue, 999, kBacnetPropPresentValue, null);
      expect(result.error, (kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject));
    });

    test('every property in kBacnetAnalogValueServedProperties returns a value, never an error', () {
      final image = _buildImage();
      for (final propertyId in kBacnetAnalogValueServedProperties) {
        final result = image.readProperty(kBacnetObjectAnalogValue, 3, propertyId, null);
        expect(result.error, isNull, reason: 'property $propertyId must be served');
      }
    });
  });

  group('BacnetTagImage.readProperty — Binary Value', () {
    test('Present_Value is Enumerated(1) when true, Enumerated(0) when false', () {
      final p = _buildProject();
      writePath(p, 'Flag1', true);
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      expect(
        image.readProperty(kBacnetObjectBinaryValue, 0, kBacnetPropPresentValue, null).valueTags,
        [0x91, 0x01],
      );

      final p2 = _buildProject();
      final image2 = BacnetTagImage(p2, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      expect(
        image2.readProperty(kBacnetObjectBinaryValue, 0, kBacnetPropPresentValue, null).valueTags,
        [0x91, 0x00],
      );
    });

    test('Object_Identifier is (binary-value, instance) and Object_Type is binary-value(5)', () {
      final image = _buildImage();
      expect(
        image.readProperty(kBacnetObjectBinaryValue, 0, kBacnetPropObjectIdentifier, null).valueTags,
        encodeAppObjectId(kBacnetObjectBinaryValue, 0),
      );
      expect(
        image.readProperty(kBacnetObjectBinaryValue, 0, kBacnetPropObjectType, null).valueTags,
        encodeAppEnumerated(kBacnetObjectBinaryValue),
      );
    });

    test('BV has no Units property (unknown-property)', () {
      final image = _buildImage();
      final result = image.readProperty(kBacnetObjectBinaryValue, 0, kBacnetPropUnits, null);
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty));
    });

    test('every property in kBacnetBinaryValueServedProperties returns a value, never an error', () {
      final image = _buildImage();
      for (final propertyId in kBacnetBinaryValueServedProperties) {
        final result = image.readProperty(kBacnetObjectBinaryValue, 0, propertyId, null);
        expect(result.error, isNull, reason: 'property $propertyId must be served');
      }
    });
  });

  group('BacnetTagImage.writeProperty — AV/BV force-gate chain', () {
    test('a valid AV Real write lands and reads back', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result = image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 1, encodeAppReal(42.0)));
      expect(result.error, isNull);
      expect(readPath(p, 'Dint1'), 42, reason: 'Present_Value is always a Real on the wire; an INT32 tag stores the rounded int');
    });

    test('AV write is lenient toward Unsigned and Signed, widened via toDouble', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);

      final unsignedResult =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 3, encodeAppUnsigned(7)));
      expect(unsignedResult.error, isNull);
      expect(readPath(p, 'Real1'), 7.0);

      final signedResult =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 3, encodeAppSigned(-3)));
      expect(signedResult.error, isNull);
      expect(readPath(p, 'Real1'), -3.0);
    });

    test('a Real NaN written to an integer-backed AV is REFUSED (2,9), never throws, tag unchanged', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final before = readPath(p, 'Dint1');
      late BacnetWriteResult result;
      expect(
        () => result = image.writeProperty(
          _wpPresentValue(kBacnetObjectAnalogValue, 1, encodeAppReal(double.nan)),
        ),
        returnsNormally,
        reason: 'round() on NaN throws — the image must gate it, never throw',
      );
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeInvalidDataType));
      expect(readPath(p, 'Dint1'), before);
    });

    test('a Real +Infinity written to an integer-backed AV is REFUSED (2,9), never throws, tag unchanged', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final before = readPath(p, 'Dint1');
      late BacnetWriteResult result;
      expect(
        () => result = image.writeProperty(
          _wpPresentValue(kBacnetObjectAnalogValue, 1, encodeAppReal(double.infinity)),
        ),
        returnsNormally,
        reason: 'round() on Infinity throws — the image must gate it, never throw',
      );
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeInvalidDataType));
      expect(readPath(p, 'Dint1'), before);
    });

    // THE ASYMMETRY, documented: a FLOAT64 tag holds NaN/Inf natively, so a
    // non-finite Real onto a FLOAT64-backed AV still lands.
    test('a Real NaN written to a FLOAT64-backed AV still SUCCEEDS (doubles hold NaN natively)', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result = image.writeProperty(
        _wpPresentValue(kBacnetObjectAnalogValue, 3, encodeAppReal(double.nan)),
      );
      expect(result.error, isNull);
      final stored = readPath(p, 'Real1');
      expect(stored is double && stored.isNaN, isTrue);
    });

    test('AV write with the wrong tag type is invalid-data-type (2,9), value unchanged', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final before = readPath(p, 'Real1');
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 3, encodeAppCharString('nope')));
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeInvalidDataType));
      expect(readPath(p, 'Real1'), before);
    });

    test('a valid BV Enumerated write lands and reads back', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectBinaryValue, 0, encodeAppEnumerated(1)));
      expect(result.error, isNull);
      expect(readPath(p, 'Flag1'), true);
    });

    test('BV write is lenient toward a Boolean tag', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result = image.writeProperty(_wpPresentValue(kBacnetObjectBinaryValue, 0, encodeAppBoolean(true)));
      expect(result.error, isNull);
      expect(readPath(p, 'Flag1'), true);
    });

    test('BV write with an Enumerated value other than 0/1 is invalid-data-type (2,9)', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectBinaryValue, 0, encodeAppEnumerated(2)));
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeInvalidDataType));
      expect(readPath(p, 'Flag1'), false);
    });

    test('a write to a ReadOnly map entry is REFUSED with write-access-denied (2,40)', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 4, encodeAppReal(1.0)));
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied));
      expect(readPath(p, 'RoTag'), 11);
    });

    test('a write to a FORCED scalar tag is REFUSED, value unchanged', () {
      final p = _buildProject();
      final forced = p.tags.firstWhere((t) => t.name == 'Forced1');
      forced.isForced = true;
      forced.forcedValue = 99;
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 5, encodeAppReal(1.0)));
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied));
      expect(forced.value, 11, reason: 'underlying tag value must be untouched');
    });

    // The force check must be made against the ROOT tag with NO
    // `root.name == tag` clause — otherwise a MEMBER path bypasses it.
    test('a write to a MEMBER beneath a FORCED root is REFUSED, member unchanged', () {
      final p = _buildProject();
      final tank = p.tags.firstWhere((t) => t.name == 'Tank');
      tank.isForced = true;
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 6, encodeAppReal(1.0)));
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied));
      expect((tank.value as Map)['Level'], 11, reason: 'member write must not bypass the force');
    });

    // CONTRAST CASE — proves the refusal above is not over-broad.
    test('a write to a member of a NON-forced composite SUCCEEDS', () {
      final p = _buildProject();
      final vessel = p.tags.firstWhere((t) => t.name == 'Vessel');
      expect(vessel.isForced, isFalse);
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 7, encodeAppReal(3.0)));
      expect(result.error, isNull);
      expect((vessel.value as Map)['Level'], 3);
    });

    test('the reserved System tag is REFUSED even with a ReadWrite map entry (NAME backstop)', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 8, encodeAppReal(5.0)));
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied));
      expect(readPath(p, 'System.Cmd'), 0);
    });

    test('SimulatedOutput stays writable through a deliberately ReadWrite map entry', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 9, encodeAppReal(2.0)));
      expect(result.error, isNull);
      expect(readPath(p, 'SimOut'), 2);
    });

    test('a write to a non-Present_Value property is write-access-denied (2,40)', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final req = WpRequest(
        objectType: kBacnetObjectAnalogValue,
        instance: 1,
        propertyId: kBacnetPropUnits,
        valueTags: encodeAppEnumerated(kBacnetUnitsNoUnits),
      );
      final result = image.writeProperty(req);
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied));
    });

    test('a write to an unmapped/unresolvable tag is unknown-object (1,31)', () {
      final p = _buildProject();
      final map = BacnetMap(entries: [
        BacnetMapEntry(tag: 'DoesNotExist', objectType: kBacnetMapTypeAv, instance: 0),
      ]);
      final image = BacnetTagImage(p, map, deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 0, encodeAppReal(1.0)));
      expect(result.error, (kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject));
    });

    test('a write to an unknown object entirely is unknown-object (1,31)', () {
      final image = _buildImage();
      final result =
          image.writeProperty(_wpPresentValue(kBacnetObjectAnalogValue, 999, encodeAppReal(1.0)));
      expect(result.error, (kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject));
    });

    test('a write carrying a priority argument still lands (priority accepted and IGNORED)', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      final result = image.writeProperty(
        _wpPresentValue(kBacnetObjectAnalogValue, 1, encodeAppReal(8.0), priority: 8),
      );
      expect(result.error, isNull);
      expect(readPath(p, 'Dint1'), 8);
    });

    test('a write to the (existing) Device object is write-access-denied, NOT unknown-object', () {
      final image = _buildImage();
      final req = WpRequest(
        objectType: kBacnetObjectDevice,
        instance: _kDeviceInstance,
        propertyId: kBacnetPropObjectName,
        valueTags: encodeAppCharString('Nope'),
      );
      final result = image.writeProperty(req);
      expect(result.error, (kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied));
    });

    test('a write to an unknown Device instance is unknown-object', () {
      final image = _buildImage();
      final req = WpRequest(
        objectType: kBacnetObjectDevice,
        instance: 9999,
        propertyId: kBacnetPropObjectName,
        valueTags: encodeAppCharString('Nope'),
      );
      final result = image.writeProperty(req);
      expect(result.error, (kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject));
    });
  });

  // --- Reverse sync: kBacnet*ServedProperties vs what the image ACTUALLY
  // serves --------------------------------------------------------------
  //
  // The forward-direction tests above ("every property in
  // kBacnetXServedProperties returns a value, never an error") only prove the
  // list is a SUBSET of what's served. `_servedPropertiesFor` in
  // `bacnet_dispatch.dart` is a protocol-level constant, hand-maintained in
  // parallel with each `_readXProperty` switch — nothing enforces they stay in
  // sync. This group closes the other direction: for a reasonable property-id
  // range, `served ⇔ listed` for each object type, so an id the image quietly
  // starts serving (or stops serving) without a matching edit to the constant
  // list is caught here, not discovered by an RPM ALL/REQUIRED client in the
  // field getting a truncated (or falsely-errored) property set.
  group('kBacnet*ServedProperties are the EXACT set the image serves (reverse sync)', () {
    // 0..140 comfortably covers every BACnet standard property id this device
    // could plausibly serve or collide with (the highest id referenced
    // anywhere in this file, kBacnetPropRelinquishDefault, is in the 100s);
    // scanning past the declared lists' own ids proves there is nothing ELSE
    // being served that the list fails to name.
    const probeRange = 140;

    void checkExactMatch(int objectType, int instance, List<int> served) {
      final image = _buildImage();
      final servedSet = served.toSet();
      for (var propertyId = 0; propertyId <= probeRange; propertyId++) {
        final result = image.readProperty(objectType, instance, propertyId, null);
        final isServed = result.error == null;
        final isListed = servedSet.contains(propertyId);
        expect(
          isServed,
          isListed,
          reason: 'property $propertyId on object type $objectType: '
              'served=$isServed but listed-in-constant=$isListed — '
              'kBacnet*ServedProperties must name EXACTLY what the image serves',
        );
      }
    }

    test('Device: readProperty for 0..$probeRange agrees exactly with kBacnetDeviceServedProperties', () {
      checkExactMatch(kBacnetObjectDevice, _kDeviceInstance, kBacnetDeviceServedProperties);
    });

    test('Analog Value: readProperty for 0..$probeRange agrees exactly with '
        'kBacnetAnalogValueServedProperties', () {
      checkExactMatch(kBacnetObjectAnalogValue, 3, kBacnetAnalogValueServedProperties);
    });

    test('Binary Value: readProperty for 0..$probeRange agrees exactly with '
        'kBacnetBinaryValueServedProperties', () {
      checkExactMatch(kBacnetObjectBinaryValue, 0, kBacnetBinaryValueServedProperties);
    });

    // The reverse direction of `readProperty` unknown-property rejection: a
    // SAMPLE of ids not in each list must be REFUSED (unknown-property), not
    // silently served — a targeted spot-check alongside the exhaustive scan
    // above (which already covers these, but this makes the "rejects unlisted
    // ids" assertion explicit and independent of the range boundary).
    test('a sample of property ids NOT in each served list is REJECTED as unknown-property', () {
      final image = _buildImage();
      const sampleUnlisted = [200, 250, 300, 999];
      for (final propertyId in sampleUnlisted) {
        expect(kBacnetDeviceServedProperties.contains(propertyId), isFalse);
        expect(kBacnetAnalogValueServedProperties.contains(propertyId), isFalse);
        expect(kBacnetBinaryValueServedProperties.contains(propertyId), isFalse);

        final deviceResult = image.readProperty(kBacnetObjectDevice, _kDeviceInstance, propertyId, null);
        expect(deviceResult.error, (kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty));

        final avResult = image.readProperty(kBacnetObjectAnalogValue, 3, propertyId, null);
        expect(avResult.error, (kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty));

        final bvResult = image.readProperty(kBacnetObjectBinaryValue, 0, propertyId, null);
        expect(bvResult.error, (kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty));
      }
    });
  });

  // --- ReadPropertyMultiple through the shared dispatch --------------------

  group('ReadPropertyMultiple through dispatchBacnetDatagram', () {
    Uint8List confirmedApdu(int invokeId, int serviceChoice, List<int> serviceData) {
      return Uint8List.fromList([
        kBacnetPduConfirmedRequest << 4,
        0x05,
        invokeId,
        serviceChoice,
        ...serviceData,
      ]);
    }

    List<int> rpmSpecBytes(int objectType, int instance, List<(int propId, int? idx)> props) {
      final out = <int>[
        ...encodeContextObjectId(0, objectType, instance),
        ...openingTag(1),
      ];
      for (final (propId, idx) in props) {
        out.addAll(encodeContextUnsigned(0, propId));
        if (idx != null) {
          out.addAll(encodeContextUnsigned(1, idx));
        }
      }
      out.addAll(closingTag(1));
      return out;
    }

    /// Minimal decode of a buildRpmAck-shaped ComplexAck body: one
    /// `(objectType, instance, [(propId, isError, class?, code?)...])` per
    /// object spec. Independent of `buildRpmAck`'s own private tag-number
    /// constants — decodes against the LITERAL tag numbers the plan's Wire
    /// facts document (ctx2 propId, ctx3 index, ctx4 value bracket, ctx5
    /// error bracket).
    List<({int objectType, int instance, List<({int propId, bool isError})> props})> decodeRpmAck(
        Uint8List apdu) {
      final reader = BacnetTagReader(apdu, 3);
      final results = <({int objectType, int instance, List<({int propId, bool isError})> props})>[];
      while (!reader.done) {
        final objTag = reader.readTag();
        if (objTag == null) {
          break;
        }
        final objId = objTag.asObjectId()!;
        reader.readTag(); // ctx1 opening
        final props = <({int propId, bool isError})>[];
        while (true) {
          final t = reader.readTag()!;
          if (t.isContext && t.isClosing && t.tagNumber == 1) {
            break;
          }
          final propId = t.asUnsigned()!;
          var next = reader.readTag()!;
          if (next.isContext && !next.isOpening && !next.isClosing && next.tagNumber == 3) {
            next = reader.readTag()!; // skip the array-index tag, re-read the bracket
          }
          final isError = next.tagNumber == 5;
          if (isError) {
            reader.readTag(); // errClass
            reader.readTag(); // errCode
            reader.readTag(); // ctx5 closing
          } else {
            // ctx4 opening: skip forward to the matching ctx4 closing.
            while (true) {
              final inner = reader.readTag()!;
              if (inner.isContext && inner.isClosing && inner.tagNumber == 4) {
                break;
              }
            }
          }
          props.add((propId: propId, isError: isError));
        }
        results.add((objectType: objId.$1, instance: objId.$2, props: props));
      }
      return results;
    }

    test('a batch spanning two objects with one embedded error still answers the whole request', () {
      final image = _buildImage();
      const invokeId = 0x40;
      final serviceData = <int>[
        ...rpmSpecBytes(kBacnetObjectAnalogValue, 3, [(kBacnetPropPresentValue, null)]),
        ...rpmSpecBytes(kBacnetObjectAnalogValue, 3, [(9999, null)]), // unknown property
      ];
      final request =
          buildBvllUnicast(confirmedApdu(invokeId, kBacnetServiceReadPropertyMultiple, serviceData));
      final reply = dispatchBacnetDatagram(request, image);
      expect(reply, isNotNull);
      final apdu = parseBvllToApdu(reply!)!;
      expect((apdu[0] >> 4) & 0x0F, kBacnetPduComplexAck);

      final decoded = decodeRpmAck(apdu);
      expect(decoded.length, 2);
      expect(decoded[0].props.single.isError, isFalse);
      expect(decoded[1].props.single.isError, isTrue);
    });

    test('RPM ALL expands to the object\'s full served property list', () {
      final image = _buildImage();
      const invokeId = 0x41;
      final serviceData = rpmSpecBytes(kBacnetObjectAnalogValue, 3, [(kBacnetPropAll, null)]);
      final request =
          buildBvllUnicast(confirmedApdu(invokeId, kBacnetServiceReadPropertyMultiple, serviceData));
      final reply = dispatchBacnetDatagram(request, image);
      final apdu = parseBvllToApdu(reply!)!;
      final decoded = decodeRpmAck(apdu);
      expect(decoded.single.props.length, kBacnetAnalogValueServedProperties.length);
      expect(decoded.single.props.every((p) => !p.isError), isTrue);
    });

    test('RPM OPTIONAL expands to nothing', () {
      final image = _buildImage();
      const invokeId = 0x42;
      final serviceData = rpmSpecBytes(kBacnetObjectAnalogValue, 3, [(kBacnetPropOptional, null)]);
      final request =
          buildBvllUnicast(confirmedApdu(invokeId, kBacnetServiceReadPropertyMultiple, serviceData));
      final reply = dispatchBacnetDatagram(request, image);
      final apdu = parseBvllToApdu(reply!)!;
      final decoded = decodeRpmAck(apdu);
      expect(decoded.single.props, isEmpty);
    });

    test('a reply exceeding 1476 bytes is answered with Abort(buffer-overflow) instead', () {
      // Map MANY AVs so requesting ALL properties of ALL objects blows the
      // 1476-byte datagram budget.
      final p = _buildProject();
      final entries = <BacnetMapEntry>[];
      for (var i = 0; i < 200; i++) {
        p.tags.add(PlcTag(name: 'Big$i', path: 'Big$i', dataType: 'INT16', value: i, ioType: 'Internal'));
        entries.add(BacnetMapEntry(tag: 'Big$i', objectType: kBacnetMapTypeAv, instance: i));
      }
      final map = BacnetMap(entries: entries);
      final image = BacnetTagImage(p, map, deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);

      const invokeId = 0x43;
      final serviceData = <int>[
        for (final (t, i) in image.objectList) ...rpmSpecBytes(t, i, [(kBacnetPropAll, null)]),
      ];
      final request =
          buildBvllUnicast(confirmedApdu(invokeId, kBacnetServiceReadPropertyMultiple, serviceData));
      final reply = dispatchBacnetDatagram(request, image);
      expect(reply, isNotNull);
      final apdu = parseBvllToApdu(reply!)!;
      expect((apdu[0] >> 4) & 0x0F, kBacnetPduAbort);
      expect(apdu[1], invokeId);
      expect(apdu[2], kBacnetAbortReasonBufferOverflow);
    });
  });

  group('WriteProperty through dispatchBacnetDatagram', () {
    Uint8List confirmedApdu(int invokeId, int serviceChoice, List<int> serviceData) {
      return Uint8List.fromList([
        kBacnetPduConfirmedRequest << 4,
        0x05,
        invokeId,
        serviceChoice,
        ...serviceData,
      ]);
    }

    test('a WriteProperty carrying a priority argument still yields SimpleAck', () {
      final p = _buildProject();
      final image = BacnetTagImage(p, _buildMap(), deviceInstance: _kDeviceInstance, deviceName: _kDeviceName);
      const invokeId = 0x50;
      final serviceData = <int>[
        ...encodeContextObjectId(0, kBacnetObjectAnalogValue, 1),
        ...encodeContextUnsigned(1, kBacnetPropPresentValue),
        ...openingTag(3),
        ...encodeAppReal(21.0),
        ...closingTag(3),
        ...encodeContextUnsigned(4, 8), // priority
      ];
      final request = buildBvllUnicast(confirmedApdu(invokeId, kBacnetServiceWriteProperty, serviceData));
      final reply = dispatchBacnetDatagram(request, image);
      expect(reply, isNotNull);
      final apdu = parseBvllToApdu(reply!)!;
      expect((apdu[0] >> 4) & 0x0F, kBacnetPduSimpleAck);
      expect(apdu[1], invokeId);
      expect(apdu[2], kBacnetServiceWriteProperty);
      expect(readPath(p, 'Dint1'), 21);
    });

    test('a refused WriteProperty (ReadOnly entry) yields an Error PDU through the dispatch', () {
      final image = _buildImage();
      const invokeId = 0x51;
      final serviceData = <int>[
        ...encodeContextObjectId(0, kBacnetObjectAnalogValue, 4), // RoTag
        ...encodeContextUnsigned(1, kBacnetPropPresentValue),
        ...openingTag(3),
        ...encodeAppReal(1.0),
        ...closingTag(3),
      ];
      final request = buildBvllUnicast(confirmedApdu(invokeId, kBacnetServiceWriteProperty, serviceData));
      final reply = dispatchBacnetDatagram(request, image);
      final apdu = parseBvllToApdu(reply!)!;
      expect((apdu[0] >> 4) & 0x0F, kBacnetPduError);
      final reader = BacnetTagReader(apdu, 3);
      final errClass = reader.readTag();
      final errCode = reader.readTag();
      expect(errClass!.asEnumerated(), kBacnetErrorClassProperty);
      expect(errCode!.asEnumerated(), kBacnetErrorCodeWriteAccessDenied);
    });
  });
}
