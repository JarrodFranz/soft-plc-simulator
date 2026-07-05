# Editor UX Fixes + Pin-Based FBD Wiring (WS7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four editor UX issues (LD toolbar overflow, LD phone pan/zoom, project CRUD ⋮ menu, type-ahead tag fields) and rebuild FBD into a pin-based editor — named input/output pins, pin-addressed wires, multi-output blocks (e.g. timers `Q`/`ET`) — with wiring you can draw, grounded in the PLCopen/IEC reference model.

**Architecture:** A pure `fbd_pins.dart` registry defines each block type's ordered input/output pin names; `FbdWire` becomes pin-addressed (`fromPin`/`toPin`); `fbd_exec.dart` evaluates each block to an output-pin→value map and executes `TON`/`TOF` statefully; `fbd_editor_screen.dart` renders pins as dots and lets you tap/drag to connect them. The four UX fixes are independent. Verification: pure engine tests + scan-equivalence round-trip (WS6 harness) + widget tests at phone/desktop sizes.

**Tech Stack:** Flutter / Dart, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding in any user-facing string, label, comment, or identifier. IEC-standard pin names (`IN1`/`OUT`/`Q`/`ET`/`MN`/`IN`/`MX`/`G`/`IN0`) are allowed.
- Dark theme preserved. `flutter analyze` zero issues. Braces on flow-control; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`; `initialValue:` on `DropdownButtonFormField`.
- No RenderFlex overflow at 360/320/1400. **Responsive decisions inside embedded editors key on LOCAL available width (`LayoutBuilder`/local constraints), never window width (`MediaQuery.sizeOf`/`context.isExpanded`).**
- Engines stay pure Dart in `mobile/lib/models` (UI-free). Lossless persistence preserved — the WS6 serialization round-trip + scan-equivalence tests are the guard for the FBD model change.
- Existing 207 tests must keep passing.

**Sequencing:** Tasks 1–3 (UX fixes) are independent and land first (fast, user-visible). Task 4 (FBD pin engine) is the model+executor+migration foundation, gated by scan-equivalence. Task 5 (FBD editor) builds the wiring UI on it. Task 6 validates + final review.

---

### Task 1: LD editor phone fixes — local-width toolbar + pan/zoom canvas

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart`
- Test: `mobile/test/ld_editor_responsive_test.dart`

**Behavior spec:**
1. **Toolbar overflow fix:** the toolbar's compact-vs-wide decision (currently `if (!context.isExpanded)` at ~line 198) must use the **local** available width. Wrap `_buildToolbar()`'s content in a `LayoutBuilder` and choose the wrapping `Wrap` layout when `constraints.maxWidth` is below a threshold (~560), else the `Row`. Never overflow regardless of window width. (This fixes the reported `w≤257` overflow that happened because the window was ≥840 but the pane was ~257.)
2. **Ladder pan/zoom on compact:** when the *local* width is compact, wrap the rung list (the `Row` with rails + `ListView`) in an `InteractiveViewer` (pan enabled, modest `minScale`/`maxScale`, `boundaryMargin`) so every element is reachable by swiping; keep per-rung horizontal scroll as-is for wide rungs. Desktop (wide local width) layout unchanged. (If InteractiveViewer + inner scrollables conflict, prefer the InteractiveViewer for the whole canvas on compact and drop the inner per-rung scroll on compact only.)

- [ ] **Step 1: Write `mobile/test/ld_editor_responsive_test.dart`** — construct `LdEditorScreen` with a default LD program (read its real constructor; e.g. `proj_conveyor`'s ladder program). Pump inside a `SizedBox(width: 257, height: 600)` (a NARROW pane) at a DESKTOP window size (so `context.isExpanded` is true but the local pane is 257) and assert `tester.takeException()` is null (no toolbar overflow) — this reproduces the reported bug and proves the local-width fix. Also pump at phone size and assert an `InteractiveViewer` is present; at desktop full-width assert the toolbar `Row` path renders without overflow.
- [ ] **Step 2: Run → FAIL** (toolbar overflows at 257 under a wide window). **Step 3: Implement** the `LayoutBuilder` toolbar + compact `InteractiveViewer`.
- [ ] **Step 4: Tests → PASS; `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `fix(ld): local-width toolbar (no overflow in narrow pane) + pan/zoom ladder on compact`.

---

### Task 2: Project CRUD → ⋮ menu

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart`
- Test: `mobile/test/project_menu_test.dart`

**Behavior spec:** Replace the `Wrap` of 7 `_projectCrudButton`s (`workspace_shell.dart:1062-1074`) with a single `PopupMenuButton` (⋮) placed in a `Row` next to the SELECT PROJECT `DropdownButton` (dropdown `Expanded`, ⋮ trailing). Menu items: New, Duplicate, Rename, Delete, Reset to Defaults, Export, Import — each calling the existing `_createNewProject`/`_duplicate…`/etc. handlers. Keep tooltips as item labels. Remove `_projectCrudButton` if now unused.

- [ ] **Step 1: Write `mobile/test/project_menu_test.dart`** — boot `WorkspaceShell` (mock prefs via `setMockInitialValues({})`) at phone + desktop; assert the CRUD `Wrap`/its 7 inline buttons are gone and a `PopupMenuButton` exists in the project switcher; open it and assert all 7 action labels are present; `takeException()` null.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** the ⋮ menu.
- [ ] **Step 4: Tests → PASS; analyze clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(ui): collapse project CRUD buttons into a ⋮ menu beside the project dropdown`.

---

### Task 3: Reusable type-ahead tag field

**Files:**
- Create: `mobile/lib/widgets/tag_autocomplete_field.dart`
- Modify: `mobile/lib/screens/fbd_editor_screen.dart`, `ld_editor_screen.dart`, `hmi_dashboard_builder_screen.dart`, `simulated_io_screen.dart`
- Test: `mobile/test/tag_autocomplete_field_test.dart`

**Interfaces produced:** `class TagAutocompleteField extends StatelessWidget { TagAutocompleteField({required List<String> options, required String initialValue, required ValueChanged<String> onChanged, String? label, bool allowFreeText = true}); }` — a text field with an autocomplete overlay (Flutter `Autocomplete<String>`/`RawAutocomplete`) that filters `options` by the typed substring (case-insensitive), calls `onChanged` on selection AND on free-text edit (when `allowFreeText`), dark-themed, phone-safe (overlay width clamped, no overflow).

- [ ] **Step 1: Write `mobile/test/tag_autocomplete_field_test.dart`** — pump the field with options `['JamTimer','JamTimer.DN','Belt_Motor']`; type "Jam" → assert the two `JamTimer*` options appear and `Belt_Motor` doesn't; select one → `onChanged` fires with it; type a free-text value not in options → `onChanged` fires with the typed text (allowFreeText). No overflow at 320.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** `TagAutocompleteField`, then replace the 6 tag `DropdownButtonFormField`s: `fbd_editor` (configure dialog + inline block editor), `ld_editor` node dialog, `hmi_dashboard_builder` component dialog, `simulated_io` target-path + the two clause operand pickers. Source options from `currentProject.tags.map((t)=>t.name)` (and `leafAndNodePaths(...)` where a full path is wanted — match each site's current source). Keep each site's existing binding/callback.
- [ ] **Step 4: Tests → PASS; analyze clean; full suite passes; `flutter build web --release` succeeds.**
- [ ] **Step 5: Commit** `feat(ui): reusable type-ahead TagAutocompleteField; replace tag dropdowns across editors`.

---

### Task 4: FBD pin engine — registry, pin-addressed wires, executor, migration

**Files:**
- Create: `mobile/lib/models/fbd_pins.dart`
- Modify: `mobile/lib/models/project_model.dart` (`FbdBlock.inputCount`, `FbdWire` pin fields + serialization), `mobile/lib/models/fbd_exec.dart`, `mobile/lib/data/default_projects.dart` (migrate FBD wires)
- Test: `mobile/test/fbd_pins_test.dart`, `mobile/test/fbd_exec_test.dart` (extend), `mobile/test/serialization_roundtrip_test.dart` (already covers all projects — must stay green)

**Interfaces produced:**
- `List<String> fbdInputPins(String type, {int inputCount = 2})`, `List<String> fbdOutputPins(String type)` in `fbd_pins.dart` (the registry from the spec table; IEC names; TON/TOF → `Q`,`ET`; extensible AND/OR/ADD/MUL → `IN1..INn`).
- `FbdWire { String fromBlockId; String fromPin; String toBlockId; String toPin; }` (+ toJson/fromJson; legacy no-pin wire reads as first-output→first-input).
- `FbdBlock.inputCount` (int, default via registry).
- `executeFbdPrograms(p, dtMs, rt)` now evaluates blocks to `Map<String,dynamic>` output maps and executes `TON`/`TOF` with per-block state in `FbdRuntime`.

- [ ] **Step 1: Write `mobile/test/fbd_pins_test.dart`** — assert `fbdInputPins`/`fbdOutputPins` for each type: `TAG_OUTPUT` in `['IN']` out `[]`; `TON` in `['IN','PT']` out `['Q','ET']`; `AND` inputCount 3 → `['IN1','IN2','IN3']` out `['OUT']`; `SUB` `['IN1','IN2']`; `LIMIT` `['MN','IN','MX']`; `CONST`/`TAG_INPUT` out `['OUT']` in `[]`; unknown type → empty lists (never throws).

- [ ] **Step 2: Extend `mobile/test/fbd_exec_test.dart`** with pin-addressed cases and multi-output:
  - A `SUB` fed `IN1`←const 5, `IN2`←const 3 → `OUT` == 2 (pin order, not wire order); reversing which const wires to `IN1`/`IN2` flips the result (proves pins address inputs, not insertion order).
  - Fan-out: one `CONST` `OUT` wired to two different blocks' inputs both see it.
  - **Multi-output `TON`**: `IN`←true, `PT`←const 300ms; over scan ticks, `Q` goes true only after ET≥PT, and `ET` (wired to a numeric `TAG_OUTPUT`) increases each scan — asserting BOTH outputs independently.
  - Cycle terminates; unknown/empty program skipped; force-aware `TAG_OUTPUT` unchanged.

- [ ] **Step 3: Implement** `fbd_pins.dart`; extend `FbdBlock`/`FbdWire` (+ serialization, legacy fallback); rewrite `fbd_exec.dart` to: build per-block ordered input values by resolving each input pin's wire to the source block's named output; evaluate to an output-pin map; keep topological worklist + cycle termination + never-throws; add `TON`/`TOF` stateful eval (state in `FbdRuntime` keyed by block id, `ET += dtMs` while `IN`, `Q = ET>=PT` for TON / inverse dwell for TOF), producing `{'Q':…, 'ET':…}`. Keep `TAG_OUTPUT` force-aware writing its single `IN`.

- [ ] **Step 4: Migrate `default_projects.dart` FBD diagrams** — convert each block-to-block `FbdWire` to pin-addressed (`fromPin` = source's single output `OUT`; `toPin` = the correct target input pin per the diagram's intent and the registry's pin order, e.g. HVAC `SUB` gets `IN1`←Setpoint, `IN2`←Deadband; tank `LT` gets `IN1`←Level_PV, `IN2`←SP-5). Set `inputCount` where an operator takes >2 inputs. The migration MUST preserve execution — proven by:

- [ ] **Step 5: Run tests → the existing `serialization_roundtrip_test.dart` (20-scan scan-equivalence for every default project) MUST stay green** (proves the pin migration didn't change execution), plus the new `fbd_pins_test` + extended `fbd_exec_test` pass. `flutter analyze` → No issues found! Full suite passes.

- [ ] **Step 6: Commit** `feat(fbd): pin-based engine — named in/out pins, pin-addressed wires, multi-output TON/TOF; migrate diagrams (scan-equivalent)`.

---

### Task 5: FBD editor — pin dots, draw wires, extensible inputs

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart`
- Test: `mobile/test/fbd_editor_test.dart`

**Behavior spec:**
- Render each block's input pins as small labeled dots down the LEFT edge and output pins down the RIGHT edge (names/positions from `fbd_pins.dart`); a two-output block (`TON`) shows two right dots (`Q`, `ET`).
- **Wiring:** tap an output dot → the pin is "armed"; tap an input dot on another block → create `FbdWire(from,fromPin,to,toPin)` (on desktop, a drag from output to input does the same). Wires render as lines/curves between the two dot positions (a `CustomPainter` over the block `Stack`). Tapping near a wire selects it → a delete affordance removes it. Connecting to an already-wired input replaces the existing wire. Prevent obviously-invalid connections (output→output, input→input, a block to itself) with a gentle no-op + optional toast.
- **Extensible inputs:** for AND/OR/ADD/MUL show +/- to change `inputCount` (clamp 2–8); update pins and drop wires to removed pins.
- **Config:** block tag binding uses `TagAutocompleteField` (Task 3); `CONST` value via text; delete-block removes the block and its wires.
- Canvas stays in the WS5 `InteractiveViewer`; desktop free-drag of blocks preserved; all editing dialogs use `showAdaptiveWidthDialog`. No overflow at 360/320.

- [ ] **Step 1: Write `mobile/test/fbd_editor_test.dart`** — construct `FbdEditorScreen` with a program containing a couple of blocks (e.g. a `CONST` and a `TAG_OUTPUT`, plus a `TON`); pump at phone + desktop. Assert: pins render (find the input/output dot widgets by key/type; the `TON` shows two output dots); simulate arming an output dot then tapping an input dot → a new `FbdWire` is added to the program (assert `program.fbdWires.length` increased with correct `fromPin`/`toPin`); tapping the wire + delete removes it; the extensible +/- changes an `AND` block's `inputCount` and pin count; `takeException()` null at 320/360.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** the pin rendering, wire-draw interaction, wire painter, delete, extensible controls, and config (reusing Task 3's field). Keep the expanded desktop drag behavior.
- [ ] **Step 4: Tests → PASS; analyze clean; full suite passes; `flutter build web --release` succeeds.**
- [ ] **Step 5: Commit** `feat(fbd-editor): pin dots + draw/delete pin-to-pin wires + extensible inputs + tag autocomplete`.

---

### Task 6: Whole-workstream validation + final review

- [ ] **Step 1:** Full verification: `flutter test` (all pass, incl. scan-equivalence unchanged, new pin/exec/editor tests) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" lib test` → no matches.
- [ ] **Step 2:** Confirm end-to-end: the reported LD overflow is gone (narrow-pane test), the ladder pans on a phone, the project ⋮ menu works, tag fields type-ahead, and an FBD `TON` block can be wired (`Q`/`ET`) and executes. Add a smoke test only if a gap remains.
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** A1 local-width toolbar (Task 1) ✓; A2 ladder pan/zoom (Task 1) ✓; A3 ⋮ menu (Task 2) ✓; A4 type-ahead field ×6 (Task 3) ✓; B1 pin registry + B2 model/wire + B3 executor incl. multi-output TON/TOF + B5 migration (Task 4) ✓; B4 editor pins/wiring/extensible (Task 5) ✓; validation (Task 6) ✓.
- **Acceptance guard:** the WS6 20-scan scan-equivalence per default project MUST stay green through the FBD model change (Task 4) — a migration that alters execution fails it immediately; a new TON diagram proves multi-output.
- **Type consistency:** `fbdInputPins`/`fbdOutputPins`, `FbdWire{fromBlockId,fromPin,toBlockId,toPin}`, `FbdBlock.inputCount`, `TagAutocompleteField` used identically across tasks.
- **Local-width rule** (not window) is the fix for A1 and a general correction applied wherever an embedded editor made a window-based responsive decision.
- **Deferred:** EN/ENO, CTU/CTD execution, wire auto-routing, LD/SFC pin editors.
