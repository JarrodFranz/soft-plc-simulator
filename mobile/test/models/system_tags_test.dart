import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _proj() => PlcProject(
      id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: const [], programs: const [], tasks: const [], hmis: const [],
    );

void main() {
  test('ensureSystemTag injects a reserved System tag when absent', () {
    final p = _proj();
    expect(p.tags.any((t) => t.name == 'System'), isFalse);
    ensureSystemTag(p);
    final sys = p.tags.firstWhere((t) => t.name == 'System');
    expect(sys.dataType, 'SYSTEM');
    expect(readPath(p, 'System.Fault'), false);
    expect(readPath(p, 'System.AlarmReset'), false);
    expect(readPath(p, 'System.Hour'), 0);
    expect(readPath(p, 'System.DateTime'), '');
  });

  test('ensureSystemTag back-fills missing fields, keeps existing values', () {
    final p = _proj();
    // Simulate a legacy System tag missing newer fields but with a set value.
    p.tags.add(PlcTag(
      name: 'System', path: 'System', dataType: 'SYSTEM',
      value: <String, dynamic>{'ScanCount': 7}, ioType: 'Internal',
    ));
    ensureSystemTag(p);
    expect(readPath(p, 'System.ScanCount'), 7); // preserved
    expect(readPath(p, 'System.Fault'), false); // back-filled
    expect(p.tags.where((t) => t.name == 'System').length, 1); // no duplicate
  });

  test('updateSystemStatus writes status fields incl. wall clock', () {
    final p = _proj();
    ensureSystemTag(p);
    updateSystemStatus(p, const SystemSnapshot(
      fault: true, faultTask: 'PumpTask', faultCode: 1,
      running: true, firstScan: false, scanCount: 12,
      scanTimeMs: 3.5, maxScanTimeMs: 9.0, minScanTimeMs: 1.0,
      freeRun: true, uptimeMs: 4200,
      year: 2026, month: 7, day: 13, hour: 14, minute: 5, second: 32,
      dateTime: '2026-07-13 14:05:32',
    ));
    expect(readPath(p, 'System.Fault'), true);
    expect(readPath(p, 'System.FaultTask'), 'PumpTask');
    expect(readPath(p, 'System.FaultCode'), 1);
    expect(readPath(p, 'System.ScanCount'), 12);
    expect(readPath(p, 'System.FreeRun'), true);
    expect(readPath(p, 'System.UptimeMs'), 4200);
    expect(readPath(p, 'System.Hour'), 14);
    expect(readPath(p, 'System.DateTime'), '2026-07-13 14:05:32');
  });

  test('consumeAlarmReset returns true + self-clears only when set', () {
    final p = _proj();
    ensureSystemTag(p);
    expect(consumeAlarmReset(p), isFalse); // default false
    writePath(p, 'System.AlarmReset', true);
    expect(consumeAlarmReset(p), isTrue);
    expect(readPath(p, 'System.AlarmReset'), false); // self-cleared
    expect(consumeAlarmReset(p), isFalse); // stays cleared
  });
}
