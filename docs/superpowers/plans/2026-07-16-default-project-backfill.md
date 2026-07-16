# Non-Destructive Default-Project Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make newly-added built-in default projects appear on existing installs after upgrade, without overwriting user edits, duplicating projects, or resurrecting user-deleted defaults.

**Architecture:** A persisted `seeded_default_ids` ledger + a `backfillNewDefaults()` repository method that adds only defaults whose id was never seeded (bootstrapping the ledger from the current catalog for pre-migration installs). Wire it into app startup in place of `seedDefaultsIfEmpty()`.

**Tech Stack:** Flutter/Dart, `shared_preferences`. `flutter test`, `flutter analyze`, `flutter build web --release`. Package `soft_plc_mobile`.

## Global Constraints

- Braces on all control flow; zero `flutter analyze` warnings; dark theme.
- Additive/backward-compatible: no change to project blobs, catalog format, or any default project's content; the new key is additive.
- Deterministic; never throws (defensive reads matching the repository's existing style).

## Key facts (verified)

- `mobile/lib/data/project_repository.dart`: `class ProjectRepository { ProjectRepository(this._prefs); final SharedPreferences _prefs; ... }`. Existing keys: `static const String _catalogKey = 'project_catalog';`, `_activeProjectIdKey = 'active_project_id'`, `static String _projectKey(String id) => 'project_$id';`. Helpers: `List<ProjectSummary> _readCatalog()`, `Future<void> _writeCatalog(...)`, `Future<void> saveProject(PlcProject p, {DateTime? updatedAt})` (upserts blob + catalog summary), `Future<void> deleteProject(String id)`, `Future<void> seedDefaultsIfEmpty()` (line 189; seeds `DefaultProjects.all()` only if catalog empty), `Future<void> resetToDefaults()` (line 199; wipes blobs + catalog + active-id, then `seedDefaultsIfEmpty()`). `import 'dart:convert'` (jsonEncode/Decode) and `DefaultProjects` are already imported.
- `DefaultProjects.all()` (in `mobile/lib/data/default_projects.dart`) returns `List<PlcProject>` each with a stable `.id` (e.g. `proj_sfc_batchmix`).
- Startup: `mobile/lib/screens/workspace_shell.dart:257` calls `await repo.seedDefaultsIfEmpty();` inside the boot `try`. Line ~1024 calls `seedDefaultsIfEmpty()` in the delete-last-project recovery path (LEAVE THAT ONE).
- Test harness (`mobile/test/project_repository_test.dart`): `SharedPreferences.setMockInitialValues({}); final prefs = await SharedPreferences.getInstance(); return ProjectRepository(prefs);` with `TestWidgetsFlutterBinding.ensureInitialized();`.

---

### Task 1: `backfillNewDefaults()` + seeded-ids ledger (repository)

**Files:**
- Modify: `mobile/lib/data/project_repository.dart`
- Test: `mobile/test/project_repository_test.dart` (add cases)

**Interfaces:**
- Produces: `Future<void> backfillNewDefaults()`; new `static const String _seededDefaultIdsKey = 'seeded_default_ids'`; `resetToDefaults()` also clears `_seededDefaultIdsKey`.

- [ ] **Step 1: Write the failing tests**

Add to `mobile/test/project_repository_test.dart` (reuse the existing `freshRepo()` helper):

```dart
test('backfillNewDefaults seeds all on a fresh store and is idempotent', () async {
  final repo = await freshRepo();
  await repo.backfillNewDefaults();
  final n = (await repo.listProjects()).length;
  expect(n, DefaultProjects.all().length);
  await repo.backfillNewDefaults(); // no duplication
  expect((await repo.listProjects()).length, n);
});

test('backfillNewDefaults adds a genuinely-new default to an existing install', () async {
  final repo = await freshRepo();
  // Simulate a prior app version: save every default EXCEPT the last one,
  // and leave the seeded-ids ledger absent (pre-migration).
  final all = DefaultProjects.all();
  final missing = all.last;
  for (final p in all) {
    if (p.id != missing.id) {
      await repo.saveProject(p);
    }
  }
  expect((await repo.listProjects()).any((s) => s.id == missing.id), isFalse);
  await repo.backfillNewDefaults();
  final ids = (await repo.listProjects()).map((s) => s.id).toSet();
  expect(ids.contains(missing.id), isTrue, reason: 'new default backfilled');
  expect(ids.length, all.length, reason: 'no duplicates');
});

test('backfillNewDefaults does not overwrite a user-edited default', () async {
  final repo = await freshRepo();
  await repo.backfillNewDefaults(); // seed all + record ledger
  final id = (await repo.listProjects()).first.id;
  final p = await repo.loadProject(id);
  final newName = '${p!.name} (edited)';
  final edited = p..name = newName; // mutate in place (name is mutable on PlcProject)
  await repo.saveProject(edited);
  await repo.backfillNewDefaults(); // must NOT restore the original
  final reloaded = await repo.loadProject(id);
  expect(reloaded!.name, newName);
});

test('backfillNewDefaults does not resurrect a user-deleted default', () async {
  final repo = await freshRepo();
  await repo.backfillNewDefaults(); // records all default ids in the ledger
  final id = (await repo.listProjects()).first.id;
  await repo.deleteProject(id);
  await repo.backfillNewDefaults(); // id is in the ledger -> not re-added
  expect((await repo.listProjects()).any((s) => s.id == id), isFalse);
});

test('resetToDefaults clears the ledger and leaves the full default set once', () async {
  final repo = await freshRepo();
  await repo.backfillNewDefaults();
  await repo.resetToDefaults();
  final ids = (await repo.listProjects()).map((s) => s.id).toList();
  expect(ids.toSet().length, ids.length, reason: 'no duplicates after reset');
  expect(ids.length, DefaultProjects.all().length);
  // A following backfill must be a no-op (ledger rebuilt / bootstrap from catalog).
  await repo.backfillNewDefaults();
  expect((await repo.listProjects()).length, DefaultProjects.all().length);
});
```

Note for the implementer: if `PlcProject.name` is not directly mutable, edit any other mutable field (e.g. a tag value) and assert it survives instead — the point is "backfill does not overwrite an existing project blob". Keep the assertion's intent.

- [ ] **Step 2: Run — expect FAIL**

Run: `cd mobile && flutter test test/project_repository_test.dart`
Expected: the new cases fail (`backfillNewDefaults` undefined).

- [ ] **Step 3: Implement**

In `ProjectRepository`:
- Add `static const String _seededDefaultIdsKey = 'seeded_default_ids';`.
- Add the method (defensive decode; never throws):

```dart
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
```

- In `resetToDefaults()`, add `await _prefs.remove(_seededDefaultIdsKey);` after removing the active-project id and before `seedDefaultsIfEmpty()`.

- [ ] **Step 4: Run — expect PASS**

Run: `cd mobile && flutter test test/project_repository_test.dart`
Expected: all pass (new + existing repository tests).

- [ ] **Step 5: analyze + commit**

Run: `cd mobile && flutter analyze lib/data/project_repository.dart test/project_repository_test.dart` (zero warnings).

```bash
git add mobile/lib/data/project_repository.dart mobile/test/project_repository_test.dart
git commit -m "feat(persistence): non-destructive backfill of new default projects (seeded-ids ledger)"
```

---

### Task 2: Wire into startup + integration test + docs

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (startup call swap)
- Test: `mobile/test/persistence_integration_test.dart` (add an existing-install case)
- Docs: `README.md` (short persistence note)

**Interfaces:**
- Consumes: `ProjectRepository.backfillNewDefaults()` (Task 1).

- [ ] **Step 1: Write the failing integration test**

Add to `mobile/test/persistence_integration_test.dart` (mirror its existing setup for building a repo over mock prefs; if it constructs `ProjectRepository` directly, follow that; otherwise use the `SharedPreferences.setMockInitialValues` pattern):

```dart
test('existing install backfills a new default on startup path', () async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final repo = ProjectRepository(prefs);
  // Simulate an older install: every default except the last, ledger absent.
  final all = DefaultProjects.all();
  final missing = all.last;
  for (final p in all) {
    if (p.id != missing.id) {
      await repo.saveProject(p);
    }
  }
  // The startup path now calls backfillNewDefaults() instead of seedDefaultsIfEmpty().
  await repo.backfillNewDefaults();
  final ids = (await repo.listProjects()).map((s) => s.id).toSet();
  expect(ids.contains(missing.id), isTrue);
  expect(ids.length, all.length);
});
```

(If `persistence_integration_test.dart` lacks the `shared_preferences` import or the binding init, add them, matching `project_repository_test.dart`.)

- [ ] **Step 2: Run — expect PASS of the new test in isolation**

Run: `cd mobile && flutter test test/persistence_integration_test.dart`
(The test exercises the repository method directly, so it passes once Task 1 is in. Its purpose is to lock the startup contract.)

- [ ] **Step 3: Swap the startup call**

In `mobile/lib/screens/workspace_shell.dart` at ~line 257, change:
```dart
await repo.seedDefaultsIfEmpty();
```
to:
```dart
await repo.backfillNewDefaults();
```
Leave the `seedDefaultsIfEmpty()` call in the delete-last-project recovery path (~line 1024) unchanged.

- [ ] **Step 4: Run the boot/integration/repository suites**

Run: `cd mobile && flutter test test/persistence_integration_test.dart test/project_repository_test.dart test/widget_test.dart`
Expected: all pass (the app still boots and seeds correctly on a fresh store via the backfill bootstrap path).

- [ ] **Step 5: Full gate + docs**

Run: `cd mobile && flutter analyze` (clean), `cd mobile && flutter test` (ALL pass — record the count), `cd mobile && flutter build web --release` (builds). Report failures verbatim.

Docs: add a short note (README persistence section, or the relevant existing doc) that built-in default projects backfill non-destructively on upgrade — new defaults appear without wiping user projects or edits, and "Reset to Defaults" remains the full destructive restore. No forbidden branding.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/test/persistence_integration_test.dart README.md
git commit -m "feat(persistence): backfill new defaults on startup; docs"
```

---

## Self-Review

**Spec coverage:**
- `seeded_default_ids` ledger + `backfillNewDefaults()` with bootstrap → Task 1. ✓
- Fresh-install seed / idempotent / new-default-added / no-overwrite / no-resurrect / reset-clears-ledger → Task 1 tests. ✓
- Startup wiring swap (keep delete-last recovery `seedDefaultsIfEmpty`) → Task 2. ✓
- Existing-install integration + full gate + docs → Task 2. ✓

**Placeholder scan:** All code is complete; the one conditional instruction (edit `name` vs a tag value if `name` isn't mutable) preserves the test's intent without weakening it.

**Type consistency:** `backfillNewDefaults()` / `_seededDefaultIdsKey` / `_decodeStringSet` are internal to `ProjectRepository`; `saveProject`/`_readCatalog`/`deleteProject` used as they exist. Startup swap matches the method name. `DefaultProjects.all()` and `dart:convert` are already imported in the repository.

**Note for the executor:** The behavioural contract is the five repository tests (seed / idempotent / add-new / no-overwrite / no-resurrect / reset). Keep them binding. After merge, an existing Windows install will show "SFC — Batch Mix & Dispatch" on next launch without any reset.
