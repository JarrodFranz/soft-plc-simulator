import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ld_translate.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';

void main() {
  test('translated series rung executes as AND', () {
    // L-[A]-[B]-(C): C = A AND B.
    IrGraphNode n(int id, String type, {Map<String, String>? a}) =>
        IrGraphNode(localId: id, elementType: type, attributes: a ?? const {});
    IrConnection c(int to, int from) => IrConnection(toLocalId: to, fromLocalId: from);
    final body = GraphBody(nodes: [
      n(100, 'leftPowerRail'), n(200, 'rightPowerRail'),
      n(1, 'contact', a: {'variable': 'A'}),
      n(2, 'contact', a: {'variable': 'B'}),
      n(3, 'coil', a: {'variable': 'C'}),
    ], connections: [c(1, 100), c(2, 1), c(3, 2), c(200, 3)]);
    final tr = translateLdBody(body, pouName: 'P');
    expect(tr.translatedRungCount, 1);
    expect(tr.stubbedRungCount, 0);

    final proj = PlcProject(
      id: 'p', name: 'p', controllerName: 'PLC',
      programs: [
        PlcProgram(name: 'Main', language: 'LadderLogic', rungs: tr.rungs),
      ],
      tasks: [], hmis: [], structDefs: [],
      tags: [
        PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal'),
        PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: true, ioType: 'Internal'),
        PlcTag(name: 'C', path: 'C', dataType: 'BOOL', value: false, ioType: 'Internal'),
      ]);
    final rt = LdExecRuntime();
    executeLdPrograms(proj, 100, rt);
    expect(proj.tags.firstWhere((t) => t.name == 'C').value, true);
    // Flip B -> C false.
    proj.tags.firstWhere((t) => t.name == 'B').value = false;
    executeLdPrograms(proj, 100, rt);
    expect(proj.tags.firstWhere((t) => t.name == 'C').value, false);
  });
}
