import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/type_normalize.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

PlcProject _p() => PlcProject(id: 'p', name: 'P', controllerName: 'PLC',
    programs: [], tasks: [], hmis: [], structDefs: [], tags: []);

void main() {
  group('normalizeType', () {
    test('elementary IEC types map to app types', () {
      final k = <String>{};
      expect(normalizeType('BOOL', knownDutNames: k), 'BOOL');
      expect(normalizeType('INT', knownDutNames: k), 'INT16');
      expect(normalizeType('UINT', knownDutNames: k), 'INT16');
      expect(normalizeType('DINT', knownDutNames: k), 'INT32');
      expect(normalizeType('LINT', knownDutNames: k), 'INT64');
      expect(normalizeType('REAL', knownDutNames: k), 'FLOAT64');
      expect(normalizeType('LREAL', knownDutNames: k), 'FLOAT64');
      expect(normalizeType('STRING', knownDutNames: k), 'STRING');
      expect(normalizeType('TIME', knownDutNames: k), 'TIMER');
    });
    test('case-insensitive', () {
      expect(normalizeType('bool', knownDutNames: {}), 'BOOL');
    });
    test('a known DUT name maps to itself', () {
      expect(normalizeType('MotorType', knownDutNames: {'MotorType'}), 'MotorType');
    });
    test('unknown type falls back to INT16', () {
      expect(normalizeType('WEIRD_T', knownDutNames: {}), 'INT16');
    });
  });

  group('coerceInitialValue', () {
    test('coerces a scalar text value per app type', () {
      final w = <ImportWarning>[];
      expect(coerceInitialValue(_p(), 'INT16', 0, '42', w), 42);
      expect(coerceInitialValue(_p(), 'FLOAT64', 0, '12.5', w), 12.5);
      expect(coerceInitialValue(_p(), 'BOOL', 0, 'TRUE', w), true);
      expect(w, isEmpty);
    });
    test('null raw -> type default, no warning', () {
      final w = <ImportWarning>[];
      expect(coerceInitialValue(_p(), 'INT16', 0, null, w), 0);
      expect(w, isEmpty);
    });
    test('an array or composite initial -> type default + info warning', () {
      final w = <ImportWarning>[];
      final v = coerceInitialValue(_p(), 'FLOAT64', 2, '1.0', w);
      expect(v, isA<List<dynamic>>());
      expect(w.length, 1);
      expect(w.single.severity, WarningSeverity.info);
    });
  });
}
