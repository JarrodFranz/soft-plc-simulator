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
  });
}
