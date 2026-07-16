import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_region.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'dart:convert';

PlcProject _batchMix() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_sfc_batchmix');

void main() {
  test('batch-mix project is registered and round-trips losslessly', () {
    final p = _batchMix();
    expect(p.name, 'SFC — Batch Mix & Dispatch');
    final back = PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())));
    expect(jsonEncode(back.toJson()), jsonEncode(p.toJson()));
  });

  test('chart parses to one parallel region (2 branches) + one alternative (2 arms)', () {
    final prog = _batchMix().programs.firstWhere((pr) => pr.language == 'SequentialFunctionChart');
    final region = parseSfc(prog.sfcSteps, prog.sfcTransitions);
    final pars = <ParRegion>[];
    final alts = <AltRegion>[];
    void walk(SfcRegion r) {
      if (r is ParRegion) { pars.add(r); for (final b in r.branches) { for (final x in b) { walk(x); } } }
      else if (r is AltRegion) { alts.add(r); for (final b in r.branches) { for (final x in b) { walk(x); } } }
      else if (r is SeqRegion) { for (final x in r.items) { walk(x); } }
    }
    walk(region);
    expect(pars.length, 1);
    expect(pars.first.branches.length, 2);
    expect(alts.length, 1);
    expect(alts.first.branches.length, 2);
  });

  test('multi-scan run: fork -> both branches -> join -> DISPATCH when Quality_OK', () {
    final p = _batchMix();
    final prog = p.programs.firstWhere((pr) => pr.language == 'SequentialFunctionChart');
    final rt = SfcRuntime();
    final sim = SimRuntime();
    void tick(int ms) {
      applySimRules(p, p.simRules, ms, sim);
      executeSfcPrograms(p, ms, rt);
    }
    // set inputs
    void setTag(String name, dynamic v) => p.tags.firstWhere((t) => t.name == name).value = v;
    setTag('Quality_OK', true);
    setTag('Start_Cmd', true);
    // run enough scans for both branches to complete, join, mix dwell, then dispatch
    Set<String> sawParallel = {};
    for (var i = 0; i < 120; i++) { // 120 * 200ms = 24s
      tick(200);
      final act = rt.active[prog.name] ?? {};
      if (act.length >= 2) { sawParallel = {...act}; }
    }
    // during the run we must have had two simultaneously-active steps (parallel)
    expect(sawParallel.length, greaterThanOrEqualTo(2));
    // Quality_OK true -> Dispatch pump fired at least once (Batch_Count advanced)
    final batch = p.tags.firstWhere((t) => t.name == 'Batch_Count').value as int;
    expect(batch, greaterThanOrEqualTo(1));
    final reject = p.tags.firstWhere((t) => t.name == 'Reject_Count').value as int;
    expect(reject, 0);
  });

  test('multi-scan run: REJECT arm when NOT Quality_OK', () {
    final p = _batchMix();
    final rt = SfcRuntime();
    final sim = SimRuntime();
    void setTag(String name, dynamic v) => p.tags.firstWhere((t) => t.name == name).value = v;
    setTag('Quality_OK', false);
    setTag('Start_Cmd', true);
    for (var i = 0; i < 120; i++) {
      applySimRules(p, p.simRules, 200, sim);
      executeSfcPrograms(p, 200, rt);
    }
    expect(p.tags.firstWhere((t) => t.name == 'Reject_Count').value as int, greaterThanOrEqualTo(1));
    expect(p.tags.firstWhere((t) => t.name == 'Batch_Count').value as int, 0);
  });

  test('DISPATCH counter is a true one-shot: Batch_Count increments exactly once per completed batch', () {
    final p = _batchMix();
    final rt = SfcRuntime();
    final sim = SimRuntime();
    void tick(int ms) {
      applySimRules(p, p.simRules, ms, sim);
      executeSfcPrograms(p, ms, rt);
    }
    void setTag(String name, dynamic v) => p.tags.firstWhere((t) => t.name == name).value = v;
    int batchCount() => p.tags.firstWhere((t) => t.name == 'Batch_Count').value as int;

    setTag('Quality_OK', true);
    setTag('Start_Cmd', true);
    // Run until Batch_Count first reaches 1 (bounded so a broken chart can't hang the test).
    var guard = 0;
    while (batchCount() < 1 && guard < 500) {
      tick(200);
      guard++;
    }
    expect(batchCount(), 1);
    // Prevent a new batch from starting, then keep scanning well past the DISPATCH dwell.
    setTag('Start_Cmd', false);
    for (var i = 0; i < 40; i++) {
      tick(200);
    }
    // Must remain exactly 1 -- proves the increment fires once per batch, not once per scan.
    expect(batchCount(), 1);
  });
}
