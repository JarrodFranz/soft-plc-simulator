import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_pins.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

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

  test('some project uses a custom FB block type in an FBD network', () {
    final found = projects.any((p) => p.programs.any((prog) =>
        prog.language == 'FunctionBlockDiagram' &&
        prog.fbdBlocks.any((b) => fbDefinitionFor(p, b.type) != null)));
    expect(found, isTrue,
        reason: 'no default wires a custom FB instance into an FBD network');
  });

  test('some ST source contains an array-index read', () {
    // An index reference not immediately followed by ':=' is a read, not the
    // lvalue of an index write (which this app's ST subset doesn't even
    // support on an array — but the shape check stays honest either way).
    final arrayRead = RegExp(r'[A-Za-z_]\w*\[[^\]]+\]\s*(?!:=)');
    final found = projects.any((p) => p.programs.any((prog) =>
        prog.language == 'StructuredText' && arrayRead.hasMatch(prog.stSource)));
    expect(found, isTrue,
        reason: 'no ST program in any default reads an array element');
  });

  test('some ST source contains a struct-member write', () {
    final structWrite = RegExp(r'[A-Za-z_]\w*\.[A-Za-z_]\w*\s*:=');
    final found = projects.any((p) => p.programs.any((prog) =>
        prog.language == 'StructuredText' && structWrite.hasMatch(prog.stSource)));
    expect(found, isTrue,
        reason: 'no ST program in any default writes a struct member');
  });

  test('some project has more than one HMI screen', () {
    expect(projects.any((p) => p.hmis.length > 1), isTrue,
        reason: 'no default ships a multi-screen HMI');
  });

  test('some project has a PID block resolvable by the autotune loop resolver',
      () {
    // Mirrors PidAutoTuneScreen._loopOptions(): an FBD program with a block
    // whose type is 'PID'.
    bool hasPidLoop(PlcProject p) => p.programs.any((prog) =>
        prog.language == 'FunctionBlockDiagram' &&
        prog.fbdBlocks.any((b) => b.type == 'PID'));
    expect(projects.any(hasPidLoop), isTrue,
        reason: 'no default exposes a PID loop the autotune screen can find');
  });

  test('some SFC project has a step with isInitial', () {
    final found = projects.any((p) => p.programs.any((prog) =>
        prog.language == 'SequentialFunctionChart' &&
        prog.sfcSteps.any((s) => s.isInitial)));
    expect(found, isTrue, reason: 'no SFC program declares an initial step');
  });

  /// Pins the two "Not covered" doc bullets in docs/default-projects.md that
  /// claimed to be "pinned as a set in the coverage guard" without an actual
  /// assertion backing that claim.
  test('no default ships a SignalGen (pinned uncovered set)', () {
    expect(projects.every((p) => p.signalGens.isEmpty), isTrue,
        reason: 'a default now ships a SignalGen — update the "Not covered" '
            'section of docs/default-projects.md and strike the matching row '
            'in docs/DEFERRED.md');
  });

  test(
      'no default configures a protocol beyond Modbus + OPC UA (pinned uncovered set)',
      () {
    final configuredBeyond = projects.any((p) {
      final protocols = p.protocols;
      if (protocols == null) return false;
      return protocols.mqtt != null ||
          protocols.dnp3 != null ||
          protocols.ethernetIp != null ||
          protocols.s7 != null ||
          protocols.fins != null ||
          protocols.slmp != null ||
          protocols.bacnet != null;
    });
    expect(configuredBeyond, isFalse,
        reason: 'a default now pre-configures a protocol beyond Modbus + OPC '
            'UA — update the "Not covered" section of docs/default-projects.md '
            'and strike the matching row in docs/DEFERRED.md');
  });
}
