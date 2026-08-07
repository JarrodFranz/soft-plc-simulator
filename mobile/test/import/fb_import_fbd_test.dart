// mapImportedFbs' FBD arm: an L5X FBD-Logic AOI compiles at import into an
// FBD-bodied FbDefinition, against the FB registry built SO FAR. PLCopen FBD
// functionBlock POUs keep the old warning path (dialect gate, spec R2).
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fb_import.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

ImportedVar _v(String name, String type, VarScope scope) =>
    ImportedVar(name: name, baseType: type, scope: scope);

/// TAG_INPUT('In') -> NOT -> TAG_OUTPUT('Out') as neutral IR.
GraphBody _notBody() => GraphBody(nodes: [
      IrGraphNode(localId: 0, elementType: 'inVariable', x: 0, y: 0,
          attributes: {'variable': 'In'}),
      IrGraphNode(localId: 1, elementType: 'block', x: 50, y: 0,
          attributes: {'typeName': 'NOT'}),
      IrGraphNode(localId: 2, elementType: 'outVariable', x: 100, y: 0,
          attributes: {'variable': 'Out'}),
    ], connections: [
      IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'IN'),
      IrConnection(fromLocalId: 1, fromPin: 'OUT', toLocalId: 2, toPin: 'IN'),
    ]);

ImportedPou _fbdAoi(String name, GraphBody body, {List<ImportedVar>? vars}) =>
    ImportedPou(
      name: name,
      kind: PouKind.functionBlock,
      lang: PouLanguage.fbd,
      localVars: vars ??
          [
            _v('In', 'BOOL', VarScope.input),
            _v('Out', 'BOOL', VarScope.output),
          ],
      body: body,
    );

/// A trivial ST-bodied FB with a BOOL `In`/`Out` interface, so an FBD AOI can
/// call it as a nested instance.
ImportedPou _stFb(String name) => ImportedPou(
      name: name,
      kind: PouKind.functionBlock,
      lang: PouLanguage.st,
      localVars: [
        _v('In', 'BOOL', VarScope.input),
        _v('Out', 'BOOL', VarScope.output),
      ],
      body: TextBody('Out := In;'));

FbImportResult _map(List<ImportedPou> pous, List<ImportWarning> warnings,
        {ImportDialect dialect = ImportDialect.l5x}) =>
    mapImportedFbs(pous,
        structs: const [], dutNames: const {}, warnings: warnings,
        dialect: dialect);

void main() {
  test('an L5X FBD AOI becomes an FBD-bodied FbDefinition', () {
    final warnings = <ImportWarning>[];
    final res = _map([_fbdAoi('Inverter', _notBody())], warnings);

    final def = res.defs.single;
    expect(def.name, 'Inverter');
    expect(def.stSource, '');
    expect(def.ladderRungs, isEmpty);
    expect(def.fbdBlocks.map((b) => b.type), ['TAG_INPUT', 'NOT', 'TAG_OUTPUT']);
    expect(def.fbdWires, hasLength(2));
    expect(def.fbdNetworks, hasLength(1));
    expect(res.translatedFbdNetworkCount, 1);
    expect(res.stubbedFbdNetworkCount, 0);
    expect(warnings.any((w) => w.message.contains('not imported')), isFalse);
  });

  test('a PLCopen FBD functionBlock keeps the unchanged warning path', () {
    final warnings = <ImportWarning>[];
    final res = _map([_fbdAoi('PlcopenFb', _notBody())], warnings,
        dialect: ImportDialect.plcOpen);

    expect(res.defs, isEmpty);
    final w = warnings.single;
    expect(w.severity, WarningSeverity.warning);
    expect(w.message, contains('Function block "PlcopenFb" has a graphical body'));
    expect(w.message, contains('(fbd)'));
    expect(w.message, contains('not imported'));
    expect(w.message, contains('3 elements captured'));
  });

  test('zero translated networks -> interface-only + a warning naming the AOI', () {
    final warnings = <ImportWarning>[];
    final bad = GraphBody(nodes: [
      IrGraphNode(localId: 0, elementType: 'block', attributes: {'typeName': 'SCL'}),
    ], connections: const []);
    final res = _map([_fbdAoi('Scaler', bad)], warnings);

    final def = res.defs.single;
    expect(def.fbdBlocks, isEmpty);
    expect(def.vars.map((v) => v.name), ['In', 'Out']); // interface survives
    expect(
        warnings.any((w) =>
            w.severity == WarningSeverity.warning &&
            w.message.contains('Scaler') &&
            w.message.contains('logic not translated')),
        isTrue);
    expect(res.unsupportedFbdBlockTypes, contains('SCL'));
    expect(res.fbdStubReasons['unsupported-block'], 1);
  });

  test('a ZERO-NODE FBD body is silent (nothing to fail at)', () {
    final warnings = <ImportWarning>[];
    final res = _map([
      _fbdAoi('Empty', GraphBody(nodes: const [], connections: const [])),
    ], warnings);

    expect(res.defs.single.fbdBlocks, isEmpty);
    expect(warnings.any((w) => w.message.contains('Empty')), isFalse);
  });

  test('registry-so-far: an AOI defined EARLIER routes, a LATER one stubs', () {
    final warnings = <ImportWarning>[];
    GraphBody callBody(String type) => GraphBody(nodes: [
          IrGraphNode(localId: 0, elementType: 'inVariable',
              attributes: {'variable': 'In'}),
          IrGraphNode(localId: 1, elementType: 'block',
              attributes: {'typeName': type, 'instanceName': 'Nested'}),
          IrGraphNode(localId: 2, elementType: 'outVariable',
              attributes: {'variable': 'Out'}),
        ], connections: [
          IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'In'),
          IrConnection(fromLocalId: 1, fromPin: 'Out', toLocalId: 2, toPin: 'IN'),
        ]);

    final res = _map([
      ImportedPou(name: 'Leaf', kind: PouKind.functionBlock,
          lang: PouLanguage.st,
          localVars: [_v('In', 'BOOL', VarScope.input), _v('Out', 'BOOL', VarScope.output)],
          body: TextBody('Out := In;')),
      _fbdAoi('UsesEarlier', callBody('Leaf')),
      _fbdAoi('UsesLater', callBody('Future')),
      ImportedPou(name: 'Future', kind: PouKind.functionBlock,
          lang: PouLanguage.st,
          localVars: [_v('In', 'BOOL', VarScope.input), _v('Out', 'BOOL', VarScope.output)],
          body: TextBody('Out := In;')),
    ], warnings);

    final earlier = res.defs.firstWhere((d) => d.name == 'UsesEarlier');
    expect(earlier.fbdBlocks.map((b) => b.type), contains('Leaf'));

    final later = res.defs.firstWhere((d) => d.name == 'UsesLater');
    expect(later.fbdBlocks, isEmpty); // forward reference stubs
    expect(res.unsupportedFbdBlockTypes, contains('Future'));
  });

  test('R3: a nested instance reuses a matching FbVar, else synthesizes one', () {
    GraphBody nested() => GraphBody(nodes: [
          IrGraphNode(localId: 0, elementType: 'inVariable',
              attributes: {'variable': 'In'}),
          IrGraphNode(localId: 1, elementType: 'block',
              attributes: {'typeName': 'Leaf', 'instanceName': 'Nested'}),
          IrGraphNode(localId: 2, elementType: 'outVariable',
              attributes: {'variable': 'Out'}),
        ], connections: [
          IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'In'),
          IrConnection(fromLocalId: 1, fromPin: 'Out', toLocalId: 2, toPin: 'IN'),
        ]);
    final leaf = ImportedPou(name: 'Leaf', kind: PouKind.functionBlock,
        lang: PouLanguage.st,
        localVars: [_v('In', 'BOOL', VarScope.input), _v('Out', 'BOOL', VarScope.output)],
        body: TextBody('Out := In;'));

    // (a) The AOI already declares a LocalTag typed as the nested AOI.
    final warnA = <ImportWarning>[];
    final resA = _map([
      leaf,
      _fbdAoi('OuterA', nested(), vars: [
        _v('In', 'BOOL', VarScope.input),
        _v('Out', 'BOOL', VarScope.output),
        _v('Nested', 'Leaf', VarScope.local),
      ]),
    ], warnA);
    final a = resA.defs.firstWhere((d) => d.name == 'OuterA');
    expect(a.vars.where((v) => v.name == 'Nested'), hasLength(1)); // no dupe
    expect(a.vars.firstWhere((v) => v.name == 'Nested').dataType, 'Leaf');

    // (b) No such var: one is synthesized as an INTERNAL var so the nested
    // instance lives inside the AOI struct (per-instance state).
    final warnB = <ImportWarning>[];
    final resB = _map([leaf, _fbdAoi('OuterB', nested())], warnB);
    final b = resB.defs.firstWhere((d) => d.name == 'OuterB');
    final syn = b.vars.firstWhere((v) => v.name == 'Nested');
    expect(syn.dataType, 'Leaf');
    expect(syn.direction, FbVarDir.internal);
    expect(syn.initialValue, isA<Map>());
  });

  test('R3: a synthesized nested-instance name is sanitized and retargeted', () {
    final leaf = ImportedPou(name: 'Leaf', kind: PouKind.functionBlock,
        lang: PouLanguage.st,
        localVars: [_v('In', 'BOOL', VarScope.input), _v('Out', 'BOOL', VarScope.output)],
        body: TextBody('Out := In;'));
    // A Logix Operand is not bound by this app's identifier rules.
    final body = GraphBody(nodes: [
      IrGraphNode(localId: 0, elementType: 'inVariable',
          attributes: {'variable': 'In'}),
      IrGraphNode(localId: 1, elementType: 'block',
          attributes: {'typeName': 'Leaf', 'instanceName': 'Pump-1'}),
      IrGraphNode(localId: 2, elementType: 'outVariable',
          attributes: {'variable': 'Out'}),
    ], connections: [
      IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'In'),
      IrConnection(fromLocalId: 1, fromPin: 'Out', toLocalId: 2, toPin: 'IN'),
    ]);

    final warnings = <ImportWarning>[];
    final res = _map([leaf, _fbdAoi('Outer', body)], warnings);
    final outer = res.defs.firstWhere((d) => d.name == 'Outer');

    // NOTE: translateFbdBody's own `_fbInstanceName` rejects 'Pump-1' as an
    // identifier and falls back to '<pouName>_fb<localId>'; whichever name
    // arrives, the var and the block binding must AGREE and must be a legal
    // identifier, or the nested instance is unaddressable at runtime.
    final callBlock = outer.fbdBlocks.firstWhere((b) => b.type == 'Leaf');
    expect(RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(callBlock.tagBinding),
        isTrue);
    expect(outer.vars.map((v) => v.name), contains(callBlock.tagBinding));
    expect(
        outer.vars.firstWhere((v) => v.name == callBlock.tagBinding).dataType,
        'Leaf');
  });

  test('R3: a retarget never cascades onto a block an EARLIER tag already moved', () {
    // Two call networks stacked so the layout-ordered instance tags arrive
    // Leaf-first: 'Nested' (Leaf) at y=0, 'Nested_2' (Other) at y=200. The AOI
    // declares an UNRELATED BOOL local called 'Nested', which forces the
    // type-mismatch dedupe branch — 'Nested' -> 'Nested_2', which is exactly
    // the name the SECOND call block still carries. Rescanning every block for
    // the second tag's original name would drag the Leaf block along with it.
    final body = GraphBody(nodes: [
      IrGraphNode(localId: 0, elementType: 'inVariable', y: 0,
          attributes: {'variable': 'In'}),
      IrGraphNode(localId: 1, elementType: 'block', x: 50, y: 0,
          attributes: {'typeName': 'Leaf', 'instanceName': 'Nested'}),
      IrGraphNode(localId: 2, elementType: 'outVariable', x: 100, y: 0,
          attributes: {'variable': 'Out'}),
      IrGraphNode(localId: 3, elementType: 'inVariable', y: 200,
          attributes: {'variable': 'In2'}),
      IrGraphNode(localId: 4, elementType: 'block', x: 50, y: 200,
          attributes: {'typeName': 'Other', 'instanceName': 'Nested_2'}),
      IrGraphNode(localId: 5, elementType: 'outVariable', x: 100, y: 200,
          attributes: {'variable': 'Out2'}),
    ], connections: [
      IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'In'),
      IrConnection(fromLocalId: 1, fromPin: 'Out', toLocalId: 2, toPin: 'IN'),
      IrConnection(fromLocalId: 3, fromPin: 'OUT', toLocalId: 4, toPin: 'In'),
      IrConnection(fromLocalId: 4, fromPin: 'Out', toLocalId: 5, toPin: 'IN'),
    ]);

    final warnings = <ImportWarning>[];
    final res = _map([
      _stFb('Leaf'),
      _stFb('Other'),
      _fbdAoi('Outer', body, vars: [
        _v('In', 'BOOL', VarScope.input),
        _v('Out', 'BOOL', VarScope.output),
        _v('In2', 'BOOL', VarScope.input),
        _v('Out2', 'BOOL', VarScope.output),
        _v('Nested', 'BOOL', VarScope.local),
      ]),
    ], warnings);

    final outer = res.defs.firstWhere((d) => d.name == 'Outer');
    final leafBlock = outer.fbdBlocks.firstWhere((b) => b.type == 'Leaf');
    final otherBlock = outer.fbdBlocks.firstWhere((b) => b.type == 'Other');
    expect(leafBlock.tagBinding, isNot(otherBlock.tagBinding));
    // Each call block must land on a member of its OWN type.
    expect(outer.vars.firstWhere((v) => v.name == leafBlock.tagBinding).dataType,
        'Leaf');
    expect(outer.vars.firstWhere((v) => v.name == otherBlock.tagBinding).dataType,
        'Other');
    // The AOI's own unrelated BOOL local is left exactly as declared.
    expect(outer.vars.firstWhere((v) => v.name == 'Nested').dataType, 'BOOL');
    expect(
        warnings.any((w) =>
            w.severity == WarningSeverity.info &&
            w.message.contains('may not resolve')),
        isTrue);
  });

  test('R3: two nested instances never SHARE one synthesized member', () {
    // 'Pump-1' is not an identifier, so translateFbdBody falls back to
    // '<pouName>_fb<localId>' and the mapper sanitizes it to 'AOI_Outer_fb1'.
    // The SECOND call block is literally named 'AOI_Outer_fb1' and is the SAME
    // type, so the same-type reuse path would hand both instances one member —
    // and one member means one shared lump of nested state.
    final body = GraphBody(nodes: [
      IrGraphNode(localId: 0, elementType: 'inVariable', y: 0,
          attributes: {'variable': 'In'}),
      IrGraphNode(localId: 1, elementType: 'block', x: 50, y: 0,
          attributes: {'typeName': 'Leaf', 'instanceName': 'Pump-1'}),
      IrGraphNode(localId: 2, elementType: 'outVariable', x: 100, y: 0,
          attributes: {'variable': 'Out'}),
      IrGraphNode(localId: 3, elementType: 'inVariable', y: 200,
          attributes: {'variable': 'In2'}),
      IrGraphNode(localId: 4, elementType: 'block', x: 50, y: 200,
          attributes: {'typeName': 'Leaf', 'instanceName': 'AOI_Outer_fb1'}),
      IrGraphNode(localId: 5, elementType: 'outVariable', x: 100, y: 200,
          attributes: {'variable': 'Out2'}),
    ], connections: [
      IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'In'),
      IrConnection(fromLocalId: 1, fromPin: 'Out', toLocalId: 2, toPin: 'IN'),
      IrConnection(fromLocalId: 3, fromPin: 'OUT', toLocalId: 4, toPin: 'In'),
      IrConnection(fromLocalId: 4, fromPin: 'Out', toLocalId: 5, toPin: 'IN'),
    ]);

    final warnings = <ImportWarning>[];
    final res = _map([
      _stFb('Leaf'),
      _fbdAoi('Outer', body, vars: [
        _v('In', 'BOOL', VarScope.input),
        _v('Out', 'BOOL', VarScope.output),
        _v('In2', 'BOOL', VarScope.input),
        _v('Out2', 'BOOL', VarScope.output),
      ]),
    ], warnings);

    final outer = res.defs.firstWhere((d) => d.name == 'Outer');
    final calls = outer.fbdBlocks.where((b) => b.type == 'Leaf').toList();
    expect(calls, hasLength(2));
    expect(calls[0].tagBinding, isNot(calls[1].tagBinding));
    for (final b in calls) {
      expect(outer.vars.firstWhere((v) => v.name == b.tagBinding).dataType, 'Leaf');
    }
  });
}
