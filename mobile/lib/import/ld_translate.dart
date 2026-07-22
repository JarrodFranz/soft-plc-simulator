import '../models/project_model.dart';
import 'import_ir.dart';

/// Result of translating one LD `GraphBody`. `rungs` includes placeholder
/// rungs (for untranslatable components) so program rung numbering matches the
/// source. `translatedRungCount > 0` is the mapper's real-program-vs-stub
/// decision. `instanceTags` are TIMER/COUNTER-typed tags the mapper must add so
/// translated timer/counter blocks have backing state.
class LdTranslation {
  final List<LdRung> rungs;
  final List<ImportWarning> warnings;
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedBlockTypes;
  final Map<String, int> stubReasons;
  final List<PlcTag> instanceTags;
  LdTranslation({
    required this.rungs,
    required this.warnings,
    required this.translatedRungCount,
    required this.stubbedRungCount,
    required this.unsupportedBlockTypes,
    required this.stubReasons,
    required this.instanceTags,
  });
}

/// Parses an IEC 61131 duration literal (`T#5s`, `TIME#500ms`, `T#1m30s`,
/// `T#1.5s`) to milliseconds. Case-insensitive. Returns null if [literal] is
/// not a duration. Supported units: d, h, m, s, ms.
int? parseIecDuration(String literal) {
  var s = literal.trim().toLowerCase();
  if (s.startsWith('time#')) {
    s = s.substring(5);
  } else if (s.startsWith('t#')) {
    s = s.substring(2);
  } else {
    return null;
  }
  if (s.isEmpty) return null;
  // Ordered so 'ms' is matched before 'm'.
  final re = RegExp(r'(\d+(?:\.\d+)?)(ms|d|h|m|s)');
  const unitMs = {'d': 86400000.0, 'h': 3600000.0, 'm': 60000.0, 's': 1000.0, 'ms': 1.0};
  double total = 0;
  var matchedLen = 0;
  for (final m in re.allMatches(s)) {
    matchedLen += m.group(0)!.length;
    total += double.parse(m.group(1)!) * unitMs[m.group(2)]!;
  }
  if (matchedLen != s.length || matchedLen == 0) {
    return null; // stray characters -> not a clean duration
  }
  return total.round();
}

/// One connected component of a PLCopen LD `GraphBody` after the power-rail
/// nodes have been removed — i.e. one rung. [leftRailNodeIds]/[rightRailNodeIds]
/// are the component's own node ids that were directly wired to the
/// left/right rail before the rail nodes were stripped out.
class LdComponent {
  final List<IrGraphNode> nodes;
  final List<IrConnection> edges;
  final Set<int> leftRailNodeIds;
  final Set<int> rightRailNodeIds;
  LdComponent({
    required this.nodes,
    required this.edges,
    required this.leftRailNodeIds,
    required this.rightRailNodeIds,
  });
}

bool _isLeftRail(String t) => t == 'leftPowerRail';
bool _isRightRail(String t) => t == 'rightPowerRail';

/// Splits [body] into one [LdComponent] per rung by removing the
/// `leftPowerRail`/`rightPowerRail` nodes and taking connected components of
/// the remaining (undirected) graph. Components are ordered top-to-bottom:
/// min `y`, then min `x`, then min `localId`.
List<LdComponent> segmentRungs(GraphBody body) {
  final byId = {for (final n in body.nodes) n.localId: n};
  final railIds = <int>{
    for (final n in body.nodes)
      if (_isLeftRail(n.elementType) || _isRightRail(n.elementType)) n.localId
  };
  final leftRailIds = {
    for (final n in body.nodes) if (_isLeftRail(n.elementType)) n.localId
  };
  final rightRailIds = {
    for (final n in body.nodes) if (_isRightRail(n.elementType)) n.localId
  };

  // Record rail attachment before removing rails.
  final touchesLeft = <int>{};
  final touchesRight = <int>{};
  for (final e in body.connections) {
    if (leftRailIds.contains(e.fromLocalId)) touchesLeft.add(e.toLocalId);
    if (leftRailIds.contains(e.toLocalId)) touchesLeft.add(e.fromLocalId);
    if (rightRailIds.contains(e.fromLocalId)) touchesRight.add(e.toLocalId);
    if (rightRailIds.contains(e.toLocalId)) touchesRight.add(e.fromLocalId);
  }

  // Undirected adjacency over non-rail nodes.
  final adj = <int, Set<int>>{
    for (final n in body.nodes) if (!railIds.contains(n.localId)) n.localId: <int>{}
  };
  for (final e in body.connections) {
    if (railIds.contains(e.fromLocalId) || railIds.contains(e.toLocalId)) continue;
    if (adj.containsKey(e.fromLocalId) && adj.containsKey(e.toLocalId)) {
      adj[e.fromLocalId]!.add(e.toLocalId);
      adj[e.toLocalId]!.add(e.fromLocalId);
    }
  }

  // Connected components (deterministic: iterate node ids in file order).
  final seen = <int>{};
  final comps = <LdComponent>[];
  for (final n in body.nodes) {
    if (railIds.contains(n.localId) || seen.contains(n.localId)) continue;
    final memberIds = <int>[];
    final stack = [n.localId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!seen.add(id)) continue;
      memberIds.add(id);
      for (final m in adj[id] ?? const <int>{}) {
        if (!seen.contains(m)) stack.add(m);
      }
    }
    final memberSet = memberIds.toSet();
    final compNodes = [for (final id in memberIds) byId[id]!];
    final compEdges = [
      for (final e in body.connections)
        if (memberSet.contains(e.fromLocalId) && memberSet.contains(e.toLocalId)) e
    ];
    comps.add(LdComponent(
      nodes: compNodes,
      edges: compEdges,
      leftRailNodeIds: memberSet.intersection(touchesLeft),
      rightRailNodeIds: memberSet.intersection(touchesRight),
    ));
  }

  // Order components top-to-bottom: min y, then min x, then min localId.
  double minY(LdComponent c) => c.nodes.map((n) => n.y).reduce((a, b) => a < b ? a : b);
  double minX(LdComponent c) => c.nodes.map((n) => n.x).reduce((a, b) => a < b ? a : b);
  int minId(LdComponent c) => c.nodes.map((n) => n.localId).reduce((a, b) => a < b ? a : b);
  comps.sort((a, b) {
    final cy = minY(a).compareTo(minY(b));
    if (cy != 0) return cy;
    final cx = minX(a).compareTo(minX(b));
    if (cx != 0) return cx;
    return minId(a).compareTo(minId(b));
  });
  return comps;
}
