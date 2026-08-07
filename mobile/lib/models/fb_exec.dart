import 'project_model.dart';
import 'fbd_exec.dart';
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

/// Rockwell re-evaluates an AOI's implicit EnableIn on EVERY call, so a
/// graphical body that clears it (an `OTU(EnableIn)` rung, or an FBD network
/// writing `EnableIn`) must not permanently self-disable. The import path
/// retains EnableIn as an INTERNAL BOOL var for RLL- and FBD-Logic AOIs (see
/// l5x_parser.dart), so that shape — and only that shape — is re-asserted true
/// here, just before the body runs. Data-driven on the var list rather than a
/// per-definition flag, so old JSON needs no new field. An EnableIn that is a
/// real interface pin (input/output) is caller-driven and left alone; the ST
/// path is untouched.
void _reassertEnableIn(PlcProject p, FbDefinition fb, String instanceName) {
  for (final v in fb.vars) {
    if (v.name == 'EnableIn' &&
        v.direction == FbVarDir.internal &&
        v.dataType == 'BOOL') {
      writePath(p, '$instanceName.EnableIn', true);
      return;
    }
  }
}

/// Runs one FB instance for a single scan: writes [inputs] into the instance
/// struct, executes the FB's body scoped to that instance (bare vars resolve
/// to `<instanceName>.<var>`, else global), and returns the output-var values.
///
/// Body dispatch (the single source of truth for body precedence): a non-empty
/// [FbDefinition.ladderRungs] runs the native ladder body via
/// `runScopedLdBody`; else a non-empty [FbDefinition.fbdBlocks] runs the
/// native FBD body via `runScopedFbdBody`; else the existing scoped-ST path
/// runs, unchanged. [dtMs] drives a graphical body's timers, [ldRt] carries a
/// ladder body's edge/pulse state and [fbdRt] an FBD body's
/// timer/counter/edge state. Both engine call sites thread their real scan
/// `dtMs` and runtimes down to here (the LD engine gains `fbdRt` from
/// `runScanTick`; the FBD engine passes its own `FbdRuntime`), so the
/// ephemeral `LdExecRuntime()` / `FbdRuntime()` fallbacks are unreachable in
/// the scan — they only catch direct/ad-hoc callers, where they degrade ONLY
/// stateful blocks (a body TON restarts each call; never throws).
///
/// [readOnly] is the engine's read-only tag set (signal-generator/simulated
/// test tags). It is threaded into a GRAPHICAL body (ladder or FBD) so an FB
/// coil / TAG_OUTPUT targeting one of those globals is dropped, exactly as a
/// program coil would be. Instance
/// members are never affected — those paths are `<instance>.<var>`, which no
/// readOnly entry names. The ST path still ignores it (unchanged). Omitting it
/// keeps the pre-existing ungated behaviour, so every existing caller compiles
/// and behaves identically.
///
/// Pure/deterministic; never throws.
Map<String, dynamic> executeFbInstance(
    PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs,
    {int dtMs = 0, LdExecRuntime? ldRt, FbdRuntime? fbdRt, Set<String>? readOnly}) {
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
    // 2. Run the scoped body (precedence: ladder > FBD > ST).
    final varNames = {for (final v in fb.vars) v.name};
    if (fb.ladderRungs.isNotEmpty) {
      _reassertEnableIn(p, fb, instanceName);
      runScopedLdBody(p, fb.ladderRungs, LdScope(instanceName, varNames), dtMs,
          ldRt ?? LdExecRuntime(), readOnly: readOnly, fbdRt: fbdRt);
    } else if (fb.fbdBlocks.isNotEmpty) {
      _reassertEnableIn(p, fb, instanceName);
      runScopedFbdBody(p, fb.fbdBlocks, fb.fbdWires,
          LdScope(instanceName, varNames), dtMs, fbdRt ?? FbdRuntime(),
          readOnly: readOnly, ldRt: ldRt);
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
