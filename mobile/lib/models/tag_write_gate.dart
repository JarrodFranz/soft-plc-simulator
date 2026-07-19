// Shared write-gate predicates (protocol-hardening workstream, Task 1).
//
// Two helpers that look similar but serve different purposes:
//
// - `defaultsExternallyWritable` is the AUTO-GENERATION default used when a
//   protocol map is first built (or rebuilt) from the project's tags.
// - `isExternallyWritable` is the write-time HARD BACKSTOP a protocol write
//   handler consults in addition to (never instead of) its own map entry,
//   so a mutable map entry can never make the reserved `System` tag or a
//   tag the user declared `ReadOnly` writable.
//
// Both judge the ROOT tag (the tag whose name is the leaf path's first
// segment) via `rootTagOf`, so a member path (e.g. `Tank.Level`) is judged
// by `Tank`, not the member itself.
//
// Pure Dart: no Flutter, no `dart:io`.

import 'project_model.dart';
import 'system_tags.dart';
import 'tag_resolver.dart';

/// Whether [leafPath] should default to externally writable when a
/// protocol map is auto-generated.
///
/// `SimulatedOutput` (a simulated field output driven by the local
/// simulation engine, not an external client), the reserved `System` tag
/// (checked by NAME, not just its `access` field, so this holds even if
/// `System`'s own `access` were ever left at its default), and any tag
/// whose own `access` is explicitly `ReadOnly` all default to
/// non-writable; everything else (`SimulatedInput`, `Internal`) defaults
/// to writable. An unknown path (no resolvable root) defaults to
/// non-writable.
bool defaultsExternallyWritable(PlcProject project, String leafPath) {
  final root = rootTagOf(project, leafPath);
  return root != null &&
      root.name != kSystemTagName &&
      root.ioType != 'SimulatedOutput' &&
      root.access != 'ReadOnly';
}

/// Whether [leafPath] may be written by an external client, independent of
/// whatever a (mutable) protocol map entry currently says. This is the
/// write-time hard backstop every write gate must additionally consult.
///
/// Deliberately does NOT check `ioType` — a `SimulatedOutput` tag stays
/// overridable: a user may set its map entry `ReadWrite` to drive a
/// simulated field device from an external test harness, and that
/// deliberate choice must still work. The only hard, non-overridable
/// rules are the reserved `System` tag (checked by NAME, independent of
/// its own `access` field) and a tag the user declared `access ==
/// 'ReadOnly'` on the tag itself. An unknown path (no resolvable root)
/// is refused.
bool isExternallyWritable(PlcProject project, String leafPath) {
  final root = rootTagOf(project, leafPath);
  return root != null && root.name != kSystemTagName && root.access != 'ReadOnly';
}
