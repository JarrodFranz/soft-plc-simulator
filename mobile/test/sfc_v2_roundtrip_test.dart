// SFC-v2 Task 8: round-trip / no-persist guard.
//
// This is a validation-only guard, NOT a test of the parser/layout/engine
// (those are covered by their own dedicated test files). It pins three
// contracts that the whole SFC-v2 feature depends on:
//
//  1. A chart using the new `parallelFork` / `parallelJoin` transition kind
//     round-trips through `PlcProject.toJson`/`fromJson` with `kind`,
//     `toStepIds`/`to_step_ids`, and `fromStepIds`/`from_step_ids` preserved,
//     list order intact.
//  2. A legacy single-token chart — JSON with none of the new keys at all,
//     the shape an old saved project file actually has on disk — loads
//     unchanged as `kind: 'single'` with empty fork/join lists, and stays
//     stable across a further save/reload.
//  3. The session-only Go-Online / live-execution state (`SfcRuntime`) never
//     leaks into persisted project JSON, no matter how many scans run.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';

void main() {
  test('a chart with parallelFork + parallelJoin round-trips (kind/toStepIds/fromStepIds, order preserved)', () {
    final prog = PlcProgram(name: 'PAR', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'START', isInitial: true),
      SfcStep(id: 's1', name: 'BR1_A'),
      SfcStep(id: 's2', name: 'BR1_B'),
      SfcStep(id: 's3', name: 'BR2_A'),
      SfcStep(id: 's4', name: 'AFTER'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(
        id: 'fork0',
        fromStepId: 's0',
        toStepId: '',
        conditionSt: 'TRUE',
        kind: 'parallelFork',
        toStepIds: ['s1', 's3'],
      ),
      SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'TRUE'),
      SfcTransition(
        id: 'join0',
        fromStepId: '',
        toStepId: 's4',
        conditionSt: 'TRUE',
        kind: 'parallelJoin',
        fromStepIds: ['s2', 's3'],
      ),
    ]);
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

    final json = proj.toJson();
    final round = PlcProject.fromJson(json);
    final rp = round.programs.single;

    final fork = rp.sfcTransitions.firstWhere((t) => t.id == 'fork0');
    expect(fork.kind, 'parallelFork');
    expect(fork.toStepIds, ['s1', 's3']); // order preserved
    expect(fork.fromStepIds, isEmpty);

    final join = rp.sfcTransitions.firstWhere((t) => t.id == 'join0');
    expect(join.kind, 'parallelJoin');
    expect(join.fromStepIds, ['s2', 's3']); // order preserved
    expect(join.toStepIds, isEmpty);

    final single = rp.sfcTransitions.firstWhere((t) => t.id == 't1');
    expect(single.kind, 'single');

    // Stable re-serialize (byte-for-byte equivalent graph).
    expect(round.toJson().toString(), json.toString());

    // Raw JSON carries the snake_case keys with list order intact (proves the
    // wire format itself, not just the in-memory round-trip).
    final rawTransitions =
        (((json['project'] as Map)['programs'] as List).first as Map)['sfc_transitions'] as List;
    final rawFork = rawTransitions.firstWhere((t) => (t as Map)['id'] == 'fork0') as Map;
    expect(rawFork['kind'], 'parallelFork');
    expect(rawFork['to_step_ids'], ['s1', 's3']);
    final rawJoin = rawTransitions.firstWhere((t) => (t as Map)['id'] == 'join0') as Map;
    expect(rawJoin['kind'], 'parallelJoin');
    expect(rawJoin['from_step_ids'], ['s2', 's3']);
  });

  test('legacy single-token JSON (no kind/to_step_ids/from_step_ids keys) loads as single with empty lists', () {
    // Mirrors exactly what an OLD saved project file looks like on disk: the
    // sfc_transitions entries carry none of the new keys at all.
    final legacyJson = {
      'schema': 1,
      'project': {
        'id': 'legacy',
        'name': 'Legacy',
        'version': '1.0.0',
        'description': '',
        'controller': {'name': 'PLC_01', 'scan_period_ms': 100},
        'tags': <Map<String, dynamic>>[],
        'struct_defs': <Map<String, dynamic>>[],
        'programs': [
          {
            'name': 'SEQ',
            'language': 'SequentialFunctionChart',
            'description': '',
            'st_source': '',
            'rungs': <Map<String, dynamic>>[],
            'fbd_blocks': <Map<String, dynamic>>[],
            'fbd_wires': <Map<String, dynamic>>[],
            'sfc_steps': [
              {'id': 's0', 'name': 'IDLE', 'is_initial': true, 'action_st': ''},
              {'id': 's1', 'name': 'RUN', 'is_initial': false, 'action_st': ''},
            ],
            'sfc_transitions': [
              {'id': 't0', 'from_step_id': 's0', 'to_step_id': 's1', 'condition_st': 'Start'},
              {'id': 't1', 'from_step_id': 's1', 'to_step_id': 's0', 'condition_st': 'TRUE'},
            ],
            'enabled': true,
          },
        ],
        'tasks': <Map<String, dynamic>>[],
        'hmis': <Map<String, dynamic>>[],
      },
    };

    final proj = PlcProject.fromJson(legacyJson);
    final prog = proj.programs.single;
    expect(prog.sfcTransitions.length, 2);
    for (final t in prog.sfcTransitions) {
      expect(t.kind, 'single');
      expect(t.toStepIds, isEmpty);
      expect(t.fromStepIds, isEmpty);
    }
    expect(
      prog.sfcTransitions.map((t) => '${t.fromStepId}->${t.toStepId}:${t.conditionSt}').toList(),
      ['s0->s1:Start', 's1->s0:TRUE'],
    );

    // Save/reload again with the CURRENT (additive) serializer: the model is
    // unchanged and now stable across further round-trips.
    final resaved = proj.toJson();
    final round2 = PlcProject.fromJson(resaved);
    expect(round2.toJson().toString(), resaved.toString());
    final rp2 = round2.programs.single;
    for (final t in rp2.sfcTransitions) {
      expect(t.kind, 'single');
      expect(t.toStepIds, isEmpty);
      expect(t.fromStepIds, isEmpty);
    }
  });

  test('Go-Online / live execution never leaks into persisted project JSON', () {
    final prog = PlcProgram(name: 'SEQ', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'IDLE', isInitial: true),
      SfcStep(id: 's1', name: 'RUN'),
    ]);
    prog.sfcTransitions.add(
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'TRUE'),
    );
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

    final before = proj.toJson();

    // Simulate "going online": run several scans against a live SfcRuntime,
    // which owns the active-step set + STEP_T timers entirely outside the
    // project model (mirrors how the editor's `_online` flag and the shell's
    // `scanRunning` are pure widget/session state, never written to
    // PlcProject).
    final rt = SfcRuntime();
    executeSfcPrograms(proj, 100, rt);
    executeSfcPrograms(proj, 100, rt);
    executeSfcPrograms(proj, 100, rt);
    expect(rt.active[prog.name], isNotEmpty); // runtime genuinely advanced
    expect(rt.stepElapsedMs.isNotEmpty, isTrue);

    final after = proj.toJson();
    expect(after.toString(), before.toString());

    // No online/runtime-shaped key anywhere in the serialized JSON.
    final flat = after.toString();
    expect(flat.contains('online'), isFalse);
    expect(flat.contains('scan_running'), isFalse);
    expect(flat.contains('step_elapsed'), isFalse);
    expect(flat.contains('active'), isFalse);
  });
}
