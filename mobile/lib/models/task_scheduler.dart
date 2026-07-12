import 'project_model.dart';

/// One task that is due to run this scan tick, with its already-deduped,
/// ordered program list (programs claimed by a higher-priority due task in the
/// same tick are removed) and its watchdog budget.
class DueTask {
  final String taskName;
  final int watchdogMs;
  final List<String> programs;
  DueTask({required this.taskName, required this.watchdogMs, required this.programs});
}

/// Per-run-session scheduler state. Reset at run-session boundaries (Run
/// pressed from stopped, project switch).
class TaskSchedulerRuntime {
  bool startupFired = false;
  final Map<String, int> periodicAccumMs = {};
  final Map<String, bool> eventPrevTrigger = {};

  void reset() {
    startupFired = false;
    periodicAccumMs.clear();
    eventPrevTrigger.clear();
  }
}

/// Priority order: Startup > Event > Periodic > Continuous.
const List<String> _priority = ['Startup', 'Event', 'Periodic', 'Continuous'];

/// Decide which tasks are due this tick, in priority order, with per-task
/// deduped program lists. Pure + deterministic: all time enters via [dtMs];
/// [boolLookup] returns the current BOOL value of an Event task's trigger tag
/// (false for unknown / non-BOOL paths). Advances [rt] (startup flag, periodic
/// accumulators, event edge memory) as a side effect.
List<DueTask> scheduleTick(
  List<PlcTask> tasks,
  int dtMs,
  TaskSchedulerRuntime rt,
  bool Function(String path) boolLookup,
) {
  final isFirstScan = !rt.startupFired;

  // Periodic accumulation (enabled periodic tasks only). Fires at most once per
  // tick; carries the remainder, clamped so a task that cannot keep up does not
  // accumulate unbounded time.
  final periodicDue = <String, bool>{};
  for (final t in tasks) {
    if (!t.enabled || t.type != 'Periodic') {
      continue;
    }
    final acc = (rt.periodicAccumMs[t.name] ?? 0) + dtMs;
    final due = t.periodMs <= 0 ? true : acc >= t.periodMs;
    periodicDue[t.name] = due;
    var next = due ? (t.periodMs <= 0 ? 0 : acc - t.periodMs) : acc;
    if (t.periodMs > 0 && next > t.periodMs) {
      next = t.periodMs;
    }
    rt.periodicAccumMs[t.name] = next;
  }

  bool dueStartup(PlcTask t) => t.type == 'Startup' && isFirstScan;
  bool dueEvent(PlcTask t) {
    if (t.type != 'Event') {
      return false;
    }
    final now = boolLookup(t.triggerTag);
    final prev = rt.eventPrevTrigger[t.name] ?? false;
    return now && !prev;
  }

  final anyHigherDue = tasks.any((t) =>
      t.enabled &&
      (dueStartup(t) || dueEvent(t) || (periodicDue[t.name] ?? false)));

  bool isDue(PlcTask t) {
    switch (t.type) {
      case 'Startup':
        return dueStartup(t);
      case 'Event':
        return dueEvent(t);
      case 'Periodic':
        return periodicDue[t.name] ?? false;
      case 'Continuous':
        return !anyHigherDue;
      default:
        return false;
    }
  }

  final claimed = <String>{};
  final out = <DueTask>[];
  for (final type in _priority) {
    for (final t in tasks) {
      if (!t.enabled || t.type != type || !isDue(t)) {
        continue;
      }
      final progs = <String>[];
      for (final pn in t.programNames) {
        if (claimed.add(pn)) {
          progs.add(pn);
        }
      }
      if (progs.isNotEmpty) {
        out.add(DueTask(taskName: t.name, watchdogMs: t.watchdogMs, programs: progs));
      }
    }
  }

  // Advance edge memory for all Event tasks (even not-due / disabled), so a
  // re-enabled task detects a fresh edge rather than a stale one.
  for (final t in tasks) {
    if (t.type == 'Event') {
      rt.eventPrevTrigger[t.name] = boolLookup(t.triggerTag);
    }
  }
  rt.startupFired = true;
  return out;
}
