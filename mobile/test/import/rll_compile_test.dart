import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/rll_compile.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

NeutralLadderBody _body(List<String> texts) => NeutralLadderBody(
    rungs: [for (var i = 0; i < texts.length; i++) RllRung(number: i, text: texts[i])]);

void main() {
  test('contacts + coil compile to a series rung', () {
    final tr = compileRllRungs(_body(['XIC(A)XIO(B)OTE(C);']), pouName: 'P');
    expect(tr.translatedRungCount, 1);
    final nodes = tr.rungs.single.nodes;
    final a = nodes.firstWhere((n) => n.variable == 'A');
    expect(a.kind, LdKind.contact);
    expect(a.modifier, 'normal');
    expect(nodes.firstWhere((n) => n.variable == 'B').modifier, 'negated');
    final c = nodes.firstWhere((n) => n.variable == 'C');
    expect(c.kind, LdKind.coil);
    expect(c.modifier, 'normal');
  });

  test('OTL/OTU -> set/reset coils', () {
    final tr = compileRllRungs(_body(['OTL(A);', 'OTU(B);']), pouName: 'P');
    expect(tr.rungs[0].nodes.firstWhere((n) => n.variable == 'A').modifier, 'set');
    expect(tr.rungs[1].nodes.firstWhere((n) => n.variable == 'B').modifier, 'reset');
  });

  test('branch -> parallel lanes', () {
    final tr = compileRllRungs(_body(['XIC(A)[XIC(B),XIC(C)]OTE(D);']), pouName: 'P');
    expect(tr.translatedRungCount, 1);
    final rows = tr.rungs.single.nodes.map((n) => n.row).toSet();
    expect(rows.contains(1), isTrue); // a parallel lane exists
  });

  test('compare / math / MOV blocks', () {
    final tr = compileRllRungs(
        _body(['EQU(x,y)OTE(f);', 'ADD(a,b,d);', 'MOV(s,t);']), pouName: 'P');
    final eq = tr.rungs[0].nodes.firstWhere((n) => n.blockType == 'EQ');
    expect(eq.operandA, 'x');
    expect(eq.operandB, 'y');
    final add = tr.rungs[1].nodes.firstWhere((n) => n.blockType == 'ADD');
    expect(add.operandA, 'a');
    expect(add.operandB, 'b');
    expect(add.variable, 'd');
    final mov = tr.rungs[2].nodes.firstWhere((n) => n.blockType == 'MOVE');
    expect(mov.operandA, 's');
    expect(mov.variable, 't');
  });

  test('MOVE alias compiles to the same nodes as MOV', () {
    final trMove = compileRllRungs(_body(['MOVE(5,Out);']), pouName: 'P');
    final trMov = compileRllRungs(_body(['MOV(5,Out);']), pouName: 'P');
    expect(trMove.translatedRungCount, 1);
    final moveNode = trMove.rungs[0].nodes.firstWhere((n) => n.blockType == 'MOVE');
    final movNode = trMov.rungs[0].nodes.firstWhere((n) => n.blockType == 'MOVE');
    expect(moveNode.operandA, movNode.operandA);
    expect(moveNode.variable, movNode.variable);
    expect(moveNode.operandA, '5');
    expect(moveNode.variable, 'Out');
  });

  test('timer with literal preset is exact; with ? preset defaults + warns', () {
    final tr = compileRllRungs(_body(['TON(T1,5000,0);', 'TON(T2,?,?);']), pouName: 'P');
    expect(tr.translatedRungCount, 2); // both translate (best-effort)
    expect(tr.rungs[0].nodes.firstWhere((n) => n.blockType == 'TON').presetMs, 5000);
    expect(tr.warnings.any((w) => w.message.contains('T2') && w.message.contains('preset')), isTrue);
  });

  test('NOP -> empty valid rung', () {
    final tr = compileRllRungs(_body(['NOP();']), pouName: 'P');
    expect(tr.translatedRungCount, 1);
  });

  test('RTO + unknown mnemonic + nested branch stub their rung', () {
    final tr = compileRllRungs(
        _body(['RTO(T,?,?);', 'FOO(A);', 'XIC(A)[[XIC(B)],XIC(C)]OTE(D);']), pouName: 'P');
    expect(tr.translatedRungCount, 0);
    expect(tr.stubbedRungCount, 3);
    expect(tr.stubReasons['unsupported-instruction'], 2); // RTO + FOO
    expect(tr.stubReasons['complex-topology'], 1);        // nested branch
    expect(tr.unsupportedInstructions, containsAll(['RTO', 'FOO']));
    // placeholder rungs preserve numbering
    expect(tr.rungs, hasLength(3));
  });

  FbDefinition scalerFb() => FbDefinition(name: 'Scaler', vars: [
        FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      ], stSource: 'Out := In * Gain;');

  test('AOI call with matching arity -> FB-call node with positional pinBindings', () {
    final tr = compileRllRungs(_body(['Scaler(Inst1,PV,2.0,CV);']),
        pouName: 'P', fbRegistry: {'Scaler': scalerFb()});
    expect(tr.translatedRungCount, 1);
    final fb = tr.rungs.single.nodes.firstWhere((n) => n.blockType == 'Scaler');
    expect(fb.variable, 'Inst1');
    expect(fb.pinBindings['In'], 'PV');
    expect(fb.pinBindings['Gain'], '2.0');
    expect(fb.pinBindings['Out'], 'CV');
  });

  test('renamed AOI routes via fbRenameMap', () {
    final tr = compileRllRungs(_body(['AND(I1,X);']), pouName: 'P',
        fbRegistry: {
          'AND_1': FbDefinition(name: 'AND_1', vars: [
            FbVar(name: 'X', dataType: 'BOOL', direction: FbVarDir.input),
          ], stSource: '')
        },
        fbRenameMap: {'AND': 'AND_1'});
    expect(tr.translatedRungCount, 1);
    expect(tr.rungs.single.nodes.any((n) => n.blockType == 'AND_1'), isTrue);
  });

  test('AOI arity mismatch stubs the rung', () {
    final tr = compileRllRungs(_body(['Scaler(Inst1,PV);']),
        pouName: 'P', fbRegistry: {'Scaler': scalerFb()});
    expect(tr.translatedRungCount, 0);
    expect(tr.stubReasons['aoi-mismatch'], 1);
    expect(tr.unsupportedInstructions, contains('Scaler'));
  });

  test('adversarial deeply-nested branch text degrades to a placeholder rung '
      'instead of crashing the whole import (never-throws invariant)', () {
    final deep = '${'[' * 5000}XIC(A)${']' * 5000}';
    final tr = compileRllRungs(_body([deep]), pouName: 'P');
    expect(tr.translatedRungCount, 0);
    expect(tr.stubbedRungCount, 1);
    expect(tr.stubReasons['parse-error'], 1);
    expect(tr.rungs, hasLength(1));
  });

  test('AOI arity/binding ignores INTERNAL vars (LocalTags, EnableIn/EnableOut)', () {
    // Neutral text passes the instance tag + the AOI's interface params only.
    final aoi = FbDefinition(name: 'Latch', vars: [
      FbVar(name: 'EnableIn', dataType: 'BOOL', direction: FbVarDir.internal, initialValue: true),
      FbVar(name: 'EnableOut', dataType: 'BOOL', direction: FbVarDir.internal, initialValue: false),
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Tmp', dataType: 'BOOL', direction: FbVarDir.internal),
    ]);
    final tr = compileRllRungs(_body(['Latch(A1,Src,Dst);']),
        pouName: 'P', fbRegistry: {'Latch': aoi});
    expect(tr.translatedRungCount, 1);
    final node = tr.rungs.single.nodes.firstWhere((n) => n.blockType == 'Latch');
    expect(node.variable, 'A1');
    expect(node.pinBindings, {'In': 'Src', 'Out': 'Dst'});
  });
}
