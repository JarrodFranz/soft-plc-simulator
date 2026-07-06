// OPC UA address space built from a project's exposed-tag map — pure Dart,
// no dart:io / Flutter imports. See docs/superpowers/plans/
// 2026-07-06-in-app-opcua-server.md, Task 3.
//
// v1 scope: a flat address space — one Variable node per `OpcuaMap` entry,
// organized directly under the standard Objects folder (i=85). This is the
// simplest UAExpert-friendly shape ("Objects > all your tags") and matches
// the brief's "v1: flat under Objects" guidance.
//
// Every standard NodeId / AttributeId / NodeClass / DataTypeId value used
// here is cross-checked against the Rust `opcua` crate (v0.12.0), vendored
// locally at:
//   C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/
// Specific files cited inline next to each constant.
library opcua_address_space;

import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'opcua_binary.dart';

/// Standard NodeIds (types/node_ids.rs), all namespace 0.
class OpcUaStandardNodeIds {
  static const rootFolder = OpcNodeId.numeric(0, 84); // node_ids.rs:1607
  static const objectsFolder = OpcNodeId.numeric(0, 85); // node_ids.rs:1608
  static const organizesReferenceType = OpcNodeId.numeric(0, 35); // node_ids.rs:849
  static const hasTypeDefinitionReferenceType = OpcNodeId.numeric(0, 40); // node_ids.rs:854
  static const folderType = OpcNodeId.numeric(0, 61); // node_ids.rs:975
  static const baseDataVariableType = OpcNodeId.numeric(0, 63); // node_ids.rs:1450
}

/// NodeClass enum values (service_types/enums.rs:589-599), Int32-encoded.
class OpcUaNodeClass {
  static const object = 1;
  static const variable = 2;
}

/// AttributeId values (types/attribute.rs:23-51).
class OpcUaAttributeIds {
  static const nodeId = 1;
  static const nodeClass = 2;
  static const browseName = 3;
  static const displayName = 4;
  static const value = 13;
  static const dataType = 14;
  static const accessLevel = 17;
  static const userAccessLevel = 18;
}

/// AccessLevel / UserAccessLevel bit values (Part 3 §5.6.3 — a Byte mask;
/// only the two bits v1 uses are named here).
const int kAccessLevelCurrentRead = 0x01;
const int kAccessLevelCurrentWrite = 0x02;

/// Maps a `PlcTag.dataType` string to its OPC UA Variant scalar type id
/// (variant.rs / node_ids.rs `DataTypeId`) and its standard DataType NodeId
/// (node_ids.rs): Boolean i=1, Int16 i=4, Int32 i=6, Int64 i=8, Float i=10,
/// Double i=11, String i=12 — all verified against the Rust source.
class OpcUaTypeMapping {
  final int variantTypeId;
  final OpcNodeId dataTypeNodeId;

  const OpcUaTypeMapping({required this.variantTypeId, required this.dataTypeNodeId});
}

const Map<String, OpcUaTypeMapping> _dataTypeMap = {
  'BOOL': OpcUaTypeMapping(variantTypeId: 1, dataTypeNodeId: OpcNodeId.numeric(0, 1)),
  'INT16': OpcUaTypeMapping(variantTypeId: 4, dataTypeNodeId: OpcNodeId.numeric(0, 4)),
  'INT32': OpcUaTypeMapping(variantTypeId: 6, dataTypeNodeId: OpcNodeId.numeric(0, 6)),
  'INT64': OpcUaTypeMapping(variantTypeId: 8, dataTypeNodeId: OpcNodeId.numeric(0, 8)),
  'FLOAT32': OpcUaTypeMapping(variantTypeId: 10, dataTypeNodeId: OpcNodeId.numeric(0, 10)),
  'FLOAT64': OpcUaTypeMapping(variantTypeId: 11, dataTypeNodeId: OpcNodeId.numeric(0, 11)),
  'STRING': OpcUaTypeMapping(variantTypeId: 12, dataTypeNodeId: OpcNodeId.numeric(0, 12)),
};

/// Numeric Variant type ids eligible for cross-numeric coercion on Write
/// (everything except Boolean(1)/String(12) — SByte, Byte, Int16, UInt16,
/// Int32, UInt32, Int64, UInt64, Float, Double). See `OpcUaAddressSpaceEntry
/// .coerceForWrite` for the documented coercion rule.
const Set<int> _numericVariantTypeIds = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11};

/// One exposed Variable node: the parsed [nodeId], its browse/display name
/// (the tag's short name), the underlying project tag name it reads/writes
/// through ([tagName]), the tag's PLC dataType, and the map's access level
/// ('ReadOnly' | 'ReadWrite').
class OpcUaAddressSpaceEntry {
  final OpcNodeId nodeId;
  final String browseName;
  final String tagName;
  final String dataType;
  final String access;

  const OpcUaAddressSpaceEntry({
    required this.nodeId,
    required this.browseName,
    required this.tagName,
    required this.dataType,
    required this.access,
  });

  bool get isWritable => access == 'ReadWrite';

  int get accessLevelByte =>
      kAccessLevelCurrentRead | (isWritable ? kAccessLevelCurrentWrite : 0);

  OpcUaTypeMapping? get typeMapping => _dataTypeMap[dataType];

  /// Reads the LIVE value from [project] at call time and wraps it in the
  /// Variant type matching [dataType]. Returns `null` if the dataType is
  /// unrecognized (shouldn't happen for a well-formed map, but defensive).
  OpcVariant? readVariant(PlcProject project) {
    final mapping = typeMapping;
    if (mapping == null) return null;
    final raw = readPath(project, tagName);
    switch (dataType) {
      case 'BOOL':
        return OpcVariant(typeId: mapping.variantTypeId, value: raw == true);
      case 'INT16':
      case 'INT32':
      case 'INT64':
        return OpcVariant(
          typeId: mapping.variantTypeId,
          value: raw is num ? raw.toInt() : 0,
        );
      case 'FLOAT32':
      case 'FLOAT64':
        return OpcVariant(
          typeId: mapping.variantTypeId,
          value: raw is num ? raw.toDouble() : 0.0,
        );
      case 'STRING':
        return OpcVariant(typeId: mapping.variantTypeId, value: raw is String ? raw : '');
      default:
        return null;
    }
  }

  /// Coerces [variant] into a value assignable to this entry's dataType, per
  /// the documented v1 coercion rule:
  ///   - Boolean tag accepts ONLY a Boolean variant.
  ///   - String tag accepts ONLY a String variant.
  ///   - Any numeric tag (INT16/INT32/INT64/FLOAT32/FLOAT64) accepts ANY
  ///     numeric Variant type (SByte/Byte/Int16/UInt16/Int32/UInt32/Int64/
  ///     UInt64/Float/Double) and coerces via `num.toInt()` (truncating
  ///     toward zero) or `num.toDouble()` as appropriate — "strict but
  ///     coercing numerics", matching the brief's recommendation. Boolean
  ///     and String never cross-coerce with numerics or each other.
  /// Returns `null` if the variant's type is incompatible (caller maps that
  /// to Bad_TypeMismatch).
  Object? coerceForWrite(OpcVariant variant) {
    switch (dataType) {
      case 'BOOL':
        return variant.typeId == 1 && variant.value is bool ? variant.value : null;
      case 'STRING':
        return variant.typeId == 12 && variant.value is String ? variant.value : null;
      case 'INT16':
      case 'INT32':
      case 'INT64':
        if (!_numericVariantTypeIds.contains(variant.typeId)) return null;
        final v = variant.value;
        return v is num ? v.toInt() : null;
      case 'FLOAT32':
      case 'FLOAT64':
        if (!_numericVariantTypeIds.contains(variant.typeId)) return null;
        final v = variant.value;
        return v is num ? v.toDouble() : null;
      default:
        return null;
    }
  }
}

/// The address space for one project: a flat set of Variable nodes organized
/// under the standard Objects folder. Values are NOT stored here — reads and
/// writes always go through the live project's tag DB (see
/// `OpcUaAddressSpaceEntry.readVariant` / `OpcUaProjectServices.writeValue`).
class OpcUaAddressSpace {
  final List<OpcUaAddressSpaceEntry> _entries;
  final Map<OpcNodeId, OpcUaAddressSpaceEntry> _byNodeId;

  OpcUaAddressSpace._(this._entries, this._byNodeId);

  /// Builds the address space from `project.protocols?.opcua` (the map +
  /// namespaceUri). Nodes whose `node_id` string cannot be parsed as either
  /// `ns=<n>;s=<string>` or `ns=<n>;i=<numeric>` are skipped (malformed —
  /// tolerated, not fatal).
  factory OpcUaAddressSpace.build(PlcProject project) {
    final opcua = project.protocols?.opcua;
    final entries = <OpcUaAddressSpaceEntry>[];
    final byNodeId = <OpcNodeId, OpcUaAddressSpaceEntry>{};
    if (opcua != null) {
      for (final node in opcua.map.nodes) {
        final parsed = _parseNodeId(node.nodeId);
        if (parsed == null) {
          continue; // malformed node id string — skip this node.
        }
        final tag = _findTag(project, node.tag);
        if (tag == null) {
          continue; // dangling tag reference — skip this node.
        }
        final entry = OpcUaAddressSpaceEntry(
          nodeId: parsed,
          browseName: tag.name,
          tagName: node.tag,
          dataType: tag.dataType,
          access: node.access,
        );
        entries.add(entry);
        byNodeId[parsed] = entry;
      }
    }
    return OpcUaAddressSpace._(entries, byNodeId);
  }

  static PlcTag? _findTag(PlcProject project, String name) {
    for (final t in project.tags) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// Parses a `node_id` string in either `ns=<n>;s=<string>` (string
  /// identifier) or `ns=<n>;i=<numeric>` (numeric identifier) form. Returns
  /// `null` for anything else (malformed — tolerated, the node is skipped).
  static OpcNodeId? _parseNodeId(String raw) {
    final parts = raw.split(';');
    if (parts.length != 2) return null;
    final nsPart = parts[0];
    final idPart = parts[1];
    if (!nsPart.startsWith('ns=')) return null;
    final ns = int.tryParse(nsPart.substring(3));
    if (ns == null) return null;
    if (idPart.startsWith('s=')) {
      final stringId = idPart.substring(2);
      if (stringId.isEmpty) return null;
      return OpcNodeId.string(ns, stringId);
    }
    if (idPart.startsWith('i=')) {
      final numericId = int.tryParse(idPart.substring(2));
      if (numericId == null) return null;
      return OpcNodeId.numeric(ns, numericId);
    }
    return null;
  }

  /// The entry for [nodeId], or `null` if it isn't one of ours (nor the
  /// Objects folder — see [isObjectsFolder]).
  OpcUaAddressSpaceEntry? byNodeId(OpcNodeId nodeId) => _byNodeId[nodeId];

  bool isObjectsFolder(OpcNodeId nodeId) => nodeId == OpcUaStandardNodeIds.objectsFolder;

  /// The direct children of [parent] in the Organizes hierarchy: all
  /// variables when [parent] is the Objects folder, otherwise empty (v1's
  /// flat layout has no further nesting).
  List<OpcUaAddressSpaceEntry> children(OpcNodeId parent) {
    if (isObjectsFolder(parent)) {
      return List.unmodifiable(_entries);
    }
    return const [];
  }

  /// All exposed entries (unordered iteration order = map order).
  List<OpcUaAddressSpaceEntry> get entries => List.unmodifiable(_entries);
}
