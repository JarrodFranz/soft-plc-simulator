import 'project_model.dart';
import 'tag_resolver.dart';

/// A unique, project-wide tag name for a new instance of function block
/// definition [fbName]: `fbName` itself if no tag already claims it, else
/// `fbName_2`, `fbName_3`, ... — the same suffixing scheme a user would reach
/// for by hand. Checked against every existing tag name so two instances of
/// the same FB never collide (mirrors how TIMER/COUNTER instances are named
/// by hand elsewhere in the editors).
String uniqueFbInstanceName(PlcProject p, String fbName) {
  final taken = p.tags.map((t) => t.name).toSet();
  if (!taken.contains(fbName)) {
    return fbName;
  }
  var i = 2;
  while (taken.contains('${fbName}_$i')) {
    i++;
  }
  return '${fbName}_$i';
}

/// Builds the backing instance [PlcTag] for a new FB block/node: a
/// struct-typed tag (`dataType == fb.name`) whose live value is the FB's
/// structural default (each var's `initialValue`, recursively resolved via
/// `defaultValueFor`/`lookupComposite` — see `tag_resolver.dart`). Mirrors how
/// the Memory Manager's "Add Tag" dialog constructs a non-scalar/composite
/// tag: `defaultValue` stays null (the effective default is always
/// recomputed structurally, never frozen at creation time) and `ioType` is
/// 'Internal' (an FB instance is not a physical I/O point). [name] overrides
/// the auto-generated unique name when the caller already picked one.
PlcTag createFbInstanceTag(PlcProject p, FbDefinition fb, {String? name}) {
  final tagName = name ?? uniqueFbInstanceName(p, fb.name);
  return PlcTag(
    name: tagName,
    path: tagName,
    dataType: fb.name,
    value: defaultValueFor(p, fb.name, 0),
    ioType: 'Internal',
  );
}
