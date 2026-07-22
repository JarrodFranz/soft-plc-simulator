import 'project_model.dart';

/// Pure, deterministic helpers for editing an FBD program's network
/// structure (`PlcProgram.fbdNetworks` + `FbdBlock.network`). These mutate
/// the passed [PlcProgram] in place and never throw: an out-of-range
/// network index, `from`/`to` index, or unknown block id is always a no-op.
///
/// Invariant maintained by every operation here: after any call, no
/// `FbdWire` crosses a network boundary (both its endpoints are always in
/// the same network). `deleteFbdNetwork` and `setBlockNetwork` enforce this
/// directly; `moveFbdNetwork` never needs to, because it moves an entire
/// network (all its blocks) together, so wires internal to that network
/// stay intra-network.

/// Blocks belonging to network [net], in `p.fbdBlocks` order. An
/// out-of-range [net] simply yields no matches (never throws).
List<FbdBlock> fbdBlocksInNetwork(PlcProgram p, int net) {
  return p.fbdBlocks.where((b) => b.network == net).toList();
}

/// Appends a new (empty) network with the given [comment] and returns its
/// index.
int addFbdNetwork(PlcProgram p, {String comment = ''}) {
  p.fbdNetworks.add(FbdNetwork(comment: comment));
  return p.fbdNetworks.length - 1;
}

/// Reorders the network at index [from] to index [to], rewriting every
/// block's `network` index so membership follows the move (this changes
/// FBD execution order, which is network-index order). Out-of-range
/// [from]/[to] (negative or >= network count) is a no-op; so is `from ==
/// to`.
void moveFbdNetwork(PlcProgram p, int from, int to) {
  final n = p.fbdNetworks.length;
  if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;

  // Compute the new arrangement of old indices, then read off an
  // old-index -> new-index remap from it. This is the same remap for both
  // the network header list and every block's `network` field, so headers
  // and block membership can never drift apart.
  final order = List<int>.generate(n, (i) => i);
  final moved = order.removeAt(from);
  order.insert(to, moved);

  final oldToNew = List<int>.filled(n, 0);
  for (var newIndex = 0; newIndex < n; newIndex++) {
    oldToNew[order[newIndex]] = newIndex;
  }

  p.fbdNetworks = order.map((oldIndex) => p.fbdNetworks[oldIndex]).toList();

  for (final b in p.fbdBlocks) {
    if (b.network >= 0 && b.network < n) {
      b.network = oldToNew[b.network];
    }
  }
}

/// Removes the network at index [net], every block in it, and every wire
/// touching those blocks; renumbers remaining blocks/networks so indices
/// stay contiguous `0..n-1`. Out-of-range [net] is a no-op.
void deleteFbdNetwork(PlcProgram p, int net) {
  final n = p.fbdNetworks.length;
  if (net < 0 || net >= n) return;

  final removedBlockIds =
      p.fbdBlocks.where((b) => b.network == net).map((b) => b.id).toSet();

  p.fbdBlocks.removeWhere((b) => b.network == net);
  p.fbdWires.removeWhere((w) =>
      removedBlockIds.contains(w.fromBlockId) ||
      removedBlockIds.contains(w.toBlockId));
  p.fbdNetworks.removeAt(net);

  // Renumber: any network index above the deleted one shifts down by one
  // so remaining indices stay contiguous 0..n-2.
  for (final b in p.fbdBlocks) {
    if (b.network > net) {
      b.network -= 1;
    }
  }
}

/// Reassigns block [blockId] to network [net], then prunes any wire that
/// now crosses a network boundary as a result. Unknown [blockId] or
/// out-of-range [net] is a no-op.
void setBlockNetwork(PlcProgram p, String blockId, int net) {
  if (net < 0 || net >= p.fbdNetworks.length) return;
  FbdBlock? block;
  for (final b in p.fbdBlocks) {
    if (b.id == blockId) {
      block = b;
      break;
    }
  }
  if (block == null) return;

  block.network = net;
  pruneCrossNetworkWires(p);
}

/// Removes every `FbdWire` whose two endpoints are in different networks.
/// A wire referencing an unknown block id is left untouched (it is not
/// this function's job to clean up dangling references). Idempotent: a
/// program with no cross-network wires is unchanged by a repeat call.
void pruneCrossNetworkWires(PlcProgram p) {
  final networkOf = <String, int>{
    for (final b in p.fbdBlocks) b.id: b.network,
  };

  p.fbdWires.removeWhere((w) {
    final fromNet = networkOf[w.fromBlockId];
    final toNet = networkOf[w.toBlockId];
    if (fromNet == null || toNet == null) return false;
    return fromNet != toNet;
  });
}
