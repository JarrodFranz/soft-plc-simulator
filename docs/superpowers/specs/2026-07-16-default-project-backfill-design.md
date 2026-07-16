# Non-Destructive Default-Project Backfill — Design Spec

**Date:** 2026-07-16
**Status:** Approved (design)
**Workstream:** Project persistence — make newly-added built-in default projects appear on existing installs without wiping user data.

## Goal

When a new built-in default project is added to `DefaultProjects.all()` (e.g. "SFC — Batch Mix & Dispatch"), it must appear on an **existing** install after upgrade — not only on a first-ever launch. Do this **non-destructively**: never overwrite a user's edits to a default, never duplicate an existing project, and never resurrect a default the user deliberately deleted.

## Problem (as-found)

`ProjectRepository.seedDefaultsIfEmpty()` (`mobile/lib/data/project_repository.dart:189`) seeds `DefaultProjects.all()` only when the catalog is **empty** (first launch). On an existing install the catalog is non-empty, so the call is a no-op and any newly-added default is never inserted. Rebuilding the app does not help.

## Approach

Track which default ids have ever been seeded, in a new persisted key, and on startup add only defaults whose id has never been seeded. Bootstrapping for pre-migration installs treats defaults already present in the catalog as already-seeded, so the first backfill adds exactly the genuinely-new default(s).

### Storage (new key)

- `seeded_default_ids` → JSON list of default project ids that have been seeded. Absent = pre-migration install (never tracked).

### New method — `Future<void> backfillNewDefaults()`

```
catalog       = _readCatalog(); catalogIds = { s.id }
seededRaw     = _prefs.getString(_seededDefaultIdsKey)
Set<String> seeded
if (seededRaw == null) {
  // pre-migration bootstrap: defaults already in the catalog are treated
  // as already-seeded, so we don't re-add ones the user may have edited,
  // and (crucially) we DON'T add ones already present.
  seeded = { d.id for d in DefaultProjects.all() if catalogIds.contains(d.id) }
} else {
  seeded = decodeJsonStringList(seededRaw).toSet()
}
var changed = false
for (final d in DefaultProjects.all()) {
  if (!seeded.contains(d.id)) {
    if (!catalogIds.contains(d.id)) {
      await saveProject(d);   // add the genuinely-new default
    }
    seeded.add(d.id);
    changed = true;
  }
}
if (changed || seededRaw == null) {
  await _prefs.setString(_seededDefaultIdsKey, jsonEncode(seeded.toList()));
}
```

Behaviour matrix:
- **Existing install** (12 defaults present, key absent): bootstrap `seeded = {12 present ids}`; the new default (id absent) is saved and recorded → user sees 13, no user data touched.
- **Fresh install** (catalog empty, key absent): bootstrap `seeded = {}`; all defaults saved and recorded → subsumes the empty-seed.
- **Next launch** (key present, all recorded): nothing added, no write.
- **User deleted a default** (its id in `seeded`): not re-added — stays deleted.
- **Future new default** added in code: added once, then recorded.

### Wiring

- Startup (`workspace_shell.dart` ~line 257): replace the `await repo.seedDefaultsIfEmpty();` call with `await repo.backfillNewDefaults();`. (Backfill subsumes the empty-seed via the bootstrap path.)
- `resetToDefaults()` (`project_repository.dart:199`): after wiping the catalog / active-id, also `await _prefs.remove(_seededDefaultIdsKey);` before re-seeding, so the ledger is rebuilt fresh (the subsequent seed/backfill re-records all current defaults). Reset stays fully destructive-by-design (it already warns the user).
- Keep `seedDefaultsIfEmpty()` unchanged for the delete-last-project recovery path (`workspace_shell.dart:1024`), which is an emptiness-recovery concern independent of the seeded-ids ledger. (When the catalog is empty it seeds all; a following `backfillNewDefaults` then just records ids already present — no duplication.)

## Global Constraints

- Dark theme; braces on all control flow; zero `flutter analyze` warnings.
- Additive/backward-compatible: no change to existing project blobs, catalog format, or any default project's content. The new key is additive and defaults to "bootstrap from catalog".
- Deterministic; never throws (defensive reads, matching the repository's existing style — a corrupt `seeded_default_ids` value is treated as absent → bootstrap).

## Error handling / edge cases

- Corrupt/undecodable `seeded_default_ids` → treat as absent (bootstrap from catalog), never throw.
- A default present in the catalog but not in `seeded` (pre-migration) → recorded, not re-saved (no overwrite of user edits).
- Bootstrap runs once; after it writes the key, later launches take the fast path.

## Testing

Pure repository tests (mirror `project_repository_test.dart`'s `SharedPreferences.setMockInitialValues({})` + `ProjectRepository(prefs)` harness):
- **Fresh install:** `backfillNewDefaults()` on an empty store seeds all `DefaultProjects.all()` once; a second call adds nothing (idempotent); `seeded_default_ids` contains every default id.
- **Existing install gains a new default:** seed all-but-one default and remove one id from the (absent) ledger scenario — concretely: seed `DefaultProjects.all()` except simulate a prior version by saving all defaults, deleting one default's blob+catalog entry AND clearing the ledger key, then `backfillNewDefaults()` re-adds exactly that one and records it. (Simpler realization: save every default except the last, leave the ledger key absent, call backfill → the missing one is added, count == all; user projects/edits untouched.)
- **User edits preserved:** edit a seeded default (change a tag), run `backfillNewDefaults()` → the edited project is unchanged (not overwritten).
- **Deleted default not resurrected:** run backfill once (records all ids), delete a default via `deleteProject`, run backfill again → it is NOT re-added (its id is in the ledger).
- **Reset clears the ledger:** after `resetToDefaults()`, the ledger key is gone (or rebuilt), and a following `backfillNewDefaults()` leaves the full default set present with no duplicates.

Integration/widget:
- An existing-install simulation booting `WorkspaceShell` (mock prefs pre-populated with the old default set minus the new project) shows the new project in the catalog after startup, and does not duplicate the others.
- Full gate: `flutter analyze` (clean), `flutter test` (all pass — report count), `flutter build web --release`.

## Files

- **Modify:** `mobile/lib/data/project_repository.dart` (add `_seededDefaultIdsKey`, `backfillNewDefaults()`, clear-ledger in `resetToDefaults`), `mobile/lib/screens/workspace_shell.dart` (startup call swap).
- **Test:** extend `mobile/test/project_repository_test.dart`; add an existing-install integration case (in `project_repository_test.dart` or `persistence_integration_test.dart`).
- **Docs:** a short note in the persistence/README section that new built-in defaults backfill non-destructively on upgrade.

## Non-goals / YAGNI

- No versioned migration framework; no per-project schema migration (blobs already round-trip losslessly).
- No UI for the backfill (silent on startup); the existing "Reset to Defaults" remains the destructive full-restore.
- No re-adding of user-deleted defaults (explicitly avoided via the ledger).
