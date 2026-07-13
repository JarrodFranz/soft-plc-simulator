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

  // --- Task 2 (discovery) additions --- all cross-checked against
  // C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/node_ids.rs
  /// `ObjectId::Server`. node_ids.rs:1827.
  static const serverNode = OpcNodeId.numeric(0, 2253);

  /// `VariableId::Server_NamespaceArray`. node_ids.rs:3936.
  static const serverNamespaceArray = OpcNodeId.numeric(0, 2255);

  /// `ObjectTypeId::ServerType`. node_ids.rs:979.
  static const serverType = OpcNodeId.numeric(0, 2004);
}

/// The standard "OPC Foundation" namespace URI — always index 0 of every OPC
/// UA server's NamespaceArray (Part 3 §8.2.3). Verified against
/// opcua-0.12.0/src/server/address_space/address_space.rs:193
/// (`AddressSpace::new()`'s initial `namespaces: vec!["http://opcfoundation.org/UA/"...]`).
const String kOpcFoundationNamespaceUri = 'http://opcfoundation.org/UA/';

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

/// Reserved NodeId-string prefix for synthesized folder Object nodes. A real
/// tag NodeId is `ns=1;s=<tagName>` (plain identifier), so this marker can
/// never collide with one.
const String kFolderNodePrefix = '__folder__/';

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
  final String folder;

  const OpcUaAddressSpaceEntry({
    required this.nodeId,
    required this.browseName,
    required this.tagName,
    required this.dataType,
    required this.access,
    required this.folder,
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

  /// `project.protocols?.opcua?.namespaceUri`, captured at build time so the
  /// services layer can serve `Server_NamespaceArray` (i=2255) without a
  /// second lookup into the project. Empty string when the project has no
  /// `opcua` config (matches the map/entries also being empty in that case).
  final String namespaceUri;

  /// Distinct non-empty tag folders, alphabetically sorted.
  final List<String> _folders;

  OpcUaAddressSpace._(this._entries, this._byNodeId, this.namespaceUri, this._folders);

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
          folder: tag.folder,
        );
        entries.add(entry);
        byNodeId[parsed] = entry;
      }
    }
    final folderSet = <String>{};
    for (final e in entries) {
      if (e.folder.isNotEmpty) {
        folderSet.add(e.folder);
      }
    }
    final folders = folderSet.toList()..sort();
    return OpcUaAddressSpace._(entries, byNodeId, opcua?.namespaceUri ?? '', folders);
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

  /// Task 2 (discovery): true for the standard Root folder (i=84) — the
  /// entry point a top-down client (Root -> Objects -> tags) starts from.
  bool isRootFolder(OpcNodeId nodeId) => nodeId == OpcUaStandardNodeIds.rootFolder;

  /// Task 2 (discovery): true for the standard Server object (i=2253),
  /// served (Browse-only) so a strict client sees SOMETHING organized under
  /// Objects besides the flat tag list — matches a real server's shape.
  bool isServerNode(OpcNodeId nodeId) => nodeId == OpcUaStandardNodeIds.serverNode;

  /// Task 2 (discovery): true for the standard `Server_NamespaceArray`
  /// variable (i=2255), whose Value a strict client reads to resolve what
  /// namespace index 1 (this project's tags) actually means.
  bool isNamespaceArrayNode(OpcNodeId nodeId) => nodeId == OpcUaStandardNodeIds.serverNamespaceArray;

  /// The `Server_NamespaceArray` Value: index 0 is always the OPC
  /// Foundation's standard namespace URI, index 1 is this project's tag
  /// namespace URI (matches the `ns=1;...` prefix every mapped tag NodeId
  /// carries — see [_parseNodeId]).
  List<String> get namespaceArray => [kOpcFoundationNamespaceUri, namespaceUri];

  /// Distinct non-empty tag folders, alphabetically sorted.
  List<String> get folders => List.unmodifiable(_folders);

  /// The synthesized folder Object node for [folder]. Uses the reserved
  /// [kFolderNodePrefix] string-identifier form in namespace 1 — the same
  /// namespace real tag NodeIds live in — so it never collides with one.
  OpcNodeId folderNodeId(String folder) => OpcNodeId.string(1, '$kFolderNodePrefix$folder');

  /// True if [nodeId] is one of our synthesized folder Object nodes.
  bool isFolderNode(OpcNodeId nodeId) =>
      nodeId.namespace == 1 && nodeId.isString && (nodeId.stringId ?? '').startsWith(kFolderNodePrefix);

  /// The folder name encoded in [nodeId], or `null` if it isn't a folder
  /// node (see [isFolderNode]).
  String? folderNameOf(OpcNodeId nodeId) =>
      isFolderNode(nodeId) ? nodeId.stringId!.substring(kFolderNodePrefix.length) : null;

  /// Entries with no folder (`folder == ''`), in map order.
  List<OpcUaAddressSpaceEntry> rootVariables() =>
      _entries.where((e) => e.folder.isEmpty).toList();

  /// The folder names to show directly under [parent]: all [folders] when
  /// [parent] is the Objects folder, otherwise empty (folders don't nest).
  List<String> childFolders(OpcNodeId parent) =>
      isObjectsFolder(parent) ? List.unmodifiable(_folders) : const [];

  /// Entries belonging to [folder], in map order.
  List<OpcUaAddressSpaceEntry> folderVariables(String folder) =>
      _entries.where((e) => e.folder == folder).toList();

  /// The direct Variable children of [parent] in the Organizes hierarchy:
  /// root variables when [parent] is the Objects folder, a folder's
  /// variables when [parent] is one of our synthesized folder nodes,
  /// otherwise empty. Callers that also need the folder Object nodes
  /// themselves should use [childFolders] alongside this.
  List<OpcUaAddressSpaceEntry> children(OpcNodeId parent) {
    if (isObjectsFolder(parent)) {
      return rootVariables();
    }
    final folder = folderNameOf(parent);
    if (folder != null) {
      return folderVariables(folder);
    }
    return const [];
  }

  /// All exposed entries (unordered iteration order = map order).
  List<OpcUaAddressSpaceEntry> get entries => List.unmodifiable(_entries);
}
