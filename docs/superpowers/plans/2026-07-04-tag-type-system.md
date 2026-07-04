# Tag & Type System (WS2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat/faked tag model with structured, path-resolved values so struct/TIMER members, integer bits, and array elements are real, addressable, forceable, and referenceable — and retire the separate Data Blocks concept in favour of DUT-typed tags.

**Architecture:** A new pure module `tag_resolver.dart` owns the type/value logic (default init, `readPath`/`writePath`, `childrenOf`, `leafAndNodePaths`) over a structured `PlcTag.value` (`Map` for structs, `List` for arrays, `int` for bit-holders). The Memory Manager renders generic recursive expansion via the resolver; the scan engine and editor tag pickers route through it. Built-in composites (`TIMER`) are implicit DUTs so there is no per-type special-casing.

**Tech Stack:** Flutter / Dart (web), `flutter test`, `flutter analyze`, Chrome preview.

## Global Constraints

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved. `flutter analyze` must report **zero** issues. Use `withValues(alpha:)` (not `withOpacity`), `initialValue:` (not `value:`) on `DropdownButtonFormField`, braces on all flow-control bodies, prefer `const`, `x.isNotEmpty` not `x.length >= 1`.
- No RenderFlex overflow.
- All shell commands run from `mobile/`.
- Path syntax: `.field` (struct/DUT/composite member), `.N` numeric (integer bit), `[i]` (array element). Bits: INT16→16, INT32→32, INT64→64.

**Sequencing note:** tasks are ordered so the app compiles and `flutter analyze` is clean after **every** task. Task 1 is purely additive; Task 2 stops the Memory Manager from using Data Blocks; Task 3 then removes the Data Blocks model.

---

### Task 1: Structured value model + `tag_resolver.dart`

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (add `arrayLength` to `PlcTag` and `StructFieldDef`, incl. JSON)
- Create: `mobile/lib/models/tag_resolver.dart`
- Test: `mobile/test/tag_resolver_test.dart`

**Interfaces:**
- Consumes: `PlcTag`, `PlcStructDef`, `StructFieldDef`, `PlcProject` from `project_model.dart`.
- Produces (used by Tasks 2-4): `TagChild`; `builtinCompositeNames()`; `lookupComposite`; `isIntegerType`; `bitWidth`; `defaultValueFor`; `readPath`; `writePath`; `childrenOf`; `leafAndNodePaths`.

- [ ] **Step 1: Add `arrayLength` to the model**

In `mobile/lib/models/project_model.dart`:

In `class PlcTag`, add a field `int arrayLength;` (place it after `dataType`), add `this.arrayLength = 0,` to the constructor, read it in `fromJson` with `arrayLength: json['array_length'] ?? 0,`, and add `'array_length': arrayLength,` to `toJson`.

In `class StructFieldDef`, add `int arrayLength;` and constructor param `this.arrayLength = 0,`.

- [ ] **Step 2: Write the failing tests**

Create `mobile/test/tag_resolver_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _proj(List<PlcTag> tags, {List<PlcStructDef> defs = const []}) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: defs, dataBlocks: [], programs: [], tasks: [], hmis: [],
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
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `flutter test test/tag_resolver_test.dart`
Expected: FAIL — `tag_resolver.dart` does not exist.

- [ ] **Step 4: Implement `tag_resolver.dart`**

Create `mobile/lib/models/tag_resolver.dart`:

```dart
import 'project_model.dart';

/// A child node under a composite/array/integer tag path, for UI expansion.
class TagChild {
  final String label;      // '.DN', '[0]', '.5'
  final String path;       // full path from the root tag
  final String dataType;   // base type of the child
  final int arrayLength;   // >0 if the child is itself an array
  final dynamic value;     // current leaf/subtree value
  final bool hasChildren;  // can this child expand further?
  TagChild({
    required this.label,
    required this.path,
    required this.dataType,
    required this.arrayLength,
    required this.value,
    required this.hasChildren,
  });
}

/// Built-in composite types, exposed as implicit DUTs.
final List<PlcStructDef> _builtinComposites = [
  PlcStructDef(name: 'TIMER', fields: [
    StructFieldDef(name: 'EN', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'TT', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'DN', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'PRE', dataType: 'INT32', defaultValue: 5000),
    StructFieldDef(name: 'ACC', dataType: 'INT32', defaultValue: 0),
  ]),
];

List<String> builtinCompositeNames() => _builtinComposites.map((s) => s.name).toList();

/// The DUT/composite definition for a type name, or null if it is a scalar.
PlcStructDef? lookupComposite(PlcProject p, String typeName) {
  for (final s in p.structDefs) {
    if (s.name == typeName) {
      return s;
    }
  }
  for (final s in _builtinComposites) {
    if (s.name == typeName) {
      return s;
    }
  }
  return null;
}

const List<String> _intTypes = ['INT16', 'INT32', 'INT64'];
bool isIntegerType(String base) => _intTypes.contains(base);
int bitWidth(String base) {
  switch (base) {
    case 'INT16':
      return 16;
    case 'INT32':
      return 32;
    case 'INT64':
      return 64;
    default:
      return 0;
  }
}

/// Recursive default value for a base type + arrayLength.
dynamic defaultValueFor(PlcProject p, String base, int arrayLength) {
  if (arrayLength > 0) {
    return List<dynamic>.generate(arrayLength, (_) => defaultValueFor(p, base, 0));
  }
  final comp = lookupComposite(p, base);
  if (comp != null) {
    final m = <String, dynamic>{};
    for (final f in comp.fields) {
      m[f.name] = f.defaultValue ?? defaultValueFor(p, f.dataType, f.arrayLength);
    }
    return m;
  }
  switch (base) {
    case 'BOOL':
      return false;
    case 'FLOAT64':
      return 0.0;
    case 'STRING':
      return '';
    default:
      return 0; // integer types
  }
}

class _Seg {
  final String raw;     // 'field' or 'N' or '2' (index inside [])
  final bool isIndex;   // came from [i]
  _Seg(this.raw, this.isIndex);
}

List<_Seg> _segments(String path) {
  final segs = <_Seg>[];
  final buf = StringBuffer();
  for (int i = 0; i < path.length; i++) {
    final c = path[i];
    if (c == '.') {
      if (buf.isNotEmpty) {
        segs.add(_Seg(buf.toString(), false));
        buf.clear();
      }
    } else if (c == '[') {
      if (buf.isNotEmpty) {
        segs.add(_Seg(buf.toString(), false));
        buf.clear();
      }
      final end = path.indexOf(']', i);
      if (end == -1) {
        break;
      }
      segs.add(_Seg(path.substring(i + 1, end), true));
      i = end;
    } else {
      buf.write(c);
    }
  }
  if (buf.isNotEmpty) {
    segs.add(_Seg(buf.toString(), false));
  }
  return segs;
}

PlcTag? _rootTag(PlcProject p, String name) {
  for (final t in p.tags) {
    if (t.name == name) {
      return t;
    }
  }
  return null;
}

/// The field definition for [name] within composite type [typeName], or null.
StructFieldDef? _field(PlcProject p, String typeName, String name) {
  final comp = lookupComposite(p, typeName);
  if (comp == null) {
    return null;
  }
  for (final f in comp.fields) {
    if (f.name == name) {
      return f;
    }
  }
  return null;
}

/// Reads a leaf/subtree value by path, or null if the path is invalid.
dynamic readPath(PlcProject p, String path) {
  final segs = _segments(path);
  if (segs.isEmpty) {
    return null;
  }
  final root = _rootTag(p, segs.first.raw);
  if (root == null) {
    return null;
  }
  dynamic cur = root.value;
  String curType = root.dataType;
  int curArray = root.arrayLength;
  for (int i = 1; i < segs.length; i++) {
    final seg = segs[i];
    if (seg.isIndex) {
      final idx = int.tryParse(seg.raw);
      if (idx == null || cur is! List || idx < 0 || idx >= cur.length) {
        return null;
      }
      cur = cur[idx];
      curArray = 0;
    } else if (curArray == 0 && isIntegerType(curType) && int.tryParse(seg.raw) != null) {
      final bit = int.parse(seg.raw);
      if (cur is! int || bit < 0 || bit >= bitWidth(curType)) {
        return null;
      }
      return (cur & (1 << bit)) != 0;
    } else {
      if (cur is! Map || !cur.containsKey(seg.raw)) {
        return null;
      }
      final f = _field(p, curType, seg.raw);
      if (f == null) {
        return null;
      }
      cur = cur[seg.raw];
      curType = f.dataType;
      curArray = f.arrayLength;
    }
  }
  return cur;
}

/// Writes a leaf value by path (including integer bit set/clear). No-op on an
/// invalid path.
void writePath(PlcProject p, String path, dynamic value) {
  final segs = _segments(path);
  if (segs.isEmpty) {
    return;
  }
  final root = _rootTag(p, segs.first.raw);
  if (root == null) {
    return;
  }
  if (segs.length == 1) {
    root.value = value;
    return;
  }
  // Walk to the container holding the final segment.
  dynamic parent = root.value;
  String curType = root.dataType;
  int curArray = root.arrayLength;
  for (int i = 1; i < segs.length - 1; i++) {
    final seg = segs[i];
    if (seg.isIndex) {
      final idx = int.tryParse(seg.raw);
      if (idx == null || parent is! List || idx < 0 || idx >= parent.length) {
        return;
      }
      parent = parent[idx];
      curArray = 0;
    } else {
      final f = _field(p, curType, seg.raw);
      if (parent is! Map || f == null || !parent.containsKey(seg.raw)) {
        return;
      }
      parent = parent[seg.raw];
      curType = f.dataType;
      curArray = f.arrayLength;
    }
  }
  final last = segs.last;
  if (last.isIndex) {
    final idx = int.tryParse(last.raw);
    if (idx != null && parent is List && idx >= 0 && idx < parent.length) {
      parent[idx] = value;
    }
  } else if (curArray == 0 && isIntegerType(curType) && int.tryParse(last.raw) != null) {
    // Bit write on the integer held one level up. Re-resolve the container of
    // the integer itself (the parent of the last named segment).
    final bit = int.parse(last.raw);
    final containerPath = segs.length == 2
        ? segs.first.raw
        : path.substring(0, path.lastIndexOf('.'));
    final intVal = readPath(p, containerPath);
    if (intVal is int && bit >= 0 && bit < bitWidth(curType)) {
      final newVal = value == true ? (intVal | (1 << bit)) : (intVal & ~(1 << bit));
      writePath(p, containerPath, newVal);
    }
  } else if (parent is Map) {
    parent[last.raw] = value;
  }
}

/// Children of a composite/array/integer path, for UI expansion. Empty for
/// scalars that are not integers.
List<TagChild> childrenOf(PlcProject p, String path) {
  final segs = _segments(path);
  if (segs.isEmpty) {
    return const [];
  }
  final root = _rootTag(p, segs.first.raw);
  if (root == null) {
    return const [];
  }
  // Determine the type + arrayLength at [path] by walking field defs.
  String curType = root.dataType;
  int curArray = root.arrayLength;
  for (int i = 1; i < segs.length; i++) {
    final seg = segs[i];
    if (seg.isIndex) {
      curArray = 0;
    } else {
      final f = _field(p, curType, seg.raw);
      if (f == null) {
        return const [];
      }
      curType = f.dataType;
      curArray = f.arrayLength;
    }
  }
  final value = readPath(p, path);
  final out = <TagChild>[];
  if (curArray > 0 && value is List) {
    for (int i = 0; i < value.length; i++) {
      final childPath = '$path[$i]';
      out.add(TagChild(
        label: '[$i]',
        path: childPath,
        dataType: curType,
        arrayLength: 0,
        value: value[i],
        hasChildren: _hasChildren(p, curType, 0, value[i]),
      ));
    }
    return out;
  }
  final comp = lookupComposite(p, curType);
  if (comp != null && value is Map) {
    for (final f in comp.fields) {
      final childPath = '$path.${f.name}';
      out.add(TagChild(
        label: '.${f.name}',
        path: childPath,
        dataType: f.dataType,
        arrayLength: f.arrayLength,
        value: value[f.name],
        hasChildren: _hasChildren(p, f.dataType, f.arrayLength, value[f.name]),
      ));
    }
    return out;
  }
  if (curArray == 0 && isIntegerType(curType) && value is int) {
    for (int b = 0; b < bitWidth(curType); b++) {
      out.add(TagChild(
        label: '.$b',
        path: '$path.$b',
        dataType: 'BOOL',
        arrayLength: 0,
        value: (value & (1 << b)) != 0,
        hasChildren: false,
      ));
    }
  }
  return out;
}

bool _hasChildren(PlcProject p, String base, int arrayLength, dynamic value) {
  if (arrayLength > 0) {
    return true;
  }
  if (lookupComposite(p, base) != null) {
    return true;
  }
  return isIntegerType(base);
}

/// Addressable paths for editor tag pickers: tags + composite members + array
/// elements (recursive). Integers are leaves here (bits are omitted to avoid
/// exploding the list).
List<String> leafAndNodePaths(PlcProject p) {
  final out = <String>[];
  void walk(String path, String base, int arrayLength, dynamic value) {
    out.add(path);
    if (arrayLength > 0 && value is List) {
      for (int i = 0; i < value.length; i++) {
        walk('$path[$i]', base, 0, value[i]);
      }
      return;
    }
    final comp = lookupComposite(p, base);
    if (comp != null && value is Map) {
      for (final f in comp.fields) {
        walk('$path.${f.name}', f.dataType, f.arrayLength, value[f.name]);
      }
    }
  }

  for (final t in p.tags) {
    walk(t.name, t.dataType, t.arrayLength, t.value);
  }
  return out;
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `flutter test test/tag_resolver_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 6: Analyze and commit**

Run: `flutter analyze` → **No issues found!**

```bash
git add mobile/lib/models/project_model.dart mobile/lib/models/tag_resolver.dart mobile/test/tag_resolver_test.dart
git commit -m "feat(tags): structured value model + path resolver (members, bits, arrays)"
```

---

### Task 2: Memory Manager — generic recursive expansion, DUT-typed tags, drop Data Blocks tab

**Files:**
- Modify: `mobile/lib/screens/memory_manager_screen.dart`

**Interfaces:**
- Consumes: `tag_resolver.dart` (`childrenOf`, `defaultValueFor`, `writePath`, `readPath`, `builtinCompositeNames`, `lookupComposite`, `TagChild`).
- Produces: two-tab Memory Manager (Tags, Struct Definitions) with resolver-driven expansion and DUT/array-aware tag creation. After this task the file no longer references `PlcProject.dataBlocks`.

- [ ] **Step 1: Import the resolver**

Add to the top of `memory_manager_screen.dart`:

```dart
import '../models/tag_resolver.dart';
```

- [ ] **Step 2: Drop the Data Blocks tab and the TIMER-faking**

- Change `_tabController = TabController(length: 3, ...)` to `length: 2`.
- Remove the third `Tab(... 'Data Blocks (DB)')` from the `TabBar` and the `_buildDataBlocksTab()` child from the `TabBarView`.
- Delete the `_buildDataBlocksTab()` method entirely.
- Delete `_ensureTimerParentTags()` and its call in `initState` (real TIMER tags now come from the project data, added in Task 3).

- [ ] **Step 3: Replace the hardcoded expansion with resolver-driven rows**

The current global-tags tab hardcodes TIMER children and int bits. Replace the child-row generation (the `if (isTimer && isParentExpanded)` block and the nested int-bit block inside `_buildGlobalTagsHierarchicalTab`) with a generic recursive builder. Add this method and call it to emit child rows for any expanded row, keyed by full path:

```dart
  // Emits DataRows for the children of [path] when it is expanded, recursing
  // into any expanded descendant. `depth` drives the indent.
  List<DataRow> _childRows(String path, int depth) {
    final rows = <DataRow>[];
    if (!_expandedTagKeys.contains(path)) {
      return rows;
    }
    for (final child in childrenOf(widget.currentProject, path)) {
      final expandable = child.hasChildren;
      final isExpanded = _expandedTagKeys.contains(child.path);
      rows.add(DataRow(cells: [
        DataCell(Padding(
          padding: EdgeInsets.only(left: 16.0 * depth),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (expandable)
              IconButton(
                icon: Icon(isExpanded ? Icons.arrow_drop_down_circle : Icons.play_arrow,
                    size: 14, color: Colors.amberAccent),
                onPressed: () => setState(() {
                  if (isExpanded) {
                    _expandedTagKeys.remove(child.path);
                  } else {
                    _expandedTagKeys.add(child.path);
                  }
                }),
              )
            else
              const SizedBox(width: 14),
            Text(child.label,
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 12)),
          ]),
        )),
        DataCell(Text(child.path, style: const TextStyle(fontSize: 10, color: Colors.grey))),
        DataCell(Text('${child.dataType}${child.arrayLength > 0 ? '[${child.arrayLength}]' : ''}',
            style: const TextStyle(fontSize: 10, color: Colors.cyanAccent))),
        DataCell(_leafValueCell(child)),
        const DataCell(Text('Good', style: TextStyle(color: Colors.greenAccent, fontSize: 10))),
        const DataCell(Text('Derived', style: TextStyle(fontSize: 10, color: Colors.grey))),
        const DataCell(SizedBox()),
      ]));
      rows.addAll(_childRows(child.path, depth + 1));
    }
    return rows;
  }

  // A value cell for a leaf child: BOOL toggles, integers/others show value.
  Widget _leafValueCell(TagChild child) {
    if (child.hasChildren) {
      return Text(child.value is Map ? '{...}' : (child.value is List ? '[${(child.value as List).length}]' : '${child.value}'),
          style: const TextStyle(fontSize: 10, color: Colors.grey));
    }
    if (child.dataType == 'BOOL') {
      final on = child.value == true;
      return TextButton(
        onPressed: () {
          writePath(widget.currentProject, child.path, !on);
          setState(() {});
          widget.onProjectUpdated();
        },
        child: Text(on ? 'TRUE (1)' : 'FALSE (0)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: on ? Colors.greenAccent : Colors.grey)),
      );
    }
    return Text('${child.value}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white));
  }
```

Then, where the parent tag rows are generated, (a) use the resolver to decide whether a parent row is expandable — replace `isTimer` checks with `childrenOf(widget.currentProject, tag.name).isNotEmpty`, keying the expand toggle by `tag.name`; and (b) after each parent row, append `..._childRows(tag.name, 1)` to the row list. Remove the old TIMER-specific and int-bit-specific child code.

- [ ] **Step 4: DUT/array-aware tag creation**

In `_showAddTagDialog`, replace `availableTypes` and the value initializer:

```dart
        final availableTypes = ['BOOL', 'INT16', 'INT32', 'INT64', 'FLOAT64', 'STRING',
            ...builtinCompositeNames(), ...widget.currentProject.structDefs.map((s) => s.name)];
```

Add an array-length controller near the other controllers:

```dart
        final arrayLenCtrl = TextEditingController(text: '0');
```

Add a field to the dialog `Column` (after the data-type dropdown):

```dart
                TextField(
                  controller: arrayLenCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Array Length (0 = scalar)'),
                ),
```

Replace the tag construction in the Add button's `onPressed`:

```dart
                  final arrLen = int.tryParse(arrayLenCtrl.text) ?? 0;
                  final tag = PlcTag(
                    name: nameCtrl.text,
                    path: pathCtrl.text,
                    dataType: dataType,
                    arrayLength: arrLen,
                    value: defaultValueFor(widget.currentProject, dataType, arrLen),
                    ioType: ioType,
                  );
```

- [ ] **Step 5: Analyze, build, and visually verify (controller does Chrome)**

Run: `flutter analyze` → **No issues found!**
Run: `flutter build web --release` → succeeds.

Do NOT attempt Chrome yourself — the controller verifies: two tabs, a TIMER tag expands to `.EN/.TT/.DN/.PRE/.ACC`, an INT16 expands to 16 bits, an array tag expands to elements, and creating a DUT-typed tag works.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/screens/memory_manager_screen.dart
git commit -m "feat(tags): generic recursive Memory Manager expansion; DUT/array-aware tag creation; drop Data Blocks tab"
```

---

### Task 3: Retire the Data Blocks model + migrate default projects

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (remove `PlcDataBlock`, `PlcProject.dataBlocks`)
- Modify: `mobile/lib/data/default_projects.dart` (drop `dataBlocks:` args; migrate DB → tags; real TIMER tags; showcase array + DUT)

**Interfaces:**
- Consumes: `defaultValueFor` from `tag_resolver.dart` (for real TIMER/array/DUT tag values).
- Produces: no `dataBlocks` anywhere; TIMER tags carry real structured values.

- [ ] **Step 1: Remove the Data Blocks model**

In `project_model.dart`: delete the entire `class PlcDataBlock { ... }`. In `class PlcProject`: remove the `List<PlcDataBlock> dataBlocks;` field, the `required this.dataBlocks,` constructor param, the `dataBlocks: [],` line in `fromJson`, and any `dataBlocks` entry in `toJson`.

- [ ] **Step 2: Fix all `dataBlocks:` call sites**

In `mobile/lib/data/default_projects.dart`, every `PlcProject(...)` literal passes `dataBlocks: [...]`. Remove each `dataBlocks:` argument. If a project defined actual `PlcDataBlock(...)` instances, convert each into a struct-typed `PlcTag` added to that project's `tags` list, e.g.:

```dart
PlcTag(
  name: '<db name>',
  path: 'Data/<db name>',
  dataType: '<structTypeName>',
  value: defaultValueFor(<the project>, '<structTypeName>', 0),
  ioType: 'Internal',
),
```

(If the DB had non-default field values, set them after construction via `writePath` or by editing the value map — preserve the original values.)

Add `import '../models/tag_resolver.dart';` to `default_projects.dart` if not present.

- [ ] **Step 3: Make timer tags real, and add showcase tags**

Wherever the default projects reference a timer tag (e.g. add a `TONTimer` internal tag if one was previously faked), define it as a real TIMER tag:

```dart
PlcTag(name: 'TONTimer', path: 'Timers/TONTimer', dataType: 'TIMER',
    value: defaultValueFor(<project>, 'TIMER', 0), ioType: 'Internal',
    description: 'On-delay timer instance'),
```

In one project (the "All Languages — Water Treatment Plant", `_allWaterProject`), add a showcase array tag and a DUT + DUT-typed tag:

```dart
// array tag
PlcTag(name: 'Recipe_Steps', path: 'Recipe/Steps', dataType: 'INT16', arrayLength: 8,
    value: defaultValueFor(<project>, 'INT16', 8), ioType: 'Internal',
    description: '8-step recipe setpoints'),
```

and in that project's `structDefs`, add a DUT and a tag of that type:

```dart
// structDefs: [ ... existing ...,
PlcStructDef(name: 'PumpStatusDUT', fields: [
  StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'Faulted', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'RunHours', dataType: 'INT32', defaultValue: 0),
]),
// tags: [ ... existing ...,
PlcTag(name: 'Pump1_Status', path: 'Status/Pump1', dataType: 'PumpStatusDUT',
    value: defaultValueFor(<project>, 'PumpStatusDUT', 0), ioType: 'Internal'),
```

Because `defaultValueFor` needs the project's `structDefs` to resolve `PumpStatusDUT`, build the `structDefs` list first as a local variable, then reference it when constructing the DUT-typed tag's value (or set `Pump1_Status.value` immediately after building the project). Use whichever keeps `flutter analyze` clean.

- [ ] **Step 4: Analyze, test, build**

Run: `flutter analyze` → **No issues found!** (no remaining `dataBlocks`/`PlcDataBlock` references — grep to confirm: `grep -rn "dataBlocks\|PlcDataBlock" mobile/lib` returns nothing.)
Run: `flutter test` → all pass.
Run: `flutter build web --release` → succeeds.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/project_model.dart mobile/lib/data/default_projects.dart
git commit -m "refactor(tags): retire PlcDataBlock; migrate to DUT-typed tags; real TIMER + showcase array/DUT"
```

---

### Task 4: Consumer integration — path-aware scan engine + editor tag pickers

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (`_getTag*`/`_setTag*` route through resolver)
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (edit dialog tag picker offers resolvable paths)

**Interfaces:**
- Consumes: `readPath`, `writePath`, `leafAndNodePaths` from `tag_resolver.dart`.
- Produces: member/bit/element addresses work in the scan helpers; the LD edit dialog can bind real member paths.

- [ ] **Step 1: Route scan get/set through the resolver**

Add `import '../models/tag_resolver.dart';` to `workspace_shell.dart`. Rewrite the six helpers so a flat name is a one-segment path and forcing still applies to the root tag:

```dart
  PlcTag? _rootOf(String path) {
    final rootName = path.split('.').first.split('[').first;
    for (final t in _activeProject.tags) {
      if (t.name == rootName) {
        return t;
      }
    }
    return null;
  }

  bool _getTagBool(String path) {
    final root = _rootOf(path);
    if (root != null && root.isForced && root.name == path) {
      return root.forcedValue == true;
    }
    return readPath(_activeProject, path) == true;
  }

  double _getTagDouble(String path) {
    final root = _rootOf(path);
    if (root != null && root.isForced && root.name == path) {
      return (root.forcedValue as num?)?.toDouble() ?? 0.0;
    }
    final v = readPath(_activeProject, path);
    return v is num ? v.toDouble() : 0.0;
  }

  int _getTagInt(String path) {
    final root = _rootOf(path);
    if (root != null && root.isForced && root.name == path) {
      return (root.forcedValue as num?)?.toInt() ?? 0;
    }
    final v = readPath(_activeProject, path);
    return v is num ? v.toInt() : 0;
  }

  void _setTagBool(String path, bool val) => _writeIfNotForced(path, val);
  void _setTagDouble(String path, double val) => _writeIfNotForced(path, val);
  void _setTagInt(String path, int val) => _writeIfNotForced(path, val);

  void _writeIfNotForced(String path, dynamic val) {
    final root = _rootOf(path);
    if (root != null && root.isForced && root.name == path) {
      return; // forced root value is not overwritten by logic
    }
    writePath(_activeProject, path, val);
  }
```

Delete the old six helper bodies they replace. (Existing call sites pass flat names, so behaviour is unchanged; member/bit/element paths now also work.)

- [ ] **Step 2: LD edit dialog binds resolvable paths**

In `ld_editor_screen.dart` `_showEditNodeDialog`, the tag dropdown currently lists `widget.currentProject.tags`. Replace its item source with resolvable paths so members are selectable:

```dart
                  items: leafAndNodePaths(widget.currentProject)
                      .map((p) => DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis)))
                      .toList(),
```

and update the `initialValue` guard to `leafAndNodePaths(widget.currentProject).contains(n.variable) ? n.variable : null`. Add `import '../models/tag_resolver.dart';` if not already present. Keep the free-text `Tag / literal` field so arbitrary references remain possible.

- [ ] **Step 3: Analyze, test, build**

Run: `flutter analyze` → **No issues found!**
Run: `flutter test` → all pass.
Run: `flutter build web --release` → succeeds.

- [ ] **Step 4: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/lib/screens/ld_editor_screen.dart
git commit -m "feat(tags): path-aware scan get/set; LD edit dialog binds resolvable member paths"
```

---

### Task 5: Final validation

**Files:** none (verification; small fixes only if a regression surfaces).

- [ ] **Step 1: Full suite + analyze + build**

Run: `flutter test` → all pass (tag_resolver, ld_graph, ld_layout, widget tests).
Run: `flutter analyze` → **No issues found!**
Run: `flutter build web --release` → succeeds.

- [ ] **Step 2: Chrome walkthrough (controller)**

Open the Memory Manager and confirm: two tabs (Tags, Struct Definitions); a TIMER tag expands to `.EN/.TT/.DN/.PRE/.ACC`; an INT16 tag expands to 16 bits and toggling a bit updates the parent integer; the `Recipe_Steps` array expands to `[0]…[7]`; the `Pump1_Status` DUT tag expands to its fields; creating a new DUT-typed tag and a new array tag works. In the LD editor edit dialog, confirm `TONTimer.DN` (or a real member path) is selectable. Confirm all 7 projects still load.

- [ ] **Step 3: Branding + data-block sweep**

Run: `grep -rn "dataBlocks\|PlcDataBlock" mobile/lib` → no matches.
Run: `grep -ri "openplc" mobile/lib mobile/test` → no matches.

- [ ] **Step 4: Commit (only if fixes were made)**

```bash
git add -A
git commit -m "test(tags): validate tag & type system across projects"
```

---

## Self-review notes

- **Spec coverage:** structured value model + resolver (Task 1) ✓; generic recursive expansion + bit/array/struct (Task 2) ✓; DUT-typed tags + retire Data Blocks + migration (Tasks 2-3) ✓; path-aware scan engine (Task 4) ✓; editor tag pickers resolve members (Task 4) ✓; showcase array + DUT (Task 3) ✓; built-in TIMER as implicit DUT (Task 1) ✓; JSON round-trip (Task 1 model + resolver tests) ✓.
- **Type consistency:** `readPath`, `writePath`, `childrenOf`, `defaultValueFor`, `leafAndNodePaths`, `TagChild`, `lookupComposite`, `isIntegerType`, `bitWidth`, `builtinCompositeNames`, and `arrayLength` are named identically across tasks.
- **Green-after-every-task:** Task 1 additive; Task 2 stops the Memory Manager using `dataBlocks`; Task 3 then removes the model and fixes `default_projects` call sites; Tasks 4-5 integrate/verify.
- **Deferred (per spec):** timer/block execution is WS3; per-member forcing is not added (root-tag forcing preserved).
