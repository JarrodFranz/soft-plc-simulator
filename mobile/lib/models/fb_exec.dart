import 'project_model.dart';
import 'st_exec.dart';
import 'tag_resolver.dart';

/// Runs one FB instance for a single scan: writes [inputs] into the instance
/// struct, executes the FB's ST body scoped to that instance (bare vars resolve
/// to `<instanceName>.<var>`, else global), and returns the output-var values.
/// Pure/deterministic; never throws.
Map<String, dynamic> executeFbInstance(
    PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs) {
  // An empty instance name has no struct to scope into: paths like `.In` would
  // strip to bare `In` and alias onto same-named GLOBAL tags. Refuse to run
  // rather than read/write unrelated globals (dangling/unbound binding).
  if (instanceName.isEmpty) return const {};
  // 1. Write inputs into the instance struct.
  for (final v in fb.vars) {
    if (v.direction == FbVarDir.input && inputs.containsKey(v.name)) {
      writePath(p, '$instanceName.${v.name}', inputs[v.name]);
    }
  }
  // 2. Run the scoped body.
  runScopedStBody(p, fb.stSource, StScope(instanceName, {for (final v in fb.vars) v.name}));
  // 3. Read outputs out.
  return {
    for (final v in fb.vars)
      if (v.direction == FbVarDir.output) v.name: readPath(p, '$instanceName.${v.name}'),
  };
}
