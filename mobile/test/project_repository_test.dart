import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/data/project_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProjectRepository> freshRepo() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return ProjectRepository(prefs);
  }

  test('seedDefaultsIfEmpty seeds once and is idempotent', () async {
    final repo = await freshRepo();
    await repo.seedDefaultsIfEmpty();
    final n = (await repo.listProjects()).length;
    expect(n, DefaultProjects.all().length);
    await repo.seedDefaultsIfEmpty(); // no duplication
    expect((await repo.listProjects()).length, n);
  });

  test('save/load round-trips an edited project', () async {
    final repo = await freshRepo();
    await repo.seedDefaultsIfEmpty();
    final id = (await repo.listProjects()).first.id;
    final p = await repo.loadProject(id);
    p!.tags.first.value = !(p.tags.first.value == true);
    await repo.saveProject(p);
    final reloaded = await repo.loadProject(id);
    expect(reloaded!.tags.first.value, p.tags.first.value);
  });

  test('duplicate mints a new id; delete removes only that project', () async {
    final repo = await freshRepo();
    await repo.seedDefaultsIfEmpty();
    final id = (await repo.listProjects()).first.id;
    final before = (await repo.listProjects()).length;
    final newId = await repo.duplicateProject(id, newName: 'Copy');
    expect(newId, isNot(id));
    expect((await repo.listProjects()).length, before + 1);
    await repo.deleteProject(newId);
    expect((await repo.listProjects()).length, before);
    expect(await repo.loadProject(id), isNotNull); // original intact
  });

  test('active id persists; corrupt blob is skipped not fatal', () async {
    final repo = await freshRepo();
    await repo.seedDefaultsIfEmpty();
    final id = (await repo.listProjects()).first.id;
    await repo.setActiveProjectId(id);
    expect(await repo.getActiveProjectId(), id);

    // A corrupt stored project must not crash listing/loading.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // Catalog references a project whose blob is invalid JSON.
    await prefs.setString(
      'project_catalog',
      '[{"id":"bad_id","name":"Bad","controllerName":"PLC","updatedAt":"2026-01-01T00:00:00.000Z"}]',
    );
    await prefs.setString('project_bad_id', '{not valid json');
    final repo2 = ProjectRepository(prefs);

    // Listing still returns the catalog entry (summary is fine)...
    final listed = await repo2.listProjects();
    expect(listed.length, 1);
    expect(listed.first.id, 'bad_id');
    // ...but loading the corrupt blob returns null rather than throwing.
    expect(await repo2.loadProject('bad_id'), isNull);

    // A fully corrupt catalog (not JSON at all) must not crash listing either.
    await prefs.setString('project_catalog', 'not json at all');
    final repo3 = ProjectRepository(prefs);
    expect(await repo3.listProjects(), isEmpty);
  });

  test('renameProject updates the summary', () async {
    final repo = await freshRepo();
    await repo.seedDefaultsIfEmpty();
    final id = (await repo.listProjects()).first.id;
    await repo.renameProject(id, 'Renamed');
    expect((await repo.loadProject(id))!.name, 'Renamed');
    expect((await repo.listProjects()).firstWhere((s) => s.id == id).name, 'Renamed');
  });

  test('resetToDefaults clears user projects and re-seeds defaults', () async {
    final repo = await freshRepo();
    await repo.seedDefaultsIfEmpty();
    final id = (await repo.listProjects()).first.id;
    await repo.duplicateProject(id, newName: 'Extra');
    expect((await repo.listProjects()).length, DefaultProjects.all().length + 1);

    await repo.resetToDefaults();
    final after = await repo.listProjects();
    expect(after.length, DefaultProjects.all().length);
  });

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
}
