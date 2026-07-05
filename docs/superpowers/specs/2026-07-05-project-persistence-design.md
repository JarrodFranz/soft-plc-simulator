# Project Persistence (WS6) — Design Spec

**Date:** 2026-07-05
**Status:** Approved by delegation (user: "project persistence"; goal — ONE
Flutter app shipped to iOS/Android stores AND running on a desktop computer).
**Author:** Claude (pairing with Jarrod)

The app builds and executes projects but cannot save them — everything loads
from hardcoded `DefaultProjects.all()` and every edit is lost on reload. This
workstream makes projects persist, with a single storage path that works
identically on all shipped targets (Android, iOS, Windows, macOS, Linux; and
web for dev).

## Guiding constraint: one app, all platforms

Per the product goal ([[product-goal]]), use ONE cross-platform code path — no
`Platform.*`/`dart:io`-path branching. Storage is via **`shared_preferences`**
(the one plugin that works on every Flutter target including web), behind a
repository abstraction so the backend can be swapped later without touching
callers. Cross-device transfer (no cloud) is via explicit file **export/import**.

## The core risk: serialization is incomplete and lossy TODAY

`PlcProject.toJson`/`fromJson` and `PlcProgram.toJson`/`fromJson` exist but
**silently drop executable content**:
- `PlcProgram` serializes only `name`/`language`/`description`/`stSource`/
  `enabled` — it **loses `rungs` (LD), `fbdBlocks`/`fbdWires` (FBD), and
  `sfcSteps`/`sfcTransitions` (SFC)** entirely.
- `PlcProject.fromJson` hardcodes `structDefs: []` and `toJson` omits
  `structDefs` — struct/DUT definitions are **lost**.
- The graph classes `StructFieldDef`, `PlcStructDef`, `LdNode`, `LdWire`,
  `LdRung`, `FbdBlock`, `FbdWire`, `SfcStep`, `SfcTransition` have **no
  `toJson`/`fromJson` at all**.
- `PlcTag` round-tripping of its structured `value` tree (struct `Map`s, array
  `List`s, bit ints), `isForced`/`forcedValue`, `quality`, `engineeringUnits`,
  `arrayLength` must be verified complete.

So the first and most important task is **completing serialization to be
lossless**, proven not just by structural round-trip but by **scan
equivalence**: a project, serialized → JSON → deserialized, must execute to
byte-identical tag values as the original over K scans. Without that, saved
projects corrupt silently.

## Architecture

### 1. Complete serialization (`mobile/lib/models/project_model.dart`)

Add `toJson`/`fromJson` to every graph class and wire them into the composites:
- `StructFieldDef`, `PlcStructDef`; include `structDefs` in `PlcProject`.
- `LdNode` (id, kind, variable, modifier, blockType, presetMs, comment, …),
  `LdWire` (fromId, toId), `LdRung` (index, comment, nodes, wires) — and
  `PlcProgram` serializes `rungs`.
- `FbdBlock` (id, type, title, tagBinding, x, y), `FbdWire` (fromBlockId,
  toBlockId) — `PlcProgram` serializes `fbdBlocks`/`fbdWires`.
- `SfcStep` (id, name, isInitial, actionSt), `SfcTransition` (id, fromStepId,
  toStepId, conditionSt) — `PlcProgram` serializes `sfcSteps`/`sfcTransitions`.
- Verify `PlcTag` covers the full value tree + forcing + quality + units +
  arrayLength; fix if not.

Enums serialize by `.name` and parse back by name with a safe default. Round-trip
is symmetric (every field written is read). No schema-version bump needed yet,
but include a top-level `"schema": 1` so future migrations are possible.

### 2. Project repository (`mobile/lib/data/project_repository.dart` — new)

```dart
class ProjectRepository {
  ProjectRepository(this._prefs);           // inject SharedPreferences for tests
  Future<List<ProjectSummary>> listProjects();
  Future<PlcProject?> loadProject(String id);
  Future<void> saveProject(PlcProject p);   // upsert by id
  Future<void> deleteProject(String id);
  Future<String> duplicateProject(String id, {String? newName}); // returns new id
  Future<void> renameProject(String id, String name);
  Future<String?> getActiveProjectId();
  Future<void> setActiveProjectId(String id);
  Future<void> seedDefaultsIfEmpty();       // first run: import DefaultProjects.all()
  Future<void> resetToDefaults();           // wipe + re-seed
}
```

Backed by `shared_preferences`: a catalog key (list of project ids + summaries)
+ one key per project holding its JSON. `ProjectSummary` = {id, name,
controllerName, updatedAt}. IDs are stable; duplicate mints a new id. Pure of
Flutter widgets; unit-tested with `SharedPreferences.setMockInitialValues({})`.

### 3. Shell integration + project CRUD (`workspace_shell.dart`, project switcher)

- On boot: `await repo.seedDefaultsIfEmpty()`, load the catalog, restore the
  last `activeProjectId` (fallback to the first). Replace the hardcoded
  `_allProjects = DefaultProjects.all()` with the repository load.
- **Autosave:** debounce (~800 ms) a `saveProject(_activeProject)` after any
  mutation (tag edits, forcing, program edits, sim-rule edits, HMI edits,
  project rename). A small "Saved ✓ / Saving…" affordance in the AppBar.
- **Project CRUD** in the existing SELECT PROJECT area: New (blank or from a
  default template), Duplicate, Rename, Delete (with confirm), Reset to
  defaults. Switching project persists the new `activeProjectId`.
- Runtime state (sim/LD/SFC/FBD/ST runtimes) already clears on project switch —
  unchanged.

### 4. Export / Import (`workspace_shell.dart` + a small service)

- **Export:** serialize the active project to pretty JSON and hand it to the
  platform's share/save sheet (`share_plus` on mobile; a save dialog on
  desktop). Filename `"<project name>.splc.json"`.
- **Import:** pick a `.json`/`.splc.json` file (`file_picker`), parse via
  `PlcProject.fromJson`, assign a fresh id if it collides, add to the catalog,
  and switch to it. Validate/parse defensively (never crash on a bad file;
  surface an error snackbar).
- This is the cross-device story (phone ⇄ computer) given no cloud.

## Testing

- **Round-trip + scan-equivalence (the linchpin):** for EVERY `DefaultProjects`
  project: `p → toJson → jsonEncode → jsonDecode → fromJson = p2`; assert (a)
  structural deep-equality of the serialized maps (`p.toJson()` == `p2.toJson()`),
  and (b) **scan equivalence** — run K (e.g. 20) scans through the full
  sim→LD→FBD→SFC→ST pipeline on both `p` and `p2` and assert every tag value
  matches at each step. This proves executable losslessness (catches dropped
  rungs/blocks/steps immediately).
- **Repository:** with mocked prefs — seed-defaults-if-empty is idempotent;
  save/load/list/delete/duplicate/rename/active-id behave; a corrupt stored
  blob is skipped, not fatal.
- **Integration:** boot the shell (mocked prefs), edit a tag, pump past the
  debounce, assert the repository received a save with the change; reboot a new
  shell against the same prefs and assert the edit survived.
- Existing 155 tests still pass; `flutter analyze` zero; `flutter build web
  --release` succeeds. New deps (`shared_preferences`, `file_picker`,
  `share_plus`) must not break the web build.

## Global constraints (unchanged)

No third-party/reference-editor branding · dark theme · `flutter analyze` zero
issues · no RenderFlex overflow (persistence UI adds dialogs — use the WS5
`showAdaptiveWidthDialog`) · width-based only · engines (`mobile/lib/models`
execution) semantics unchanged — serialization is additive. **Lossless
round-trip is the acceptance bar.**

## Out of scope (deferred)

- Cloud sync / accounts.
- Undo/redo history persistence.
- Schema migration engine (just stamp `schema: 1` now).
- App↔Rust runtime wiring and protocol adapters (separate track).
- Encrypting stored projects.
