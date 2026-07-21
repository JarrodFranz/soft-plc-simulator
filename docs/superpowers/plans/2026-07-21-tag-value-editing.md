# Tag Value Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user set a tag's default value on creation, open an existing tag's config to change its data type/default, and edit a tag's live runtime value from the Tag Inspector and the Tags & Structs view.

**Architecture:** A distinct persisted `defaultValue` field on `PlcTag` (separate from the live `value`), two pure coercion helpers, and one shared `ScalarValueField` widget reused across the Add dialog, a new Edit-config dialog, and inline live-value editing. Live edits are "pokes" that follow the existing force rule (write `forcedValue` when forced, else `value`).

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`.

**Spec:** `docs/superpowers/specs/2026-07-21-tag-value-editing-design.md`.

## Global Constraints

- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/models/`; UI in `mobile/lib/screens/` + `mobile/lib/widgets/`.
- **Additive/backward-compatible serialization**: a project JSON with no `default_value` loads with `defaultValue` derived from the existing `initial_value`; the live `value` still loads from `initial_value` unchanged. The lossless round-trip / default-projects suites stay green.
- **Live edit = poke**: write the value; the scan may overwrite it next cycle. Force stays the separate "hold" lock; editing NEVER auto-forces. Write `forcedValue` when the (root) tag `isForced`, else `value`.
- **Name/path immutable** in the edit dialog (renaming would break logic/protocol-map references by path/name).
- Reserved `System` tag (`kSystemTagName`): no edit affordance, no live-edit, no rename — the UI-level name guard is the actual enforcement (`PlcTag.access` is not enforced at the model layer).
- Scalar-only value editing: composite/array tags keep their structural (struct-field) defaults; no scalar default/live editor for them.
- Deterministic: no clock/RNG in model or coercion logic.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. No push.

## Key facts (verified on-branch — do not re-derive)

- `PlcTag` (`mobile/lib/models/project_model.dart:11-79`): fields incl. `dynamic value`, `String dataType`, `int arrayLength`, `bool isForced`, `dynamic forcedValue`, `String access`, `String engineeringUnits`, `String description`, `String name`, `String path`. Constructor ends `this.forcedValue,` (`:40`) `this.folder = ''` (`:41`). `fromJson`: `value: json['initial_value'] ?? json['value'] ?? false` (`:50`), `forcedValue: json['forced_value']` (`:58`), `folder: json['folder'] ?? ''` (`:59`). `toJson`: `'initial_value': value` (`:68`), `'forced_value': forcedValue` (`:76`), `'folder': folder` (`:77`).
- `defaultValueFor(PlcProject p, String base, int arrayLength) → dynamic` (`tag_resolver.dart:133`): BOOL→`false`, FLOAT64→`0.0`, STRING→`''`, composites→`Map`, else (integer types)→`0` (`:159-168`).
- `writePath(PlcProject p, String path, dynamic value)` (`tag_resolver.dart:318`) resolves nested paths; `readPath(project, path)` reads them. `lookupComposite(p, base)` returns a composite def or null (used to detect scalar vs composite).
- `kSystemTagName` from `models/system_tags.dart`.
- **Memory Manager** (`screens/memory_manager_screen.dart`): `_showAddTagDialog()` (`:394`) builds the tag with `value: defaultValueFor(widget.currentProject, dataType, arrLen)` (`:456`); `availableTypes` list (`:405-406`). Card row delete affordance at `:697-701` (`touchable(Icon(Icons.delete...), onTap: () => _deleteTag(row.name))`), table variant is `_buildHierarchicalRows` (`:921`). `_cardValueField(_TagRowData row)` (`:775`): BOOL leaf → `touchable(Text(...), onTap: () => _toggleBoolValue(row))` (`:790-795`); non-bool → read-only text (`:802-810`). `_toggleBoolValue` (`:915`): `writePath(project, row.path, !(row.rawValue == true)); setState; widget.onProjectUpdated()`. `_liveValueFor(row)` (`:763`) reads the current value. `widget.onProjectUpdated()` is the autosave+rebuild callback. `touchable(...)` and `_cardFieldLive(label, child)` are existing local helpers. `_TagRowData` has `path`, `rawValue`, `depth`, `hasChildren`, `isBoolLeaf`, `valueTextFor(v)`, `name`, `isDeletable`.
- **Tag Inspector** (`widgets/tag_inspector_dock.dart`): value pill at `:323-366` inside a `ListenableBuilder(listenable: LiveTickScope.of(context))`; `effectiveVal = tag.isForced ? tag.forcedValue : tag.value` (`:327`); BOOL tap branch `if (isBool && tag.name != kSystemTagName)` writes `tag.forcedValue`/`tag.value` then `widget.onTagStateChanged()` (`:329-339`). `isBool` is in scope; the Force toggle is at `:378-403`. Composite/array children render read-only (`:404+`).
- **Baseline**: `flutter test` all green (2371 as of `d0220c8`); `flutter analyze` clean. Re-confirm the count at Task 1.

---

### Task 1: Model — `defaultValue` field + `effectiveDefault`

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`PlcTag`)
- Test: `mobile/test/tag_value_model_test.dart` (create)

**Interfaces:**
- Produces: `PlcTag.defaultValue` (`dynamic`, constructor arg `this.defaultValue`), serialized key `default_value`; `PlcTag.effectiveDefault(PlcProject p) → dynamic`.

- [ ] **Step 1: Write the failing tests** (`mobile/test/tag_value_model_test.dart`):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

PlcProject _emptyProject() => PlcProject(
      id: 'p', name: 'P', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: [], tags: [],
    );

void main() {
  group('PlcTag.defaultValue', () {
    test('round-trips through toJson/fromJson', () {
      final tag = PlcTag(name: 'A', path: 'A', dataType: 'INT16', value: 5,
          defaultValue: 3, ioType: 'Internal');
      final round = PlcTag.fromJson(tag.toJson());
      expect(round.defaultValue, 3);
      expect(round.value, 5);
      expect(tag.toJson()['default_value'], 3);
    });

    test('a JSON without default_value adopts initial_value as the default', () {
      final json = {
        'name': 'B', 'path': 'B', 'data_type': 'FLOAT64',
        'initial_value': 12.5, 'io_type': 'Internal',
      };
      final tag = PlcTag.fromJson(json);
      expect(tag.value, 12.5);
      expect(tag.defaultValue, 12.5);
    });

    test('effectiveDefault returns defaultValue when set', () {
      final tag = PlcTag(name: 'C', path: 'C', dataType: 'INT16', value: 9,
          defaultValue: 7, ioType: 'Internal');
      expect(tag.effectiveDefault(_emptyProject()), 7);
    });

    test('effectiveDefault falls back to the type default when null', () {
      final tag = PlcTag(name: 'D', path: 'D', dataType: 'FLOAT64', value: 4.0,
          ioType: 'Internal');
      expect(tag.defaultValue, isNull);
      expect(tag.effectiveDefault(_emptyProject()), 0.0);
    });
  });
}
```

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/tag_value_model_test.dart` (fails: no `defaultValue`/`effectiveDefault`).
- [ ] **Step 3: Implement** in `project_model.dart`:
  - Add field after `dynamic forcedValue;` (`:24`): `dynamic defaultValue;`
  - Constructor: add `this.defaultValue,` after `this.forcedValue,` (`:40`).
  - `fromJson`: add `defaultValue: json['default_value'] ?? json['initial_value'] ?? json['value'],` after the `forcedValue:` line (`:58`).
  - `toJson`: add `'default_value': defaultValue,` after `'forced_value': forcedValue,` (`:76`).
  - Add the method (after `toJson`, still inside `PlcTag`), importing `tag_resolver.dart` at the top of the file if not already imported:

```dart
  /// The declared default when set, else the built-in default for this tag's
  /// type/shape. Callers use this instead of special-casing a null
  /// [defaultValue] (only the project is needed, to resolve a composite's
  /// structural default).
  dynamic effectiveDefault(PlcProject p) =>
      defaultValue ?? defaultValueFor(p, dataType, arrayLength);
```

  (If importing `tag_resolver.dart` into `project_model.dart` creates a cycle — `tag_resolver.dart` imports `project_model.dart` — Dart allows this cyclic import for top-level functions; confirm `flutter analyze` is clean. If analyze flags it, instead place `effectiveDefault` as a top-level function `dynamic effectiveDefaultFor(PlcProject p, PlcTag t) => t.defaultValue ?? defaultValueFor(p, t.dataType, t.arrayLength);` in `tag_resolver.dart` and update the Task-1 test + later call sites to use it. Pick whichever keeps analyze clean and note the choice in the report.)
- [ ] **Step 4: Run — expect PASS**, then the full suite: `cd mobile && flutter test` — report the count (baseline ~2371). Any pre-existing serialization/round-trip test must stay green.
- [ ] **Step 5: analyze + commit**
```bash
cd mobile && flutter analyze
git add mobile/lib/models/project_model.dart mobile/test/tag_value_model_test.dart
git commit -m "feat(tags): PlcTag.defaultValue field + effectiveDefault (backward-compatible)"
```

---

### Task 2: Pure coercion helpers + `ScalarValueField` widget

**Files:**
- Modify: `mobile/lib/models/tag_resolver.dart` (add `coerceScalarValue`, `coerceValueToType`)
- Create: `mobile/lib/widgets/scalar_value_field.dart`
- Test: `mobile/test/tag_value_coercion_test.dart`, `mobile/test/scalar_value_field_test.dart` (create both)

**Interfaces:**
- Consumes: `defaultValueFor`, `lookupComposite` (both in `tag_resolver.dart`).
- Produces:
  - `dynamic coerceScalarValue(String dataType, String input)`
  - `dynamic coerceValueToType(PlcProject p, dynamic current, String newDataType, int arrayLength)`
  - `class ScalarValueField extends StatelessWidget { const ScalarValueField({Key? key, required String dataType, required dynamic value, required ValueChanged<dynamic> onChanged}); }` — renders a BOOL switch / numeric field / string field and calls `onChanged` with a COERCED value.

- [ ] **Step 1: Write the failing coercion tests** (`mobile/test/tag_value_coercion_test.dart`):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _p() => PlcProject(id: 'p', name: 'P', controllerName: 'PLC',
    programs: [], tasks: [], hmis: [], structDefs: [], tags: []);

void main() {
  group('coerceScalarValue', () {
    test('BOOL accepts true/false/1/0/on/off case-insensitively', () {
      for (final s in ['true', 'TRUE', '1', 'on', 'ON']) {
        expect(coerceScalarValue('BOOL', s), isTrue, reason: s);
      }
      for (final s in ['false', '0', 'off', 'nonsense', '']) {
        expect(coerceScalarValue('BOOL', s), isFalse, reason: s);
      }
    });
    test('integer types parse to int, bad input -> 0', () {
      expect(coerceScalarValue('INT16', '42'), 42);
      expect(coerceScalarValue('INT32', '-7'), -7);
      expect(coerceScalarValue('INT16', 'abc'), 0);
    });
    test('FLOAT64 parses to double, bad input -> 0.0', () {
      expect(coerceScalarValue('FLOAT64', '12.5'), 12.5);
      expect(coerceScalarValue('FLOAT64', 'x'), 0.0);
    });
    test('STRING is verbatim', () {
      expect(coerceScalarValue('STRING', 'hi there'), 'hi there');
    });
  });

  group('coerceValueToType', () {
    test('number -> BOOL is nonzero-true', () {
      expect(coerceValueToType(_p(), 3, 'BOOL', 0), isTrue);
      expect(coerceValueToType(_p(), 0, 'BOOL', 0), isFalse);
    });
    test('BOOL -> integer maps to 1/0', () {
      expect(coerceValueToType(_p(), true, 'INT16', 0), 1);
      expect(coerceValueToType(_p(), false, 'INT16', 0), 0);
    });
    test('string number -> FLOAT64 parses; junk -> type default', () {
      expect(coerceValueToType(_p(), '3.5', 'FLOAT64', 0), 3.5);
      expect(coerceValueToType(_p(), 'junk', 'INT16', 0), 0);
    });
    test('changing to a composite/array yields the structural default', () {
      final v = coerceValueToType(_p(), 5, 'FLOAT64', 2);
      expect(v, isA<List<dynamic>>());
      expect((v as List).length, 2);
    });
  });
}
```

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/tag_value_coercion_test.dart`
- [ ] **Step 3: Implement** the two functions in `tag_resolver.dart` (place after `defaultValueFor`, `:135`):

```dart
/// Parses a user-typed [input] string into the runtime type a scalar tag of
/// [dataType] expects. Never throws: unparseable numeric input falls back to
/// the type's zero default. Composites/unknown types return their structural
/// default (callers should not offer scalar editing for those).
dynamic coerceScalarValue(String dataType, String input) {
  switch (dataType) {
    case 'BOOL':
      final s = input.trim().toLowerCase();
      return s == 'true' || s == '1' || s == 'on';
    case 'FLOAT64':
      return double.tryParse(input.trim()) ?? 0.0;
    case 'STRING':
      return input;
    case 'INT16':
    case 'INT32':
    case 'INT64':
      return int.tryParse(input.trim()) ?? 0;
    default:
      return 0;
  }
}

/// Re-coerces an existing [current] value to [newDataType] when a tag's type
/// changes. Best-effort BOOL<->number<->string; a composite/array target (or
/// an unparseable value) yields the new type's structural default via
/// [defaultValueFor]. Never throws.
dynamic coerceValueToType(
    PlcProject p, dynamic current, String newDataType, int arrayLength) {
  if (arrayLength > 0 || lookupComposite(p, newDataType) != null) {
    return defaultValueFor(p, newDataType, arrayLength);
  }
  switch (newDataType) {
    case 'BOOL':
      if (current is bool) {
        return current;
      }
      if (current is num) {
        return current != 0;
      }
      if (current is String) {
        return coerceScalarValue('BOOL', current);
      }
      return false;
    case 'FLOAT64':
      if (current is num) {
        return current.toDouble();
      }
      if (current is bool) {
        return current ? 1.0 : 0.0;
      }
      if (current is String) {
        return double.tryParse(current.trim()) ?? 0.0;
      }
      return 0.0;
    case 'STRING':
      return current == null ? '' : '$current';
    case 'INT16':
    case 'INT32':
    case 'INT64':
      if (current is int) {
        return current;
      }
      if (current is num) {
        return current.round();
      }
      if (current is bool) {
        return current ? 1 : 0;
      }
      if (current is String) {
        return int.tryParse(current.trim()) ?? 0;
      }
      return 0;
    default:
      return defaultValueFor(p, newDataType, arrayLength);
  }
}
```

- [ ] **Step 4: Run coercion tests — expect PASS.**
- [ ] **Step 5: Write the failing widget test** (`mobile/test/scalar_value_field_test.dart`):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/widgets/scalar_value_field.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('numeric field emits a coerced int', (tester) async {
    dynamic emitted;
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'INT16', value: 0, onChanged: (v) => emitted = v)));
    await tester.enterText(find.byType(TextField), '42');
    await tester.pump();
    expect(emitted, 42);
  });

  testWidgets('FLOAT64 field emits a coerced double', (tester) async {
    dynamic emitted;
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'FLOAT64', value: 0.0, onChanged: (v) => emitted = v)));
    await tester.enterText(find.byType(TextField), '12.5');
    await tester.pump();
    expect(emitted, 12.5);
  });

  testWidgets('BOOL renders a Switch and emits bool', (tester) async {
    dynamic emitted;
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'BOOL', value: false, onChanged: (v) => emitted = v)));
    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(emitted, true);
  });

  testWidgets('STRING field emits the verbatim string', (tester) async {
    dynamic emitted;
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'STRING', value: '', onChanged: (v) => emitted = v)));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(emitted, 'hello');
  });

  testWidgets('a composite type shows a disabled note, no input', (tester) async {
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'SomeStruct', value: const {}, onChanged: (_) {})));
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('struct'), findsOneWidget);
  });
}
```

- [ ] **Step 6: Run — expect FAIL.** `cd mobile && flutter test test/scalar_value_field_test.dart`
- [ ] **Step 7: Implement** `mobile/lib/widgets/scalar_value_field.dart`:

```dart
import 'package:flutter/material.dart';
import '../models/tag_resolver.dart';

/// One reusable value input for a SCALAR tag, rendering the right control per
/// [dataType] and emitting a COERCED value (via [coerceScalarValue] for the
/// text types). BOOL -> a Switch; INT/FLOAT -> a numeric TextField; STRING ->
/// a text TextField. A composite/array/unknown type shows a disabled note
/// (its default is edited structurally in the struct editor, not here).
class ScalarValueField extends StatelessWidget {
  const ScalarValueField({
    super.key,
    required this.dataType,
    required this.value,
    required this.onChanged,
  });

  final String dataType;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  static const _scalarTypes = {'BOOL', 'INT16', 'INT32', 'INT64', 'FLOAT64', 'STRING'};

  @override
  Widget build(BuildContext context) {
    if (dataType == 'BOOL') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Value', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(width: 8),
          Switch(
            key: const Key('scalar_value_bool_switch'),
            value: value == true,
            onChanged: (v) => onChanged(v),
          ),
        ],
      );
    }
    if (!_scalarTypes.contains(dataType)) {
      return const Text(
        'Structured default — edit fields in the struct editor.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      );
    }
    final numeric = dataType != 'STRING';
    return TextField(
      key: const Key('scalar_value_text_field'),
      controller: TextEditingController(text: value == null ? '' : '$value'),
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      style: const TextStyle(fontSize: 12, color: Colors.white),
      decoration: const InputDecoration(
        isDense: true,
        labelText: 'Default value',
        border: OutlineInputBorder(),
      ),
      onChanged: (raw) => onChanged(coerceScalarValue(dataType, raw)),
    );
  }
}
```

  Note on the `TextEditingController` created in `build`: it is intentionally recreated per build (the widget is `StatelessWidget` and value flows one-way from the parent's state). This matches the app's existing dialog-field pattern (see `_showAddTagDialog`'s controllers). Do not add a `dispose` — the field is short-lived inside dialogs/popovers.
- [ ] **Step 8: Run widget test — expect PASS.**
- [ ] **Step 9: analyze + commit**
```bash
cd mobile && flutter analyze
git add mobile/lib/models/tag_resolver.dart mobile/lib/widgets/scalar_value_field.dart mobile/test/tag_value_coercion_test.dart mobile/test/scalar_value_field_test.dart
git commit -m "feat(tags): scalar value coercion helpers + reusable ScalarValueField"
```

---

### Task 3: Add default field + Edit Tag Config dialog (Memory Manager)

**Files:**
- Modify: `mobile/lib/screens/memory_manager_screen.dart`
- Test: `mobile/test/memory_manager_tag_config_test.dart` (create)

**Interfaces:**
- Consumes: `PlcTag.defaultValue`/`effectiveDefault` (Task 1), `coerceValueToType`, `ScalarValueField` (Task 2).
- Produces: `_showEditTagDialog(PlcTag tag)`; a per-row edit affordance keyed `Key('edit_tag_${tag.name}')`.

**Context:** The Add dialog (`:394`) gets a Default value row (scalar + arrayLength 0 only) that seeds BOTH `defaultValue` and the initial `value`. A new Edit dialog changes data type (re-coercing default + live value), default value, access, description, engineering units — name/path shown read-only; plus a "Reset live value → default" button that sets `value = tag.effectiveDefault(project)` and clears force. Row edit affordance sits beside the existing delete (`:697-701` card, and the table variant). `System` shows no edit affordance.

- [ ] **Step 1: Write the failing tests** (`mobile/test/memory_manager_tag_config_test.dart`). Pump `MemoryManagerScreen` with a fixture project (mirror the setup used by existing `test/memory_manager_*_test.dart` — read one for the exact `_app`/pump helper and required constructor args). Tests:
  - Adding a tag with type INT16 and default `5` typed into the default field creates a tag with `defaultValue == 5` and `value == 5`.
  - Opening the edit dialog for an existing FLOAT64 tag, changing its default to `80` and saving, sets `tag.defaultValue == 80.0` (name/path unchanged).
  - In the edit dialog, changing the data type from INT16 to BOOL re-coerces: a live `value` of `1` becomes `true`.
  - "Reset live value → default" sets `value` back to `effectiveDefault` and clears `isForced`.
  - The reserved `System` tag row shows no `Key('edit_tag_System')` affordance.
  - No overflow at 320/360/1400 with the edit dialog open (`expect(tester.takeException(), isNull)`).

  (Write these as concrete `testWidgets` using `find.byKey`/`enterText`/`tap`, keys: default field is `ScalarValueField`'s `Key('scalar_value_text_field')`/`Key('scalar_value_bool_switch')`; give the Add dialog's default row a wrapping `Key('add_tag_default_field')`, the edit dialog a `Key('edit_tag_dialog')`, its type dropdown `Key('edit_tag_type_dropdown')`, its reset button `Key('edit_tag_reset_button')`, its save `Key('edit_tag_save_button')`.)
- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/memory_manager_tag_config_test.dart`
- [ ] **Step 3: Implement the Add default field.** In `_showAddTagDialog` (`:394`), add dialog state `dynamic defaultVal = defaultValueFor(widget.currentProject, dataType, 0);`. In the type dropdown's `onChanged` (`:424`), after setting `dataType`, also `defaultVal = defaultValueFor(widget.currentProject, dataType, int.tryParse(arrayLenCtrl.text) ?? 0);`. After the I/O dropdown, add (only for scalar + arrayLength 0):

```dart
Builder(builder: (_) {
  final arrLen = int.tryParse(arrayLenCtrl.text) ?? 0;
  final isScalar = arrLen == 0 &&
      lookupComposite(widget.currentProject, dataType) == null;
  if (!isScalar) {
    return const SizedBox.shrink();
  }
  return Padding(
    key: const Key('add_tag_default_field'),
    padding: const EdgeInsets.only(top: 12),
    child: ScalarValueField(
      dataType: dataType,
      value: defaultVal,
      onChanged: (v) => defaultVal = v,
    ),
  );
}),
```

  In the "Add Tag" `onPressed` (`:443`), replace the `value:` line (`:456`) so that for a scalar the entered default is used for both:

```dart
final isScalar = arrLen == 0 &&
    lookupComposite(widget.currentProject, dataType) == null;
final initial = isScalar
    ? defaultVal
    : defaultValueFor(widget.currentProject, dataType, arrLen);
final tag = PlcTag(
  name: nameCtrl.text,
  path: pathCtrl.text,
  dataType: dataType,
  arrayLength: arrLen,
  value: initial,
  defaultValue: isScalar ? defaultVal : null,
  ioType: ioType,
);
```
  Import `ScalarValueField` and (if not present) `lookupComposite`/`tag_resolver.dart` at the top of the file.
- [ ] **Step 4: Implement `_showEditTagDialog`.** Add a method that mirrors the Add dialog's `StatefulBuilder`/`AlertDialog` shape:

```dart
void _showEditTagDialog(PlcTag tag) {
  showDialog(
    context: context,
    builder: (ctx) {
      String dataType = tag.dataType;
      dynamic defaultVal = tag.effectiveDefault(widget.currentProject);
      String access = tag.access;
      final descCtrl = TextEditingController(text: tag.description);
      final unitsCtrl = TextEditingController(text: tag.engineeringUnits);
      final availableTypes = ['BOOL', 'INT16', 'INT32', 'INT64', 'FLOAT64', 'STRING',
          ...builtinCompositeNames(), ...widget.currentProject.structDefs.map((s) => s.name)];

      return StatefulBuilder(
        key: const Key('edit_tag_dialog'),
        builder: (context, setDlgState) => AlertDialog(
          title: Text('Edit Tag — ${tag.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Name: ${tag.name}', style: const TextStyle(color: Colors.white70)),
                Text('Path: ${tag.path}', style: const TextStyle(color: Colors.white70)),
                const Text('(rename not supported yet)',
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('edit_tag_type_dropdown'),
                  initialValue: dataType,
                  decoration: const InputDecoration(labelText: 'Data Type'),
                  items: availableTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (val) => setDlgState(() {
                    dataType = val!;
                    defaultVal = coerceValueToType(
                        widget.currentProject, defaultVal, dataType, tag.arrayLength);
                  }),
                ),
                const SizedBox(height: 12),
                if (tag.arrayLength == 0 &&
                    lookupComposite(widget.currentProject, dataType) == null)
                  ScalarValueField(
                    dataType: dataType,
                    value: defaultVal,
                    onChanged: (v) => defaultVal = v,
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: access,
                  decoration: const InputDecoration(labelText: 'Access'),
                  items: const ['ReadWrite', 'ReadOnly']
                      .map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (val) => setDlgState(() => access = val!),
                ),
                TextField(controller: descCtrl, decoration: const InputDecoration(labelText: 'Description')),
                TextField(controller: unitsCtrl, decoration: const InputDecoration(labelText: 'Engineering Units')),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('edit_tag_reset_button'),
                  onPressed: () {
                    setState(() {
                      tag.value = tag.effectiveDefault(widget.currentProject);
                      tag.isForced = false;
                    });
                    widget.onProjectUpdated();
                  },
                  child: const Text('Reset live value → default'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              key: const Key('edit_tag_save_button'),
              onPressed: () {
                setState(() {
                  final typeChanged = tag.dataType != dataType;
                  tag.dataType = dataType;
                  tag.access = access;
                  tag.description = descCtrl.text;
                  tag.engineeringUnits = unitsCtrl.text;
                  final isScalar = tag.arrayLength == 0 &&
                      lookupComposite(widget.currentProject, dataType) == null;
                  tag.defaultValue = isScalar ? defaultVal : null;
                  if (typeChanged) {
                    tag.value = coerceValueToType(
                        widget.currentProject, tag.value, dataType, tag.arrayLength);
                    if (tag.forcedValue != null) {
                      tag.forcedValue = coerceValueToType(
                          widget.currentProject, tag.forcedValue, dataType, tag.arrayLength);
                    }
                  }
                });
                widget.onProjectUpdated();
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
    },
  );
}
```
- [ ] **Step 5: Wire the row edit affordance.** In the card row (`:697-701`), before the delete `touchable`, add (skip for `System`):

```dart
if (row.isDeletable && row.depth == 0 && row.name != kSystemTagName)
  touchable(
    Icon(Icons.edit, color: Colors.cyanAccent, size: 18, key: Key('edit_tag_${row.name}')),
    onTap: () {
      final tag = widget.currentProject.tags.firstWhere((t) => t.name == row.name);
      _showEditTagDialog(tag);
    },
  ),
```
  Add the equivalent `IconButton` in the DataTable variant (`_buildHierarchicalRows`, `:921`) beside its delete control, same key/skip rule. (Read the existing delete control in that method and mirror its cell placement.)
- [ ] **Step 6: Run — expect PASS**, then full suite (`cd mobile && flutter test`) — report the count.
- [ ] **Step 7: analyze + commit**
```bash
cd mobile && flutter analyze
git add mobile/lib/screens/memory_manager_screen.dart mobile/test/memory_manager_tag_config_test.dart
git commit -m "feat(tags): default value on add + Edit Tag Config dialog (type/default/reset)"
```

---

### Task 4: Live scalar value editing (Inspector + Tags & Structs) + validation

**Files:**
- Modify: `mobile/lib/widgets/tag_inspector_dock.dart`, `mobile/lib/screens/memory_manager_screen.dart`
- Test: `mobile/test/tag_inspector_live_edit_test.dart` (create), additions to `mobile/test/memory_manager_tag_config_test.dart`

**Interfaces:**
- Consumes: `coerceScalarValue`, `ScalarValueField`, `writePath`, `kSystemTagName`.
- Produces: a shared inline-editor helper `Future<void> _editScalarLiveValue(...)` in each screen (a small popover dialog with one `ScalarValueField` + OK/Cancel).

**Context:** Live edit follows the existing BOOL rule. In the inspector the write target is `tag.forcedValue` (if `tag.isForced`) else `tag.value` then `onTagStateChanged()`; in Memory Manager the target is `writePath(project, row.path, coerced)` (matching `_toggleBoolValue`, which the force state is already reflected through — root force is not surfaced there per `_liveValueFor`'s doc, so a poke writes the live `value` via `writePath`). Numeric/STRING scalars get an edit affordance; BOOL keeps its toggle; `System` and composites are excluded.

- [ ] **Step 1: Write the failing inspector test** (`mobile/test/tag_inspector_live_edit_test.dart`). Pump `TagInspectorDock` with a fixture project (mirror an existing `test/tag_inspector_*_test.dart` for the pump/`LiveTickScope` setup). Tests:
  - Tapping a numeric tag's value pill opens an editor; entering `80` and confirming sets the tag's `value` to `80` (unforced → writes `value`).
  - When the tag `isForced`, the same flow writes `forcedValue` (not `value`), leaving `value` unchanged.
  - The reserved `System` tag's pill does not open an editor.
- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/tag_inspector_live_edit_test.dart`
- [ ] **Step 3: Implement in the inspector** (`tag_inspector_dock.dart`). Add a helper:

```dart
Future<void> _editScalarLiveValue(PlcTag tag) async {
  if (tag.name == kSystemTagName) {
    return;
  }
  dynamic pending = tag.isForced ? tag.forcedValue : tag.value;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Set ${tag.name}'),
      content: ScalarValueField(
        dataType: tag.dataType,
        value: pending,
        onChanged: (v) => pending = v,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          key: const Key('scalar_live_edit_ok'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  if (ok == true) {
    setState(() {
      if (tag.isForced) {
        tag.forcedValue = pending;
      } else {
        tag.value = pending;
      }
    });
    widget.onTagStateChanged();
  }
}
```
  In the value pill's `onTap` (`:329`), extend the BOOL branch: for a scalar non-BOOL, non-composite, non-System tag, call `_editScalarLiveValue(tag)`:

```dart
onTap: () {
  if (tag.name == kSystemTagName) {
    return;
  }
  if (isBool) {
    setState(() {
      if (tag.isForced) {
        tag.forcedValue = !(tag.forcedValue == true);
      } else {
        tag.value = !(tag.value == true);
      }
    });
    widget.onTagStateChanged();
  } else if (tag.value is! Map && tag.value is! List) {
    _editScalarLiveValue(tag);
  }
},
```
- [ ] **Step 4: Run inspector test — expect PASS.**
- [ ] **Step 5: Implement in Memory Manager** (`memory_manager_screen.dart`). Add an analogous helper writing through `writePath`:

```dart
Future<void> _editScalarLiveValueRow(_TagRowData row) async {
  final tag = widget.currentProject.tags
      .where((t) => t.name == row.path).cast<PlcTag?>().firstWhere((_) => true, orElse: () => null);
  final dataType = tag?.dataType ?? _leafTypeFor(row); // for nested leaves, resolve via the row
  if (row.path == kSystemTagName) {
    return;
  }
  dynamic pending = _liveValueFor(row);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Set ${row.name}'),
      content: ScalarValueField(dataType: dataType, value: pending, onChanged: (v) => pending = v),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          key: const Key('scalar_live_edit_ok'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('OK')),
      ],
    ),
  );
  if (ok == true) {
    writePath(widget.currentProject, row.path, pending);
    setState(() {});
    widget.onProjectUpdated();
  }
}
```
  Determine the leaf data type: if `_TagRowData` already carries a data type (check its fields — it exposes `displayType`; derive the base type by stripping any `[n]` suffix, or add a `dataType` field to `_TagRowData` populated in `_buildRowData` from the resolved tag/leaf). Use that for `ScalarValueField`. In `_cardValueField` (`:775`), change the non-BOOL scalar leaf branch (`:802-810`) so the value text is `touchable(..., onTap: () => _editScalarLiveValueRow(row))` when the row is a scalar leaf (`!row.hasChildren` and not a composite/array and `row.path != kSystemTagName`); leave composite/array rows read-only. Apply the same to the DataTable value cell.
- [ ] **Step 6: Add the Memory Manager live-edit tests** to `memory_manager_tag_config_test.dart`: tapping a numeric tag's Live Value opens the editor; entering `80` writes the tag's `value` to `80`; `System`'s value is not editable. Run — expect PASS.
- [ ] **Step 7: Full validation**
```bash
cd mobile && flutter analyze                 # zero warnings
cd mobile && flutter test                     # ALL pass — record the count
cd mobile && flutter build web --release      # compiles
```
- [ ] **Step 8: Commit**
```bash
git add mobile/lib/widgets/tag_inspector_dock.dart mobile/lib/screens/memory_manager_screen.dart mobile/test/tag_inspector_live_edit_test.dart mobile/test/memory_manager_tag_config_test.dart
git commit -m "feat(tags): live scalar value editing in Tag Inspector and Tags & Structs"
```

---

## Self-Review

**Spec coverage:** Component 1 (model `defaultValue` + `effectiveDefault`) → Task 1 ✓; Component 2 (coercion helpers + `ScalarValueField`) → Task 2 ✓; Component 3 (Add default + Edit config dialog) → Task 3 ✓; Component 4 (live editing in both surfaces) → Task 4 ✓; Component 5 testing folded into each task. The four approved decisions are bound: distinct `defaultValue` (Task 1), poke-not-force (Task 4's write rule), name/path immutable (Task 3 read-only), one shared editor (Task 2 `ScalarValueField` used by Tasks 3 + 4). Reserved-`System` exclusion appears in Tasks 3 and 4.

**Placeholder scan:** No TBDs. The two spots that read from existing structure — the exact `MemoryManagerScreen`/`TagInspectorDock` pump helpers, and whether `_TagRowData` needs a `dataType` field — are explicit instructions to read a named sibling test / add a named field, not vague hand-waving. The `effectiveDefault` cyclic-import contingency is spelled out with the exact fallback signature.

**Type consistency:** `PlcTag.defaultValue`/`effectiveDefault(PlcProject)` (Task 1) are consumed by `coerceValueToType` call sites and the dialogs (Tasks 3-4). `coerceScalarValue(String, String)` / `coerceValueToType(PlcProject, dynamic, String, int)` (Task 2) signatures match every call site in Tasks 3-4. `ScalarValueField({dataType, value, onChanged})` (Task 2) matches its uses. `writePath(PlcProject, String, dynamic)` and `_liveValueFor(_TagRowData)` are pre-existing and used as-is.

**Note for the executor:** the binding properties are (a) serialization is additive — no `default_value` key ⇒ default adopts `initial_value`, and the live `value` path is byte-unchanged; (b) live editing is a POKE following the existing force rule (write `forcedValue` if forced, else `value`) and NEVER auto-forces; (c) name/path are immutable in the edit dialog; (d) reserved `System` is excluded from every editor; (e) scalar-only — composites keep their structural defaults; (f) one `ScalarValueField` serves all three surfaces; (g) zero analyze warnings and no overflow at 320/360/1400. Tasks 1-2 are pure/independently testable; Tasks 3-4 are UI wiring over them.
