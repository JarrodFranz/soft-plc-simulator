import '../models/project_model.dart';
import '../models/sim_engine.dart';
import '../models/signal_engine.dart';
import '../models/ld_exec.dart';
import '../models/ld_monitor.dart';
import '../models/fbd_exec.dart';
import '../models/sfc_exec.dart';
import '../models/st_exec.dart';
import '../models/task_scheduler.dart';
import '../models/tag_resolver.dart';

/// Holds the engine runtimes + scheduler state across ticks (owned by the shell).
class ScanTickRuntime {
  final SimRuntime sim = SimRuntime();
  final LdExecRuntime ld = LdExecRuntime();
  final LdMonitor ldMonitor = LdMonitor();
  final FbdRuntime fbd = FbdRuntime();
  final SfcRuntime sfc = SfcRuntime();
  final StRuntime st = StRuntime();
  final TaskSchedulerRuntime scheduler = TaskSchedulerRuntime();
  final SignalRuntime signal = SignalRuntime();

  /// When >= 0, used instead of a real Stopwatch as the measured per-task
  /// execution time (ms). Test-only; production leaves it at -1.
  int elapsedForTest = -1;

  void resetSession() {
    sim.byRuleId.clear();
    ld.clear();
    ldMonitor.clear();
    fbd.clear();
    sfc.clear();
    st.clear();
    scheduler.reset();
    signal.reset();
  }
}

/// Result of one scan tick: whether a watchdog faulted, and first-scan flag.
class ScanTickResult {
  final bool firstScan;
  final bool faulted;
  final String faultTask;
  final int faultCode;
  const ScanTickResult({
    required this.firstScan,
    required this.faulted,
    required this.faultTask,
    required this.faultCode,
  });
}

/// One scan: sim rules (always), then due tasks in priority order with per-task
/// watchdog timing. Stops at the first watchdog trip. Pure w.r.t. wall-clock
/// (timing is measured with a Stopwatch here, or overridden for tests).
ScanTickResult runScanTick(PlcProject p, int dtMs, ScanTickRuntime rt) {
  final firstScan = !rt.scheduler.startupFired;
  applySimRules(p, p.simRules, dtMs, rt.sim);

  applySignalGens(p, p.signalGens, dtMs, rt.signal);
  final readOnly = generatedPaths(p.signalGens);

  final due = scheduleTick(
    p.tasks,
    dtMs,
    rt.scheduler,
    (path) => readPath(p, path) == true,
  );

  for (final task in due) {
    final only = task.programs.toSet();
    final sw = Stopwatch()..start();
    executeLdPrograms(p, dtMs, rt.ld, only: only, readOnly: readOnly, monitor: rt.ldMonitor);
    executeFbdPrograms(p, dtMs, rt.fbd, only: only, readOnly: readOnly);
    executeSfcPrograms(p, dtMs, rt.sfc, only: only, readOnly: readOnly);
    executeStPrograms(p, dtMs, rt.st, only: only, readOnly: readOnly);
    sw.stop();
    final elapsed = rt.elapsedForTest >= 0 ? rt.elapsedForTest : sw.elapsedMilliseconds;
    if (task.watchdogMs > 0 && elapsed > task.watchdogMs) {
      return ScanTickResult(
        firstScan: firstScan, faulted: true, faultTask: task.taskName, faultCode: 1);
    }
  }
  return ScanTickResult(
    firstScan: firstScan, faulted: false, faultTask: '', faultCode: 0);
}
