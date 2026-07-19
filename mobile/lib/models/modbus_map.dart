// Pure Dart Modbus TCP tag<->register map model (WS24).
//
// Mirrors the OPC UA node<->tag map (opcua_map.dart) but for Modbus: instead
// of a single flat OPC UA address space, tags are assigned into one of four
// classic Modbus data tables (coil / discrete input / holding register /
// input register), each with its own independently-numbered address space.
//
// No Flutter dependency — this file must stay pure Dart so it can be used
// from services and widgets alike without pulling Flutter into model code.

import 'project_model.dart';
import 'tag_resolver.dart';
import 'tag_write_gate.dart';

/// One Modbus register-map entry, binding a project tag to an address in one
/// of the four Modbus data tables.
///
/// `table` is one of `'coil'`, `'discrete'`, `'holding'`, `'input'`.
/// `access` is either `'ReadOnly'` or `'ReadWrite'`.
class ModbusMapEntry {
  String tag;
  String table;
  int address;
  String access;

  ModbusMapEntry({
    required this.tag,
    required this.table,
    required this.address,
    this.access = 'ReadWrite',
  });

  factory ModbusMapEntry.fromJson(Map<String, dynamic> json) => ModbusMapEntry(
        tag: json['tag']?.toString() ?? '',
        table: json['table']?.toString() ?? 'holding',
        address: (json['address'] as num?)?.toInt() ?? 0,
        access: json['access']?.toString() ?? 'ReadWrite',
      );

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'table': table,
        'address': address,
        'access': access,
      };
}

/// The editable Modbus register map for a project: the list of tag<->address
/// bindings across the four Modbus data tables.
class ModbusMap {
  List<ModbusMapEntry> entries;

  ModbusMap({List<ModbusMapEntry>? entries}) : entries = entries ?? [];

  factory ModbusMap.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return ModbusMap(
      entries: (rawEntries is List)
          ? rawEntries
              .whereType<Map>()
              .map((e) => ModbusMapEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <ModbusMapEntry>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// Number of consecutive 16-bit registers a scalar data type occupies in a
  /// Modbus register table (holding/input). Bit tables (coil/discrete) always
  /// occupy exactly one bit and don't use this — it only matters for the
  /// register-table address-advance step in [autoGenerate].
  static int regsForType(String dataType) {
    switch (dataType) {
      case 'INT16':
        return 1;
      case 'INT32':
        return 2;
      case 'FLOAT64':
        return 4;
      default:
        return 1;
    }
  }

  /// Builds a default map from a project's scalar leaf tags (`scalarLeaves`):
  /// composite/array tags are expanded into one entry per scalar leaf whose
  /// type is `BOOL`, `INT16`, `INT32`, or `FLOAT64` — `STRING` leaves (and
  /// any other non-scalar-table type) are skipped (v1 doesn't support them
  /// over Modbus). Leaves are keyed by their dotted path (e.g.
  /// `System.ScanTimeMs`); a bare scalar tag yields itself, unchanged from
  /// before.
  ///
  /// Access/table selection is inherited from the ROOT tag (the tag whose
  /// name is the leaf path's first segment): `SimulatedOutput` or an
  /// explicit `ReadOnly` tag `access` (e.g. the reserved `System` tag) is
  /// read-only; everything else (`SimulatedInput`, `Internal`) is
  /// read-write. Table selection: `BOOL` -> `coil` (RW) / `discrete` (RO);
  /// numeric -> `holding` (RW) / `input` (RO). Addresses are assigned
  /// sequentially per table in leaf order, advancing by 1 for bit tables or
  /// by [regsForType] for register tables.
  static ModbusMap autoGenerate(PlcProject p) {
    const skipTypes = {'TIMER', 'COUNTER', 'STRING'};
    const scalarTypes = {'BOOL', 'INT16', 'INT32', 'FLOAT64'};
    final nextAddr = <String, int>{'coil': 0, 'discrete': 0, 'holding': 0, 'input': 0};
    final entries = <ModbusMapEntry>[];
    for (final leaf in scalarLeaves(p)) {
      final dataType = leaf.dataType;
      if (skipTypes.contains(dataType) || !scalarTypes.contains(dataType)) {
        continue;
      }
      final rw = defaultsExternallyWritable(p, leaf.path);
      final access = rw ? 'ReadWrite' : 'ReadOnly';
      final String table;
      final int advance;
      if (dataType == 'BOOL') {
        table = rw ? 'coil' : 'discrete';
        advance = 1;
      } else {
        table = rw ? 'holding' : 'input';
        advance = regsForType(dataType);
      }
      final address = nextAddr[table]!;
      nextAddr[table] = address + advance;
      entries.add(ModbusMapEntry(
        tag: leaf.path,
        table: table,
        address: address,
        access: access,
      ));
    }
    return ModbusMap(entries: entries);
  }
}
