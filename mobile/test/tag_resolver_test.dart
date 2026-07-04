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
}
