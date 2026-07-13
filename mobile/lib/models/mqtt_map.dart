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

  /// Builds a default map from a project's scalar leaf tags: one entry per
  /// tag whose type is `BOOL`, `INT16`, `INT32`, or `FLOAT64` — composite
  /// tags (structs/arrays) and `TIMER`/`COUNTER`/`STRING` types are skipped,
  /// exactly like `ModbusMap.autoGenerate`.
  ///
  /// Metric name defaults to the tag name; `SimulatedOutput` tags are
  /// read-only (matching the OPC UA/Modbus auto-map convention), everything
  /// else (`SimulatedInput`, `Internal`) is writable.
  static MqttMap autoGenerate(PlcProject p) {
    const skipTypes = {'TIMER', 'COUNTER', 'STRING'};
    const scalarTypes = {'BOOL', 'INT16', 'INT32', 'FLOAT64'};
    final entries = <MqttMapEntry>[];
    for (final tag in p.tags) {
      final dataType = tag.dataType;
      if (skipTypes.contains(dataType) || !scalarTypes.contains(dataType)) {
        continue;
      }
      final value = tag.value;
      if (value is Map || value is List) {
        continue;
      }
      entries.add(MqttMapEntry(
        tag: tag.name,
        metric: tag.folder.isEmpty ? tag.name : '${tag.folder}/${tag.name}',
        writable: tag.ioType != 'SimulatedOutput',
      ));
    }
    return MqttMap(entries: entries);
  }
}
