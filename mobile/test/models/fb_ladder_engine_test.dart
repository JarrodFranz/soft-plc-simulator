// Engine threading: both engines hand their real dtMs + LdExecRuntime to a
// ladder-bodied FB, so an FB-local TON accumulates across scans instead of
// restarting every scan.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/scan_tick.dart';

/// Ladder-bodied on-delay FB with an instance-local TIMER var.
FbDefinition _delayFb() => FbDefinition(name: 'Delay', vars: [
      FbVar(name: 'Run', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'T', dataType: 'TIMER', direction: FbVarDir.internal),
      FbVar(name: 'Done', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Run'),
        LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 300),
        LdNode(id: '', kind: LdKind.coil, variable: 'Done'),
      ]),
    ]);

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

Map<String, dynamic> _instanceValue(FbDefinition fb) {
  final defaults = PlcProject(id: 'd', name: 'd', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
  return Map<String, dynamic>.from(defaultValueFor(defaults, fb.name, 0) as Map);
}

void main() {
  test('an LD program calling a ladder FB threads dtMs + runtime into the body', () {
    final fb = _delayFb();
    final prog = PlcProgram(name: 'P1', language: 'LadderLogic', rungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Start'),
        LdNode(id: '', kind: LdKind.block, blockType: 'Delay', variable: 'D1',
            pinBindings: {'Run': 'Start', 'Done': 'Lamp'}),
      ]),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Start', 'BOOL', true),
          _tag('Lamp', 'BOOL', false),
          _tag('D1', 'Delay', _instanceValue(fb)),
        ],
        structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb]);

    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'D1.T.ACC'), 100); // NOT restarted at 0 each scan
    executeLdPrograms(p, 100, rt);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'D1.T.ACC'), 300);
    expect(readPath(p, 'D1.Done'), isTrue);
    expect(readPath(p, 'Lamp'), isTrue); // output pin written back out
  });

  test('an FBD program calling a ladder FB threads dtMs + the supplied ldRt', () {
    final fb = _delayFb();
    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: '', tagBinding: 'Start'),
      FbdBlock(id: 'd1', type: 'Delay', title: '', tagBinding: 'D1'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: '', tagBinding: 'Lamp'),
    ]);
    prog.fbdWires.addAll([
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'd1', toPin: 'Run'),
      FbdWire(fromBlockId: 'd1', fromPin: 'Done', toBlockId: 'to', toPin: 'IN'),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Start', 'BOOL', true),
          _tag('Lamp', 'BOOL', false),
          _tag('D1', 'Delay', _instanceValue(fb)),
        ],
        structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb]);

    final fbdRt = FbdRuntime();
    final ldRt = LdExecRuntime();
    executeFbdPrograms(p, 100, fbdRt, ldRt: ldRt);
    executeFbdPrograms(p, 100, fbdRt, ldRt: ldRt);
    expect(readPath(p, 'D1.T.ACC'), 200);
    expect(readPath(p, 'D1.Done'), isFalse);
    executeFbdPrograms(p, 100, fbdRt, ldRt: ldRt);
    expect(readPath(p, 'D1.Done'), isTrue);
    expect(readPath(p, 'Lamp'), isTrue);
  });

  test('executeFbdPrograms without ldRt still runs the ladder body (never-throws)', () {
    final fb = _delayFb();
    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: '', tagBinding: 'Start'),
      FbdBlock(id: 'd1', type: 'Delay', title: '', tagBinding: 'D1'),
    ]);
    prog.fbdWires.add(FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'd1', toPin: 'Run'));
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [_tag('Start', 'BOOL', true), _tag('D1', 'Delay', _instanceValue(fb))],
        structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb]);

    expect(() => executeFbdPrograms(p, 100, FbdRuntime()), returnsNormally);
    expect(readPath(p, 'D1.T.ACC'), 100);
  });

  test('runScanTick drives an FBD-hosted ladder FB timer across ticks', () {
    final fb = _delayFb();
    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: '', tagBinding: 'Start'),
      FbdBlock(id: 'd1', type: 'Delay', title: '', tagBinding: 'D1'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: '', tagBinding: 'Lamp'),
    ]);
    prog.fbdWires.addAll([
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'd1', toPin: 'Run'),
      FbdWire(fromBlockId: 'd1', fromPin: 'Done', toBlockId: 'to', toPin: 'IN'),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Start', 'BOOL', true),
          _tag('Lamp', 'BOOL', false),
          _tag('D1', 'Delay', _instanceValue(fb)),
        ],
        structDefs: [], programs: [prog],
        tasks: [PlcTask(name: 'Main', type: 'Continuous', programNames: ['F1'])],
        hmis: [], fbDefinitions: [fb]);

    final rt = ScanTickRuntime();
    runScanTick(p, 150, rt);
    runScanTick(p, 150, rt);
    expect(readPath(p, 'D1.T.ACC'), 300);
    expect(readPath(p, 'Lamp'), isTrue);
  });
}
