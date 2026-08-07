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

  // Covers `runScanTick`'s production `executeLdPrograms(..., fbdRt: rt.fbd)`
  // forward — the one link in the FBD-runtime chain that no engine-level test
  // reaches. A LadderLogic rung calls an FBD-bodied AOI whose body holds a
  // TON; the timer's accumulator lives in the FbdRuntime, so it only survives
  // the scan boundary if the shell hands the LD engine the SAME `rt.fbd` the
  // FBD engine uses. Drop that argument and the TON restarts every tick, so
  // `Dst` never latches.
  test('runScanTick shares its FbdRuntime with the LD engine: an FBD-bodied '
      'AOI called from a ladder rung keeps its timer state across ticks', () {
    final fb = FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'pt', fromPin: 'OUT', toBlockId: 'ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'ton', fromPin: 'Q', toBlockId: 'to', toPin: 'IN'),
    ]);
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [fb]);

    final prog = PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [
      LdRung(rungIndex: 0, nodes: [
        LdNode(id: 'L', kind: LdKind.leftRail),
        LdNode(id: 'b', kind: LdKind.block, blockType: 'Ramp', variable: 'R1',
            pinBindings: {'In': 'Src', 'Out': 'Dst'}),
        LdNode(id: 'R', kind: LdKind.rightRail),
      ], wires: [
        LdWire(fromId: 'L', toId: 'b'),
        LdWire(fromId: 'b', toId: 'R'),
      ]),
    ]);
    final p = PlcProject(
      id: 'x', name: 'x', controllerName: 'C',
      tags: [
        PlcTag(name: 'Src', path: 'Src', dataType: 'BOOL', value: true, ioType: 'Internal'),
        PlcTag(name: 'Dst', path: 'Dst', dataType: 'BOOL', value: false, ioType: 'Internal'),
        PlcTag(name: 'R1', path: 'R1', dataType: 'Ramp',
            value: defaultValueFor(defaults, 'Ramp', 0), ioType: 'Internal'),
      ],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb],
    );
    p.tasks.add(PlcTask(name: 'Main', type: 'Continuous', programNames: ['Main']));

    final rt = ScanTickRuntime();
    runScanTick(p, 500, rt);
    expect(readPath(p, 'Dst'), isFalse); // ET 500 < PT 1000
    runScanTick(p, 500, rt);
    expect(readPath(p, 'Dst'), isTrue); // ET accumulated across the scan boundary
  });
}
