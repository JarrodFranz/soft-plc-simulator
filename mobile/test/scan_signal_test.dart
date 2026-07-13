import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/signal_gen.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/scan_tick.dart';

void main() {
  test('runScanTick advances a generated tag and logic cannot overwrite it', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    p.tags.add(PlcTag(name: 'Ramp', path: 'Ramp', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput'));
    p.tags.add(PlcTag(name: 'Copy', path: 'Copy', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    p.signalGens.add(SignalGen(id: 'g', targetPath: 'Ramp', type: 'ramp',
        minValue: 0, maxValue: 100, periodMs: 1000, phase: 0, enabled: true));
    p.programs.add(PlcProgram(name: 'P', language: 'StructuredText',
        stSource: 'Copy := Ramp;\nRamp := -1.0;'));
    p.tasks.add(PlcTask(name: 'Main', type: 'Continuous', programNames: ['P']));

    final rt = ScanTickRuntime();
    runScanTick(p, 250, rt); // elapsed 250 -> Ramp ~25
    expect(readPath(p, 'Ramp'), closeTo(25, 1e-9)); // generator wrote it, logic's -1 refused
    expect(readPath(p, 'Copy'), closeTo(25, 1e-9)); // logic read the fresh value

    rt.resetSession();
    runScanTick(p, 250, rt);
    expect(readPath(p, 'Ramp'), closeTo(25, 1e-9)); // clock restarted
  });
}
