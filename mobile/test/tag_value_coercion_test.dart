import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _p() => PlcProject(id: 'p', name: 'P', controllerName: 'PLC',
    programs: [], tasks: [], hmis: [], structDefs: [], tags: []);

void main() {
  group('coerceScalarValue', () {
    test('BOOL accepts true/false/1/0/on/off case-insensitively', () {
      for (final s in ['true', 'TRUE', '1', 'on', 'ON']) {
        expect(coerceScalarValue('BOOL', s), isTrue, reason: s);
      }
      for (final s in ['false', '0', 'off', 'nonsense', '']) {
        expect(coerceScalarValue('BOOL', s), isFalse, reason: s);
      }
    });
    test('integer types parse to int, bad input -> 0', () {
      expect(coerceScalarValue('INT16', '42'), 42);
      expect(coerceScalarValue('INT32', '-7'), -7);
      expect(coerceScalarValue('INT16', 'abc'), 0);
    });
    test('FLOAT64 parses to double, bad input -> 0.0', () {
      expect(coerceScalarValue('FLOAT64', '12.5'), 12.5);
      expect(coerceScalarValue('FLOAT64', 'x'), 0.0);
    });
    test('STRING is verbatim', () {
      expect(coerceScalarValue('STRING', 'hi there'), 'hi there');
    });
  });

  group('coerceValueToType', () {
    test('number -> BOOL is nonzero-true', () {
      expect(coerceValueToType(_p(), 3, 'BOOL', 0), isTrue);
      expect(coerceValueToType(_p(), 0, 'BOOL', 0), isFalse);
    });
    test('BOOL -> integer maps to 1/0', () {
      expect(coerceValueToType(_p(), true, 'INT16', 0), 1);
      expect(coerceValueToType(_p(), false, 'INT16', 0), 0);
    });
    test('string number -> FLOAT64 parses; junk -> type default', () {
      expect(coerceValueToType(_p(), '3.5', 'FLOAT64', 0), 3.5);
      expect(coerceValueToType(_p(), 'junk', 'INT16', 0), 0);
    });
    test('changing to a composite/array yields the structural default', () {
      final v = coerceValueToType(_p(), 5, 'FLOAT64', 2);
      expect(v, isA<List<dynamic>>());
      expect((v as List).length, 2);
    });
  });
}
