// Pure Dart MQTT / Sparkplug B tag<->metric map model.
//
// Mirrors the Modbus tag<->register map (modbus_map.dart) but for MQTT:
// instead of assigning tags into Modbus data tables, each tag is bound to a
// flat metric name published under the project's MQTT topic tree (or, in
// Sparkplug B mode, as a metric in the NBIRTH/NDATA payload).
//
// No Flutter dependency — this file must stay pure Dart so it can be used
// from services and widgets alike without pulling Flutter into model code.

import 'project_model.dart';
import 'tag_resolver.dart';
import 'tag_write_gate.dart';

/// One MQTT tag<->metric map entry, binding a project tag to a published
/// metric name.
///
/// `writable` mirrors the Modbus/OPC UA auto-map convention: tags that are
/// not `SimulatedOutput` accept remote writes (subject to
/// `MqttProtocolConfig.allowRemoteWrites`); `SimulatedOutput` tags are
/// read-only (publish-only).
class MqttMapEntry {
  String tag;
  String metric;
  bool writable;

  MqttMapEntry({
    required this.tag,
    required this.metric,
    this.writable = true,
  });

  factory MqttMapEntry.fromJson(Map<String, dynamic> json) => MqttMapEntry(
        tag: json['tag']?.toString() ?? '',
        metric: json['metric']?.toString() ?? '',
        writable: json['writable'] == true,
      );

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'metric': metric,
        'writable': writable,
      };
}

/// The editable MQTT tag<->metric map for a project: the list of
/// tag<->metric bindings published to the broker.
class MqttMap {
  List<MqttMapEntry> entries;

  MqttMap({List<MqttMapEntry>? entries}) : entries = entries ?? [];

  factory MqttMap.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return MqttMap(
      entries: (rawEntries is List)
          ? rawEntries
              .whereType<Map>()
              .map((e) => MqttMapEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <MqttMapEntry>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// Builds a default map from a project's scalar leaf tags (`scalarLeaves`):
  /// composite/array tags are expanded into one entry per scalar leaf whose
  /// type is `BOOL`, `INT16`, `INT32`, `FLOAT64`, or `STRING` (STRING is
  /// allowed on MQTT, unlike Modbus/DNP3). Leaves are keyed by their dotted
  /// path (e.g. `System.DateTime`); a bare scalar tag yields itself,
  /// unchanged from before.
  ///
  /// Metric name defaults to the leaf's dotted path, prefixed with the ROOT
  /// tag's folder (the tag whose name is the leaf path's first segment);
  /// `SimulatedOutput` tags or an explicit `ReadOnly` root tag `access`
  /// (e.g. the reserved `System` tag, checked by name, not just its `access`
  /// field, so this holds even if `System`'s own `access` were ever left at
  /// its default) are read-only, everything else (`SimulatedInput`, `Internal`)
  /// is writable.
  static MqttMap autoGenerate(PlcProject p) {
    const scalarTypes = {'BOOL', 'INT16', 'INT32', 'FLOAT64', 'STRING'};
    final entries = <MqttMapEntry>[];
    for (final leaf in scalarLeaves(p)) {
      if (!scalarTypes.contains(leaf.dataType)) {
        continue;
      }
      final root = rootTagOf(p, leaf.path);
      final rootFolder = root?.folder ?? '';
      final writable = defaultsExternallyWritable(p, leaf.path);
      entries.add(MqttMapEntry(
        tag: leaf.path,
        metric: rootFolder.isEmpty ? leaf.path : '$rootFolder/${leaf.path}',
        writable: writable,
      ));
    }
    return MqttMap(entries: entries);
  }
}
