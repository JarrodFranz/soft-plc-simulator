import 'project_model.dart';

/// One outgoing transition of a step in the laid-out chart.
class SfcOutgoing {
  final SfcTransition transition;

  /// The transition's target step, or null if `toStepId` matches no step
  /// (a dangling/deleted target).
  final SfcStep? target;

  /// True for the one outgoing whose target is drawn as the card directly
  /// below this step (the inline connector). All others are GOTO chips.
  final bool inline;

  const SfcOutgoing({required this.transition, required this.target, required this.inline});
}

/// A step plus its outgoing transitions (in priority order).
class SfcLayoutRow {
  final SfcStep step;
  final List<SfcOutgoing> outgoing;
  const SfcLayoutRow({required this.step, required this.outgoing});
}

/// Orders steps by flow from the initial step: depth-first following each
/// step's FIRST not-yet-placed outgoing target. A target is placed the first
/// time it is reached; additional branches and already-placed targets become
/// GOTO chips (inline == false). Branch-reachable steps follow the main path;
/// steps that are never reached come last, in `steps` list order. Cycle-safe.
List<SfcLayoutRow> layoutSfc(List<SfcStep> steps, List<SfcTransition> transitions) {
  SfcStep? byId(String id) {
    for (final s in steps) {
      if (s.id == id) {
        return s;
      }
    }
    return null;
  }

  List<SfcTransition> outOf(String id) =>
      transitions.where((t) => t.fromStepId == id).toList(growable: false);

  final placedOrder = <SfcStep>[];
  final placed = <String>{};

  // Depth-first placement following the first not-yet-placed target.
  void place(SfcStep step) {
    if (placed.contains(step.id)) {
      return;
    }
    placed.add(step.id);
    placedOrder.add(step);
    for (final t in outOf(step.id)) {
      final target = byId(t.toStepId);
      if (target != null && !placed.contains(target.id)) {
        place(target); // first not-yet-placed target continues the main line
      }
    }
  }

  // Root: the initial step (fallback: first step), mirroring the engine.
  SfcStep? root;
  for (final s in steps) {
    if (s.isInitial) {
      root = s;
      break;
    }
  }
  root ??= steps.isNotEmpty ? steps.first : null;
  if (root != null) {
    place(root);
  }
  // Any steps never reached (unreachable) come last, in list order.
  for (final s in steps) {
    if (!placed.contains(s.id)) {
      placedOrder.add(s);
      placed.add(s.id);
    }
  }

  // Build rows; mark the FIRST outgoing whose target is the card immediately
  // below this step as inline, everything else as GOTO.
  final rowIndexOf = <String, int>{
    for (var i = 0; i < placedOrder.length; i++) placedOrder[i].id: i,
  };
  final rows = <SfcLayoutRow>[];
  for (var i = 0; i < placedOrder.length; i++) {
    final step = placedOrder[i];
    final outs = outOf(step.id);
    var inlineTaken = false;
    final outgoing = <SfcOutgoing>[];
    for (final t in outs) {
      final target = byId(t.toStepId);
      // Inline iff this target is the very next placed card and no earlier
      // outgoing already claimed the inline slot.
      final isNextCard =
          target != null && rowIndexOf[target.id] == i + 1;
      final inline = !inlineTaken && isNextCard;
      if (inline) {
        inlineTaken = true;
      }
      outgoing.add(SfcOutgoing(transition: t, target: target, inline: inline));
    }
    rows.add(SfcLayoutRow(step: step, outgoing: outgoing));
  }
  return rows;
}
