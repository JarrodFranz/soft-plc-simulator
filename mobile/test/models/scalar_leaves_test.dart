import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';

void main() {
  test('a scalar tag is a single leaf (itself)', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: []);
    final leaves = scalarLeaves(p);
    expect(leaves.map((l) => l.path), ['A']);
    expect(leaves.single.dataType, 'FLOAT64');
  });

  test('a SYSTEM composite expands to its scalar leaves with dotted paths + types', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    ensureSystemTag(p); // adds the reserved System SYSTEM composite tag
    final leaves = scalarLeaves(p);
    final byPath = {for (final l in leaves) l.path: l.dataType};
    expect(byPath['System.Fault'], 'BOOL');
    expect(byPath['System.ScanTimeMs'], 'FLOAT64');
    expect(byPath['System.Hour'], 'INT32');
    expect(byPath['System.DateTime'], 'STRING');
    // The composite container itself is NOT a leaf.
    expect(byPath.containsKey('System'), isFalse);
  });

  test('an array tag expands to scalar elements', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [PlcTag(name: 'Arr', path: 'Arr', dataType: 'INT32', arrayLength: 3, value: [0, 0, 0], ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: []);
    expect(scalarLeaves(p).map((l) => l.path), ['Arr[0]', 'Arr[1]', 'Arr[2]']);
  });

  test('integer leaves are NOT bit-expanded', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [PlcTag(name: 'W', path: 'W', dataType: 'INT16', value: 0, ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: []);
    expect(scalarLeaves(p).map((l) => l.path), ['W']);
  });
}
