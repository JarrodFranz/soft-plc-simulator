import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ld_translate.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

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

  test('translated TON block reaches DN after its preset elapses', () {
    // L-[TON]-(Done)-R, PT <- inVariable T#5s. IN is driven by the left rail
    // (always powered), so the on-delay timer counts every scan and completes
    // after ~5000ms. Proves the block LdNode + TIMER instance tag are correct.
    IrGraphNode n(int id, String type, {Map<String, String>? a}) =>
        IrGraphNode(localId: id, elementType: type, attributes: a ?? const {});
    IrConnection c(int to, int from, {String? toPin}) =>
        IrConnection(toLocalId: to, fromLocalId: from, toPin: toPin);
    final body = GraphBody(nodes: [
      n(100, 'leftPowerRail'), n(200, 'rightPowerRail'),
      n(1, 'block', a: {'typeName': 'TON', 'instanceName': 'T1'}),
      n(2, 'coil', a: {'variable': 'Done'}),
      n(3, 'inVariable', a: {'variable': 'T#5s'}),
    ], connections: [c(1, 100), c(2, 1), c(200, 2), c(1, 3, toPin: 'PT')]);
    final tr = translateLdBody(body, pouName: 'P');
    expect(tr.translatedRungCount, 1);
    expect(tr.instanceTags.single.dataType, 'TIMER');

    final proj = PlcProject(
      id: 'p', name: 'p', controllerName: 'PLC',
      programs: [
        PlcProgram(name: 'Main', language: 'LadderLogic', rungs: tr.rungs),
      ],
      tasks: [], hmis: [], structDefs: [],
      tags: [
        ...tr.instanceTags,
        PlcTag(name: 'Done', path: 'Done', dataType: 'BOOL', value: false, ioType: 'Internal'),
      ]);
    final rt = LdExecRuntime();
    // 100ms scans, 5000ms preset => not done at 10 scans (1000ms)...
    for (var i = 0; i < 10; i++) {
      executeLdPrograms(proj, 100, rt);
    }
    expect(readPath(proj, 'T1.DN'), false);
    // ...but done after crossing the preset (70 scans = 7000ms total).
    for (var i = 0; i < 60; i++) {
      executeLdPrograms(proj, 100, rt);
    }
    expect(readPath(proj, 'T1.DN'), true);
    expect(proj.tags.firstWhere((t) => t.name == 'Done').value, true);
  });
}
