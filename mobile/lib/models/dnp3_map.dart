// Pure Dart DNP3 tag<->point map model (DNP3 outstation workstream, Task 1).
//
// Mirrors the Modbus tag<->register map (modbus_map.dart) but for DNP3:
// instead of the four classic Modbus data tables, tags are assigned into
// one of four DNP3 point types (binary input / binary output / analog
// input / analog output), each with its own independently-numbered
// 0-based index space.
//
// No Flutter dependency — this file must stay pure Dart so it can be used
// from services and widgets alike without pulling Flutter into model code.

import 'project_model.dart';
import 'tag_resolver.dart';
import 'tag_write_gate.dart';

/// One DNP3 point-map entry, binding a project tag to an index within one
/// of the four DNP3 point types.
///
/// `pointType` is one of `'binaryInput'`, `'binaryOutput'`, `'analogInput'`,
/// `'analogOutput'`.
class DnpMapEntry {
  String tag;
  String pointType;
  int index;

  /// DNP3 event class assignment for INPUT points: 0 = static-only (no
  /// events, the default and back-compat behavior), 1/2/3 = this point's
  /// changes are captured into event Class 1/2/3. Meaningful only for
  /// `binaryInput`/`analogInput`; ignored for output point types.
  int eventClass;

  DnpMapEntry({
    required this.tag,
    required this.pointType,
    required this.index,
    this.eventClass = 0,
  });

  factory DnpMapEntry.fromJson(Map<String, dynamic> json) => DnpMapEntry(
        tag: json['tag']?.toString() ?? '',
        pointType: json['point_type']?.toString() ?? 'binaryInput',
        index: (json['index'] as num?)?.toInt() ?? 0,
        eventClass: (((json['event_class'] as num?)?.toInt() ?? 0)).clamp(0, 3),
      );

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'point_type': pointType,
        'index': index,
        'event_class': eventClass,
      };
}

/// The editable DNP3 point map for a project: the list of tag<->index
/// bindings across the four DNP3 point types.
class DnpMap {
  List<DnpMapEntry> entries;

  DnpMap({List<DnpMapEntry>? entries}) : entries = entries ?? [];

  factory DnpMap.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return DnpMap(
      entries: (rawEntries is List)
          ? rawEntries
              .whereType<Map>()
              .map((e) => DnpMapEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <DnpMapEntry>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// Builds a default map from a project's scalar leaf tags (`scalarLeaves`):
  /// composite/array tags are expanded into one entry per scalar leaf whose
  /// type is `BOOL`, `INT16`, `INT32`, or `FLOAT64` — `STRING` leaves (and
  /// any other non-scalar-table type) are skipped (v1 doesn't support them
  /// over DNP3). Leaves are keyed by their dotted path (e.g. `System.Fault`);
  /// a bare scalar tag yields itself, unchanged from before.
  ///
  /// Access/point-type selection is inherited from the ROOT tag (the tag
  /// whose name is the leaf path's first segment): `SimulatedOutput` or an
  /// explicit `ReadOnly` tag `access` (e.g. the reserved `System` tag,
  /// checked by name, not just its `access` field, so this holds even if
  /// `System`'s own `access` were ever left at its default) is read-only;
  /// everything else (`SimulatedInput`, `Internal`) is read-write. Point type
  /// selection: `BOOL` -> `binaryInput` (RO) / `binaryOutput` (RW); numeric ->
  /// `analogInput` (RO) / `analogOutput` (RW). Indexes are assigned
  /// sequentially per point type in leaf order, each starting from 0.
  static DnpMap autoGenerate(PlcProject p) {
    const skipTypes = {'TIMER', 'COUNTER', 'STRING'};
    const scalarTypes = {'BOOL', 'INT16', 'INT32', 'FLOAT64'};
    final nextIndex = <String, int>{
      'binaryInput': 0,
      'binaryOutput': 0,
      'analogInput': 0,
      'analogOutput': 0,
    };
    final entries = <DnpMapEntry>[];
    for (final leaf in scalarLeaves(p)) {
      final dataType = leaf.dataType;
      if (skipTypes.contains(dataType) || !scalarTypes.contains(dataType)) {
        continue;
      }
      final ro = !defaultsExternallyWritable(p, leaf.path);
      final String pointType;
      if (dataType == 'BOOL') {
        pointType = ro ? 'binaryInput' : 'binaryOutput';
      } else {
        pointType = ro ? 'analogInput' : 'analogOutput';
      }
      final index = nextIndex[pointType]!;
      nextIndex[pointType] = index + 1;
      entries.add(DnpMapEntry(
        tag: leaf.path,
        pointType: pointType,
        index: index,
        eventClass: 0,
      ));
    }
    return DnpMap(entries: entries);
  }
}
