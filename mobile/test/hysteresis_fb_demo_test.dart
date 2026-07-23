import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

/// The "Noisy Level Measurement" default project — chosen host for the shipped
/// custom-function-block demo (see `default_projects.dart`'s
/// `_noisyLevelProject`).
PlcProject _proj() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_noisy_level');

void main() {
  test('the Hysteresis FbDefinition is shipped with the expected interface',
      () {
    final p = _proj();
    final fb = p.fbDefinitions.firstWhere((f) => f.name == 'Hysteresis');

    expect(
        fb.vars.map((v) => v.name).toList(), ['PV', 'High', 'Low', 'Q', 'Out']);
    final pv = fb.vars.firstWhere((v) => v.name == 'PV');
    expect(pv.direction, FbVarDir.input);
    expect(pv.dataType, 'FLOAT64');
    final high = fb.vars.firstWhere((v) => v.name == 'High');
    expect(high.direction, FbVarDir.input);
    expect(high.initialValue, 60.0);
    final low = fb.vars.firstWhere((v) => v.name == 'Low');
    expect(low.direction, FbVarDir.input);
    expect(low.initialValue, 40.0);
    final q = fb.vars.firstWhere((v) => v.name == 'Q');
    expect(q.direction, FbVarDir.internal,
        reason:
            'Q is the per-instance state that must persist across scans — the feature headline');
    final out = fb.vars.firstWhere((v) => v.name == 'Out');
    expect(out.direction, FbVarDir.output);
  });

  test(
      'LevelAlarmHyst is a struct-typed FB instance tag bound to the Hysteresis FB',
      () {
    final p = _proj();
    final tag = p.tags.firstWhere((t) => t.name == 'LevelAlarmHyst');
    expect(tag.dataType, 'Hysteresis');
    expect(tag.ioType, 'Internal');
    // Structural default resolves through the FB's vars (composite expansion).
    expect(tag.value, isA<Map>());
    final v = tag.value as Map;
    expect(v.keys.toSet(), {'PV', 'High', 'Low', 'Q', 'Out'});
    expect(v['High'], 60.0);
    expect(v['Low'], 40.0);
    expect(v['Q'], false);
  });

  test(
      'the FBD program wires TAG_INPUT/CONST -> Hysteresis -> TAG_OUTPUT in its own network',
      () {
    final p = _proj();
    final prog =
        p.programs.firstWhere((pr) => pr.name == 'NoisyLevelMonitor_FBD');
    final hystBlock = prog.fbdBlocks.firstWhere((b) => b.type == 'Hysteresis');
    expect(hystBlock.tagBinding, 'LevelAlarmHyst');
    expect(hystBlock.network, 1,
        reason:
            'kept in its own network from the pre-existing Fill_Valve monitor (network 0)');

    final wiresIntoHyst =
        prog.fbdWires.where((w) => w.toBlockId == hystBlock.id).toList();
    final wiredPins = wiresIntoHyst.map((w) => w.toPin).toSet();
    expect(wiredPins, {'PV', 'High', 'Low'});

    final wireOut =
        prog.fbdWires.singleWhere((w) => w.fromBlockId == hystBlock.id);
    expect(wireOut.fromPin, 'Out');
    final outBlock =
        prog.fbdBlocks.firstWhere((b) => b.id == wireOut.toBlockId);
    expect(outBlock.type, 'TAG_OUTPUT');
    expect(outBlock.tagBinding, 'Level_Alarm');
  });

  test(
      'running the FBD network: Level_Alarm sets above High, HOLDS through the deadband '
      '(internal Q persists), then resets below Low — the per-instance-state headline',
      () {
    final p = _proj();
    final rt = FbdRuntime();
    const dtMs = 500;

    void runWith(double levelFiltered) {
      writePath(p, 'Level_Filtered', levelFiltered);
      executeFbdPrograms(p, dtMs, rt, only: {'NoisyLevelMonitor_FBD'});
    }

    // Start below the deadband: alarm must be clear.
    runWith(20.0);
    expect(readPath(p, 'Level_Alarm'), false);

    // Cross above High (60): alarm sets.
    runWith(65.0);
    expect(readPath(p, 'Level_Alarm'), true);

    // Fall back INSIDE the deadband (between Low=40 and High=60): a
    // stateless comparator would immediately clear here. The Hysteresis FB's
    // internal Q must persist the prior TRUE state instead.
    runWith(50.0);
    expect(readPath(p, 'Level_Alarm'), true,
        reason:
            'Q must hold its set state while PV sits in the 40-60 deadband');

    // Repeat a couple more scans inside the deadband: still holding.
    runWith(45.0);
    expect(readPath(p, 'Level_Alarm'), true);

    // Cross below Low (40): alarm resets.
    runWith(35.0);
    expect(readPath(p, 'Level_Alarm'), false);

    // Back inside the deadband from below: must hold the reset state too
    // (symmetric proof the deadband isn't one-sided).
    runWith(50.0);
    expect(readPath(p, 'Level_Alarm'), false,
        reason:
            'Q must hold its reset state while PV sits in the 40-60 deadband');
  });
}
