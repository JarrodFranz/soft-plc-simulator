import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/models/fb_exec.dart';

FbDefinition _accumFb() => FbDefinition(name: 'Accum', stSource: 'Sum := Sum + In; Out := Sum;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Sum', dataType: 'FLOAT64', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);

PlcProject _proj(FbDefinition fb, {List<PlcTag>? tags}) => PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: tags ?? [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

void main() {
  test('executeFbInstance runs scoped body; internal state persists across calls', () {
    final fb = _accumFb();
    final p = _proj(fb, tags: [
      PlcTag(name: 'A1', path: 'A1', dataType: 'Accum', ioType: 'Internal', value: defaultValueFor(_proj(fb), 'Accum', 0)),
    ]);
    var out = executeFbInstance(p, fb, 'A1', {'In': 3.0});
    expect(out['Out'], 3.0);
    out = executeFbInstance(p, fb, 'A1', {'In': 4.0});
    expect(out['Out'], 7.0); // Sum persisted in the A1 struct
    expect(readPath(p, 'A1.Sum'), 7.0);
  });

  test('two instances keep independent state', () {
    final fb = _accumFb();
    final p = _proj(fb, tags: [
      PlcTag(name: 'A1', path: 'A1', dataType: 'Accum', ioType: 'Internal', value: defaultValueFor(_proj(fb), 'Accum', 0)),
      PlcTag(name: 'A2', path: 'A2', dataType: 'Accum', ioType: 'Internal', value: defaultValueFor(_proj(fb), 'Accum', 0)),
    ]);
    executeFbInstance(p, fb, 'A1', {'In': 5.0});
    final o2 = executeFbInstance(p, fb, 'A2', {'In': 9.0});
    expect(o2['Out'], 9.0);
    expect(readPath(p, 'A1.Sum'), 5.0);
  });

  test('an empty instance name refuses to run and does not touch same-named globals', () {
    // A dangling/unbound FB block would call with instanceName == '' — paths like
    // '.In' strip to bare 'In' and would otherwise alias onto globals. Guard it.
    final fb = _accumFb();
    final p = _proj(fb, tags: [
      // Same-named globals the aliasing bug would have clobbered / read.
      PlcTag(name: 'In', path: 'In', dataType: 'FLOAT64', ioType: 'Internal', value: 5.0),
      PlcTag(name: 'Sum', path: 'Sum', dataType: 'FLOAT64', ioType: 'Internal', value: 42.0),
      PlcTag(name: 'Out', path: 'Out', dataType: 'FLOAT64', ioType: 'Internal', value: 7.0),
    ]);
    final out = executeFbInstance(p, fb, '', {'In': 3.0});
    expect(out, isEmpty); // no outputs produced
    // Globals untouched — inputs not written, body not run.
    expect(readPath(p, 'In'), 5.0);
    expect(readPath(p, 'Sum'), 42.0);
    expect(readPath(p, 'Out'), 7.0);
  });

  test('a body reference not in the FB vars falls through to a global tag', () {
    final fb = FbDefinition(name: 'Gue', stSource: 'Out := In + Bias;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);
    final p = _proj(fb, tags: [
      PlcTag(name: 'G1', path: 'G1', dataType: 'Gue', ioType: 'Internal', value: defaultValueFor(_proj(fb), 'Gue', 0)),
      PlcTag(name: 'Bias', path: 'Bias', dataType: 'FLOAT64', ioType: 'Internal', value: 100.0),
    ]);
    final out = executeFbInstance(p, fb, 'G1', {'In': 1.0});
    expect(out['Out'], 101.0); // Bias read from the global tag
  });
}
