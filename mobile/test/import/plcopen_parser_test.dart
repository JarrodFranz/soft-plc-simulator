import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';

void main() {
  group('parsePlcOpen', () {
    late String basicXml;

    setUpAll(() {
      basicXml =
          File('test/fixtures/plcopen/basic.xml').readAsStringSync();
    });

    test('project name comes from contentHeader', () {
      final project = parsePlcOpen(basicXml);
      expect(project.name, 'DemoProject');
    });

    test('parses the DUT with its fields', () {
      final project = parsePlcOpen(basicXml);
      expect(project.types, hasLength(1));
      final motorType = project.types.single;
      expect(motorType.name, 'MotorType');
      expect(motorType.fields, hasLength(2));

      final running = motorType.fields.firstWhere((f) => f.name == 'Running');
      expect(running.baseType, 'BOOL');

      final rpm = motorType.fields.firstWhere((f) => f.name == 'Rpm');
      expect(rpm.baseType, 'INT');
      expect(rpm.initialValue, '1500');
    });

    test('parses global vars', () {
      final project = parsePlcOpen(basicXml);
      expect(project.globalVars, hasLength(3));

      final tempPv = project.globalVars.firstWhere((v) => v.name == 'Temp_PV');
      expect(tempPv.baseType, 'REAL');
      expect(tempPv.initialValue, '20.0');
      expect(tempPv.scope, VarScope.global);

      final enable = project.globalVars.firstWhere((v) => v.name == 'Enable');
      expect(enable.baseType, 'BOOL');
      expect(enable.initialValue, 'TRUE');
      expect(enable.scope, VarScope.global);

      final retained =
          project.globalVars.firstWhere((v) => v.name == 'Retained');
      expect(retained.baseType, 'LREAL');
      expect(retained.retain, isTrue);
      expect(retained.scope, VarScope.global);
    });

    test('parses the ST POU as a TextBody', () {
      final project = parsePlcOpen(basicXml);
      final main = project.pous.firstWhere((p) => p.name == 'Main');
      expect(main.lang, PouLanguage.st);
      expect(main.localVars, hasLength(1));
      final count = main.localVars.single;
      expect(count.name, 'Count');
      expect(count.baseType, 'DINT');
      expect(count.initialValue, '7');

      final body = main.body;
      expect(body, isA<TextBody>());
      expect((body as TextBody).source, contains('Count := Count + 1;'));
    });

    test('parses the LD POU as a lossless GraphBody', () {
      final project = parsePlcOpen(basicXml);
      final rung1 = project.pous.firstWhere((p) => p.name == 'Rung1');
      expect(rung1.lang, PouLanguage.ld);

      final body = rung1.body;
      expect(body, isA<GraphBody>());
      final graph = body as GraphBody;
      expect(graph.nodes, hasLength(2));
      expect(graph.connections, hasLength(1));

      final contact = graph.nodes.firstWhere((n) => n.localId == 1);
      expect(contact.elementType, 'contact');
      expect(contact.attributes['variable'], 'Start');
      expect(contact.x, 10);
      expect(contact.y, 20);

      final coil = graph.nodes.firstWhere((n) => n.localId == 2);
      expect(coil.elementType, 'coil');

      final conn = graph.connections.single;
      expect(conn.toLocalId, 2);
      expect(conn.fromLocalId, 1);
    });

    test(
        'FBD <block> captures connections nested under inputVariables/variable '
        '(not just direct-child connectionPointIn)', () {
      final fbdXml =
          File('test/fixtures/plcopen/fbd_block.xml').readAsStringSync();
      final project = parsePlcOpen(fbdXml);
      final pou = project.pous.firstWhere((p) => p.name == 'FbdBlock');
      expect(pou.lang, PouLanguage.fbd);

      final body = pou.body;
      expect(body, isA<GraphBody>());
      final graph = body as GraphBody;
      expect(graph.nodes, hasLength(3));

      // Direct-child case (coil localId=4 <- contact localId=1) must still work.
      expect(
        graph.connections.any((c) => c.toLocalId == 4 && c.fromLocalId == 1),
        isTrue,
        reason: 'direct-child connectionPointIn on <coil> should be captured',
      );

      // Nested case (block localId=2 <- contact localId=1, connection buried
      // under <inputVariables><variable><connectionPointIn>) must be captured.
      expect(
        graph.connections.any((c) => c.toLocalId == 2 && c.fromLocalId == 1),
        isTrue,
        reason: 'connectionPointIn nested inside <block><inputVariables> '
            'must not be silently dropped',
      );

      expect(graph.connections, hasLength(2));
    });

    test(
        'clamps an oversized array dimension to the supported maximum and '
        'emits a warning instead of allocating an unbounded array', () {
      final arrayDimXml =
          File('test/fixtures/plcopen/array_dim.xml').readAsStringSync();

      // Must not throw, even though the raw dimension (0..100000000 ->
      // 100000001 elements) would otherwise try to eagerly allocate a
      // huge list downstream.
      final project = parsePlcOpen(arrayDimXml);

      final main = project.pous.firstWhere((p) => p.name == 'Main');
      final bigArr =
          main.localVars.firstWhere((v) => v.name == 'BigArr');
      expect(bigArr.arrayLength, 65535);

      final clampWarning = project.warnings.where((w) =>
          w.severity == WarningSeverity.warning &&
          w.message.contains('BigArr') &&
          w.message.contains('clamp'));
      expect(clampWarning, isNotEmpty,
          reason: 'expected a warning about the clamped array dimension');
    });

    test('an ordinary small array dimension is left unchanged (no clamp)',
        () {
      final arrayDimXml =
          File('test/fixtures/plcopen/array_dim.xml').readAsStringSync();
      final project = parsePlcOpen(arrayDimXml);

      final main = project.pous.firstWhere((p) => p.name == 'Main');
      final smallArr =
          main.localVars.firstWhere((v) => v.name == 'SmallArr');
      expect(smallArr.arrayLength, 8);

      final smallArrWarnings = project.warnings.where((w) =>
          w.message.contains('SmallArr') && w.message.contains('clamp'));
      expect(smallArrWarnings, isEmpty);
    });

    test('throws FormatException on malformed XML', () {
      final malformed =
          File('test/fixtures/plcopen/malformed.xml').readAsStringSync();
      expect(() => parsePlcOpen(malformed), throwsFormatException);
    });

    test('throws FormatException when root is not <project>', () {
      final notPlcOpen =
          File('test/fixtures/plcopen/not_plcopen.xml').readAsStringSync();
      expect(() => parsePlcOpen(notPlcOpen), throwsFormatException);
    });

    test('inVariable/outVariable <expression> populates attributes[variable]', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="Expr"/>
  <types><dataTypes/><pous>
    <pou name="P" pouType="program">
      <interface><localVars/></interface>
      <body><FBD>
        <inVariable localId="1"><position x="0" y="0"/><expression>PV</expression>
          <connectionPointOut/></inVariable>
        <outVariable localId="2"><position x="100" y="0"/><expression>CV</expression>
          <connectionPointIn><connection refLocalId="1"/></connectionPointIn></outVariable>
      </FBD></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';
      final ir = parsePlcOpen(xml);
      final pou = ir.pous.single;
      final body = pou.body as GraphBody;
      final inV = body.nodes.firstWhere((n) => n.localId == 1);
      final outV = body.nodes.firstWhere((n) => n.localId == 2);
      expect(inV.attributes['variable'], 'PV');
      expect(outV.attributes['variable'], 'CV');
    });

    test('<variable> still wins over <expression> when both present', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="Both"/>
  <types><dataTypes/><pous>
    <pou name="P" pouType="program">
      <interface><localVars/></interface>
      <body><FBD>
        <inVariable localId="1"><position x="0" y="0"/>
          <variable>WINS</variable><expression>LOSES</expression>
          <connectionPointOut/></inVariable>
      </FBD></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';
      final ir = parsePlcOpen(xml);
      final n = (ir.pous.single.body as GraphBody).nodes.single;
      expect(n.attributes['variable'], 'WINS');
    });

    test('negated block input pin sets attributes[hasNegatedPin]', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="Neg"/>
  <types><dataTypes/><pous>
    <pou name="P" pouType="program">
      <interface><localVars/></interface>
      <body><FBD>
        <inVariable localId="1"><position x="0" y="0"/><expression>A</expression>
          <connectionPointOut/></inVariable>
        <block localId="2" typeName="AND"><position x="60" y="0"/>
          <inputVariables>
            <variable formalParameter="IN1" negated="true">
              <connectionPointIn><connection refLocalId="1"/></connectionPointIn>
            </variable>
          </inputVariables>
          <outputVariables>
            <variable formalParameter="OUT"><connectionPointOut/></variable>
          </outputVariables>
        </block>
      </FBD></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';
      final ir = parsePlcOpen(xml);
      final blk = (ir.pous.single.body as GraphBody).nodes
          .firstWhere((n) => n.localId == 2);
      final inV = (ir.pous.single.body as GraphBody).nodes
          .firstWhere((n) => n.localId == 1);
      expect(blk.attributes['hasNegatedPin'], 'true');
      expect(inV.attributes.containsKey('hasNegatedPin'), isFalse);
    });

    test(
        'two nodes with distinct unparseable localIds get distinct synthetic '
        'ids (no collision/merge of unrelated malformed networks)', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="TwoMalformed"/>
  <types><dataTypes/><pous>
    <pou name="P" pouType="program">
      <interface><localVars/></interface>
      <body><FBD>
        <inVariable localId="oops"><position x="0" y="0"/><expression>A</expression>
          <connectionPointOut/></inVariable>
        <outVariable localId="2"><position x="100" y="0"/><expression>QA</expression>
          <connectionPointIn><connection refLocalId="oops"/></connectionPointIn></outVariable>
        <inVariable localId="bad"><position x="200" y="0"/><expression>B</expression>
          <connectionPointOut/></inVariable>
        <outVariable localId="4"><position x="300" y="0"/><expression>QB</expression>
          <connectionPointIn><connection refLocalId="bad"/></connectionPointIn></outVariable>
      </FBD></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';
      final ir = parsePlcOpen(xml);
      final body = ir.pous.single.body as GraphBody;
      expect(body.nodes, hasLength(4));

      final malformedNodes = body.nodes
          .where((n) => n.attributes['variable'] == 'A' ||
              n.attributes['variable'] == 'B')
          .toList();
      expect(malformedNodes, hasLength(2));

      // Both unparseable localIds must be negative (so the FBD translator's
      // `localId < 0` guard still stubs them) but DISTINCT from each other
      // (so they don't collide in localId-keyed maps like
      // weaklyConnectedComponents' `byId`, which would silently merge these
      // two unrelated networks and drop a node).
      final ids = malformedNodes.map((n) => n.localId).toList();
      expect(ids[0], lessThan(0));
      expect(ids[1], lessThan(0));
      expect(ids[0], isNot(equals(ids[1])));
    });
  });
}
