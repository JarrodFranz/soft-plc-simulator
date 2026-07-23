/// Transient, session-only tap of the FBD executor's per-block pin values,
/// captured as each block is evaluated. Not persisted; cleared on
/// project/session reset. Mirrors `LdMonitor`'s role for Ladder Logic.
class FbdMonitor {
  /// Key: '<progName>|<blockId>|<pinName>' -> the value that pin held the
  /// last time its owning block was evaluated.
  final Map<String, dynamic> pinValue = {};

  String keyFor(String prog, String blockId, String pin) =>
      '$prog|$blockId|$pin';

  void clear() => pinValue.clear();
}
