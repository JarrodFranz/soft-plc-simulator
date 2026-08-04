// mapImportedFbs' NeutralLadderBody branch: an RLL-Logic AOI compiles to a
// native ladder FB body; a body where nothing compiles falls back to today's
// no-op + a warning; ST-bodied FBs are untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fb_import.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

ImportedVar _v(String name, String type, VarScope scope, {dynamic init}) =>
    ImportedVar(name: name, baseType: type, scope: scope, initialValue: init);

ImportedPou _ladderAoi(String name, List<ImportedVar> vars, List<String> rungTexts) =>
    ImportedPou(name: name, kind: PouKind.functionBlock, lang: PouLanguage.ld,
        localVars: vars,
        body: NeutralLadderBody(rungs: [
          for (var i = 0; i < rungTexts.length; i++)
            RllRung(number: i, text: rungTexts[i]),
        ]));

List<ImportedVar> _latchVars() => [
      _v('EnableIn', 'BOOL', VarScope.local, init: true),
      _v('EnableOut', 'BOOL', VarScope.local, init: false),
      _v('In', 'BOOL', VarScope.input),
      _v('Out', 'BOOL', VarScope.output),
    ];

void main() {
  test('a NeutralLadderBody AOI compiles to ladderRungs with an empty stSource', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Latch', _latchVars(), ['XIC(EnableIn)XIC(In)OTE(Out);']),
    ], structs: [], dutNames: {}, warnings: warnings);

    final fb = res.defs.single;
    expect(fb.name, 'Latch');
    expect(fb.stSource, '');
    expect(fb.ladderRungs, hasLength(1));
    expect(fb.ladderRungs.single.nodes.where((n) => n.kind == LdKind.contact)
        .map((n) => n.variable), ['EnableIn', 'In']);
    expect(fb.ladderRungs.single.nodes.where((n) => n.kind == LdKind.coil)
        .single.variable, 'Out');
    // EnableIn/EnableOut land as internal vars with their initial values.
    expect(fb.vars.map((v) => v.name), ['EnableIn', 'EnableOut', 'In', 'Out']);
    expect(fb.vars[0].direction, FbVarDir.internal);
    expect(fb.vars[0].initialValue, true);
    expect(fb.vars[1].initialValue, false);
    expect(res.registry['Latch'], same(fb));
    expect(res.renameMap['Latch'], 'Latch');
  });

  test('AOI-body compile counters ride on FbImportResult', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Mix', _latchVars(),
          ['XIC(In)OTE(Out);', 'CPT(Dest,Expr);']), // 2nd is unsupported
    ], structs: [], dutNames: {}, warnings: warnings);

    expect(res.translatedRllRungCount, 1);
    expect(res.stubbedRllRungCount, 1);
    expect(res.unsupportedRllInstructions, contains('CPT'));
    expect(res.rllStubReasons['unsupported-instruction'], 1);
    expect(res.defs.single.ladderRungs, hasLength(2)); // stub kept as placeholder
  });

  test('an AOI where NOTHING compiles falls back to the no-op body + a warning', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Bad', _latchVars(), ['CPT(A,B);']),
    ], structs: [], dutNames: {}, warnings: warnings);

    final fb = res.defs.single;
    expect(fb.ladderRungs, isEmpty); // no-op, exactly like before this feature
    expect(fb.stSource, '');
    expect(warnings.any((w) =>
        w.severity == WarningSeverity.warning &&
        w.message.contains('Bad') &&
        w.message.contains('ladder')), isTrue);
  });

  test('an AOI ladder calling an EARLIER AOI routes to that FB', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Inner', [_v('X', 'BOOL', VarScope.input)], ['XIC(X)OTE(X);']),
      _ladderAoi('Outer', [_v('Y', 'BOOL', VarScope.input)], ['Inner(I1,Y);']),
    ], structs: [], dutNames: {}, warnings: warnings);

    final outer = res.defs.firstWhere((d) => d.name == 'Outer');
    expect(outer.ladderRungs.single.nodes.any((n) => n.blockType == 'Inner'), isTrue);
  });

  test('an AOI ladder calling an AOI defined LATER stubs that rung (ordering limit)', () {
    // Spec §5's documented forward-reference limitation: the registry grows in
    // document order, so the callee must precede the caller. Rockwell exports
    // list dependencies first, so this is rare — but it must degrade, not throw.
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Outer', [_v('Y', 'BOOL', VarScope.input)], ['Callee(C1,Y);']),
      _ladderAoi('Callee', [_v('Z', 'BOOL', VarScope.input)], ['XIC(Z)OTE(Z);']),
    ], structs: [], dutNames: {}, warnings: warnings);

    final outer = res.defs.firstWhere((d) => d.name == 'Outer');
    // The forward reference is an unknown mnemonic: that rung stubs to an
    // inert rail-to-rail placeholder, and the caller has NO real logic left.
    expect(outer.ladderRungs, isEmpty);
    expect(outer.stSource, '');
    expect(res.unsupportedRllInstructions, contains('Callee'));
    expect(res.rllStubReasons['unsupported-instruction'], 1);
    expect(warnings.any((w) =>
        w.severity == WarningSeverity.warning && w.message.contains('Outer')), isTrue);

    // The callee itself, defined later, still compiles normally.
    expect(res.defs.firstWhere((d) => d.name == 'Callee').ladderRungs, hasLength(1));
  });

  test('ST-bodied FBs are untouched (regression)', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      ImportedPou(name: 'Scaler', kind: PouKind.functionBlock, lang: PouLanguage.st,
          localVars: [_v('In', 'REAL', VarScope.input), _v('Out', 'REAL', VarScope.output)],
          body: TextBody('Out := In * 2.0;')),
    ], structs: [], dutNames: {}, warnings: warnings);

    expect(res.defs.single.stSource, 'Out := In * 2.0;');
    expect(res.defs.single.ladderRungs, isEmpty);
    expect(res.translatedRllRungCount, 0);
  });

  test('AOI-body rungs fold into the report\'s existing RLL fields', () {
    final ir = ImportedProject(name: 'P', types: const [], globalVars: const [],
        warnings: const [],
        pous: [_ladderAoi('Latch', _latchVars(), ['XIC(In)OTE(Out);'])]);
    final res = mapImportedProject(ir, projectName: 'P', projectId: 'x');
    expect(res.report.translatedRllRungCount, 1);
    expect(res.report.importedFbCount, 1);
    expect(res.project.fbDefinitions.single.ladderRungs, hasLength(1));
  });
}
