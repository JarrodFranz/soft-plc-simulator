import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_pins.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

/// Mechanical enforcement of the spec's §5 coverage matrix: the shipped
/// defaults must, between them, exercise every feature listed here. A cell may
/// never go from covered to uncovered without a conscious edit to this file.
void main() {
  final projects = DefaultProjects.all();

  /// LD blockTypes the defaults deliberately do NOT showcase (documented as a
  /// deferred row in docs/DEFERRED.md). Adding a default that uses one of these
  /// is fine — removing an entry from here is the conscious edit.
  const knownUncoveredLdBlockTypes = {
    'GE',
    'LE',
    'NE',
    'MUL',
    'DIV',
    'TP',
    'CTD',
    'CTUD',
  };
  const knownUncoveredTaskTypes = {'Event'};

  test('every built-in FBD block type appears in some default project', () {
    final seen = <String>{
      for (final p in projects)
        for (final prog in p.programs)
          for (final b in prog.fbdBlocks) b.type,
    };
    for (final type in kFbdBuiltinBlockTypes) {
      expect(seen, contains(type),
          reason: 'FBD block $type is not showcased anywhere');
    }
  });

  test('LD contact and coil modifiers, and the claimed LD block set, all appear',
      () {
    final contactMods = <String>{};
    final coilMods = <String>{};
    final blockTypes = <String>{};
    void visit(LdRung r) {
      for (final n in r.nodes) {
        switch (n.kind) {
          case LdKind.contact:
            contactMods.add(n.modifier);
            break;
          case LdKind.coil:
            coilMods.add(n.modifier);
            break;
          case LdKind.block:
            blockTypes.add(n.blockType);
            break;
          default:
            break;
        }
      }
    }

    for (final p in projects) {
      for (final prog in p.programs) {
        prog.rungs.forEach(visit);
      }
      for (final fb in p.fbDefinitions) {
        fb.ladderRungs.forEach(visit);
      }
    }

    expect(contactMods, containsAll({'normal', 'negated', 'rising', 'falling'}));
    expect(coilMods,
        containsAll({'normal', 'negated', 'set', 'reset', 'rising', 'falling'}));
    expect(
        blockTypes,
        containsAll(
            {'TON', 'TOF', 'CTU', 'GT', 'LT', 'EQ', 'ADD', 'SUB', 'MOVE'}));
    expect(blockTypes.intersection(knownUncoveredLdBlockTypes), isEmpty,
        reason:
            'a default now uses a previously-uncovered LD block — remove it from '
            'knownUncoveredLdBlockTypes and strike its deferred row');
  });

  test('all eight sim behaviours appear', () {
    final seen = <String>{
      for (final p in projects)
        for (final r in p.simRules) r.behavior,
    };
    expect(
        seen,
        containsAll({
          'setWhileCondition',
          'delayedSet',
          'pulse',
          'ramp',
          'integrate',
          'firstOrderLag',
          'deadTime',
          'noise',
        }));
  });

  test('a non-linear valve curve and a gaussian noise distribution appear', () {
    final rules = [for (final p in projects) ...p.simRules];
    expect(rules.any((r) => r.valveCurve != 'linear'), isTrue);
    expect(
        rules.any(
            (r) => r.noiseDistribution == 'gaussian' && r.driftAmplitude > 0),
        isTrue);
  });

  test('all nine HMI component types appear, and some component carries pens',
      () {
    final seen = <String>{
      for (final p in projects)
        for (final h in p.hmis)
          for (final c in h.components) c.type,
    };
    expect(
        seen,
        containsAll({
          'PushbuttonSwitch',
          'ToggleSwitch',
          'NumericSliderInput',
          'TextInputField',
          'LedIndicatorLight',
          'DigitalGaugeDisplay',
          'StatusPillDisplay',
          'TankGraphicDisplay',
          kTrendChartDisplay,
        }));
    final withPens = [
      for (final p in projects)
        for (final h in p.hmis)
          for (final c in h.components)
            if (c.trendPens.isNotEmpty) c,
    ];
    expect(withPens, isNotEmpty);
    expect(projects.any((p) => p.trends.isNotEmpty), isTrue);
  });

  test('both FbDefinition body kinds are shipped', () {
    final fbs = [for (final p in projects) ...p.fbDefinitions];
    expect(fbs.any((f) => f.stSource.isNotEmpty && f.ladderRungs.isEmpty), isTrue,
        reason: 'no ST-bodied FB');
    expect(fbs.any((f) => f.ladderRungs.isNotEmpty), isTrue,
        reason: 'no ladder-bodied FB');
  });

  test('SFC fork, join, alternative divergence and a STEP_T dwell all appear',
      () {
    final transitions = [
      for (final p in projects)
        for (final prog in p.programs) ...prog.sfcTransitions,
    ];
    expect(transitions.any((t) => t.kind == 'parallelFork'), isTrue);
    expect(transitions.any((t) => t.kind == 'parallelJoin'), isTrue);
    expect(transitions.any((t) => t.conditionSt.contains('STEP_T')), isTrue);

    var sawAlternative = false;
    for (final p in projects) {
      for (final prog in p.programs) {
        final byFrom = <String, int>{};
        for (final t in prog.sfcTransitions) {
          if (t.kind == 'single' && t.fromStepId.isNotEmpty) {
            byFrom[t.fromStepId] = (byFrom[t.fromStepId] ?? 0) + 1;
          }
        }
        if (byFrom.values.any((n) => n >= 2)) {
          sawAlternative = true;
        }
      }
    }
    expect(sawAlternative, isTrue, reason: 'no alternative divergence anywhere');
  });

  test('the three covered task types appear and Event stays documented-uncovered',
      () {
    final seen = <String>{
      for (final p in projects)
        for (final t in p.tasks) t.type,
    };
    expect(seen, containsAll({'Startup', 'Continuous', 'Periodic'}));
    expect(seen.intersection(knownUncoveredTaskTypes), isEmpty,
        reason: 'a default now uses an Event task — remove it from '
            'knownUncoveredTaskTypes and strike its deferred row');
  });

  test('some default ships pre-configured Modbus + OPC UA maps', () {
    final configured = projects.where((p) =>
        p.protocols?.modbus != null &&
        p.protocols?.opcua != null &&
        p.protocols!.modbus!.map.entries.isNotEmpty &&
        p.protocols!.opcua!.map.nodes.isNotEmpty);
    expect(configured, isNotEmpty);
  });

  test('some HMI component binds a reserved System.* member', () {
    final bound = [
      for (final p in projects)
        for (final h in p.hmis)
          for (final c in h.components)
            if (c.tagBinding.startsWith('System.')) c.tagBinding,
    ];
    expect(bound, isNotEmpty);
  });

  test('array tags, DUTs and TIMER composites all appear', () {
    final tags = [for (final p in projects) ...p.tags];
    expect(tags.any((t) => t.arrayLength > 0), isTrue);
    expect(projects.any((p) => p.structDefs.isNotEmpty), isTrue);
    expect(tags.any((t) => t.dataType == 'TIMER'), isTrue);
  });
}
