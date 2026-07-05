import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/data/project_transfer.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  group('encodeProject / decodeProject round-trip', () {
    for (final original in DefaultProjects.all()) {
      test('round-trips ${original.id} losslessly', () {
        final encoded = ProjectTransfer.encodeProject(original);
        final decoded = ProjectTransfer.decodeProject(encoded);

        // Structural equality via re-serialization: since toJson is a pure
        // function of state, identical JSON implies identical structure.
        expect(jsonEncode(decoded.toJson()), jsonEncode(original.toJson()));

        expect(decoded.id, original.id);
        expect(decoded.name, original.name);
        expect(decoded.tags.length, original.tags.length);
        expect(decoded.programs.length, original.programs.length);
        expect(decoded.hmis.length, original.hmis.length);
        expect(decoded.simRules.length, original.simRules.length);
      });
    }

    test('pretty-printed JSON is indented (human/diff friendly)', () {
      final encoded = ProjectTransfer.encodeProject(DefaultProjects.all().first);
      expect(encoded, contains('\n  '));
    });
  });

  group('decodeProject rejects bad input via FormatException', () {
    test('non-JSON text throws FormatException', () {
      expect(() => ProjectTransfer.decodeProject('not json'), throwsFormatException);
    });

    test('empty string throws FormatException', () {
      expect(() => ProjectTransfer.decodeProject(''), throwsFormatException);
    });

    test('JSON array (not an object) throws FormatException', () {
      expect(() => ProjectTransfer.decodeProject('[]'), throwsFormatException);
    });

    test('JSON object with unrelated shape throws FormatException', () {
      expect(
        () => ProjectTransfer.decodeProject('{"nonsense":1}'),
        throwsFormatException,
      );
    });

    test('empty JSON object throws FormatException', () {
      expect(() => ProjectTransfer.decodeProject('{}'), throwsFormatException);
    });

    test('malformed/truncated JSON throws FormatException, not some other type', () {
      expect(() => ProjectTransfer.decodeProject('{"project": {'), throwsFormatException);
    });
  });

  group('suggestFileName', () {
    test('produces a safe .splc.json name from a simple project name', () {
      final p = PlcProject(
        id: 'proj_x',
        name: 'Motor Control',
        controllerName: 'PLC_01',
        tags: [],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );
      expect(ProjectTransfer.suggestFileName(p), 'Motor_Control.splc.json');
    });

    test('strips path separators and reserved characters', () {
      final p = PlcProject(
        id: 'proj_y',
        name: r'weird/na:me*?"<>|here',
        controllerName: 'PLC_01',
        tags: [],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );
      final name = ProjectTransfer.suggestFileName(p);
      expect(name, endsWith('.splc.json'));
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains('\\')));
      expect(name, isNot(contains(':')));
      expect(name, isNot(contains('*')));
      expect(name, isNot(contains('?')));
      expect(name, isNot(contains('"')));
      expect(name, isNot(contains('<')));
      expect(name, isNot(contains('>')));
      expect(name, isNot(contains('|')));
      expect(name, isNot(contains(' ')));
    });

    test('falls back to a default name for a blank project name', () {
      final p = PlcProject(
        id: 'proj_z',
        name: '   ',
        controllerName: 'PLC_01',
        tags: [],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );
      expect(ProjectTransfer.suggestFileName(p), 'untitled_project.splc.json');
    });
  });

  group('reassignIdIfColliding', () {
    PlcProject makeProject(String id) => PlcProject(
          id: id,
          name: 'Imported',
          controllerName: 'PLC_01',
          tags: [],
          structDefs: [],
          programs: [],
          tasks: [],
          hmis: [],
        );

    test('leaves a non-colliding id unchanged', () {
      final p = makeProject('proj_unique');
      final result = ProjectTransfer.reassignIdIfColliding(p, {'proj_other'});
      expect(result.id, 'proj_unique');
    });

    test('reassigns a colliding id to a new unique id', () {
      final p = makeProject('proj_motor');
      final result = ProjectTransfer.reassignIdIfColliding(p, {'proj_motor'});
      expect(result.id, isNot('proj_motor'));
      expect(result.id, 'proj_motor_import');
    });

    test('reassignment is deterministic and keeps incrementing on repeated collisions', () {
      final p = makeProject('proj_motor');
      final result = ProjectTransfer.reassignIdIfColliding(
        p,
        {'proj_motor', 'proj_motor_import'},
      );
      expect(result.id, 'proj_motor_import_2');
    });
  });
}
