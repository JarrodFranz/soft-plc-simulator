// BACnet/IP tag-backed object image — pure Dart, no dart:io / Flutter
// imports. This is where BACnet meets the app's tag database, and (per the
// plan) the highest-risk unit in the whole workstream: an external client
// reads AND writes live PLC state through this file's force-gate chain.
//
// `BacnetTagImage` implements the `BacnetObjectImage` seam
// (`bacnet_dispatch.dart`, Task 3) by serving:
//  - the Device object itself (identity/capability properties, plus
//    Object_List — both the whole array and by index, index 0 = count);
//  - one Analog Value (AV) object per `BacnetMap` entry mapped to a numeric
//    leaf (INT16/INT32/INT64/FLOAT64), Present_Value = an app-tagged Real
//    (IEEE-754 single precision) — a NARROWING conversion, exactly like
//    SLMP's REAL and S7's FLOAT32-over-FLOAT64 story;
//  - one Binary Value (BV) object per `BacnetMap` entry mapped to a BOOL
//    leaf, Present_Value = an app-tagged Enumerated (0/1).
//
// *** THE WRITE-GATE CHAIN (mirrors `slmp_device_image.dart` exactly) ***
// A WriteProperty is refused, in order, if: the target object/property isn't
// Present_Value on a known AV/BV object (unknown object -> error(1,31);
// anything else -> error(2,40) write-access-denied); the underlying mapped
// tag doesn't resolve at all (error(1,31) — "gap" semantics: reads of an
// unresolvable tag serve 0.0/inactive instead of erroring, but a WRITE to a
// tag that isn't really there is reported as an unknown object, since there
// is nothing real behind the map entry to write); the map entry's own
// `access` is `'ReadOnly'` (error(2,40)); the write-time hard backstop
// `isExternallyWritable` refuses it (reserved `System`, or the tag's own
// `access` is `ReadOnly` — independent of what a mutable map entry claims)
// (error(2,40)); the tag's ROOT is FORCED (error(2,40) — forcing is
// authoritative, an external write must never change the value behind a
// force). Only after all four gates pass is the incoming value decoded
// (AV: Real, leniently Unsigned/Signed -> `toDouble`; BV: Enumerated 0/1,
// leniently Boolean) — a value of the wrong tag type is error(2,9)
// invalid-data-type. The write PRIORITY argument is accepted (per
// `WpRequest.priority`) and deliberately IGNORED, per the approved spec.
//
// Safety contract: neither `readProperty` nor `writeProperty` ever throws —
// every failure mode is reported as a `BacnetReadResult`/`BacnetWriteResult`
// error, since `dispatchBacnetDatagram` feeds this image requests parsed
// straight off the wire.
library bacnet_object_image;

import 'dart:typed_data';

import '../../models/bacnet_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import '../../models/tag_write_gate.dart';
import 'bacnet_dispatch.dart';
import 'bacnet_services.dart';
import 'bacnet_tags.dart';

/// Honest vendor identity this device advertises (see [buildIAm] /
/// `kBacnetIAmVendorIdentifier`) — no competitor-tooling impersonation.
const String kBacnetVendorName = 'Soft PLC Simulator';

/// Model_Name this device advertises — same honest-identity rationale.
const String kBacnetModelName = 'Soft PLC Simulator';

/// Firmware_Revision / Application_Software_Version this device advertises.
const String kBacnetFirmwareRevision = '1.1';

/// Number of BACnet BitString bits in Protocol_Services_Supported /
/// Protocol_Object_Types_Supported (see the plan's Wire facts).
const int _kSupportedBitStringLength = 40;

/// Protocol_Services_Supported bits this device sets: readProperty(12),
/// readPropertyMultiple(14), writeProperty(15), i-Am(26), who-Is(34).
const Set<int> _kServicesSupportedBits = {12, 14, 15, 26, 34};

/// Protocol_Object_Types_Supported bits this device sets: analog-value(2),
/// binary-value(5), device(8).
const Set<int> _kObjectTypesSupportedBits = {2, 5, 8};

/// Number of write-priority slots in a served Priority_Array (BACnet fixes
/// this at 16 regardless of whether the object is truly commandable).
const int _kPriorityArrayLength = 16;

/// A tag-backed [BacnetObjectImage]: the Device object plus one Analog Value
/// or Binary Value object per [BacnetMap] entry, all read from — and, for
/// Present_Value, written back onto — the live [PlcProject] tag tree via
/// `tag_resolver.dart`, gated by the shared write-gate
/// (`tag_write_gate.dart`) exactly as every other protocol's tag-backed image
/// is. See the file header for the full write-gate chain.
class BacnetTagImage implements BacnetObjectImage {
  final PlcProject project;
  final BacnetMap map;
  @override
  final int deviceInstance;
  final String deviceName;

  /// `(numeric objectType, instance) -> map entry`, built once at
  /// construction (the map is treated as fixed for this image's lifetime,
  /// exactly like every other protocol's tag-backed image) so lookups by
  /// object identity are O(1) instead of an O(n) scan per call.
  late final Map<(int, int), BacnetMapEntry> _byObject;

  BacnetTagImage(
    this.project,
    this.map, {
    required this.deviceInstance,
    required this.deviceName,
  }) {
    _byObject = {
      for (final e in map.entries) (_objectTypeNumber(e.objectType), e.instance): e,
    };
  }

  static int _objectTypeNumber(String objectType) =>
      objectType == kBacnetMapTypeBv ? kBacnetObjectBinaryValue : kBacnetObjectAnalogValue;

  @override
  List<(int type, int instance)> get objectList => [
        (kBacnetObjectDevice, deviceInstance),
        for (final e in map.entries) (_objectTypeNumber(e.objectType), e.instance),
      ];

  // --- ReadProperty -----------------------------------------------------

  @override
  BacnetReadResult readProperty(
    int objectType,
    int instance,
    int propertyId,
    int? arrayIndex,
  ) {
    if (objectType == kBacnetObjectDevice && instance == deviceInstance) {
      return _readDeviceProperty(propertyId, arrayIndex);
    }
    final entry = _byObject[(objectType, instance)];
    if (entry == null) {
      return BacnetReadResult.error(kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject);
    }
    if (objectType == kBacnetObjectAnalogValue) {
      return _readAvProperty(entry, propertyId, arrayIndex);
    }
    if (objectType == kBacnetObjectBinaryValue) {
      return _readBvProperty(entry, propertyId, arrayIndex);
    }
    return BacnetReadResult.error(kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject);
  }

  BacnetReadResult _readDeviceProperty(int propertyId, int? arrayIndex) {
    switch (propertyId) {
      case kBacnetPropObjectIdentifier:
        return BacnetReadResult.ok(encodeAppObjectId(kBacnetObjectDevice, deviceInstance));
      case kBacnetPropObjectName:
        return BacnetReadResult.ok(encodeAppCharString(deviceName));
      case kBacnetPropObjectType:
        return BacnetReadResult.ok(encodeAppEnumerated(kBacnetObjectDevice));
      case kBacnetPropSystemStatus:
        return BacnetReadResult.ok(encodeAppEnumerated(kBacnetSystemStatusOperational));
      case kBacnetPropVendorName:
        return BacnetReadResult.ok(encodeAppCharString(kBacnetVendorName));
      case kBacnetPropVendorIdentifier:
        return BacnetReadResult.ok(encodeAppUnsigned(kBacnetIAmVendorIdentifier));
      case kBacnetPropModelName:
        return BacnetReadResult.ok(encodeAppCharString(kBacnetModelName));
      case kBacnetPropFirmwareRevision:
        return BacnetReadResult.ok(encodeAppCharString(kBacnetFirmwareRevision));
      case kBacnetPropApplicationSoftwareVersion:
        return BacnetReadResult.ok(encodeAppCharString(kBacnetFirmwareRevision));
      case kBacnetPropProtocolVersion:
        return BacnetReadResult.ok(encodeAppUnsigned(1));
      case kBacnetPropProtocolRevision:
        return BacnetReadResult.ok(encodeAppUnsigned(14));
      case kBacnetPropProtocolServicesSupported:
        return BacnetReadResult.ok(
          encodeAppBitString(_kSupportedBitStringLength, _kServicesSupportedBits),
        );
      case kBacnetPropProtocolObjectTypesSupported:
        return BacnetReadResult.ok(
          encodeAppBitString(_kSupportedBitStringLength, _kObjectTypesSupportedBits),
        );
      case kBacnetPropMaxApduLengthAccepted:
        return BacnetReadResult.ok(encodeAppUnsigned(kBacnetIAmMaxApduLength));
      case kBacnetPropSegmentationSupported:
        return BacnetReadResult.ok(encodeAppEnumerated(kBacnetSegmentationNoSegmentation));
      case kBacnetPropObjectList:
        return _readObjectList(arrayIndex);
      default:
        return BacnetReadResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty);
    }
  }

  /// Object_List: the whole array (no [arrayIndex]) is every element of
  /// [objectList] concatenated as app-tagged ObjectIdentifiers; index 0 is
  /// the element COUNT (app Unsigned); index N (1-based) is the Nth element;
  /// any other index is invalid-array-index.
  BacnetReadResult _readObjectList(int? arrayIndex) {
    final list = objectList;
    if (arrayIndex == null) {
      final out = <int>[];
      for (final (t, i) in list) {
        out.addAll(encodeAppObjectId(t, i));
      }
      return BacnetReadResult.ok(Uint8List.fromList(out));
    }
    if (arrayIndex == 0) {
      return BacnetReadResult.ok(encodeAppUnsigned(list.length));
    }
    if (arrayIndex < 1 || arrayIndex > list.length) {
      return BacnetReadResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeInvalidArrayIndex);
    }
    final (t, i) = list[arrayIndex - 1];
    return BacnetReadResult.ok(encodeAppObjectId(t, i));
  }

  /// Priority_Array (AV/BV): the whole array (no [arrayIndex]) is 16
  /// app-Nulls; index 0 is the slot COUNT (app Unsigned 16); index N
  /// (1-16) is one app-Null (this device never actually commands a
  /// priority slot, so every slot always reads as relinquished/Null); any
  /// other index is invalid-array-index.
  BacnetReadResult _readPriorityArray(int? arrayIndex) {
    if (arrayIndex == null) {
      final out = <int>[];
      for (var i = 0; i < _kPriorityArrayLength; i++) {
        out.addAll(encodeAppNull());
      }
      return BacnetReadResult.ok(Uint8List.fromList(out));
    }
    if (arrayIndex == 0) {
      return BacnetReadResult.ok(encodeAppUnsigned(_kPriorityArrayLength));
    }
    if (arrayIndex < 1 || arrayIndex > _kPriorityArrayLength) {
      return BacnetReadResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeInvalidArrayIndex);
    }
    return BacnetReadResult.ok(encodeAppNull());
  }

  BacnetReadResult _readAvProperty(BacnetMapEntry entry, int propertyId, int? arrayIndex) {
    switch (propertyId) {
      case kBacnetPropObjectIdentifier:
        return BacnetReadResult.ok(encodeAppObjectId(kBacnetObjectAnalogValue, entry.instance));
      case kBacnetPropObjectName:
        return BacnetReadResult.ok(encodeAppCharString(entry.tag));
      case kBacnetPropObjectType:
        return BacnetReadResult.ok(encodeAppEnumerated(kBacnetObjectAnalogValue));
      case kBacnetPropPresentValue:
      case kBacnetPropRelinquishDefault:
        return BacnetReadResult.ok(encodeAppReal(_avValue(entry)));
      case kBacnetPropStatusFlags:
        return BacnetReadResult.ok(encodeAppBitString(4, const {}));
      case kBacnetPropEventState:
        return BacnetReadResult.ok(encodeAppEnumerated(kBacnetEventStateNormal));
      case kBacnetPropOutOfService:
        return BacnetReadResult.ok(encodeAppBoolean(false));
      case kBacnetPropUnits:
        return BacnetReadResult.ok(encodeAppEnumerated(kBacnetUnitsNoUnits));
      case kBacnetPropPriorityArray:
        return _readPriorityArray(arrayIndex);
      default:
        return BacnetReadResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty);
    }
  }

  BacnetReadResult _readBvProperty(BacnetMapEntry entry, int propertyId, int? arrayIndex) {
    switch (propertyId) {
      case kBacnetPropObjectIdentifier:
        return BacnetReadResult.ok(encodeAppObjectId(kBacnetObjectBinaryValue, entry.instance));
      case kBacnetPropObjectName:
        return BacnetReadResult.ok(encodeAppCharString(entry.tag));
      case kBacnetPropObjectType:
        return BacnetReadResult.ok(encodeAppEnumerated(kBacnetObjectBinaryValue));
      case kBacnetPropPresentValue:
      case kBacnetPropRelinquishDefault:
        return BacnetReadResult.ok(encodeAppEnumerated(_bvValue(entry) ? 1 : 0));
      case kBacnetPropStatusFlags:
        return BacnetReadResult.ok(encodeAppBitString(4, const {}));
      case kBacnetPropEventState:
        return BacnetReadResult.ok(encodeAppEnumerated(kBacnetEventStateNormal));
      case kBacnetPropOutOfService:
        return BacnetReadResult.ok(encodeAppBoolean(false));
      case kBacnetPropPriorityArray:
        return _readPriorityArray(arrayIndex);
      default:
        return BacnetReadResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty);
    }
  }

  /// The AV's current value as a double for Present_Value/Relinquish_Default
  /// encoding, or `0.0` if the mapped tag doesn't resolve or isn't numeric —
  /// GAP semantics, exactly like every other protocol's tag-backed image
  /// (an unmapped/unresolvable read serves a default rather than erroring).
  double _avValue(BacnetMapEntry entry) {
    final v = readPath(project, entry.tag);
    return v is num ? v.toDouble() : 0.0;
  }

  /// The BV's current value, or `false` (inactive) if the mapped tag doesn't
  /// resolve or isn't a bool — same gap semantics as [_avValue].
  bool _bvValue(BacnetMapEntry entry) => readPath(project, entry.tag) == true;

  // --- WriteProperty ------------------------------------------------------

  @override
  BacnetWriteResult writeProperty(WpRequest req) {
    if (req.objectType == kBacnetObjectDevice && req.instance == deviceInstance) {
      // The Device object EXISTS (it's fully readable) but has no writable
      // property in v1 — this must be write-access-denied, not
      // unknown-object (that would incorrectly tell the client the object
      // itself doesn't exist).
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied);
    }
    final entry = _byObject[(req.objectType, req.instance)];
    if (entry == null) {
      return BacnetWriteResult.error(kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject);
    }
    if (req.propertyId != kBacnetPropPresentValue) {
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied);
    }

    // Unresolvable mapped tag: nothing real behind this map entry to write.
    final dataType = dataTypeOfPath(project, entry.tag);
    if (dataType == null) {
      return BacnetWriteResult.error(kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject);
    }

    if (entry.access == 'ReadOnly') {
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied);
    }

    // Write-time hard backstop: the BacnetMap entry above is a MUTABLE map a
    // hand-edit could re-target at the reserved System tag.
    // `isExternallyWritable` re-checks the underlying ROOT tag itself,
    // independent of whatever this entry claims.
    if (!isExternallyWritable(project, entry.tag)) {
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied);
    }

    // Force-aware write: a forced ROOT tag refuses writes to EVERY path
    // beneath it. `rootTagOf` walks to the leaf path's FIRST segment, so for
    // `Tank.Level` it returns `Tank`. There is deliberately NO
    // `root.name == entry.tag` clause: that comparison is false for any
    // member path, which would SKIP this check and let the write land
    // silently.
    final root = rootTagOf(project, entry.tag);
    if (root != null && root.isForced) {
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeWriteAccessDenied);
    }

    if (req.objectType == kBacnetObjectAnalogValue) {
      return _writeAv(entry, dataType, req.valueTags);
    }
    if (req.objectType == kBacnetObjectBinaryValue) {
      return _writeBv(entry, req.valueTags);
    }
    return BacnetWriteResult.error(kBacnetErrorClassObject, kBacnetErrorCodeUnknownObject);

    // NOTE: `req.priority` is deliberately never consulted anywhere above —
    // accepted-but-ignored, per the approved spec.
  }

  /// AV write: accepts an app-tagged Real (the type Present_Value is always
  /// encoded as), leniently also Unsigned/Signed (widened to `double` via
  /// `toDouble`) — any other tag type is invalid-data-type. The decoded
  /// double is stored back in the underlying tag's OWN native
  /// representation: unchanged for a `FLOAT64` tag, rounded to the nearest
  /// integer for an INT16/INT32/INT64 tag (Present_Value is always carried
  /// as a Real on the wire regardless of the underlying tag's integer type,
  /// so a write must convert back rather than leave an int-typed tag holding
  /// a raw double).
  BacnetWriteResult _writeAv(BacnetMapEntry entry, String dataType, Uint8List valueTags) {
    final tag = BacnetTagReader(valueTags).readTag();
    if (tag == null || tag.isContext) {
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeInvalidDataType);
    }
    double? value;
    if (tag.tagNumber == kBacnetTagReal) {
      value = tag.asReal();
    } else if (tag.tagNumber == kBacnetTagUnsigned) {
      value = tag.asUnsigned()?.toDouble();
    } else if (tag.tagNumber == kBacnetTagSigned) {
      value = _decodeSignedContent(tag.content)?.toDouble();
    }
    if (value == null) {
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeInvalidDataType);
    }
    writePath(project, entry.tag, dataType == 'FLOAT64' ? value : value.round());
    return BacnetWriteResult.ok();
  }

  /// BV write: accepts an app-tagged Enumerated 0/1 (the type Present_Value
  /// is always encoded as), leniently also a Boolean tag — any other tag
  /// type, or an Enumerated value other than 0/1, is invalid-data-type.
  BacnetWriteResult _writeBv(BacnetMapEntry entry, Uint8List valueTags) {
    final tag = BacnetTagReader(valueTags).readTag();
    if (tag == null || tag.isContext) {
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeInvalidDataType);
    }
    bool? value;
    if (tag.tagNumber == kBacnetTagEnumerated) {
      final e = tag.asEnumerated();
      if (e == 0) {
        value = false;
      } else if (e == 1) {
        value = true;
      }
    } else if (tag.tagNumber == kBacnetTagBoolean) {
      value = tag.asBoolean();
    }
    if (value == null) {
      return BacnetWriteResult.error(kBacnetErrorClassProperty, kBacnetErrorCodeInvalidDataType);
    }
    writePath(project, entry.tag, value);
    return BacnetWriteResult.ok();
  }

  /// Decodes [content] as a BIG-ENDIAN two's-complement Signed value (1-4
  /// bytes only — comfortably covers every practical write this device
  /// receives) for the AV write's lenient Signed->double path. Returns
  /// `null` — never throws — outside that range.
  static int? _decodeSignedContent(Uint8List content) {
    if (content.isEmpty || content.length > 4) {
      return null;
    }
    var v = 0;
    for (final b in content) {
      v = (v << 8) | b;
    }
    final bits = content.length * 8;
    final signBit = 1 << (bits - 1);
    if ((v & signBit) != 0) {
      v -= 1 << bits;
    }
    return v;
  }
}
