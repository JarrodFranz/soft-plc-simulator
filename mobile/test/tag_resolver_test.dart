import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _proj(List<PlcTag> tags, {List<PlcStructDef> defs = const []}) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: defs, programs: [], tasks: [], hmis: [],
    );

PlcTag _tag(String name, String type, dynamic value, {int arrayLength = 0}) =>
    PlcTag(name: name, path: name, dataType: type, value: value, ioType: 'Internal', arrayLength: arrayLength);

void main() {
  test('defaultValueFor builds scalars, composites, and arrays recursively', () {
    final p = _proj([]);
    expect(defaultValueFor(p, 'BOOL', 0), isFalse);
    expect(defaultValueFor(p, 'INT16', 0), equals(0));
    final timer = defaultValueFor(p, 'TIMER', 0) as Map;
    expect(timer['DN'], isFalse);
    expect(timer['PRE'], equals(5000));
    final arr = defaultValueFor(p, 'INT16', 3) as List;
    expect(arr.length, equals(3));
    expect(arr[0], equals(0));
  });

  test('readPath resolves a struct member', () {
    final p = _proj([_tag('T', 'TIMER', defaultValueFor(_proj([]), 'TIMER', 0))]);
    expect(readPath(p, 'T.PRE'), equals(5000));
    expect(readPath(p, 'T.DN'), isFalse);
    expect(readPath(p, 'T.NOPE'), isNull);
  });

  test('readPath resolves an integer bit', () {
    final p = _proj([_tag('W', 'INT16', 5)]); // 0b101
    expect(readPath(p, 'W.0'), isTrue);
    expect(readPath(p, 'W.1'), isFalse);
    expect(readPath(p, 'W.2'), isTrue);
  });

  test('readPath resolves a nested array-of-struct member', () {
    final p = _proj(
      [_tag('Motors', 'TIMER', [
        defaultValueFor(_proj([]), 'TIMER', 0),
        defaultValueFor(_proj([]), 'TIMER', 0),
      ], arrayLength: 2)],
    );
    (readPath(p, 'Motors[1]') as Map)['ACC'] = 42;
    expect(readPath(p, 'Motors[1].ACC'), equals(42));
    expect(readPath(p, 'Motors[9].ACC'), isNull); // out of range
  });

  test('writePath sets a member and a bit', () {
    final p = _proj([
      _tag('T', 'TIMER', defaultValueFor(_proj([]), 'TIMER', 0)),
      _tag('W', 'INT16', 0),
    ]);
    writePath(p, 'T.ACC', 123);
    expect(readPath(p, 'T.ACC'), equals(123));
    writePath(p, 'W.3', true);
    expect(readPath(p, 'W'), equals(8));   // bit 3 set
    writePath(p, 'W.3', false);
    expect(readPath(p, 'W'), equals(0));
  });

  test('writePath no-ops on invalid/out-of-range paths (no throw)', () {
    final p = _proj([
      _tag('T', 'TIMER', defaultValueFor(_proj([]), 'TIMER', 0)),
      _tag('Motors', 'TIMER', [defaultValueFor(_proj([]), 'TIMER', 0)], arrayLength: 1),
    ]);
    writePath(p, 'T.NOPE', 1);         // unknown field
    writePath(p, 'Motors[9].ACC', 1);  // out-of-range index
    writePath(p, 'Ghost.x', 1);        // unknown root tag
    expect(readPath(p, 'T.ACC'), equals(0)); // state unchanged, nothing thrown
  });

  test('childrenOf enumerates composite fields, array elements, and int bits', () {
    final p = _proj([
      _tag('T', 'TIMER', defaultValueFor(_proj([]), 'TIMER', 0)),
      _tag('W', 'INT16', 0),
      _tag('A', 'BOOL', [false, false, false], arrayLength: 3),
    ]);
    expect(childrenOf(p, 'T').map((c) => c.label), containsAll(['.EN', '.DN', '.PRE', '.ACC']));
    expect(childrenOf(p, 'W').length, equals(16));
    expect(childrenOf(p, 'W').first.path, equals('W.0'));
    expect(childrenOf(p, 'A').map((c) => c.label).toList(), equals(['[0]', '[1]', '[2]']));
  });

  test('COUNTER builtin composite is registered with its 7 members', () {
    expect(builtinCompositeNames(), contains('COUNTER'));
    final p = _proj([]);
    final counter = lookupComposite(p, 'COUNTER');
    expect(counter, isNotNull);
    final names = counter!.fields.map((f) => f.name).toList();
    expect(names, equals(['CU', 'CD', 'QU', 'QD', 'R', 'CV', 'PV']));
    final cv = defaultValueFor(p, 'COUNTER', 0) as Map;
    expect(cv['CU'], isFalse);
    expect(cv['CD'], isFalse);
    expect(cv['QU'], isFalse);
    expect(cv['QD'], isFalse);
    expect(cv['R'], isFalse);
    expect(cv['CV'], equals(0));
    expect(cv['PV'], equals(0));
  });

  test('leafAndNodePaths includes members but not individual bits', () {
    final p = _proj([
      _tag('T', 'TIMER', defaultValueFor(_proj([]), 'TIMER', 0)),
      _tag('W', 'INT16', 0),
    ]);
    final paths = leafAndNodePaths(p);
    expect(paths, contains('T.DN'));
    expect(paths, contains('W'));
    expect(paths.where((x) => x.startsWith('W.')), isEmpty); // bits excluded
  });

  test('readPath/writePath handle a bit under an array element', () {
    final p = _proj([_tag('Arr', 'INT16', [0, 0, 0, 0], arrayLength: 4)]);
    writePath(p, 'Arr[2].5', true);
    expect(readPath(p, 'Arr[2]'), equals(32)); // bit 5 set = 32
    expect(readPath(p, 'Arr[2].5'), isTrue);
    expect(readPath(p, 'Arr[0].5'), isFalse);
    writePath(p, 'Arr[2].5', false);
    expect(readPath(p, 'Arr[2]'), equals(0));
  });

  test('structDefInUse detects tag and nested-field references', () {
    final p = _proj(
      [_tag('P1', 'PumpStatusDUT', null)],
      defs: [
        PlcStructDef(name: 'PumpStatusDUT', fields: [
          StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
        ]),
        PlcStructDef(name: 'Skid', fields: [
          StructFieldDef(name: 'Pump', dataType: 'PumpStatusDUT', defaultValue: null),
        ]),
      ],
    );
    expect(structDefInUse(p, 'PumpStatusDUT'), isTrue); // used by tag P1 and by Skid.Pump
    expect(structDefInUse(p, 'Skid'), isFalse);
  });

  test('defaultValueFor terminates on a direct self-referencing DUT (no stack overflow)', () {
    final p = _proj(
      [],
      defs: [
        PlcStructDef(name: 'SelfDUT', fields: [
          StructFieldDef(name: 'Nested', dataType: 'SelfDUT', defaultValue: null),
        ]),
      ],
    );
    // Must terminate rather than recurse infinitely; the cyclic member resolves
    // to a safe empty value instead of blowing the stack.
    final result = defaultValueFor(p, 'SelfDUT', 0) as Map;
    expect(result.containsKey('Nested'), isTrue);
  });

  test('defaultValueFor terminates on a mutual A->B->A cycle (no stack overflow)', () {
    final p = _proj(
      [],
      defs: [
        PlcStructDef(name: 'ADut', fields: [
          StructFieldDef(name: 'B', dataType: 'BDut', defaultValue: null),
        ]),
        PlcStructDef(name: 'BDut', fields: [
          StructFieldDef(name: 'A', dataType: 'ADut', defaultValue: null),
        ]),
      ],
    );
    final result = defaultValueFor(p, 'ADut', 0) as Map;
    expect(result.containsKey('B'), isTrue);
  });

  test('renameStructDef cascades to tags and nested fields', () {
    final p = _proj(
      [_tag('P1', 'PumpStatusDUT', null)],
      defs: [
        PlcStructDef(name: 'PumpStatusDUT', fields: [
          StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
        ]),
        PlcStructDef(name: 'Skid', fields: [
          StructFieldDef(name: 'Pump', dataType: 'PumpStatusDUT', defaultValue: null),
        ]),
      ],
    );
    renameStructDef(p, 'PumpStatusDUT', 'PumpDUT');
    expect(p.structDefs.any((s) => s.name == 'PumpDUT'), isTrue);
    expect(p.tags.firstWhere((t) => t.name == 'P1').dataType, 'PumpDUT');
    expect(p.structDefs.firstWhere((s) => s.name == 'Skid').fields.first.dataType, 'PumpDUT');
  });
}
