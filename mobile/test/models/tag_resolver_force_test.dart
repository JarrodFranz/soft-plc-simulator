import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _proj(List<PlcTag> tags) => PlcProject(
      id: 'p',
      name: 'p',
      controllerName: 'PLC_01',
      tags: tags,
      structDefs: const [],
      programs: const [],
      tasks: const [],
      hmis: const [],
    );

void main() {
  group('readPath force overlay', () {
    test('forced BOOL scalar reads forcedValue, not stored value', () {
      final p = _proj([
        PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL',
            value: false, ioType: 'SimulatedInput', isForced: true, forcedValue: true),
      ]);
      expect(readPath(p, 'Start_PB'), true);
    });

    test('unforced tag reads stored value', () {
      final p = _proj([
        PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL',
            value: false, ioType: 'SimulatedInput'),
      ]);
      expect(readPath(p, 'Start_PB'), false);
    });

    test('forced numeric scalar reads forcedValue', () {
      final p = _proj([
        PlcTag(name: 'Speed', path: 'Internal/Speed', dataType: 'INT32',
            value: 10, ioType: 'Internal', isForced: true, forcedValue: 55),
      ]);
      expect(readPath(p, 'Speed'), 55);
    });

    test('forced integer bit-read reflects forced integer', () {
      // forcedValue 0x04 -> bit 2 set, bits 0/1 clear.
      final p = _proj([
        PlcTag(name: 'Word', path: 'Internal/Word', dataType: 'INT16',
            value: 0, ioType: 'Internal', isForced: true, forcedValue: 4),
      ]);
      expect(readPath(p, 'Word.2'), true);
      expect(readPath(p, 'Word.0'), false);
    });

    test('force cleared returns to live value', () {
      final p = _proj([
        PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL',
            value: false, ioType: 'SimulatedInput', isForced: false, forcedValue: true),
      ]);
      expect(readPath(p, 'Start_PB'), false);
    });
  });
}
