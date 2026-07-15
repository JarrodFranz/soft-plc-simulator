import 'project_model.dart';

int _maxSuffix(Iterable<String> ids, String prefix) {
  int m = -1;
  for (final id in ids) {
    if (id.startsWith(prefix)) {
      final n = int.tryParse(id.substring(prefix.length));
      if (n != null && n > m) {
        m = n;
      }
    }
  }
  return m;
}

/// A step id not present in [p] (monotonic 's<n>').
String newSfcStepId(PlcProgram p) => 's${_maxSuffix(p.sfcSteps.map((s) => s.id), 's') + 1}';

/// A transition id not present in [p] (monotonic 't<n>').
String newSfcTransitionId(PlcProgram p) =>
    't${_maxSuffix(p.sfcTransitions.map((t) => t.id), 't') + 1}';

/// Adds a new step (default name 'Step_<n>') and returns it.
SfcStep addSfcStep(PlcProgram p, {String? name}) {
  final id = newSfcStepId(p);
  final step = SfcStep(
    id: id,
    name: name ?? 'Step_${p.sfcSteps.length}',
    isInitial: p.sfcSteps.isEmpty, // first-ever step is initial
    actionSt: '',
  );
  p.sfcSteps.add(step);
  return step;
}

/// Appends a new outgoing transition from [fromStepId]. Default target is the
/// step's own id (a self-hold the user then retargets) and condition 'TRUE'.
SfcTransition addSfcBranch(PlcProgram p, String fromStepId) {
  final t = SfcTransition(
    id: newSfcTransitionId(p),
    fromStepId: fromStepId,
    toStepId: fromStepId,
    conditionSt: 'TRUE',
  );
  p.sfcTransitions.add(t);
  return t;
}

/// Removes a transition by id.
void deleteSfcTransition(PlcProgram p, String transitionId) {
  p.sfcTransitions.removeWhere((t) => t.id == transitionId);
}

/// Removes a step and every transition referencing it (either direction).
/// If the removed step was the initial step, promotes the first remaining
/// step to initial so the engine always has a start.
void deleteSfcStep(PlcProgram p, String stepId) {
  final wasInitial = p.sfcSteps.any((s) => s.id == stepId && s.isInitial);
  p.sfcSteps.removeWhere((s) => s.id == stepId);
  p.sfcTransitions.removeWhere((t) => t.fromStepId == stepId || t.toStepId == stepId);
  if (wasInitial && p.sfcSteps.isNotEmpty && !p.sfcSteps.any((s) => s.isInitial)) {
    p.sfcSteps.first.isInitial = true;
  }
}

// ---------------------------------------------------------------------------
// Structured authoring (SFC-v2 Task 6): alternative branches, parallel
// fork/join creation + extension, nesting, and collapse-on-delete.
//
// Every helper is structure-preserving and keeps the fork/join contract
// consistent: a `parallelFork`'s `toStepIds` always equals the set of its
// branch heads, and the paired `parallelJoin`'s `fromStepIds` always equals the
// branch tails. After every call the chart stays parseable by `parseSfc` with
// no dangling references.
// ---------------------------------------------------------------------------

/// The first `single` transition out of [stepId], or null. Used to find where a
/// step currently flows in a linear chain.
SfcTransition? _firstSingleOut(PlcProgram p, String stepId) {
  for (final t in p.sfcTransitions) {
    if (t.kind == 'single' && t.fromStepId == stepId) {
      return t;
    }
  }
  return null;
}

/// The `parallelFork` transition whose source is [stepId], or null.
SfcTransition? _forkFrom(PlcProgram p, String stepId) {
  for (final t in p.sfcTransitions) {
    if (t.kind == 'parallelFork' && t.fromStepId == stepId) {
      return t;
    }
  }
  return null;
}

/// The `parallelJoin` matching [fork]: found by walking each branch head along
/// `single` edges to the tail that some join lists in its `fromStepIds`.
SfcTransition? _joinForFork(PlcProgram p, SfcTransition fork) {
  final joinByTail = <String, SfcTransition>{};
  for (final t in p.sfcTransitions) {
    if (t.kind == 'parallelJoin') {
      for (final tail in t.fromStepIds) {
        joinByTail[tail] = t;
      }
    }
  }
  for (final head in fork.toStepIds) {
    final seen = <String>{};
    String? cur = head;
    while (cur != null && !seen.contains(cur)) {
      seen.add(cur);
      final j = joinByTail[cur];
      if (j != null) {
        return j;
      }
      cur = _firstSingleOut(p, cur)?.toStepId;
    }
  }
  return null;
}

/// The branch-tail step of the branch that starts at [headId]: follows `single`
/// edges from [headId] until it reaches a step listed in [join.fromStepIds].
/// Returns [headId] itself for a single-step branch. Cycle-safe.
String _branchTail(PlcProgram p, SfcTransition join, String headId) {
  final seen = <String>{};
  String cur = headId;
  while (!seen.contains(cur)) {
    seen.add(cur);
    if (join.fromStepIds.contains(cur)) {
      return cur;
    }
    final next = _firstSingleOut(p, cur)?.toStepId;
    if (next == null) {
      return cur;
    }
    cur = next;
  }
  return cur;
}

/// Adds another `single` route out of [atStepId] — an alternative divergence.
/// Creates a fresh target step; if [atStepId] already flows onward (has a
/// `single` successor), the new branch reconverges at that same successor so the
/// result is a clean alternative diamond. Yields >= 2 singles out of [atStepId].
/// Returns the new divergence transition.
SfcTransition addAlternativeBranch(PlcProgram p, String atStepId) {
  // Capture where the anchor currently flows (its convergence step), if any.
  final mergeId = _firstSingleOut(p, atStepId)?.toStepId;

  final newStep = addSfcStep(p);
  final diverge = SfcTransition(
    id: newSfcTransitionId(p),
    fromStepId: atStepId,
    toStepId: newStep.id,
    conditionSt: 'TRUE',
  );
  p.sfcTransitions.add(diverge);

  // Reconverge the new branch at the existing successor so both alternatives
  // merge at the same step.
  if (mergeId != null && p.sfcSteps.any((s) => s.id == mergeId)) {
    p.sfcTransitions.add(SfcTransition(
      id: newSfcTransitionId(p),
      fromStepId: newStep.id,
      toStepId: mergeId,
      conditionSt: 'TRUE',
    ));
  }
  return diverge;
}

/// Inserts a fresh step immediately after [afterStepId] in sequence. If
/// [afterStepId] currently flows to a step via a `single` edge, that edge is
/// re-pointed through the new step (afterStepId -> new -> oldTarget); otherwise
/// the new step is simply appended (afterStepId -> new). Returns the new step.
SfcStep addSfcStepAfter(PlcProgram p, String afterStepId) {
  final newStep = addSfcStep(p);
  final existing = _firstSingleOut(p, afterStepId);
  if (existing != null) {
    // Splice the new step in front of the current successor.
    p.sfcTransitions.add(SfcTransition(
      id: newSfcTransitionId(p),
      fromStepId: newStep.id,
      toStepId: existing.toStepId,
      conditionSt: 'TRUE',
    ));
    existing.toStepId = newStep.id;
  } else {
    p.sfcTransitions.add(SfcTransition(
      id: newSfcTransitionId(p),
      fromStepId: afterStepId,
      toStepId: newStep.id,
      conditionSt: 'TRUE',
    ));
  }
  return newStep;
}

/// Creates or extends a parallel fork/join around/after [afterStepId].
///
/// - If [afterStepId] is NOT already a fork source, builds a new `parallelFork`
///   from it to two fresh single-step branches, with a matching `parallelJoin`
///   leading to [afterStepId]'s current successor (its `single` target, or the
///   step after an enclosing join when [afterStepId] is a branch tail — this is
///   how NESTING works — or a fresh step when [afterStepId] is a dead end).
/// - If [afterStepId] IS already a fork source, appends ANOTHER single-step
///   branch to that fork + its join.
///
/// Returns the `parallelFork` transition (new or extended).
SfcTransition addParallelBranch(PlcProgram p, String afterStepId) {
  // Extend an existing fork: add a third/Nth branch.
  final existingFork = _forkFrom(p, afterStepId);
  if (existingFork != null) {
    final join = _joinForFork(p, existingFork);
    final nb = addSfcStep(p);
    existingFork.toStepIds.add(nb.id);
    if (join != null) {
      join.fromStepIds.add(nb.id);
    }
    return existingFork;
  }

  // Determine the step the new join should lead to.
  String afterId;
  final linear = _firstSingleOut(p, afterStepId);
  if (linear != null) {
    afterId = linear.toStepId;
    // Remove the anchor's linear successor edge(s) so the fork is its sole exit.
    p.sfcTransitions
        .removeWhere((t) => t.kind == 'single' && t.fromStepId == afterStepId);
  } else {
    // Nesting: [afterStepId] is a branch tail of an enclosing join. Insert a new
    // tail step in its place; the inner join then leads to that new tail, which
    // remains the branch's tail into the outer join.
    SfcTransition? outerJoin;
    for (final t in p.sfcTransitions) {
      if (t.kind == 'parallelJoin' && t.fromStepIds.contains(afterStepId)) {
        outerJoin = t;
        break;
      }
    }
    if (outerJoin != null) {
      final newTail = addSfcStep(p);
      final idx = outerJoin.fromStepIds.indexOf(afterStepId);
      outerJoin.fromStepIds[idx] = newTail.id;
      afterId = newTail.id;
    } else {
      // Dead-end anchor: create a fresh following step.
      afterId = addSfcStep(p).id;
    }
  }

  // Two fresh single-step branches (head == tail for each).
  final b1 = addSfcStep(p);
  final b2 = addSfcStep(p);
  final fork = SfcTransition(
    id: newSfcTransitionId(p),
    fromStepId: afterStepId,
    toStepId: '',
    conditionSt: 'TRUE',
    kind: 'parallelFork',
    toStepIds: [b1.id, b2.id],
  );
  p.sfcTransitions.add(fork);
  final join = SfcTransition(
    id: newSfcTransitionId(p),
    fromStepId: '',
    toStepId: afterId,
    conditionSt: 'TRUE',
    kind: 'parallelJoin',
    fromStepIds: [b1.id, b2.id],
  );
  p.sfcTransitions.add(join);
  return fork;
}

/// Removes the branch headed by [branchHeadId] from the fork [forkTransitionId]
/// (and its matching join): deletes every step and edge along that branch. When
/// only ONE branch would remain, COLLAPSES the fork/join back into a plain
/// sequence — the fork + join transitions are removed and the surviving branch
/// is spliced in as `single` edges (anchor -> survivorHead ... survivorTail ->
/// after).
void deleteParallelBranch(PlcProgram p, String forkTransitionId, String branchHeadId) {
  final forkMatches =
      p.sfcTransitions.where((t) => t.id == forkTransitionId && t.kind == 'parallelFork');
  if (forkMatches.isEmpty) {
    return;
  }
  final fork = forkMatches.first;
  if (!fork.toStepIds.contains(branchHeadId)) {
    return;
  }
  final join = _joinForFork(p, fork);

  // Collect the steps of the branch (head..tail) so they can be deleted.
  final branchSteps = <String>[];
  {
    final seen = <String>{};
    String cur = branchHeadId;
    final tail = join != null ? _branchTail(p, join, branchHeadId) : branchHeadId;
    while (!seen.contains(cur)) {
      seen.add(cur);
      branchSteps.add(cur);
      if (cur == tail) {
        break;
      }
      final next = _firstSingleOut(p, cur)?.toStepId;
      if (next == null) {
        break;
      }
      cur = next;
    }
  }
  final branchTailId = branchSteps.isNotEmpty ? branchSteps.last : branchHeadId;

  // Detach the branch from the fork / join sets.
  fork.toStepIds.remove(branchHeadId);
  join?.fromStepIds.remove(branchTailId);

  // Remove the branch's steps (and every edge touching them).
  for (final id in branchSteps) {
    deleteSfcStep(p, id);
  }

  // Collapse when the fork can no longer diverge.
  if (fork.toStepIds.length <= 1) {
    final anchor = fork.fromStepId;
    final afterId = join?.toStepId ?? '';
    final survivorHead = fork.toStepIds.isNotEmpty ? fork.toStepIds.first : null;
    final survivorTail = (join != null && join.fromStepIds.isNotEmpty)
        ? join.fromStepIds.first
        : survivorHead;

    p.sfcTransitions.removeWhere((t) => t.id == fork.id);
    if (join != null) {
      p.sfcTransitions.removeWhere((t) => t.id == join.id);
    }

    if (survivorHead != null && p.sfcSteps.any((s) => s.id == survivorHead)) {
      // anchor -> survivor branch ...
      p.sfcTransitions.add(SfcTransition(
        id: newSfcTransitionId(p),
        fromStepId: anchor,
        toStepId: survivorHead,
        conditionSt: 'TRUE',
      ));
      // ... survivorTail -> after (only when the post-join step still exists).
      if (survivorTail != null && p.sfcSteps.any((s) => s.id == afterId)) {
        p.sfcTransitions.add(SfcTransition(
          id: newSfcTransitionId(p),
          fromStepId: survivorTail,
          toStepId: afterId,
          conditionSt: 'TRUE',
        ));
      }
    } else if (p.sfcSteps.any((s) => s.id == anchor) &&
        p.sfcSteps.any((s) => s.id == afterId)) {
      // No branches left at all: reconnect the anchor straight to the after step.
      p.sfcTransitions.add(SfcTransition(
        id: newSfcTransitionId(p),
        fromStepId: anchor,
        toStepId: afterId,
        conditionSt: 'TRUE',
      ));
    }
  }
}

/// Deletes [stepId] with collapse-aware cleanup: if the step is the head of a
/// parallel branch, the whole branch is removed (collapsing the fork/join when
/// only one branch remains); otherwise a plain [deleteSfcStep].
void deleteSfcStepStructured(PlcProgram p, String stepId) {
  for (final t in p.sfcTransitions) {
    if (t.kind == 'parallelFork' && t.toStepIds.contains(stepId)) {
      deleteParallelBranch(p, t.id, stepId);
      return;
    }
  }
  deleteSfcStep(p, stepId);
}

/// Moves a transition earlier (delta<0) or later (delta>0) among the
/// transitions that share its `fromStepId` — i.e. changes if/else-if priority.
/// Reorders within the global `sfcTransitions` list so the engine (which reads
/// list order) sees the new priority. No-op at a group boundary.
void reorderSfcBranch(PlcProgram p, String transitionId, int delta) {
  final list = p.sfcTransitions;
  final idx = list.indexWhere((t) => t.id == transitionId);
  if (idx < 0 || delta == 0) {
    return;
  }
  final from = list[idx].fromStepId;
  // Indices (in the global list) of the same-from group, in order.
  final group = <int>[];
  for (var i = 0; i < list.length; i++) {
    if (list[i].fromStepId == from) {
      group.add(i);
    }
  }
  final pos = group.indexOf(idx);
  final newPos = pos + delta;
  if (newPos < 0 || newPos >= group.length) {
    return; // boundary
  }
  // Swap the two group members by swapping their global-list slots.
  final a = group[pos];
  final b = group[newPos];
  final tmp = list[a];
  list[a] = list[b];
  list[b] = tmp;
}
