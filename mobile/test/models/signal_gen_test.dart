import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/signal_gen.dart';

void main() {
  test('PlcTag.folder defaults to empty and round-trips', () {
    final t = PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal');
    expect(t.folder, '');
    final t2 = PlcTag(
      name: 'B', path: 'B', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', folder: 'ramp1');
    expect(PlcTag.fromJson(t2.toJson()).folder, 'ramp1');
    // Legacy JSON without the key defaults to root.
    expect(PlcTag.fromJson({'name': 'C', 'data_type': 'BOOL'}).folder, '');
  });

  test('SignalGen round-trips through JSON', () {
    final g = SignalGen(
      id: 'g1', targetPath: 'ramp1.Ramp001', type: 'sine',
      minValue: 0, maxValue: 100, periodMs: 2000, phase: 0.25, enabled: true);
    final back = SignalGen.fromJson(g.toJson());
    expect(back.id, 'g1');
    expect(back.targetPath, 'ramp1.Ramp001');
    expect(back.type, 'sine');
    expect(back.minValue, 0);
    expect(back.maxValue, 100);
    expect(back.periodMs, 2000);
    expect(back.phase, 0.25);
    expect(back.enabled, isTrue);
  });

  test('PlcProject.signalGens defaults to empty and round-trips', () {
    final p = PlcProject(
      id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    expect(p.signalGens, isEmpty);
    p.signalGens.add(SignalGen(
      id: 'g1', targetPath: 'T', type: 'ramp',
      minValue: 0, maxValue: 1, periodMs: 1000, phase: 0, enabled: true));
    final back = PlcProject.fromJson(p.toJson());
    expect(back.signalGens.length, 1);
    expect(back.signalGens.first.type, 'ramp');
  });
}
