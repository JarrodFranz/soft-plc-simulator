import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _proj(FbDefinition fb, {List<PlcTag> tags = const []}) => PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [...tags], structDefs: [], programs: [], tasks: [], hmis: [],
    fbDefinitions: [fb]);

void main() {
  final fb = FbDefinition(name: 'Scaler', vars: [
    FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
    FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 2.0),
    FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
  ]);

  test('lookupComposite resolves an FB name to a struct of its vars', () {
    final comp = lookupComposite(_proj(fb), 'Scaler');
    expect(comp, isNotNull);
    expect(comp!.fields.map((f) => f.name), ['In', 'Gain', 'Out']);
  });

  test('an FB instance is a struct tag with defaults + path I/O', () {
    final p = _proj(fb, tags: [
      PlcTag(name: 'S1', path: 'S1', dataType: 'Scaler',
          value: defaultValueFor(_proj(fb), 'Scaler', 0), ioType: 'Internal'),
    ]);
    // default from FbVar.initialValue
    expect(readPath(p, 'S1.Gain'), 2.0);
    writePath(p, 'S1.In', 5.0);
    expect(readPath(p, 'S1.In'), 5.0);
  });

  test('fbDefinitionFor finds/misses', () {
    expect(fbDefinitionFor(_proj(fb), 'Scaler')?.name, 'Scaler');
    expect(fbDefinitionFor(_proj(fb), 'Nope'), isNull);
  });
}
