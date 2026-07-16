import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/project_model.dart';
import 'default_projects.dart';

/// Lightweight catalog entry describing a stored project, without loading
/// the full [PlcProject] payload. Used to render project-list UI cheaply.
class ProjectSummary {
  final String id;
  final String name;
  final String controllerName;
  final DateTime updatedAt;

  ProjectSummary({
    required this.id,
    required this.name,
    required this.controllerName,
    required this.updatedAt,
  });

  factory ProjectSummary.fromJson(Map<String, dynamic> json) => ProjectSummary(
    id: json['id'] as String,
    name: json['name'] as String,
    controllerName: json['controllerName'] as String,
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'controllerName': controllerName,
    'updatedAt': updatedAt.toIso8601String(),
  };

  ProjectSummary copyWith({String? name, String? controllerName, DateTime? updatedAt}) => ProjectSummary(
    id: id,
    name: name ?? this.name,
    controllerName: controllerName ?? this.controllerName,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// Persists [PlcProject]s to on-device storage via `shared_preferences`,
/// the one storage backend that behaves consistently across every Flutter
/// target (Android/iOS/desktop/web) so the app can ship a single code path.
///
/// Storage layout:
///  - `project_catalog`   -> JSON-encoded list of [ProjectSummary]
///  - `project_<id>`      -> JSON-encoded [PlcProject] (via toJson/fromJson)
///  - `active_project_id` -> plain string, the currently-open project id
///
/// All reads are defensive: a corrupt/missing blob is skipped (listing) or
/// returns null (loadProject) rather than throwing, so a single damaged
/// entry never takes down the whole project list.
class ProjectRepository {
  ProjectRepository(this._prefs);

  final SharedPreferences _prefs;

  static const String _catalogKey = 'project_catalog';
  static const String _activeProjectIdKey = 'active_project_id';
  static const String _seededDefaultIdsKey = 'seeded_default_ids';
  static String _projectKey(String id) => 'project_$id';

  // ── Catalog ──────────────────────────────────────────────────────────

  List<ProjectSummary> _readCatalog() {
    final raw = _prefs.getString(_catalogKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final result = <ProjectSummary>[];
      for (final entry in decoded) {
        try {
          if (entry is Map<String, dynamic>) {
            result.add(ProjectSummary.fromJson(entry));
          } else if (entry is Map) {
            result.add(ProjectSummary.fromJson(Map<String, dynamic>.from(entry)));
          }
        } catch (_) {
          // Skip a single corrupt catalog entry; keep the rest.
        }
      }
      return result;
    } catch (_) {
      // Corrupt catalog JSON entirely — treat as empty rather than throwing.
      return [];
    }
  }

  Future<void> _writeCatalog(List<ProjectSummary> summaries) async {
    await _prefs.setString(_catalogKey, jsonEncode(summaries.map((s) => s.toJson()).toList()));
  }

  /// Returns the catalog of known projects. Never throws; a corrupt catalog
  /// or corrupt individual entries yield fewer (or zero) results instead of
  /// an exception.
  Future<List<ProjectSummary>> listProjects() async {
    return _readCatalog();
  }

  // ── CRUD ─────────────────────────────────────────────────────────────

  /// Loads a full project by id. Returns null if missing or the stored
  /// blob is corrupt — never throws.
  Future<PlcProject?> loadProject(String id) async {
    final raw = _prefs.getString(_projectKey(id));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return PlcProject.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Upserts the project's blob and its catalog summary (stamping
  /// `updatedAt` to now).
  Future<void> saveProject(PlcProject p, {DateTime? updatedAt}) async {
    await _prefs.setString(_projectKey(p.id), jsonEncode(p.toJson()));

    final catalog = _readCatalog();
    final stamp = updatedAt ?? DateTime.now();
    final idx = catalog.indexWhere((s) => s.id == p.id);
    final summary = ProjectSummary(
      id: p.id,
      name: p.name,
      controllerName: p.controllerName,
      updatedAt: stamp,
    );
    if (idx >= 0) {
      catalog[idx] = summary;
    } else {
      catalog.add(summary);
    }
    await _writeCatalog(catalog);
  }

  /// Removes a project's blob and its catalog entry. No-op if the project
  /// doesn't exist.
  Future<void> deleteProject(String id) async {
    await _prefs.remove(_projectKey(id));
    final catalog = _readCatalog()..removeWhere((s) => s.id == id);
    await _writeCatalog(catalog);
  }

  /// Deep-copies the project identified by [id], assigns it a fresh unique
  /// id, optionally renames it, saves it, and returns the new id.
  Future<String> duplicateProject(String id, {String? newName}) async {
    final src = await loadProject(id);
    if (src == null) {
      throw StateError('duplicateProject: source project "$id" not found');
    }
    final existingIds = _readCatalog().map((s) => s.id).toSet();
    final copyJson = jsonDecode(jsonEncode(src.toJson())) as Map<String, dynamic>;
    final copy = PlcProject.fromJson(copyJson);
    copy.id = _uniqueId(newName ?? '${copy.name}_copy', existingIds);
    copy.name = newName ?? '${src.name} Copy';
    await saveProject(copy);
    return copy.id;
  }

  /// Renames a project both in its own blob and in the catalog summary.
  Future<void> renameProject(String id, String name) async {
    final proj = await loadProject(id);
    if (proj == null) return;
    proj.name = name;
    await saveProject(proj);
  }

  // ── Active project ──────────────────────────────────────────────────

  Future<String?> getActiveProjectId() async {
    return _prefs.getString(_activeProjectIdKey);
  }

  Future<void> setActiveProjectId(String id) async {
    await _prefs.setString(_activeProjectIdKey, id);
  }

  // ── Seeding / reset ──────────────────────────────────────────────────

  /// Seeds the built-in [DefaultProjects] into storage if the catalog is
  /// currently empty. Idempotent: calling this again once projects exist
  /// (whether seeded or user-created) is a no-op.
  Future<void> seedDefaultsIfEmpty() async {
    final catalog = _readCatalog();
    if (catalog.isNotEmpty) return;
    for (final project in DefaultProjects.all()) {
      await saveProject(project);
    }
  }

  /// Wipes all known projects and the active-project pointer, then
  /// re-seeds the built-in defaults.
  Future<void> resetToDefaults() async {
    final catalog = _readCatalog();
    for (final summary in catalog) {
      await _prefs.remove(_projectKey(summary.id));
    }
    await _writeCatalog([]);
    await _prefs.remove(_activeProjectIdKey);
    await _prefs.remove(_seededDefaultIdsKey);
    await backfillNewDefaults();
  }

  /// Adds any built-in default whose id has never been seeded on this device,
  /// without touching existing projects. Non-destructive: user edits are never
  /// overwritten, existing projects never duplicated, and a default the user
  /// deleted (its id already in the ledger) is never resurrected.
  ///
  /// On a pre-migration install (ledger absent) the defaults already present
  /// in the catalog are treated as already-seeded, so the first run adds only
  /// genuinely-new defaults and records the full set.
  Future<void> backfillNewDefaults() async {
    final catalogIds = _readCatalog().map((s) => s.id).toSet();
    final raw = _prefs.getString(_seededDefaultIdsKey);
    Set<String> seeded;
    if (raw == null) {
      seeded = <String>{
        for (final d in DefaultProjects.all())
          if (catalogIds.contains(d.id)) d.id,
      };
    } else {
      seeded = _decodeStringSet(raw);
    }
    var changed = false;
    for (final d in DefaultProjects.all()) {
      if (!seeded.contains(d.id)) {
        if (!catalogIds.contains(d.id)) {
          await saveProject(d);
        }
        seeded.add(d.id);
        changed = true;
      }
    }
    if (changed || raw == null) {
      await _prefs.setString(_seededDefaultIdsKey, jsonEncode(seeded.toList()));
    }
  }

  /// Defensive decode of the seeded-ids blob: any corruption yields an empty
  /// set (treated like a fresh ledger) rather than throwing.
  Set<String> _decodeStringSet(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toSet();
      }
    } catch (_) {
      // fall through
    }
    return <String>{};
  }

  // ── Id generation ────────────────────────────────────────────────────

  /// Derives a stable, collision-checked id of the form
  /// `proj_<sanitized-name>` (or `proj_<sanitized-name>_<n>` if that id is
  /// already taken) rather than relying solely on randomness/timestamps,
  /// so id generation stays deterministic and testable.
  String _uniqueId(String seed, Set<String> existingIds) {
    final sanitized = seed
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final base = 'proj_${sanitized.isEmpty ? 'untitled' : sanitized}';
    if (!existingIds.contains(base)) return base;
    var n = 2;
    while (existingIds.contains('${base}_$n')) {
      n++;
    }
    return '${base}_$n';
  }
}
