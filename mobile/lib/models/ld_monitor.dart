/// Transient, session-only tap of the LD power solve for the "Go-Online" view.
/// Not persisted; cleared on project/session reset.
class LdMonitor {
  /// Key: '<progName>|<rungIndex>|<nodeId>' -> whether POWER FLOWS out of this
  /// node on the last scan that executed it. Drives the wire colour.
  final Map<String, bool> nodePower = {};

  /// Same key -> the element's OWN evaluated true-state (a contact conducting,
  /// a coil/timer/counter energized-active, a compare block's result), decoupled
  /// from upstream power. Drives the element-face highlight, so an element lights
  /// when it is itself true even if no power reaches it.
  final Map<String, bool> nodeTrue = {};

  String keyFor(String prog, int rungIndex, String nodeId) =>
      '$prog|$rungIndex|$nodeId';

  void clear() {
    nodePower.clear();
    nodeTrue.clear();
  }
}
