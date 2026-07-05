import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';

// One full scan tick, exactly as the shell runs it.
void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, FbdRuntime fbd,
    SfcRuntime sfc, StRuntime st, [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
  executeFbdPrograms(p, dtMs, fbd);
  executeSfcPrograms(p, dtMs, sfc);
  executeStPrograms(p, dtMs, st);
}

// A dependency-free snapshot of every tag's observable state.
String _snapshot(PlcProject p) => jsonEncode([
      for (final t in p.tags)
        {'n': t.name, 'v': t.value, 'f': t.isForced, 'fv': t.forcedValue}
    ]);

PlcProject _roundTrip(PlcProject p) =>
    PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())));

void main() {
  for (final original in DefaultProjects.all()) {
    group('round-trip ${original.id}', () {
      test('structural: collections and struct defs are preserved', () {
        final p2 = _roundTrip(original);
        expect(p2.id, original.id);
        expect(p2.tags.length, original.tags.length);
        expect(p2.structDefs.length, original.structDefs.length,
            reason: 'struct defs must survive serialization');
        expect(p2.programs.length, original.programs.length);
        expect(p2.tasks.length, original.tasks.length);
        expect(p2.hmis.length, original.hmis.length);
        expect(p2.simRules.length, original.simRules.length);
        for (var i = 0; i < original.programs.length; i++) {
          final a = original.programs[i], b = p2.programs[i];
          expect(b.rungs.length, a.rungs.length, reason: '${a.name} LD rungs');
          expect(b.fbdBlocks.length, a.fbdBlocks.length, reason: '${a.name} FBD blocks');
          expect(b.fbdWires.length, a.fbdWires.length, reason: '${a.name} FBD wires');
          expect(b.sfcSteps.length, a.sfcSteps.length, reason: '${a.name} SFC steps');
          expect(b.sfcTransitions.length, a.sfcTransitions.length, reason: '${a.name} SFC transitions');
          expect(b.stSource, a.stSource);
        }
      });

      test('idempotent: toJson == toJson after a round-trip', () {
        final p2 = _roundTrip(original);
        expect(jsonEncode(p2.toJson()), jsonEncode(original.toJson()));
      });

      test('scan-equivalence: 20 scans identical to a fresh copy', () {
        final a = original;
        final b = _roundTrip(original);
        final aRt = (SimRuntime(), LdExecRuntime(), FbdRuntime(), SfcRuntime(), StRuntime());
        final bRt = (SimRuntime(), LdExecRuntime(), FbdRuntime(), SfcRuntime(), StRuntime());
        expect(_snapshot(a), _snapshot(b), reason: 'initial state must match');
        for (var i = 0; i < 20; i++) {
          _scan(a, aRt.$1, aRt.$2, aRt.$3, aRt.$4, aRt.$5);
          _scan(b, bRt.$1, bRt.$2, bRt.$3, bRt.$4, bRt.$5);
          expect(_snapshot(b), _snapshot(a),
              reason: 'scan $i diverged — serialization is lossy for ${original.id}');
        }
      });
    });
  }
}
