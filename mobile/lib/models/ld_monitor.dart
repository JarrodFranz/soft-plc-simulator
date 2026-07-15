/// Transient, session-only tap of the LD power solve for the "Go-Online" view.
/// Not persisted; cleared on project/session reset.
class LdMonitor {
  /// Key: '<progName>|<rungIndex>|<nodeId>' -> energized/passing on the last
  /// scan that executed this node.
  final Map<String, bool> nodePower = {};

  String keyFor(String prog, int rungIndex, String nodeId) =>
      '$prog|$rungIndex|$nodeId';

  void clear() => nodePower.clear();
}
