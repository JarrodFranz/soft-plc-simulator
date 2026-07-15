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
