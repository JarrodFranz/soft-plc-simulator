import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';

void main() {
  test('IR classes construct and hold their fields', () {
    final v = ImportedVar(name: 'Speed', baseType: 'INT', arrayLength: 0,
        initialValue: '10', scope: VarScope.global, retain: false);
    expect(v.name, 'Speed');
    final body = GraphBody(
      nodes: [IrGraphNode(localId: 1, elementType: 'contact', x: 0, y: 0, attributes: {'negated': 'false'})],
      connections: [IrConnection(toLocalId: 2, toPort: 0, fromLocalId: 1, fromPort: 0)],
    );
    final pou = ImportedPou(name: 'Main', kind: PouKind.program,
        lang: PouLanguage.ld, localVars: const [], body: body);
    expect(pou.body, isA<GraphBody>());
    final proj = ImportedProject(name: 'P', types: const [], globalVars: [v],
        pous: [pou], warnings: [ImportWarning(severity: WarningSeverity.info, message: 'hi')]);
    expect(proj.globalVars.single.name, 'Speed');
    expect((proj.pous.single.body as GraphBody).nodes.single.elementType, 'contact');
  });
}
