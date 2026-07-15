import 'project_model.dart';
import 'st_expr.dart';
import 'tag_resolver.dart';

/// Active-step state per SFC program, keyed by program name.
class SfcRuntime {
  final Map<String, Set<String>> active = {}; // progName -> active step ids
  final Map<String, int> stepElapsedMs = {}; // '<prog>|<stepId>' -> STEP_T ms
  void clear() {
    active.clear();
    stepElapsedMs.clear();
  }
}

PlcTag? _rootTagOf(PlcProject p, String path) {
  final rootName = path.split('.').first.split('[').first;
  for (final t in p.tags) {
    if (t.name == rootName) {
      return t;
    }
  }
  return null;
}

void _forceAwareWrite(PlcProject p, String path, dynamic value) {
  final root = _rootTagOf(p, path);
  if (root != null && root.isForced && root.name == path) {
    return; // forcing wins
  }
  writePath(p, path, value);
}

/// Executes every SequentialFunctionChart program: every active step's
/// action runs each scan (N semantics), STEP_T accumulates by scan ticks
/// per-step, and transitions fire against a start-of-scan snapshot of the
/// active set — first-true wins for alternative divergences, fork
/// transitions activate all branch heads at once, and join transitions wait
/// until every source step is active before firing. Newly activated steps
/// act starting next scan.
void executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt, {Set<String>? only, Set<String>? readOnly}) {
  for (final prog in p.programs) {
    if (prog.language != 'SequentialFunctionChart' || prog.sfcSteps.isEmpty) {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    SfcStep? stepById(String id) {
      for (final s in prog.sfcSteps) {
        if (s.id == id) {
          return s;
        }
      }
      return null;
    }

    // Init the active set (initial step, else first).
    var activeSet = rt.active[prog.name];
    if (activeSet == null || activeSet.isEmpty) {
      final initial = prog.sfcSteps.firstWhere((s) => s.isInitial, orElse: () => prog.sfcSteps.first);
      activeSet = {initial.id};
      rt.active[prog.name] = activeSet;
      rt.stepElapsedMs['${prog.name}|${initial.id}'] = 0;
    }

    // Advance elapsed + run actions for each active step.
    for (final id in activeSet) {
      final key = '${prog.name}|$id';
      final elapsed = (rt.stepElapsedMs[key] ?? 0) + dtMs;
      rt.stepElapsedMs[key] = elapsed;
      final step = stepById(id);
      if (step != null) {
        runStatements(p, step.actionSt, (path, v) {
          if (readOnly == null || !readOnly.contains(path)) {
            _forceAwareWrite(p, path, v);
          }
        }, extraVars: {'STEP_T': elapsed});
      }
    }

    // Compute firings against the START-OF-SCAN snapshot.
    final snapshot = Set<String>.from(activeSet);
    final consumed = <String>{};
    final toAdd = <String>{};
    for (final t in prog.sfcTransitions) {
      // sources / eligibility per kind
      List<String> sources;
      List<String> targets;
      if (t.kind == 'parallelFork') {
        sources = [t.fromStepId];
        targets = t.toStepIds;
      } else if (t.kind == 'parallelJoin') {
        sources = t.fromStepIds;
        targets = [t.toStepId];
      } else {
        sources = [t.fromStepId];
        targets = [t.toStepId];
      }
      // eligible iff all sources are in the snapshot and none already consumed
      final eligible = sources.isNotEmpty &&
          sources.every((s) => snapshot.contains(s)) &&
          sources.every((s) => !consumed.contains(s));
      if (!eligible) {
        continue;
      }
      final elapsed = rt.stepElapsedMs['${prog.name}|${sources.first}'] ?? 0;
      if (!evalStCondition(p, t.conditionSt, extraVars: {'STEP_T': elapsed})) {
        continue;
      }
      // A transition whose target(s) are entirely dangling (no such step)
      // must not strand the chart: skip it and keep evaluating later
      // transitions this scan, rather than consuming its sources for nothing.
      final validTargets = targets.where((tgt) => stepById(tgt) != null).toList();
      if (validTargets.isEmpty) {
        continue;
      }
      // commit
      consumed.addAll(sources);
      toAdd.addAll(validTargets);
    }

    // Apply.
    final next = Set<String>.from(activeSet)
      ..removeAll(consumed)
      ..addAll(toAdd);
    for (final id in toAdd) {
      if (!activeSet.contains(id)) {
        rt.stepElapsedMs['${prog.name}|$id'] = 0; // (re)activated -> reset STEP_T
      }
    }
    rt.active[prog.name] = next;
  }
}
