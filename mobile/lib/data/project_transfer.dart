import 'dart:convert';

import '../models/project_model.dart';

/// Pure, plugin-free encode/decode/rename core for moving a [PlcProject]
/// between devices as a single `.splc.json` file (export on one device,
/// import on another — there is no cloud sync, so this file IS the
/// cross-device transfer mechanism).
///
/// Every function here is a plain, synchronous, side-effect-free
/// transformation over strings/objects so it can be unit-tested without
/// `file_picker`/`share_plus` or any platform channel. Actual file
/// picking/sharing lives in thin wrappers elsewhere (see
/// `workspace_shell.dart`), never in this file.
abstract class ProjectTransfer {
  /// Serializes [p] to pretty-printed JSON suitable for writing to a
  /// `.splc.json` file. Mirrors [PlcProject.toFormattedJson] but is kept
  /// here too so the transfer format is explicit and independent of any
  /// future change to that convenience method.
  static String encodeProject(PlcProject p) {
    return const JsonEncoder.withIndent('  ').convert(p.toJson());
  }

  /// Parses [text] as a project previously produced by [encodeProject].
  ///
  /// Defensive by design: [PlcProject.fromJson] itself never throws (every
  /// field falls back to a sane default), so on its own it would happily
  /// "import" something like `{}` or `[]` as a blank project. That's the
  /// right behavior for internal storage (a damaged blob shouldn't crash
  /// the app) but wrong for a user-facing import: a file that isn't
  /// actually a project should be rejected with a clear error rather than
  /// silently imported as an empty one. So this method adds an explicit
  /// shape check on top and always throws a [FormatException] — never an
  /// uncaught/obscure error type — when [text] isn't valid JSON or isn't a
  /// recognizable project document.
  static PlcProject decodeProject(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      rethrow;
    } catch (e) {
      // jsonDecode only ever throws FormatException in practice, but guard
      // against any other decoder error type escaping uncaught.
      throw FormatException('Not valid JSON: $e');
    }

    if (decoded is! Map) {
      throw const FormatException(
        'Not a valid project file: expected a JSON object at the top level.',
      );
    }
    final map = Map<String, dynamic>.from(decoded);

    final projectField = map['project'];
    // Accept either the wrapped `{"project": {...}}` shape produced by
    // encodeProject, or a bare project map (defensive: still require it to
    // look like a project, not just any object).
    final projectMap = projectField is Map
        ? Map<String, dynamic>.from(projectField)
        : map;

    final looksLikeProject = projectMap.containsKey('name') && projectMap['name'] is String ||
        projectMap.containsKey('id') && projectMap['id'] is String ||
        projectMap.containsKey('controller') && projectMap['controller'] is Map;
    if (!looksLikeProject) {
      throw const FormatException(
        'Not a valid project file: missing project fields (name/id/controller).',
      );
    }

    try {
      return PlcProject.fromJson(map);
    } catch (e) {
      // Belt-and-braces: PlcProject.fromJson is defensive and should not
      // throw, but if a future change to the model introduces a throwing
      // path, surface it as a typed FormatException rather than letting an
      // arbitrary exception type escape to the UI layer.
      throw FormatException('Could not parse project: $e');
    }
  }

  /// Derives a filesystem-safe suggested file name for exporting [p], of
  /// the form `<sanitized-name>.splc.json`. Sanitization mirrors
  /// [ProjectRepository]'s id-sanitization approach (lowercase alnum +
  /// underscore) but preserves case/spacing-as-underscore for readability
  /// in a file name rather than folding everything to an id.
  static String suggestFileName(PlcProject p) {
    var sanitized = p.name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_') // path separators / reserved chars
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (sanitized.isEmpty) sanitized = 'untitled_project';
    return '$sanitized.splc.json';
  }

  /// If [imported]'s id already exists in [existingIds], returns a copy of
  /// [imported] with a fresh unique id (deterministic: `<id>_import`, then
  /// `<id>_import_2`, `<id>_import_3`, ... on further collisions).
  /// Otherwise returns [imported] unchanged.
  ///
  /// Mirrors the spirit of `ProjectRepository._uniqueId` (deterministic,
  /// no randomness) but is exposed as a pure, directly-testable function
  /// operating on an already-decoded [PlcProject] and a caller-supplied id
  /// set, so tests don't need a real repository/storage backend.
  static PlcProject reassignIdIfColliding(PlcProject imported, Set<String> existingIds) {
    if (!existingIds.contains(imported.id)) {
      return imported;
    }
    final base = '${imported.id}_import';
    if (!existingIds.contains(base)) {
      imported.id = base;
      return imported;
    }
    var n = 2;
    while (existingIds.contains('${base}_$n')) {
      n++;
    }
    imported.id = '${base}_$n';
    return imported;
  }
}
