# Project Persistence (WS6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make projects persist losslessly across app restarts on every shipped target (Android/iOS stores + desktop), with save/load, project CRUD, autosave, and file export/import — one cross-platform code path.

**Architecture:** Complete the JSON serialization of the whole `PlcProject` graph (proven by scan-equivalence round-trip), add a `ProjectRepository` over `shared_preferences` (universal backend, injectable for tests), wire boot-load + debounced autosave + project CRUD into the shell, and add file export/import for cross-device transfer.

**Tech Stack:** Flutter / Dart, `shared_preferences`, `file_picker`, `share_plus`, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding. Dark theme. `flutter analyze` zero issues. Braces on flow-control; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`; `initialValue:` on `DropdownButtonFormField`. Persistence dialogs use WS5's `showAdaptiveWidthDialog`. No RenderFlex overflow at 360/320/1400.
- **One cross-platform code path** — no `Platform.*`/`dart:io`-path branching for storage (use `shared_preferences`). New deps must NOT break `flutter build web --release`.
- Engine/execution semantics in `mobile/lib/models` are UNCHANGED — serialization is additive. **Lossless round-trip (structural + scan-equivalence) is the acceptance bar.**
- Existing 155 tests must keep passing.

**Sequencing:** Task 1 (serialization) is the foundation and gate for everything. Task 2 (repository) depends on it. Task 3 (shell integration) depends on 1+2. Task 4 (export/import) depends on 1. Task 5 validates.

---

### Task 1: Complete lossless serialization + round-trip/scan-equivalence tests

**Files:**
- Modify: `mobile/lib/models/project_model.dart`
- Test: `mobile/test/serialization_roundtrip_test.dart`

**Interfaces produced:** `toJson()`/`fromJson()` on ALL of `StructFieldDef`, `PlcStructDef`, `LdNode`, `LdWire`, `LdRung`, `FbdBlock`, `FbdWire`, `SfcStep`, `SfcTransition` (and existing ones), with `PlcProgram` serializing `rungs`/`fbdBlocks`/`fbdWires`/`sfcSteps`/`sfcTransitions` and `PlcProject` serializing `structDefs`.

- [ ] **Step 1: Write the failing round-trip + scan-equivalence test**

Create `mobile/test/serialization_roundtrip_test.dart`. READ each engine's real signature (`applySimRules`, `executeLdPrograms`, `executeFbdPrograms`, `executeSfcPrograms`, `executeStPrograms` + their runtimes) and adapt the `_scan` helper to match.

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';

// One full scan tick, exactly as the shell runs it.
void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, FbdRuntime fbd,
    SfcRuntime sfc, StRuntime st, [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
  executeFbdPrograms(p, dtMs, fbd);
  executeSfcPrograms(p, dtMs, sfc);
  executeStPrograms(p, dtMs, st);
}

// A dependency-free snapshot of every tag's observable state.
String _snapshot(PlcProject p) => jsonEncode([
      for (final t in p.tags)
        {'n': t.name, 'v': t.value, 'f': t.isForced, 'fv': t.forcedValue}
    ]);

PlcProject _roundTrip(PlcProject p) =>
    PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())));

void main() {
  for (final original in DefaultProjects.all()) {
    group('round-trip ${original.id}', () {
      test('structural: collections and struct defs are preserved', () {
        final p2 = _roundTrip(original);
        expect(p2.id, original.id);
        expect(p2.tags.length, original.tags.length);
        expect(p2.structDefs.length, original.structDefs.length,
            reason: 'struct defs must survive serialization');
        expect(p2.programs.length, original.programs.length);
        expect(p2.tasks.length, original.tasks.length);
        expect(p2.hmis.length, original.hmis.length);
        expect(p2.simRules.length, original.simRules.length);
        for (var i = 0; i < original.programs.length; i++) {
          final a = original.programs[i], b = p2.programs[i];
          expect(b.rungs.length, a.rungs.length, reason: '${a.name} LD rungs');
          expect(b.fbdBlocks.length, a.fbdBlocks.length, reason: '${a.name} FBD blocks');
          expect(b.fbdWires.length, a.fbdWires.length, reason: '${a.name} FBD wires');
          expect(b.sfcSteps.length, a.sfcSteps.length, reason: '${a.name} SFC steps');
          expect(b.sfcTransitions.length, a.sfcTransitions.length, reason: '${a.name} SFC transitions');
          expect(b.stSource, a.stSource);
        }
      });

      test('idempotent: toJson == toJson after a round-trip', () {
        final p2 = _roundTrip(original);
        expect(jsonEncode(p2.toJson()), jsonEncode(original.toJson()));
      });

      test('scan-equivalence: 20 scans identical to a fresh copy', () {
        final a = original;
        final b = _roundTrip(original);
        final aRt = (SimRuntime(), LdExecRuntime(), FbdRuntime(), SfcRuntime(), StRuntime());
        final bRt = (SimRuntime(), LdExecRuntime(), FbdRuntime(), SfcRuntime(), StRuntime());
        expect(_snapshot(a), _snapshot(b), reason: 'initial state must match');
        for (var i = 0; i < 20; i++) {
          _scan(a, aRt.$1, aRt.$2, aRt.$3, aRt.$4, aRt.$5);
          _scan(b, bRt.$1, bRt.$2, bRt.$3, bRt.$4, bRt.$5);
          expect(_snapshot(b), _snapshot(a),
              reason: 'scan $i diverged — serialization is lossy for ${original.id}');
        }
      });
    });
  }
}
```

- [ ] **Step 2: Run → FAIL** (dropped rungs/blocks/steps/structDefs make structural counts and scan-equivalence fail).

- [ ] **Step 3: Implement the missing serialization** in `project_model.dart`. READ each class's constructor to get exact field names/defaults. Add symmetric `toJson`/`fromJson`:
  - `StructFieldDef`, `PlcStructDef` (fields + nested field list).
  - `LdNode` (all fields incl. `kind`/`modifier` enums via `.name` + safe parse-by-name, `blockType`, `presetMs`, `comment`, `variable`, `id`), `LdWire` (`fromId`,`toId`), `LdRung` (`index`,`comment`,`nodes`,`wires`).
  - `FbdBlock` (`id`,`type`,`title`,`tagBinding`,`x`,`y`), `FbdWire` (`fromBlockId`,`toBlockId`).
  - `SfcStep` (`id`,`name`,`isInitial`,`actionSt`), `SfcTransition` (`id`,`fromStepId`,`toStepId`,`conditionSt`).
  - Extend `PlcProgram.toJson`/`fromJson` to include `rungs`/`fbdBlocks`/`fbdWires`/`sfcSteps`/`sfcTransitions`.
  - Extend `PlcProject.toJson`/`fromJson` to include `structDefs` (stop hardcoding `[]`).
  - Verify `PlcTag.toJson`/`fromJson` round-trips the full state: the structured `value` tree (Map/List/int — these are JSON-native, pass through as-is), `isForced`, `forcedValue`, `quality`, `ioType`, `dataType`, `path`, `engineeringUnits`, `arrayLength`, `description`. Fix any dropped field.
  - Add a top-level `'schema': 1` in `PlcProject.toJson` (ignored on read for now).
  - Enum fields: write `enumValue.name`; read with `Enum.values.firstWhere((e)=>e.name==s, orElse: ()=>default)`.

- [ ] **Step 4: Run tests → PASS (all default projects: structural + idempotent + scan-equivalence). Step 5: `flutter analyze` → No issues found! Full suite passes.**

- [ ] **Step 6: Commit** `feat(persist): complete lossless PlcProject serialization (LD/FBD/SFC/struct graph) + scan-equivalence round-trip tests`.

---

### Task 2: ProjectRepository over shared_preferences

**Files:**
- Create: `mobile/lib/data/project_repository.dart`
- Modify: `mobile/pubspec.yaml` (add `shared_preferences`)
- Test: `mobile/test/project_repository_test.dart`

**Interfaces produced:** `class ProjectSummary { String id, name, controllerName; DateTime updatedAt; }`; `class ProjectRepository` with `listProjects()`, `loadProject(id)`, `saveProject(p)`, `deleteProject(id)`, `duplicateProject(id,{newName})→newId`, `renameProject(id,name)`, `getActiveProjectId()`, `setActiveProjectId(id)`, `seedDefaultsIfEmpty()`, `resetToDefaults()`.

- [ ] **Step 1: Add dependency**

Add `shared_preferences: ^2.3.2` (or the latest 2.x) under `dependencies:` in `mobile/pubspec.yaml`; `flutter pub get`. (2.x supports Android/iOS/web/Windows/macOS/Linux — one code path.)

- [ ] **Step 2: Write tests `mobile/test/project_repository_test.dart`**

```dart
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
    // (Repository writes a bad blob under a catalog id and confirms listProjects
    // still returns and loadProject(badId) returns null rather than throwing —
    // implement defensively; adapt this assertion to the repo's storage keys.)
  });

  test('renameProject updates the summary', () async {
    final repo = await freshRepo();
    await repo.seedDefaultsIfEmpty();
    final id = (await repo.listProjects()).first.id;
    await repo.renameProject(id, 'Renamed');
    expect((await repo.loadProject(id))!.name, 'Renamed');
    expect((await repo.listProjects()).firstWhere((s) => s.id == id).name, 'Renamed');
  });
}
```

- [ ] **Step 3: Implement `project_repository.dart`** — a catalog key (JSON list of `ProjectSummary`) + one key per project (`project_<id>` → project JSON), an `active_project_id` key. `seedDefaultsIfEmpty` imports `DefaultProjects.all()` when the catalog is empty. `saveProject` upserts the blob + summary (stamps `updatedAt` — accept a passed-in timestamp OR use a repo field, since `DateTime.now()` is fine in app code but tests should be deterministic; keep `updatedAt` best-effort). All reads defensive (try/catch a bad blob → skip/null, never throw). Pure of widgets.

- [ ] **Step 4: Tests → PASS; `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(persist): ProjectRepository over shared_preferences (catalog, CRUD, seed defaults)`.

---

### Task 3: Shell integration — boot-load, autosave, project CRUD

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (and the project-switcher area)
- Test: `mobile/test/persistence_integration_test.dart`

**Behavior spec:**
- Boot: `await repo.seedDefaultsIfEmpty()`, load the catalog into the project list, restore the last `activeProjectId` (fallback first). Replace the hardcoded `_allProjects = DefaultProjects.all()`.
- Autosave: debounce (~800 ms) `repo.saveProject(_activeProject)` after any mutation (tag/force edits, program edits, sim rules, HMI, rename). Show a subtle "Saving…/Saved ✓" status in the AppBar. On project switch, persist `setActiveProjectId`.
- CRUD in the SELECT PROJECT area (use `showAdaptiveWidthDialog` for prompts): New (blank + pick language template or empty), Duplicate, Rename, Delete (confirm), Reset to defaults (confirm — calls `resetToDefaults`).
- Keep the runtime clears on switch unchanged. Do not change scan behavior.

- [ ] **Step 1: Write `mobile/test/persistence_integration_test.dart`** — boot `WorkspaceShell` against mocked prefs (`SharedPreferences.setMockInitialValues({})`); if the shell constructs its own repository internally, expose a test seam (e.g. an optional injected `ProjectRepository`/prefs) so the test can share the same backing store. Edit a tag via the Tag Inspector (or drive a mutation), `pump` past the debounce, then construct a SECOND shell against the same prefs and assert the edit survived (persisted). Assert no analyze/overflow regressions.
- [ ] **Step 2: Implement** the integration. Add a minimal injection seam for the repository/prefs so it's testable. Keep desktop/compact layouts (WS5) intact.
- [ ] **Step 3: Tests → PASS; analyze clean; full suite passes; `flutter build web --release` succeeds.**
- [ ] **Step 4: Commit** `feat(persist): boot from repository, debounced autosave, project CRUD in the switcher`.

---

### Task 4: Export / Import project files (cross-device transfer)

**Files:**
- Create: `mobile/lib/data/project_transfer.dart` (thin service)
- Modify: `mobile/lib/screens/workspace_shell.dart` (Export/Import actions), `mobile/pubspec.yaml` (`file_picker`, `share_plus`)
- Test: `mobile/test/project_transfer_test.dart`

**Behavior spec:**
- Export: serialize the active project to pretty JSON (`PlcProject.toJson` → `JsonEncoder.withIndent`), filename `"<name>.splc.json"`, hand to `share_plus` (mobile) / a save flow (desktop). Keep the file-writing/sharing behind the service so the PURE encode/decode is unit-testable without plugins.
- Import: pick a file (`file_picker`), read its text, `PlcProject.fromJson(jsonDecode(...))` defensively (bad file → error snackbar, never crash), assign a fresh id if it collides with an existing catalog id, `saveProject`, switch to it.
- The plugin-touching parts are thin; the `project_transfer.dart` service exposes pure `String encodeProject(PlcProject)` and `PlcProject decodeProject(String)` (the latter throws a typed `FormatException` on bad input) that the tests cover directly.

- [ ] **Step 1: Write `mobile/test/project_transfer_test.dart`** — `decodeProject(encodeProject(p))` round-trips (reuse a default project; assert scan-equivalence or structural equality); `decodeProject('not json')` and `decodeProject('{}')`-style bad input throws `FormatException` (or returns a documented error), never an uncaught crash; a colliding id is reassigned on import (test the id-reassign helper directly).
- [ ] **Step 2: Add deps** `file_picker`, `share_plus` (latest 2.x/x that support all platforms incl. web); `flutter pub get`; confirm web build still compiles. Implement the service + wire Export/Import actions.
- [ ] **Step 3: Tests → PASS; analyze clean; `flutter build web --release` succeeds.**
- [ ] **Step 4: Commit** `feat(persist): export/import projects as .splc.json files for cross-device transfer`.

---

### Task 5: Whole-workstream validation + final review

**Files:**
- Create: `mobile/test/persistence_smoke_test.dart` (optional, if gaps remain)

- [ ] **Step 1:** Full verification: `flutter test` (all pass, incl. the round-trip/repository/integration/transfer suites) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz" lib test` → no matches. If the app runs `flutter build` for other platforms trivially, note it; otherwise analyze+web+tests are the gate (per the environment).
- [ ] **Step 2:** Confirm the acceptance bar end-to-end: edit → autosave → restart → survives; export → import → identical (scan-equivalence). Add a smoke test only if Tasks 1–4 left a gap.
- [ ] **Step 3: Commit** any final test; then the branch is ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** complete lossless serialization + scan-equivalence proof (Task 1) ✓; shared_preferences repository with CRUD + seed + defensive reads (Task 2) ✓; boot-load + debounced autosave + project CRUD (Task 3) ✓; file export/import for cross-device (Task 4) ✓; whole-workstream validation (Task 5) ✓; one cross-platform path (shared_preferences, no Platform branching) ✓; engines untouched (serialization additive) ✓.
- **Acceptance bar is objective:** round-trip structural counts + `toJson` idempotence + 20-scan value equivalence per default project — a dropped rung/block/step/struct fails immediately.
- **Type consistency:** `ProjectRepository`, `ProjectSummary`, `encodeProject`/`decodeProject`, `seedDefaultsIfEmpty` used identically across tasks.
- **Risk:** the shell already has `toJson`/`fromJson` partially; Task 1 must make them symmetric and complete — the scan-equivalence test is the guard. New plugins must not break the web build — checked in Tasks 2/4/5.
