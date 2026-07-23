import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/fbd_monitor.dart';

PlcProject _proj(List<FbdBlock> blocks, List<FbdWire> wires, int networks) {
  final prog = PlcProgram(
    name: 'F', language: 'FunctionBlockDiagram', rungs: [],
    fbdBlocks: blocks, fbdWires: wires,
    fbdNetworks: [for (var i = 0; i < networks; i++) FbdNetwork()],
  );
  return PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [
      PlcTag(name: 'Src', path: 'Src', dataType: 'FLOAT64', value: 10.0, ioType: 'Internal'),
      PlcTag(name: 'Mid', path: 'Mid', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
      PlcTag(name: 'Out', path: 'Out', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    ],
    structDefs: [], programs: [prog], tasks: [], hmis: [],
  );
}

void main() {
  test('networks execute in order: producer(net0) feeds consumer(net1) via tags',
      () {
    // net0: Src(+5 via ADD const) -> Mid ; net1: Mid(+5) -> Out. Out should be 20.
    final blocks = [
      FbdBlock(id: 'in0', type: 'TAG_INPUT', title: '', tagBinding: 'Src', network: 0),
      FbdBlock(id: 'c0', type: 'CONST', title: '', tagBinding: '5', network: 0),
      FbdBlock(id: 'add0', type: 'ADD', title: '', network: 0),
      FbdBlock(id: 'out0', type: 'TAG_OUTPUT', title: '', tagBinding: 'Mid', network: 0),
      FbdBlock(id: 'in1', type: 'TAG_INPUT', title: '', tagBinding: 'Mid', network: 1),
      FbdBlock(id: 'c1', type: 'CONST', title: '', tagBinding: '5', network: 1),
      FbdBlock(id: 'add1', type: 'ADD', title: '', network: 1),
      FbdBlock(id: 'out1', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out', network: 1),
    ];
    final wires = [
      FbdWire(fromBlockId: 'in0', toBlockId: 'add0', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c0', toBlockId: 'add0', toPin: 'IN2'),
      FbdWire(fromBlockId: 'add0', toBlockId: 'out0'),
      FbdWire(fromBlockId: 'in1', toBlockId: 'add1', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c1', toBlockId: 'add1', toPin: 'IN2'),
      FbdWire(fromBlockId: 'add1', toBlockId: 'out1'),
    ];
    final proj = _proj(blocks, wires, 2);
    final rt = FbdRuntime();
    final mon = FbdMonitor();
    executeFbdPrograms(proj, 100, rt, monitor: mon);
    expect(proj.tags.firstWhere((t) => t.name == 'Out').value, 20.0);
    // monitor captured the net0 ADD output pin
    expect(mon.pinValue[mon.keyFor('F', 'add0', 'OUT')], 15.0);
  });

  test('reversed network indices: consumer runs before producer, so first scan sees stale value',
      () {
    // net0 is now the CONSUMER (Mid -> Out), net1 is the PRODUCER (Src -> Mid).
    // Since networks execute ascending (net0 before net1), net0 reads Mid's
    // pre-scan value (0.0) rather than the value net1 is about to produce.
    final blocks = [
      FbdBlock(id: 'in1', type: 'TAG_INPUT', title: '', tagBinding: 'Mid', network: 0),
      FbdBlock(id: 'c1', type: 'CONST', title: '', tagBinding: '5', network: 0),
      FbdBlock(id: 'add1', type: 'ADD', title: '', network: 0),
      FbdBlock(id: 'out1', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out', network: 0),
      FbdBlock(id: 'in0', type: 'TAG_INPUT', title: '', tagBinding: 'Src', network: 1),
      FbdBlock(id: 'c0', type: 'CONST', title: '', tagBinding: '5', network: 1),
      FbdBlock(id: 'add0', type: 'ADD', title: '', network: 1),
      FbdBlock(id: 'out0', type: 'TAG_OUTPUT', title: '', tagBinding: 'Mid', network: 1),
    ];
    final wires = [
      FbdWire(fromBlockId: 'in1', toBlockId: 'add1', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c1', toBlockId: 'add1', toPin: 'IN2'),
      FbdWire(fromBlockId: 'add1', toBlockId: 'out1'),
      FbdWire(fromBlockId: 'in0', toBlockId: 'add0', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c0', toBlockId: 'add0', toPin: 'IN2'),
      FbdWire(fromBlockId: 'add0', toBlockId: 'out0'),
    ];
    final proj = _proj(blocks, wires, 2);
    final rt = FbdRuntime();
    executeFbdPrograms(proj, 100, rt);
    // Out was computed from Mid's stale pre-scan value (0.0), not the 15.0
    // that net1 (running after net0) writes to Mid this same scan.
    expect(proj.tags.firstWhere((t) => t.name == 'Out').value, 5.0);
    expect(proj.tags.firstWhere((t) => t.name == 'Mid').value, 15.0);
  });
}
