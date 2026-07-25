import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fb_import.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

ImportedVar _v(String name, String type, VarScope scope, {dynamic init}) =>
    ImportedVar(name: name, baseType: type, scope: scope, initialValue: init);

ImportedPou _fbPou(String name, List<ImportedVar> vars, String st,
        {PouLanguage lang = PouLanguage.st}) =>
    ImportedPou(name: name, kind: PouKind.functionBlock, lang: lang,
        localVars: vars, body: TextBody(st));

void main() {
  test('ST functionBlock POU -> FbDefinition with vars, directions, body', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _fbPou('Scaler', [
        _v('In', 'REAL', VarScope.input),
        _v('Gain', 'REAL', VarScope.input, init: '2.0'),
        _v('Acc', 'REAL', VarScope.local),
        _v('Out', 'REAL', VarScope.output),
      ], 'Out := In * Gain;'),
    ], structs: [], dutNames: {}, warnings: warnings);

    expect(res.defs, hasLength(1));
    final fb = res.defs.single;
    expect(fb.name, 'Scaler');
    expect(fb.stSource, 'Out := In * Gain;');
    expect(fb.vars.map((v) => v.name).toList(), ['In', 'Gain', 'Acc', 'Out']);
    expect(fb.vars.map((v) => v.direction).toList(), [
      FbVarDir.input, FbVarDir.input, FbVarDir.internal, FbVarDir.output,
    ]);
    expect(fb.vars[0].dataType, 'FLOAT64'); // REAL normalized
    expect(fb.vars[1].initialValue, 2.0);   // coerced
    expect(res.registry.containsKey('Scaler'), isTrue);
    expect(res.renameMap['Scaler'], 'Scaler');
  });

  test('inOut var maps to input + info warning', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _fbPou('Acc', [_v('Sum', 'INT', VarScope.inOut)], 'Sum := Sum + 1;'),
    ], structs: [], dutNames: {}, warnings: warnings);
    expect(res.defs.single.vars.single.direction, FbVarDir.input);
    expect(warnings.any((w) =>
        w.severity == WarningSeverity.info && w.message.contains('VAR_IN_OUT')), isTrue);
  });

  test('graphical-bodied functionBlock POU is skipped with a warning', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      ImportedPou(name: 'Mixer', kind: PouKind.functionBlock, lang: PouLanguage.fbd,
          localVars: const [], body: GraphBody(nodes: const [], connections: const [])),
    ], structs: [], dutNames: {}, warnings: warnings);
    expect(res.defs, isEmpty);
    expect(res.registry, isEmpty);
    expect(warnings.any((w) =>
        w.severity == WarningSeverity.warning && w.message.contains('graphical body')), isTrue);
  });

  test('FB name colliding with a reserved block type is renamed + warned', () {
    final warnings = <ImportWarning>[];
    // 'AND' is a reserved built-in block type (fbNameValidationError rejects it).
    final res = mapImportedFbs([
      _fbPou('AND', [_v('a', 'BOOL', VarScope.input), _v('q', 'BOOL', VarScope.output)],
          'q := a;'),
    ], structs: [], dutNames: {}, warnings: warnings);
    final fb = res.defs.single;
    expect(fb.name, isNot('AND'));
    expect(res.registry.containsKey(fb.name), isTrue);
    expect(res.renameMap['AND'], fb.name); // original -> final
    expect(warnings.any((w) => w.message.contains('renamed')), isTrue);
  });

  test('non-functionBlock POUs are ignored', () {
    final res = mapImportedFbs([
      ImportedPou(name: 'Main', kind: PouKind.program, lang: PouLanguage.st,
          localVars: const [], body: TextBody('X := 1;')),
    ], structs: [], dutNames: {}, warnings: []);
    expect(res.defs, isEmpty);
  });
}
