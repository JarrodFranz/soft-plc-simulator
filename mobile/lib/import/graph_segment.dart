import 'import_ir.dart';

/// Weakly-connected components of the graph over [nodes], treating each
/// [IrConnection] in [connections] as an undirected edge. Every node whose
/// `localId` is in [excludeIds] is removed first, along with any edge that
/// touches it (this is how LD strips power-rail nodes before segmenting).
///
/// Each returned component is the list of its member nodes. Components are
/// ordered deterministically by layout: ascending min-y, then min-x, then
/// min-localId — the same top-to-bottom, left-to-right reading order the LD
/// and FBD translators assign to rungs/networks. Pure; never throws.
List<List<IrGraphNode>> weaklyConnectedComponents(
  List<IrGraphNode> nodes,
  List<IrConnection> connections, {
  Set<int> excludeIds = const {},
}) {
  final byId = <int, IrGraphNode>{
    for (final n in nodes)
      if (!excludeIds.contains(n.localId)) n.localId: n
  };
  final adj = <int, Set<int>>{for (final id in byId.keys) id: <int>{}};
  for (final e in connections) {
    if (!byId.containsKey(e.fromLocalId) || !byId.containsKey(e.toLocalId)) {
      continue;
    }
    adj[e.fromLocalId]!.add(e.toLocalId);
    adj[e.toLocalId]!.add(e.fromLocalId);
  }

  // Connected components — iterate node ids in input (file) order for
  // determinism, flood-fill each unseen node.
  final seen = <int>{};
  final comps = <List<IrGraphNode>>[];
  for (final n in nodes) {
    if (excludeIds.contains(n.localId) || seen.contains(n.localId)) continue;
    final members = <IrGraphNode>[];
    final stack = <int>[n.localId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!seen.add(id)) continue;
      members.add(byId[id]!);
      for (final m in adj[id] ?? const <int>{}) {
        if (!seen.contains(m)) stack.add(m);
      }
    }
    comps.add(members);
  }

  double minY(List<IrGraphNode> c) =>
      c.map((n) => n.y).reduce((a, b) => a < b ? a : b);
  double minX(List<IrGraphNode> c) =>
      c.map((n) => n.x).reduce((a, b) => a < b ? a : b);
  int minId(List<IrGraphNode> c) =>
      c.map((n) => n.localId).reduce((a, b) => a < b ? a : b);
  comps.sort((a, b) {
    final cy = minY(a).compareTo(minY(b));
    if (cy != 0) return cy;
    final cx = minX(a).compareTo(minX(b));
    if (cx != 0) return cx;
    return minId(a).compareTo(minId(b));
  });
  return comps;
}
