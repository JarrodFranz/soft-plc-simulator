import 'project_model.dart';
import 'st_expr.dart';
import 'tag_resolver.dart';

/// Active-step state per SFC program, keyed by program name.
class SfcRuntime {
  final Map<String, String> activeStepId = {};
  final Map<String, int> stepElapsedMs = {};
  void clear() {
    activeStepId.clear();
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

/// Executes every SequentialFunctionChart program: the active step's action
/// runs each scan (N semantics), STEP_T accumulates by scan ticks, and the
/// first true outgoing transition (list order) switches the active step —
/// the new step acts from the next scan.
void executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt, {Set<String>? only, Set<String>? readOnly}) {
  for (final prog in p.programs) {
    if (prog.language != 'SequentialFunctionChart' || prog.sfcSteps.isEmpty) {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    // Resolve (or initialize) the active step.
    SfcStep? active;
    final currentId = rt.activeStepId[prog.name];
    if (currentId != null) {
      for (final s in prog.sfcSteps) {
        if (s.id == currentId) {
          active = s;
          break;
        }
      }
    }
    if (active == null) {
      for (final s in prog.sfcSteps) {
        if (s.isInitial) {
          active = s;
          break;
        }
      }
      active ??= prog.sfcSteps.first;
      rt.activeStepId[prog.name] = active.id;
      rt.stepElapsedMs[prog.name] = 0;
    }

    final elapsed = (rt.stepElapsedMs[prog.name] ?? 0) + dtMs;
    rt.stepElapsedMs[prog.name] = elapsed;
    final vars = {'STEP_T': elapsed};

    // N-action: every scan while the step is active.
    runStatements(p, active.actionSt, (path, v) {
      if (readOnly == null || !readOnly.contains(path)) {
        _forceAwareWrite(p, path, v);
      }
    },
        extraVars: vars);

    // First true outgoing transition switches the step (effective next scan).
    for (final t in prog.sfcTransitions) {
      if (t.fromStepId != active.id) {
        continue;
      }
      if (evalStCondition(p, t.conditionSt, extraVars: vars)) {
        final targetExists = prog.sfcSteps.any((s) => s.id == t.toStepId);
        if (targetExists) {
          rt.activeStepId[prog.name] = t.toStepId;
          rt.stepElapsedMs[prog.name] = 0;
          break;
        }
        // Dangling target (no such step): ignore this transition and keep
        // evaluating later ones, rather than stranding the step for the scan.
      }
    }
  }
}
