import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/scan_tick.dart';

void main() {
  test('runScanTick runs only due programs and reports timing/first-scan', () {
    final p = PlcProject(
      id: 'x', name: 'x', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    p.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: false, ioType: 'Internal'));
    p.tags.add(PlcTag(name: 'Btn', path: 'Btn', dataType: 'BOOL', value: false, ioType: 'Internal'));
    p.programs.add(PlcProgram(name: 'Boot', language: 'StructuredText', stSource: 'A := TRUE;'));
    p.tasks.add(PlcTask(name: 'BootTask', type: 'Startup', programNames: ['Boot']));
    p.tasks.add(PlcTask(name: 'Main', type: 'Continuous', programNames: ['Boot']));

    final rt = ScanTickRuntime();
    // First tick: firstScan true, Boot runs (startup), A set.
    final r1 = runScanTick(p, 100, rt);
    expect(r1.firstScan, isTrue);
    expect(readPath(p, 'A'), true);
    expect(r1.faulted, isFalse);

    // Second tick: firstScan false.
    final r2 = runScanTick(p, 100, rt);
    expect(r2.firstScan, isFalse);
  });

  test('runScanTick faults when a task exceeds its watchdog', () {
    final p = PlcProject(
      id: 'x', name: 'x', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    p.programs.add(PlcProgram(name: 'Slow', language: 'StructuredText', stSource: '// nop'));
    // watchdogMs of 0 = disabled; use a negative sentinel budget to force a trip
    // deterministically via the injectable clock in ScanTickRuntime (see impl).
    p.tasks.add(PlcTask(name: 'SlowTask', type: 'Continuous', programNames: ['Slow'], watchdogMs: 1));
    final rt = ScanTickRuntime()..elapsedForTest = 5; // 5ms measured > 1ms budget
    final r = runScanTick(p, 100, rt);
    expect(r.faulted, isTrue);
    expect(r.faultTask, 'SlowTask');
    expect(r.faultCode, 1);
  });
}
