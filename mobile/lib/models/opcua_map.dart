// Pure Dart OPC UA node<->tag map model.
//
// Mirrors the on-disk shape of examples/protocol-maps/opcua_map_example.json:
//   { "opcua_map": { "namespace_uri": "...", "nodes": [ { "node_id", "tag",
//   "access" }, ... ] } }
//
// See docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md,
// "OPC UA mapping". No Flutter dependency.

import 'project_model.dart';
import 'tag_resolver.dart';

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
        nodeId: json['node_id']?.toString() ?? '',
        tag: json['tag']?.toString() ?? '',
        access: json['access']?.toString() ?? 'ReadWrite',
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
    final innerRaw = json['opcua_map'] ?? json;
    final inner = innerRaw is Map ? Map<String, dynamic>.from(innerRaw) : <String, dynamic>{};
    final rawNodes = inner['nodes'];
    return OpcuaMap(
      namespaceUri: inner['namespace_uri']?.toString() ?? '',
      nodes: (rawNodes is List)
          ? rawNodes
              .whereType<Map>()
              .map((n) => OpcuaNode.fromJson(Map<String, dynamic>.from(n)))
              .toList()
          : <OpcuaNode>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'opcua_map': {
          'namespace_uri': namespaceUri,
          'nodes': nodes.map((n) => n.toJson()).toList(),
        },
      };

  /// Builds a default map from a project's scalar leaf tags (`scalarLeaves`):
  /// composite/array tags are expanded into one node per scalar leaf, keyed
  /// by its dotted path (e.g. `System.Fault`, `DB_Motor1.Setpoint`,
  /// `Arr[0]`) — a bare scalar tag yields itself, unchanged from before.
  /// STRING leaves are allowed. Access is inherited from the ROOT tag (the
  /// tag whose name is the leaf path's first segment): `SimulatedOutput` or
  /// an explicit `ReadOnly` tag `access` (e.g. the reserved `System` tag)
  /// yields `ReadOnly`; everything else (`SimulatedInput`, `Internal`) is
  /// `ReadWrite`.
  static OpcuaMap autoGenerate(PlcProject p) {
    final nodes = <OpcuaNode>[];
    for (final leaf in scalarLeaves(p)) {
      final root = rootTagOf(p, leaf.path);
      final readOnly = root?.ioType == 'SimulatedOutput' || root?.access == 'ReadOnly';
      final access = readOnly ? 'ReadOnly' : 'ReadWrite';
      nodes.add(OpcuaNode(
        nodeId: 'ns=1;s=${leaf.path}',
        tag: leaf.path,
        access: access,
      ));
    }
    return OpcuaMap(namespaceUri: 'urn:softplc:${p.id}', nodes: nodes);
  }
}
