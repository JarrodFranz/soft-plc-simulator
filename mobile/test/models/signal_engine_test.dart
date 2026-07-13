import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/signal_gen.dart';
import 'package:soft_plc_mobile/models/signal_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

SignalGen _g(String type, {double min = 0, double max = 100, int period = 1000, double phase = 0}) =>
    SignalGen(id: 't_$type', targetPath: 'V', type: type,
        minValue: min, maxValue: max, periodMs: period, phase: phase, enabled: true);

PlcProject _proj(String dataType, dynamic initial) {
  final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
  p.tags.add(PlcTag(name: 'V', path: 'V', dataType: dataType, value: initial, ioType: 'SimulatedOutput'));
  return p;
}

void main() {
  test('ramp is a linear sawtooth over the period', () {
    expect(signalValueAt(_g('ramp'), 0), closeTo(0, 1e-9));
    expect(signalValueAt(_g('ramp'), 250), closeTo(25, 1e-9));
    expect(signalValueAt(_g('ramp'), 500), closeTo(50, 1e-9));
    expect(signalValueAt(_g('ramp'), 999), closeTo(99.9, 1e-6));
  });

  test('sine spans min..max with midpoint at t=0', () {
    expect(signalValueAt(_g('sine'), 0), closeTo(50, 1e-9));      // 0.5*span
    expect(signalValueAt(_g('sine'), 250), closeTo(100, 1e-9));   // quarter -> max
    expect(signalValueAt(_g('sine'), 500), closeTo(50, 1e-9));    // half -> mid
    expect(signalValueAt(_g('sine'), 750), closeTo(0, 1e-9));     // 3/4 -> min
  });

  test('triangle rises 0->max over first half, falls over second', () {
    expect(signalValueAt(_g('triangle'), 0), closeTo(0, 1e-9));
    expect(signalValueAt(_g('triangle'), 500), closeTo(100, 1e-9));
    expect(signalValueAt(_g('triangle'), 1000 ~/ 4), closeTo(50, 1e-9));
  });

  test('square is min in the first half, max in the second', () {
    expect(signalValueAt(_g('square'), 100), 0);
    expect(signalValueAt(_g('square'), 600), 100);
  });

  test('phase shifts the waveform', () {
    // A ramp with phase 0.5 at t=0 equals a phase-0 ramp at half period.
    expect(signalValueAt(_g('ramp', phase: 0.5), 0), closeTo(50, 1e-9));
  });

  test('periodMs <= 0 holds at min', () {
    expect(signalValueAt(_g('ramp', period: 0), 500), 0);
  });

  test('applySignalGens writes the analog tag each tick', () {
    final p = _proj('FLOAT64', 0.0);
    final rt = SignalRuntime();
    applySignalGens(p, [_g('ramp')], 250, rt); // elapsed 250
    expect(readPath(p, 'V'), closeTo(25, 1e-9));
    applySignalGens(p, [_g('ramp')], 250, rt); // elapsed 500
    expect(readPath(p, 'V'), closeTo(50, 1e-9));
  });

  test('counter increments per period as an int and clamps to max', () {
    final p = _proj('INT32', 0);
    final rt = SignalRuntime();
    final g = _g('counter', min: 0, max: 3, period: 100);
    for (var i = 0; i < 5; i++) {
      applySignalGens(p, [g], 100, rt); // elapsed 100,200,...500
    }
    // floor(500/100)=5 -> clamp into [0,3].
    expect(readPath(p, 'V'), 3);
  });

  test('toggle flips BOOL each period', () {
    final p = _proj('BOOL', false);
    final rt = SignalRuntime();
    final g = _g('toggle', period: 100);
    applySignalGens(p, [g], 100, rt); // period 1 -> true
    expect(readPath(p, 'V'), true);
    applySignalGens(p, [g], 100, rt); // period 2 -> false
    expect(readPath(p, 'V'), false);
  });

  test('random is deterministic and in range', () {
    final a = _proj('FLOAT64', 0.0);
    final b = _proj('FLOAT64', 0.0);
    final ra = SignalRuntime();
    final rb = SignalRuntime();
    final g = _g('random', min: 10, max: 20, period: 100);
    for (var i = 0; i < 8; i++) {
      applySignalGens(a, [g], 100, ra);
      applySignalGens(b, [g], 100, rb);
    }
    expect(readPath(a, 'V'), readPath(b, 'V')); // reproducible
    expect(readPath(a, 'V'), inInclusiveRange(10, 20));
  });

  test('disabled gens do not write; generatedPaths lists only enabled targets', () {
    final p = _proj('FLOAT64', 7.0);
    final rt = SignalRuntime();
    final g = _g('ramp')..enabled = false;
    applySignalGens(p, [g], 500, rt);
    expect(readPath(p, 'V'), 7.0); // untouched
    expect(generatedPaths([g]), isEmpty);
    g.enabled = true;
    expect(generatedPaths([g]), {'V'});
  });

  test('reset zeroes the clock', () {
    final p = _proj('FLOAT64', 0.0);
    final rt = SignalRuntime();
    applySignalGens(p, [_g('ramp')], 500, rt);
    rt.reset();
    applySignalGens(p, [_g('ramp')], 250, rt);
    expect(readPath(p, 'V'), closeTo(25, 1e-9)); // clock restarted from 0
  });
}
