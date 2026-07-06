// Pure Dart OPC UA node<->tag map model.
//
// Mirrors the on-disk shape of examples/protocol-maps/opcua_map_example.json:
//   { "opcua_map": { "namespace_uri": "...", "nodes": [ { "node_id", "tag",
//   "access" }, ... ] } }
//
// See docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md,
// "OPC UA mapping". No Flutter dependency.

import 'project_model.dart';

/// One OPC UA `Variable` node, bound to a project tag by name.
///
/// `access` is either `'ReadOnly'` (Current-Read) or `'ReadWrite'`
/// (Read+Write).
class OpcuaNode {
  String nodeId;
  String tag;
  String access;

  OpcuaNode({
    required this.nodeId,
    required this.tag,
    this.access = 'ReadWrite',
  });

  factory OpcuaNode.fromJson(Map<String, dynamic> json) => OpcuaNode(
        nodeId: json['node_id'] ?? '',
        tag: json['tag'] ?? '',
        access: json['access'] ?? 'ReadWrite',
      );

  Map<String, dynamic> toJson() => {
        'node_id': nodeId,
        'tag': tag,
        'access': access,
      };
}

/// The editable OPC UA address-space map for a project: a namespace URI plus
/// the list of exposed nodes.
class OpcuaMap {
  String namespaceUri;
  List<OpcuaNode> nodes;

  OpcuaMap({
    required this.namespaceUri,
    List<OpcuaNode>? nodes,
  }) : nodes = nodes ?? [];

  factory OpcuaMap.fromJson(Map<String, dynamic> json) {
    final inner = json['opcua_map'] ?? json;
    return OpcuaMap(
      namespaceUri: inner['namespace_uri'] ?? '',
      nodes: (inner['nodes'] as List? ?? [])
          .map((n) => OpcuaNode.fromJson(Map<String, dynamic>.from(n)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'opcua_map': {
          'namespace_uri': namespaceUri,
          'nodes': nodes.map((n) => n.toJson()).toList(),
        },
      };

  /// Builds a default map from a project's scalar leaf tags: one node per
  /// tag whose value is neither a Map nor a List (struct/array tags are
  /// skipped in v1). Outputs (`SimulatedOutput`) are `ReadOnly`; everything
  /// else (`SimulatedInput`, `Internal`) is `ReadWrite`.
  static OpcuaMap autoGenerate(PlcProject p) {
    final nodes = <OpcuaNode>[];
    for (final tag in p.tags) {
      if (tag.value is Map || tag.value is List) {
        continue;
      }
      final access = tag.ioType == 'SimulatedOutput' ? 'ReadOnly' : 'ReadWrite';
      nodes.add(OpcuaNode(
        nodeId: 'ns=1;s=${tag.path}',
        tag: tag.name,
        access: access,
      ));
    }
    return OpcuaMap(namespaceUri: 'urn:softplc:${p.id}', nodes: nodes);
  }
}
