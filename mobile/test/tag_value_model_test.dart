import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

PlcProject _emptyProject() => PlcProject(
      id: 'p', name: 'P', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: [], tags: [],
    );

void main() {
  group('PlcTag.defaultValue', () {
    test('round-trips through toJson/fromJson', () {
      final tag = PlcTag(name: 'A', path: 'A', dataType: 'INT16', value: 5,
          defaultValue: 3, ioType: 'Internal');
      final round = PlcTag.fromJson(tag.toJson());
      expect(round.defaultValue, 3);
      expect(round.value, 5);
      expect(tag.toJson()['default_value'], 3);
    });

    test('a JSON without default_value adopts initial_value as the default', () {
      final json = {
        'name': 'B', 'path': 'B', 'data_type': 'FLOAT64',
        'initial_value': 12.5, 'io_type': 'Internal',
      };
      final tag = PlcTag.fromJson(json);
      expect(tag.value, 12.5);
      expect(tag.defaultValue, 12.5);
    });

    test('effectiveDefault returns defaultValue when set', () {
      final tag = PlcTag(name: 'C', path: 'C', dataType: 'INT16', value: 9,
          defaultValue: 7, ioType: 'Internal');
      expect(tag.effectiveDefault(_emptyProject()), 7);
    });

    test('effectiveDefault falls back to the type default when null', () {
      final tag = PlcTag(name: 'D', path: 'D', dataType: 'FLOAT64', value: 4.0,
          ioType: 'Internal');
      expect(tag.defaultValue, isNull);
      expect(tag.effectiveDefault(_emptyProject()), 0.0);
    });
  });
}
