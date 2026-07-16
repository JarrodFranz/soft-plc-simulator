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

/// The `parallelJoin` that currently lists [stepId] as one of its branch tails,
/// or null. A step is a branch tail iff it appears in some join's `fromStepIds`;
/// this is exactly what the parser (`sfc_region.dart`) keys its branch-walk stop
/// on, so any mutator that changes a branch tail MUST keep this in sync.
SfcTransition? _joinWithTail(PlcProgram p, String stepId) {
  for (final t in p.sfcTransitions) {
    if (t.kind == 'parallelJoin' && t.fromStepIds.contains(stepId)) {
      return t;
    }
  }
  return null;
}

/// Collects every step id belonging to the branch that starts at [branchHeadId]
/// of the fork whose matching [join] is given — crossing any NESTED fork/join
/// structures inside the branch so nothing is left orphaned. Traversal follows
/// `single` edges, `parallelFork` heads, and `parallelJoin` after-steps for any
/// NESTED join, but STOPS (inclusively) at the step that is this branch's tail
/// into [join] (a member of `join.fromStepIds`) so it never crosses into the
/// join or a sibling branch. When [join] is null the branch is followed to its
/// dead ends. Cycle-safe.
Set<String> _branchSubgraph(
  PlcProgram p,
  SfcTransition? join,
  String branchHeadId,
) {
  final steps = <String>{};
  final seen = <String>{};
  final queue = <String>[branchHeadId];

  while (queue.isNotEmpty) {
    final s = queue.removeAt(0);
    if (seen.contains(s)) {
      continue;
    }
    seen.add(s);
    if (!p.sfcSteps.any((st) => st.id == s)) {
      continue;
    }
    steps.add(s);

    // Boundary: this step is the branch's tail into the OUTER join. Record it
    // (by inclusion) but do NOT expand past it — that would cross the join into
    // sibling branches or the after-step.
    if (join != null && join.fromStepIds.contains(s)) {
      continue;
    }

    for (final t in p.sfcTransitions) {
      if (t.fromStepId == s && t.kind == 'single') {
        queue.add(t.toStepId);
      } else if (t.fromStepId == s && t.kind == 'parallelFork') {
        queue.addAll(t.toStepIds);
      } else if (t.kind == 'parallelJoin' &&
          (join == null || t.id != join.id) &&
          t.fromStepIds.contains(s)) {
        // Cross a NESTED join: continue from its after-step.
        queue.add(t.toStepId);
      }
    }
  }
  return steps;
}

/// Adds another `single` route out of [atStepId] — an alternative divergence.
/// Creates a fresh target step; if [atStepId] already flows onward (has a
/// `single` successor), the new branch reconverges at that same successor so the
/// result is a clean alternative diamond. Yields >= 2 singles out of [atStepId].
/// Returns the new divergence transition.
SfcTransition addAlternativeBranch(PlcProgram p, String atStepId) {
  // Capture where the anchor currently flows (its convergence step), if any.
  final mergeId = _firstSingleOut(p, atStepId)?.toStepId;

  // Anchor is a parallel-branch TAIL (no linear successor but listed in a join's
  // fromStepIds). An unconverged alternative divergence cannot itself be a join
  // tail, so build a reconverging diamond and hand the join a NEW tail — the
  // merge step — in place of the anchor, so the invariant (join tails == current
  // branch tails) holds and the parser walks the whole branch.
  if (mergeId == null) {
    final joinTail = _joinWithTail(p, atStepId);
    if (joinTail != null) {
      final merge = addSfcStep(p);
      final altStep = addSfcStep(p);
      // Original (straight) arm: anchor -> merge.
      p.sfcTransitions.add(SfcTransition(
        id: newSfcTransitionId(p),
        fromStepId: atStepId,
        toStepId: merge.id,
        conditionSt: 'TRUE',
      ));
      // Alternative arm: anchor -> altStep -> merge.
      final diverge = SfcTransition(
        id: newSfcTransitionId(p),
        fromStepId: atStepId,
        toStepId: altStep.id,
        conditionSt: 'TRUE',
      );
      p.sfcTransitions.add(diverge);
      p.sfcTransitions.add(SfcTransition(
        id: newSfcTransitionId(p),
        fromStepId: altStep.id,
        toStepId: merge.id,
        conditionSt: 'TRUE',
      ));
      // The merge step is now the branch's actual tail into the enclosing join.
      final idx = joinTail.fromStepIds.indexOf(atStepId);
      if (idx >= 0) {
        joinTail.fromStepIds[idx] = merge.id;
      }
      return diverge;
    }
  }

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
    // If the anchor was a parallel-branch TAIL, the appended step is now the
    // branch's actual tail: hand the enclosing join the new tail id in place of
    // the anchor so the parser walks the whole branch (invariant: join tails ==
    // current branch tails) instead of stopping at the stale tail.
    final joinTail = _joinWithTail(p, afterStepId);
    if (joinTail != null) {
      final idx = joinTail.fromStepIds.indexOf(afterStepId);
      if (idx >= 0) {
        joinTail.fromStepIds[idx] = newStep.id;
      }
    }
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
/// Returns the `parallelFork` transition (new or extended), or `null` when
/// [afterStepId] is an alternative-divergence head (see guard below) and the
/// call was a safe no-op.
SfcTransition? addParallelBranch(PlcProgram p, String afterStepId) {
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

  // Safety guard: if the anchor already has >= 2 `single` outgoings, it is an
  // ALTERNATIVE-divergence head (built by `addAlternativeBranch`), not a plain
  // linear step. Forking it would silently strip every alternative arm (each
  // arm is a `single` out of the anchor) down to the fork's sole exit,
  // destroying the alt-divergence the user built. Rather than do that, bail
  // out safely and leave the chart unchanged — mirrors the `join == null`
  // no-op guard in `deleteParallelBranch`. A single (or zero) successor is not
  // an alt-divergence and still forks as before.
  final singleOutCount = p.sfcTransitions
      .where((t) => t.kind == 'single' && t.fromStepId == afterStepId)
      .length;
  if (singleOutCount >= 2) {
    return null;
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

  // Safety guard: `_joinForFork` can fail to identify the fork's own outer
  // join when EVERY OTHER branch of this fork is itself nested (none of them
  // is left as a plain, directly-listed join tail for the heuristic to find).
  // In that shape `join == null` does NOT mean "this fork has no join" — the
  // join still exists in the model, we simply cannot reliably tell which one
  // it is. Proceeding with a null join would let `_branchSubgraph` cross ANY
  // join it meets (including the real outer one) and sweep its after-step and
  // everything downstream into the delete set, while stranding the surviving
  // sibling branch. Rather than risk that corruption, bail out safely and
  // leave the chart unchanged — the caller can retry after disambiguating
  // (e.g. deleting the nested branches first).
  if (join == null) {
    return;
  }

  // Gather the ENTIRE branch subgraph (crossing any nested fork/join) so nested
  // structure is removed cleanly instead of orphaned.
  final branchSteps = _branchSubgraph(p, join, branchHeadId);

  // The branch's tail into the OUTER join is the one join tail that lives inside
  // the branch subgraph (may sit past a nested join, e.g. a nested join's
  // after-step) — NOT necessarily the branch head.
  String? branchOuterTail;
  for (final id in join.fromStepIds) {
    if (branchSteps.contains(id)) {
      branchOuterTail = id;
      break;
    }
  }

  // Detach the branch from the fork / join sets. Removing the branch's OUTER
  // tail (not merely its head) keeps join.fromStepIds consistent.
  fork.toStepIds.remove(branchHeadId);
  if (branchOuterTail != null) {
    join.fromStepIds.remove(branchOuterTail);
  }

  // Remove every transition internal to the branch (singles, nested forks and
  // nested joins), keeping the outer fork/join which are handled explicitly.
  p.sfcTransitions.removeWhere((t) {
    if (t.id == fork.id || t.id == join.id) {
      return false;
    }
    switch (t.kind) {
      case 'single':
        return branchSteps.contains(t.fromStepId) ||
            branchSteps.contains(t.toStepId);
      case 'parallelFork':
        return branchSteps.contains(t.fromStepId);
      case 'parallelJoin':
        return branchSteps.contains(t.toStepId) ||
            t.fromStepIds.any(branchSteps.contains);
      default:
        return false;
    }
  });

  // Remove the branch's steps.
  p.sfcSteps.removeWhere((s) => branchSteps.contains(s.id));

  // Collapse when the fork can no longer diverge.
  if (fork.toStepIds.length <= 1) {
    final anchor = fork.fromStepId;
    final afterId = join.toStepId;
    final survivorHead = fork.toStepIds.isNotEmpty ? fork.toStepIds.first : null;
    final survivorTail =
        join.fromStepIds.isNotEmpty ? join.fromStepIds.first : survivorHead;

    p.sfcTransitions.removeWhere((t) => t.id == fork.id);
    p.sfcTransitions.removeWhere((t) => t.id == join.id);

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

/// Deletes [stepId] with collapse-aware cleanup:
/// - If the step OWNS an outgoing `parallelFork` (it is a fork SOURCE), the
///   entire parallel construct is removed with it — the fork, every branch's
///   full subgraph, and the paired join — since deleting the source makes the
///   whole construct unreachable; leaving any of it behind would orphan it.
/// - Else if the step is the HEAD of a parallel branch, the whole branch is
///   removed (collapsing the fork/join when only one branch remains).
/// - Otherwise a plain [deleteSfcStep].
void deleteSfcStepStructured(PlcProgram p, String stepId) {
  final ownFork =
      p.sfcTransitions.where((t) => t.kind == 'parallelFork' && t.fromStepId == stepId);
  if (ownFork.isNotEmpty) {
    final fork = ownFork.first;
    final join = _joinForFork(p, fork);
    // Safety guard: mirrors `deleteParallelBranch`'s `join == null` no-op — if
    // the paired join cannot be reliably identified, sweeping the branch
    // subgraphs with a null join would let `_branchSubgraph` cross ANY join it
    // meets and over-delete. Degrade safely: fall through to the ordinary
    // structured delete instead of corrupting the chart.
    if (join != null) {
      final removeSteps = <String>{};
      for (final head in fork.toStepIds) {
        removeSteps.addAll(_branchSubgraph(p, join, head));
      }
      final wasInitial = p.sfcSteps.any((s) => s.id == stepId && s.isInitial);

      // Remove the fork, the join, and every transition internal to any
      // branch (singles, nested forks, nested joins). Nothing is reconnected —
      // the source step itself is being deleted, so the whole construct simply
      // goes away.
      p.sfcTransitions.removeWhere((t) {
        if (t.id == fork.id || t.id == join.id) {
          return true;
        }
        switch (t.kind) {
          case 'single':
            return removeSteps.contains(t.fromStepId) || removeSteps.contains(t.toStepId);
          case 'parallelFork':
            return removeSteps.contains(t.fromStepId);
          case 'parallelJoin':
            return removeSteps.contains(t.toStepId) || t.fromStepIds.any(removeSteps.contains);
          default:
            return false;
        }
      });

      p.sfcSteps.removeWhere((s) => s.id == stepId || removeSteps.contains(s.id));

      if (wasInitial && p.sfcSteps.isNotEmpty && !p.sfcSteps.any((s) => s.isInitial)) {
        p.sfcSteps.first.isInitial = true;
      }
      return;
    }
  }

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
