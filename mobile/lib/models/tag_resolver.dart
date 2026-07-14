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
  PlcStructDef(name: 'COUNTER', fields: [
    StructFieldDef(name: 'CU', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'CD', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'QU', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'QD', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'R', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'CV', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'PV', dataType: 'INT32', defaultValue: 0),
  ]),
  PlcStructDef(name: 'SYSTEM', fields: [
    StructFieldDef(name: 'Fault', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'FaultTask', dataType: 'STRING', defaultValue: ''),
    StructFieldDef(name: 'FaultCode', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'FirstScan', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'ScanCount', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'ScanTimeMs', dataType: 'FLOAT64', defaultValue: 0.0),
    StructFieldDef(name: 'MaxScanTimeMs', dataType: 'FLOAT64', defaultValue: 0.0),
    StructFieldDef(name: 'MinScanTimeMs', dataType: 'FLOAT64', defaultValue: 0.0),
    StructFieldDef(name: 'FreeRun', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'UptimeMs', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Year', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Month', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Day', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Hour', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Minute', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Second', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'DateTime', dataType: 'STRING', defaultValue: ''),
    StructFieldDef(name: 'AlarmReset', dataType: 'BOOL', defaultValue: false),
  ]),
];

List<String> builtinCompositeNames() => _builtinComposites.map((s) => s.name).toList();

/// True if any tag or struct field in [p] references the struct definition
/// named [name] as its data type.
bool structDefInUse(PlcProject p, String name) {
  if (p.tags.any((t) => t.dataType == name)) {
    return true;
  }
  return p.structDefs.any((s) => s.fields.any((f) => f.dataType == name));
}

/// Renames struct definition [oldName] to [newName] everywhere it is
/// referenced: tag data types, nested struct field data types, and the
/// definition's own name. No-op if the names are equal or no such def exists.
void renameStructDef(PlcProject p, String oldName, String newName) {
  if (oldName == newName) {
    return;
  }
  if (!p.structDefs.any((s) => s.name == oldName)) {
    return;
  }
  for (final t in p.tags) {
    if (t.dataType == oldName) {
      t.dataType = newName;
    }
  }
  for (final s in p.structDefs) {
    for (final f in s.fields) {
      if (f.dataType == oldName) {
        f.dataType = newName;
      }
    }
  }
  for (final s in p.structDefs) {
    if (s.name == oldName) {
      s.name = newName;
    }
  }
}

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
  return _defaultValueFor(p, base, arrayLength, <String>{});
}

/// Cycle-safe worker for [defaultValueFor]. [visiting] tracks composite type
/// names currently being expanded on this recursion path; a composite that
/// re-appears (direct self-reference or a mutual A->B->A cycle) is treated
/// as an empty struct instead of being recursed into again, so malformed or
/// maliciously-crafted DUT graphs (from the UI or legacy JSON) can never
/// stack-overflow.
dynamic _defaultValueFor(PlcProject p, String base, int arrayLength, Set<String> visiting) {
  if (arrayLength > 0) {
    return List<dynamic>.generate(arrayLength, (_) => _defaultValueFor(p, base, 0, visiting));
  }
  final comp = lookupComposite(p, base);
  if (comp != null) {
    if (visiting.contains(base)) {
      return <String, dynamic>{}; // cycle detected — bail out safely
    }
    final nextVisiting = {...visiting, base};
    final m = <String, dynamic>{};
    for (final f in comp.fields) {
      m[f.name] = f.defaultValue ?? _defaultValueFor(p, f.dataType, f.arrayLength, nextVisiting);
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

/// The data type of a (possibly dotted, possibly indexed) path, or null if
/// the path doesn't resolve — e.g. an unknown root tag or an unknown field
/// name partway through. Reuses the same field-def walk as [childrenOf]
/// (`_rootTag` + `_field`), but only tracks the type, not the value, so it's
/// safe to call even when the path's containers haven't been populated yet.
/// An array-index segment (`[i]`) doesn't change the element's base type, so
/// it's skipped rather than resolved against a live value.
String? dataTypeOfPath(PlcProject p, String path) {
  final segs = _segments(path);
  if (segs.isEmpty) {
    return null;
  }
  final root = _rootTag(p, segs.first.raw);
  if (root == null) {
    return null;
  }
  String curType = root.dataType;
  for (int i = 1; i < segs.length; i++) {
    final seg = segs[i];
    if (seg.isIndex) {
      continue;
    }
    final f = _field(p, curType, seg.raw);
    if (f == null) {
      return null;
    }
    curType = f.dataType;
  }
  return curType;
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
  // Forcing is authoritative for reads: a forced SCALAR root tag resolves to
  // its forcedValue everywhere (logic engines + OPC UA + Modbus all read
  // through here). The Force UI (tag_inspector_dock) only ever offers the
  // toggle for scalar tags, so a composite (struct/array) tag's isForced is
  // always false in practice; the Map/List check here is a defensive
  // belt-and-suspenders guard, not the primary gate. Seeding the walk from
  // the forced value also makes a bit-read of a forced integer (e.g.
  // `Word.2`) reflect the force.
  dynamic cur = (root.isForced && root.value is! Map && root.value is! List)
      ? root.forcedValue
      : root.value;
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

/// One scalar leaf of a tag: its addressable dotted path and base dataType.
class TagLeaf {
  final String path;
  final String dataType;
  const TagLeaf(this.path, this.dataType);
}

/// Every scalar leaf across all of [p]'s tags. A scalar tag yields itself; a
/// composite yields its scalar struct members (recursively); an array yields
/// its scalar elements. Composite/array container nodes are not emitted;
/// integers are leaves (bits are not expanded).
List<TagLeaf> scalarLeaves(PlcProject p) {
  final out = <TagLeaf>[];
  void walk(String path, String base, int arrayLength, dynamic value) {
    if (arrayLength > 0 && value is List) {
      for (var i = 0; i < value.length; i++) {
        walk('$path[$i]', base, 0, value[i]);
      }
      return;
    }
    final comp = lookupComposite(p, base);
    if (comp != null && value is Map) {
      for (final f in comp.fields) {
        walk('$path.${f.name}', f.dataType, f.arrayLength, value[f.name]);
      }
      return;
    }
    // Scalar leaf.
    out.add(TagLeaf(path, base));
  }

  for (final t in p.tags) {
    walk(t.name, t.dataType, t.arrayLength, t.value);
  }
  return out;
}
