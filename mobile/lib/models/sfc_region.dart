// Pure SFC region-tree parser (SFC-v2 Task 3).
//
// Turns a well-structured SFC graph (`List<SfcStep>` + `List<SfcTransition>`)
// into a tree of regions that a later pass (Task 4) lays out in 2D. This module
// is PURE Dart: the only import is the domain model. It performs NO layout and
// holds NO pixel coordinates — it only classifies the graph into Seq / Alt /
// Par / Step / Trans regions.
//
// Robustness: the parser never throws and never loops forever. A `visited` set
// makes every cycle terminate (loop-back edges become GOTO `TransRegion`
// leaves), dangling transitions become null-target leaves, and any steps not
// reachable from the initial step are still emitted as trailing leaves so a
// partly-built chart degrades gracefully instead of failing.

import 'project_model.dart';

/// Base type for every node in the region tree. Concrete subtypes are matched
/// with `is` checks, so no `sealed`/`enum` discriminant is required.
abstract class SfcRegion {}

/// A single SFC step (box).
class StepRegion extends SfcRegion {
  final SfcStep step;
  StepRegion(this.step);
}

/// A transition edge. [target] is the resolved destination step (null when the
/// edge dangles), and [isGoto] is true when [target] is an already-placed step
/// (a loop-back or merge into an earlier box) — a GOTO leaf is never recursed
/// into.
class TransRegion extends SfcRegion {
  final SfcTransition transition;
  final SfcStep? target;
  final bool isGoto;
  TransRegion(this.transition, this.target, this.isGoto);
}

/// An ordered sequence of regions.
class SeqRegion extends SfcRegion {
  final List<SfcRegion> items;
  SeqRegion(this.items);
}

/// An alternative (divergence/convergence) branch. [branches] is parallel to
/// [guards]: `guards[i]` is the transition out of [head] that guards
/// `branches[i]`. [merge] is the convergence step reached by every branch (null
/// when the branches GOTO out and never reconverge).
class AltRegion extends SfcRegion {
  final SfcStep head;
  final List<List<SfcRegion>> branches;
  final List<SfcTransition> guards;
  final SfcStep? merge;
  AltRegion(this.head, this.branches, this.guards, this.merge);
}

/// A simultaneous (parallel) branch. [fork] is the `parallelFork` transition,
/// [join] the matching `parallelJoin`, and [after] the step that follows the
/// join (`join.toStepId`, null when dangling). Each entry of [branches] is a
/// sequence that ends at the branch's join-tail step.
class ParRegion extends SfcRegion {
  final SfcTransition fork;
  final List<List<SfcRegion>> branches;
  final SfcTransition join;
  final SfcStep? after;
  ParRegion(this.fork, this.branches, this.join, this.after);
}

/// Parse [steps] + [transitions] into a region tree for 2D layout.
///
/// Returns a single region when the whole chart collapses to one node,
/// otherwise a [SeqRegion] wrapping the top-level walk (plus any unreachable
/// steps as trailing leaves).
SfcRegion parseSfc(List<SfcStep> steps, List<SfcTransition> transitions) {
  return _SfcParser(steps, transitions).parse();
}

/// Result of walking a sequence: the regions produced, plus the join reached
/// if the walk ended on a `parallelJoin` tail step.
class _WalkResult {
  final List<SfcRegion> regions;
  final SfcTransition? reachedJoin;
  _WalkResult(this.regions, this.reachedJoin);
}

/// Result of building a composite (Alt/Par) region: the region itself and the
/// step id from which the enclosing sequence should continue (null to stop).
class _SubResult {
  final SfcRegion region;
  final String? continueId;
  _SubResult(this.region, this.continueId);
}

class _SfcParser {
  final List<SfcStep> _steps;
  final List<SfcTransition> _transitions;
  final Map<String, SfcStep> _stepById;

  /// Maps each `parallelJoin` tail step id to its join transition, so a branch
  /// walk can detect where it ends.
  final Map<String, SfcTransition> _joinByTail;

  _SfcParser(List<SfcStep> steps, List<SfcTransition> transitions)
      : _steps = steps,
        _transitions = transitions,
        _stepById = {for (final s in steps) s.id: s},
        _joinByTail = _buildJoinByTail(transitions);

  static Map<String, SfcTransition> _buildJoinByTail(
    List<SfcTransition> transitions,
  ) {
    final map = <String, SfcTransition>{};
    for (final t in transitions) {
      if (t.kind == 'parallelJoin') {
        for (final tail in t.fromStepIds) {
          map[tail] = t;
        }
      }
    }
    return map;
  }

  SfcRegion parse() {
    final visited = <String>{};
    final regions = <SfcRegion>[];

    final start = _findStart();
    if (start != null) {
      regions.addAll(_walkSequence(start.id, visited, const <String>{}).regions);
    }

    // Degrade: emit any steps not reachable from the start as trailing leaves
    // so a partly-built chart still surfaces every box.
    for (final s in _steps) {
      if (!visited.contains(s.id)) {
        visited.add(s.id);
        regions.add(StepRegion(s));
      }
    }

    if (regions.length == 1) {
      return regions.first;
    }
    return SeqRegion(regions);
  }

  SfcStep? _findStart() {
    for (final s in _steps) {
      if (s.isInitial) {
        return s;
      }
    }
    return _steps.isNotEmpty ? _steps.first : null;
  }

  /// Walk a linear sequence starting at [startId]. Stops (without emitting the
  /// step) when it reaches a step in [stopIds] — used to bound Alt branches at
  /// their convergence step. Stops (after emitting the step) when it reaches a
  /// `parallelJoin` tail, reporting that join via [_WalkResult.reachedJoin].
  _WalkResult _walkSequence(
    String startId,
    Set<String> visited,
    Set<String> stopIds,
  ) {
    final regions = <SfcRegion>[];
    SfcTransition? reachedJoin;
    String? curId = startId;

    while (curId != null) {
      if (stopIds.contains(curId)) {
        break;
      }
      final cur = _stepById[curId];
      if (cur == null) {
        break;
      }
      if (visited.contains(curId)) {
        break;
      }
      visited.add(curId);
      regions.add(StepRegion(cur));

      // End of a parallel branch — hand the join back to the caller.
      final joinHere = _joinByTail[curId];
      if (joinHere != null) {
        reachedJoin = joinHere;
        break;
      }

      final outgoing = _transitions
          .where((t) =>
              t.fromStepId == curId &&
              (t.kind == 'single' || t.kind == 'parallelFork'))
          .toList();

      if (outgoing.isEmpty) {
        break;
      }

      // Parallel fork.
      if (outgoing.length == 1 && outgoing.first.kind == 'parallelFork') {
        final res = _buildPar(outgoing.first, visited);
        regions.add(res.region);
        curId = res.continueId;
        continue;
      }

      final singles =
          outgoing.where((t) => t.kind == 'single').toList();

      // Single successor.
      if (outgoing.length == 1 && singles.length == 1) {
        final t = singles.first;
        final target = _stepById[t.toStepId];
        if (target == null) {
          regions.add(TransRegion(t, null, false));
          break;
        }
        if (visited.contains(target.id)) {
          regions.add(TransRegion(t, target, true));
          break;
        }
        if (stopIds.contains(target.id)) {
          regions.add(TransRegion(t, target, false));
          break;
        }
        regions.add(TransRegion(t, target, false));
        curId = target.id;
        continue;
      }

      // Alternative divergence.
      if (singles.length >= 2) {
        final res = _buildAlt(cur, singles, visited, stopIds);
        regions.add(res.region);
        curId = res.continueId;
        continue;
      }

      // Degrade: an outgoing shape we do not model (e.g. multiple forks, or a
      // fork mixed with singles). Emit each edge as a leaf and stop.
      for (final t in outgoing) {
        final target = _stepById[t.toStepId];
        final goto = target != null && visited.contains(target.id);
        regions.add(TransRegion(t, target, goto));
      }
      break;
    }

    return _WalkResult(regions, reachedJoin);
  }

  /// Build a [ParRegion] from a `parallelFork`. Each branch head is walked
  /// until it reaches the matching join's tail; the join is discovered from the
  /// branch walks. Continues the enclosing sequence from `join.toStepId`.
  _SubResult _buildPar(SfcTransition fork, Set<String> visited) {
    final branches = <List<SfcRegion>>[];
    SfcTransition? join;

    for (final headId in fork.toStepIds) {
      final res = _walkSequence(headId, visited, const <String>{});
      branches.add(res.regions);
      if (res.reachedJoin != null) {
        join = res.reachedJoin;
      }
    }

    if (join == null) {
      // Degrade: branches never reached a join — inline them so nothing is lost.
      final flat = <SfcRegion>[];
      for (final b in branches) {
        flat.addAll(b);
      }
      return _SubResult(SeqRegion(flat), null);
    }

    final after = _stepById[join.toStepId];
    return _SubResult(ParRegion(fork, branches, join, after), join.toStepId);
  }

  /// Build an [AltRegion] from ≥2 `single` guards out of [head]. The merge is
  /// the first step reachable from every branch; branches are walked bounded by
  /// it. Continues the enclosing sequence from the merge (null if none).
  _SubResult _buildAlt(
    SfcStep head,
    List<SfcTransition> guards,
    Set<String> visited,
    Set<String> parentStop,
  ) {
    final chains = <List<String>>[
      for (final g in guards) _reachable(g.toStepId),
    ];
    final merge = _firstCommon(chains);

    final stop = <String>{...parentStop};
    if (merge != null) {
      stop.add(merge);
    }

    final branches = <List<SfcRegion>>[
      for (final g in guards) _walkSequence(g.toStepId, visited, stop).regions,
    ];

    final mergeStep = merge != null ? _stepById[merge] : null;
    return _SubResult(AltRegion(head, branches, guards, mergeStep), merge);
  }

  /// Steps reachable from [startId] following `single` edges only, in
  /// breadth-first discovery order. Cycle-safe via a local seen set.
  List<String> _reachable(String startId) {
    final order = <String>[];
    final seen = <String>{};
    final queue = <String>[startId];

    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      if (seen.contains(id)) {
        continue;
      }
      seen.add(id);
      if (!_stepById.containsKey(id)) {
        continue;
      }
      order.add(id);
      for (final t in _transitions) {
        if (t.fromStepId == id && t.kind == 'single') {
          queue.add(t.toStepId);
        }
      }
    }
    return order;
  }

  /// First step id (in the first chain's order) present in every chain — the
  /// convergence point. Null when the branches never share a step.
  String? _firstCommon(List<List<String>> chains) {
    if (chains.isEmpty) {
      return null;
    }
    final sets = [for (final c in chains) c.toSet()];
    for (final id in chains.first) {
      var inAll = true;
      for (final s in sets) {
        if (!s.contains(id)) {
          inAll = false;
          break;
        }
      }
      if (inAll) {
        return id;
      }
    }
    return null;
  }
}
