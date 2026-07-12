import 'project_model.dart';
import 'tag_resolver.dart';

const String kSystemTagName = 'System';
const String kSystemTypeName = 'SYSTEM';

/// A snapshot of PLC status the shell computes each scan and writes into the
/// reserved `System` tag. Pure data; the shell supplies the clock/timers.
class SystemSnapshot {
  final bool fault;
  final String faultTask;
  final int faultCode;
  final bool running;
  final bool firstScan;
  final int scanCount;
  final double scanTimeMs;
  final double maxScanTimeMs;
  final double minScanTimeMs;
  final bool freeRun;
  final int uptimeMs;
  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final String dateTime;

  const SystemSnapshot({
    required this.fault,
    required this.faultTask,
    required this.faultCode,
    required this.running,
    required this.firstScan,
    required this.scanCount,
    required this.scanTimeMs,
    required this.maxScanTimeMs,
    required this.minScanTimeMs,
    required this.freeRun,
    required this.uptimeMs,
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    required this.dateTime,
  });
}

PlcTag? _systemTag(PlcProject p) {
  for (final t in p.tags) {
    if (t.name == kSystemTagName) {
      return t;
    }
  }
  return null;
}

/// Inject the reserved `System` tag if absent; otherwise coerce its type and
/// back-fill any missing fields without clobbering existing values.
void ensureSystemTag(PlcProject p) {
  final comp = lookupComposite(p, kSystemTypeName);
  if (comp == null) {
    return; // SYSTEM built-in missing (should never happen)
  }
  var tag = _systemTag(p);
  if (tag == null) {
    tag = PlcTag(
      name: kSystemTagName,
      path: kSystemTagName,
      dataType: kSystemTypeName,
      value: defaultValueFor(p, kSystemTypeName, 0),
      ioType: 'Internal',
      access: 'ReadOnly',
      description: 'SoftPLC system status (read-only; AlarmReset writable)',
    );
    p.tags.add(tag);
    return;
  }
  tag.dataType = kSystemTypeName;
  if (tag.value is! Map) {
    tag.value = <String, dynamic>{};
  }
  final m = tag.value as Map;
  for (final f in comp.fields) {
    if (!m.containsKey(f.name)) {
      m[f.name] = f.defaultValue;
    }
  }
}

/// Write the status fields (leaves control fields like AlarmReset untouched).
void updateSystemStatus(PlcProject p, SystemSnapshot s) {
  ensureSystemTag(p);
  writePath(p, 'System.Fault', s.fault);
  writePath(p, 'System.FaultTask', s.faultTask);
  writePath(p, 'System.FaultCode', s.faultCode);
  writePath(p, 'System.Running', s.running);
  writePath(p, 'System.FirstScan', s.firstScan);
  writePath(p, 'System.ScanCount', s.scanCount);
  writePath(p, 'System.ScanTimeMs', s.scanTimeMs);
  writePath(p, 'System.MaxScanTimeMs', s.maxScanTimeMs);
  writePath(p, 'System.MinScanTimeMs', s.minScanTimeMs);
  writePath(p, 'System.FreeRun', s.freeRun);
  writePath(p, 'System.UptimeMs', s.uptimeMs);
  writePath(p, 'System.Year', s.year);
  writePath(p, 'System.Month', s.month);
  writePath(p, 'System.Day', s.day);
  writePath(p, 'System.Hour', s.hour);
  writePath(p, 'System.Minute', s.minute);
  writePath(p, 'System.Second', s.second);
  writePath(p, 'System.DateTime', s.dateTime);
}

/// If `System.AlarmReset` is set, clear it and return true (one-shot). Level +
/// self-clear gives the same observable effect as a rising edge: each set
/// triggers exactly one reset.
bool consumeAlarmReset(PlcProject p) {
  ensureSystemTag(p);
  if (readPath(p, 'System.AlarmReset') == true) {
    writePath(p, 'System.AlarmReset', false);
    return true;
  }
  return false;
}
