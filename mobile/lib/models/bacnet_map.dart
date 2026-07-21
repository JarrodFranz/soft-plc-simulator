// Pure Dart BACnet/IP tag<->object map model (BACnet workstream, Task 4).
//
// Mirrors `slmp_map.dart` (which solves the same named-tag <-> numeric-address
// problem for SLMP), with one structural difference: BACnet addresses a
// per-tag OBJECT (Analog Value or Binary Value, each its own `(objectType,
// instance)`), not a shared word/bit image. So this map is a flat list of
// `tag <-> (objectType, instance)` bindings; the actual property serving and
// force-gated writes live in `protocols/bacnet/bacnet_object_image.dart`,
// which consumes this map.
//
// Type mapping (v1 scope — Analog Value / Binary Value only, matching the
// approved spec's Ignition-scoped service set):
//   BOOL                        -> Binary Value (BV), one object per tag.
//   INT16 / INT32 / INT64 / FLOAT64 -> Analog Value (AV), one object per tag.
//     Present_Value is always an app-tagged Real (IEEE-754 single precision)
//     — see `bacnet_object_image.dart` for the narrowing conversion.
//   STRING                      -> SKIPPED by [BacnetMap.autoGenerate],
//     exactly as the FINS/SLMP/S7/ENIP maps defer STRING. A STRING can still
//     be mapped by hand, but the object image refuses to encode or decode it.
//
// No Flutter dependency and no dart:io — this file must stay pure Dart so it
// can be used from services and widgets alike.
library bacnet_map;

import 'project_model.dart';
import 'tag_resolver.dart';
import 'tag_write_gate.dart';

/// Analog Value object-type tag, as stored in [BacnetMapEntry.objectType].
const String kBacnetMapTypeAv = 'AV';

/// Binary Value object-type tag, as stored in [BacnetMapEntry.objectType].
const String kBacnetMapTypeBv = 'BV';

/// One BACnet map entry, binding a project tag (by its dotted/indexed leaf
/// path) to a served BACnet object: `objectType` is one of
/// [kBacnetMapTypeAv]/[kBacnetMapTypeBv], `instance` is that object's
/// instance number (unique WITHIN its own type — an AV 0 and a BV 0 are
/// different objects). `access` is either `'ReadOnly'` or `'ReadWrite'`.
class BacnetMapEntry {
  String tag;
  String objectType;
  int instance;
  String access;

  BacnetMapEntry({
    required this.tag,
    required this.objectType,
    required this.instance,
    this.access = 'ReadWrite',
  });

  factory BacnetMapEntry.fromJson(Map<String, dynamic> json) => BacnetMapEntry(
        tag: json['tag']?.toString() ?? '',
        objectType: json['object_type']?.toString() ?? kBacnetMapTypeAv,
        instance: (json['instance'] as num?)?.toInt() ?? 0,
        access: json['access']?.toString() ?? 'ReadWrite',
      );

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'object_type': objectType,
        'instance': instance,
        'access': access,
      };
}

/// The editable BACnet object map for a project: the list of tag<->object
/// bindings across the two supported object types.
class BacnetMap {
  List<BacnetMapEntry> entries;

  BacnetMap({List<BacnetMapEntry>? entries}) : entries = entries ?? [];

  /// Tolerant of a missing or non-list `entries` key so an older project JSON
  /// with no `bacnet` section loads cleanly (additive persistence).
  factory BacnetMap.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return BacnetMap(
      entries: (rawEntries is List)
          ? rawEntries
              .whereType<Map>()
              .map((e) => BacnetMapEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <BacnetMapEntry>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// The BACnet object type a scalar data type maps to, or `null` if the type
  /// has no v1 BACnet representation (`STRING`, and anything unrecognized).
  static String? objectTypeForDataType(String dataType) {
    switch (dataType) {
      case 'BOOL':
        return kBacnetMapTypeBv;
      case 'INT16':
      case 'INT32':
      case 'INT64':
      case 'FLOAT64':
        return kBacnetMapTypeAv;
      default:
        return null;
    }
  }

  /// Builds a default map from a project's scalar leaf tags ([scalarLeaves]):
  /// composite/array tags are expanded into one entry per scalar leaf, in
  /// LEAF (tag) order. `BOOL` leaves become Binary Value objects, instances
  /// 0, 1, 2… in the order encountered; every other numeric leaf becomes an
  /// Analog Value object, instances 0, 1, 2… in the order encountered
  /// (the two instance sequences are independent — a BV 0 and an AV 0 both
  /// exist). `STRING` leaves are SKIPPED entirely (see the file header), as
  /// is any other type with no [objectTypeForDataType].
  ///
  /// Access is inherited from the ROOT tag via [defaultsExternallyWritable],
  /// exactly as the FINS/S7/Modbus/CIP/SLMP maps do: a `SimulatedOutput` tag,
  /// an explicit tag `access` of `'ReadOnly'`, or the reserved `System` tag
  /// (checked by NAME) yields `'ReadOnly'`; everything else yields
  /// `'ReadWrite'`.
  static BacnetMap autoGenerate(PlcProject p) {
    final entries = <BacnetMapEntry>[];
    var nextAv = 0;
    var nextBv = 0;
    for (final leaf in scalarLeaves(p)) {
      final objectType = objectTypeForDataType(leaf.dataType);
      if (objectType == null) {
        continue;
      }
      final rw = defaultsExternallyWritable(p, leaf.path);
      final access = rw ? 'ReadWrite' : 'ReadOnly';
      final instance = objectType == kBacnetMapTypeBv ? nextBv++ : nextAv++;

      entries.add(BacnetMapEntry(
        tag: leaf.path,
        objectType: objectType,
        instance: instance,
        access: access,
      ));
    }
    return BacnetMap(entries: entries);
  }
}
