import 'project_model.dart';
import 'ld_exec.dart';
import 'st_exec.dart';
import 'tag_resolver.dart';

/// Maximum nesting depth of FB-inside-FB execution. A ladder-bodied FB can
/// call another FB (an AOI calling an AOI), so a cyclic definition graph —
/// unreachable from import (the FB registry only ever holds FBs defined
/// EARLIER in the file) but reachable from hand-edited/legacy JSON — would
/// otherwise recurse into the uncatchable `StackOverflowError`, breaking the
/// never-throws invariant. Beyond this depth the call is a no-op.
const int _kMaxFbCallDepth = 16;
int _fbCallDepth = 0;

/// Runs one FB instance for a single scan: writes [inputs] into the instance
/// struct, executes the FB's body scoped to that instance (bare vars resolve
/// to `<instanceName>.<var>`, else global), and returns the output-var values.
///
/// Body dispatch: a non-empty [FbDefinition.ladderRungs] runs the native
/// ladder body via `runScopedLdBody` — [dtMs] drives its timers and [ldRt]
/// carries its edge/pulse state (both engine call sites pass their real
/// runtime; the `LdExecRuntime()` fallback is unreachable in the scan and only
/// degrades edge detection if ever hit). Otherwise the existing scoped-ST path
/// runs, unchanged.
///
/// `readOnly` is deliberately not threaded into FB bodies — parity with the ST
/// path. Pure/deterministic; never throws.
Map<String, dynamic> executeFbInstance(
    PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs,
    {int dtMs = 0, LdExecRuntime? ldRt}) {
  // An empty instance name has no struct to scope into: paths like `.In` would
  // strip to bare `In` and alias onto same-named GLOBAL tags. Refuse to run
  // rather than read/write unrelated globals (dangling/unbound binding).
  if (instanceName.isEmpty) return const {};
  if (_fbCallDepth >= _kMaxFbCallDepth) return const {};
  _fbCallDepth++;
  try {
    // 1. Write inputs into the instance struct.
    for (final v in fb.vars) {
      if (v.direction == FbVarDir.input && inputs.containsKey(v.name)) {
        writePath(p, '$instanceName.${v.name}', inputs[v.name]);
      }
    }
    // 2. Run the scoped body.
    final varNames = {for (final v in fb.vars) v.name};
    if (fb.ladderRungs.isNotEmpty) {
      runScopedLdBody(p, fb.ladderRungs, LdScope(instanceName, varNames), dtMs,
          ldRt ?? LdExecRuntime());
    } else {
      runScopedStBody(p, fb.stSource, StScope(instanceName, varNames));
    }
    // 3. Read outputs out.
    return {
      for (final v in fb.vars)
        if (v.direction == FbVarDir.output) v.name: readPath(p, '$instanceName.${v.name}'),
    };
  } finally {
    _fbCallDepth--;
  }
}
