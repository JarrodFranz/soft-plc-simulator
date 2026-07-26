# L5X Import Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Rockwell L5X front-end (`parseL5x`) to the importer — UDTs→structs, AOIs→function blocks, tags→tags, ST routines→ST programs — reusing the vendor-neutral IR and every downstream mapper unchanged.

**Architecture:** A single new parser `lib/import/l5x_parser.dart` emits the same `ImportedProject` IR the PLCopen parser does; `dialect_detect.dart` gains an L5X case and `workspace_shell.dart` routes to it; `mapImportedProject` and all translators are untouched. AOIs are emitted as `functionBlock` POUs so the existing `mapImportedFbs` maps them to `FbDefinition`s (AOI-typed tags then resolve). RLL/FBD/SFC routines and non-ST AOI logic are stubbed for later sub-projects.

**Tech Stack:** Dart (Flutter package `soft_plc_mobile`, in `mobile/`). The `xml` package (already a dependency), confined to `l5x_parser.dart`. Run all `flutter` commands from `mobile/`; `flutter` is at `/c/flutter/bin/flutter`.

## Global Constraints

- Pure Dart, in-app (ADR-010). Deterministic. `parseL5x` throws `FormatException` ONLY for non-well-formed XML or a non-`<RSLogix5000Content>` root; every valid-but-unsupported element becomes an `ImportWarning` (never a throw).
- The `xml` package is confined to `l5x_parser.dart`.
- Zero `flutter analyze` warnings (run from `mobile/`).
- **Additive / backward-compatible:** the PLCopen import path is untouched; a PLCopen file still detects and imports identically. No new dependency.
- Only N-relevant here: AOI system params `EnableIn`/`EnableOut` are skipped; `Usage` Input/Output/InOut → var scope input/output/inOut.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

- **Create** `mobile/lib/import/l5x_parser.dart` — the L5X front-end (`parseL5x` + private section builders + helpers). Built up across Tasks 1–5.
- **Modify** `mobile/lib/import/import_ir.dart` — extend `enum ImportDialect`.
- **Modify** `mobile/lib/import/dialect_detect.dart` — L5X detection.
- **Modify** `mobile/lib/screens/workspace_shell.dart` — route detected L5X to `parseL5x`.
- **Modify** `mobile/test/import/corpus_import_test.dart` — L5X now detects + imports (was: rejected).
- **Create tests** `mobile/test/import/l5x_parser_test.dart`, `mobile/test/import/import_l5x_e2e_test.dart`.
- **Modify docs** `docs/import/` (new) or `docs/iec61131/`, `docs/DEFERRED.md`.

---

### Task 1: Dialect detect + `parseL5x` skeleton + routing

**Files:**
- Modify: `mobile/lib/import/import_ir.dart` (`enum ImportDialect`)
- Modify: `mobile/lib/import/dialect_detect.dart` (`detectDialect`)
- Create: `mobile/lib/import/l5x_parser.dart`
- Modify: `mobile/lib/screens/workspace_shell.dart` (`_handleImportedXmlText`)
- Test: `mobile/test/import/dialect_detect_test.dart`, `mobile/test/import/l5x_parser_test.dart` (create)

**Interfaces:**
- Consumes: `ImportedProject`, `ImportWarning`, `WarningSeverity`, `ImportDialect` (`import_ir.dart`).
- Produces: `ImportDialect.l5x`; `detectDialect` returns `ImportDialect.l5x` for an `<RSLogix5000Content>` root; `ImportedProject parseL5x(String xml)` that validates the root, reads the controller name, and returns an otherwise-empty `ImportedProject` (types/globalVars/pous filled by Tasks 2–5). Private XML helpers `_firstChild(XmlElement, String)`, `_children(XmlElement, String)` used by later tasks.

- [ ] **Step 1: Write the failing tests**

Add to `mobile/test/import/dialect_detect_test.dart` (create if absent; it imports `package:soft_plc_mobile/import/dialect_detect.dart` + `package:flutter_test/flutter_test.dart`):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/dialect_detect.dart';

void main() {
  test('detects L5X by RSLogix5000Content root', () {
    const l5x = '<?xml version="1.0"?>\n<RSLogix5000Content SchemaRevision="1.0" TargetType="Program"><Controller Name="C"/></RSLogix5000Content>';
    expect(detectDialect(l5x), ImportDialect.l5x);
  });
  test('still detects PLCopen', () {
    const p = '<?xml version="1.0"?><project xmlns="http://www.plcopen.org/xml/tc6_0201"/>';
    expect(detectDialect(p), ImportDialect.plcOpen);
  });
  test('unknown returns null', () {
    expect(detectDialect('<foo/>'), isNull);
  });
}
```

Create `mobile/test/import/l5x_parser_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';

void main() {
  test('rejects a non-L5X root', () {
    expect(() => parseL5x('<project/>'), throwsFormatException);
  });
  test('rejects malformed XML', () {
    expect(() => parseL5x('<RSLogix5000Content>'), throwsFormatException);
  });
  test('reads the controller name into the project', () {
    const xml = '<RSLogix5000Content TargetType="Controller"><Controller Name="DEVPAC"/></RSLogix5000Content>';
    final ir = parseL5x(xml);
    expect(ir.name, 'DEVPAC');
    expect(ir.types, isEmpty);
    expect(ir.pous, isEmpty);
    expect(ir.globalVars, isEmpty);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/dialect_detect_test.dart test/import/l5x_parser_test.dart`
Expected: FAIL — `ImportDialect.l5x` undefined; `parseL5x` / `l5x_parser.dart` do not exist.

- [ ] **Step 3: Extend the dialect enum**

In `mobile/lib/import/import_ir.dart`, change:

```dart
enum ImportDialect { plcOpen }
```

to:

```dart
enum ImportDialect { plcOpen, l5x }
```

- [ ] **Step 4: Add L5X detection**

In `mobile/lib/import/dialect_detect.dart`, add an L5X branch to `detectDialect` — BEFORE the `<project` check (an L5X root is not `<project>`, so order is not strictly required, but keep it explicit):

```dart
ImportDialect? detectDialect(String xml) {
  final head = xml.length > 4096 ? xml.substring(0, 4096) : xml;
  final lower = head.toLowerCase();
  if (lower.contains('<rslogix5000content')) {
    return ImportDialect.l5x;
  }
  final rootIdx = lower.indexOf('<project');
  if (rootIdx < 0) {
    return null;
  }
  if (lower.contains('plcopen') || lower.contains('tc6')) {
    return ImportDialect.plcOpen;
  }
  return null;
}
```

- [ ] **Step 5: Create `l5x_parser.dart` skeleton + helpers**

Create `mobile/lib/import/l5x_parser.dart`:

```dart
import 'package:xml/xml.dart';

import 'import_ir.dart';

/// Parses a Rockwell L5X (Studio 5000 / Logix Designer export) document into
/// the vendor-neutral IR. Throws [FormatException] ONLY when [xml] is not
/// well-formed or its root is not `<RSLogix5000Content>`. Valid-but-unsupported
/// content becomes an [ImportWarning] on the returned project — never a throw.
/// The `xml` package is confined to this file.
ImportedProject parseL5x(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException catch (e) {
    throw FormatException('Not well-formed XML: ${e.message}');
  }
  final root = doc.rootElement;
  if (root.name.local != 'RSLogix5000Content') {
    throw FormatException('Not an L5X document: root element is '
        '<${root.name.local}>, expected <RSLogix5000Content>.');
  }
  final warnings = <ImportWarning>[];
  final controller = _firstChild(root, 'Controller');
  final name = controller?.getAttribute('Name') ??
      root.getAttribute('TargetName') ??
      'Imported L5X Project';

  final types = <ImportedType>[];
  final pous = <ImportedPou>[];
  final globalVars = <ImportedVar>[];

  // Tasks 2–5 fill types/pous/globalVars from `controller`.

  return ImportedProject(
      name: name, types: types, globalVars: globalVars, pous: pous,
      warnings: warnings);
}

/// First direct child element named [local], or null.
XmlElement? _firstChild(XmlElement e, String local) {
  for (final c in e.findElements(local)) {
    return c;
  }
  return null;
}

/// Direct child elements named [local] (possibly empty).
Iterable<XmlElement> _children(XmlElement e, String local) => e.findElements(local);
```

(The `_children` helper is unused in Task 1 — later tasks use it. If `flutter analyze` flags it as unused in Task 1, add a leading `// ignore: unused_element` comment; it is removed once Task 2 uses it.)

- [ ] **Step 6: Route detected L5X in the shell**

In `mobile/lib/screens/workspace_shell.dart`, add the import near the other import-module imports:

```dart
import '../import/l5x_parser.dart';
```

In `_handleImportedXmlText` (~line 1548-1552), replace the hardcoded parse:

```dart
    final ImportResult result;
    try {
      final ir = parsePlcOpen(text);
      final id = 'proj_new_${DateTime.now().millisecondsSinceEpoch}';
      result = mapImportedProject(ir, projectName: ir.name, projectId: id);
```

with a dialect switch (reusing the `dialect` already computed above at line ~1539):

```dart
    final ImportResult result;
    try {
      final ir = dialect == ImportDialect.l5x ? parseL5x(text) : parsePlcOpen(text);
      final id = 'proj_new_${DateTime.now().millisecondsSinceEpoch}';
      result = mapImportedProject(ir, projectName: ir.name, projectId: id);
```

And broaden the unrecognized-format snackbar text (line ~1542-1543):

```dart
        content: Text("Couldn't recognize this as a supported PLC export "
            '(PLCopen TC6 XML and Rockwell L5X are supported)'),
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/dialect_detect_test.dart test/import/l5x_parser_test.dart`
Expected: PASS.

- [ ] **Step 8: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/import_ir.dart mobile/lib/import/dialect_detect.dart mobile/lib/import/l5x_parser.dart mobile/lib/screens/workspace_shell.dart mobile/test/import/dialect_detect_test.dart mobile/test/import/l5x_parser_test.dart
git commit -m "feat(import): L5X dialect detect + parseL5x skeleton + routing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: DataTypes → structs (`ImportedType`) + scalar-value helper

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` (add `_l5xTypes`, `_l5xScalar`)
- Test: `mobile/test/import/l5x_parser_test.dart`

**Interfaces:**
- Consumes: `_firstChild`/`_children` (Task 1); `ImportedType`/`ImportedField` (`import_ir.dart`).
- Produces: `List<ImportedType> _l5xTypes(XmlElement? controller, List<ImportWarning> warnings)` — user `<DataType>`s → `ImportedType` (members → `ImportedField`; array via `Dimension`; BIT-overlay member → BOOL field + info warning; member `<DefaultData>` scalar → `initialValue`). `dynamic _l5xScalar(String raw, String? radix)` — parses an L5X scalar literal (Decimal/Hex `16#ffff_0000`/Binary `2#..`/Octal `8#..`/Float) to `int`/`double`, or null; reused by Tasks 3–4.

- [ ] **Step 1: Write the failing tests**

Add to `mobile/test/import/l5x_parser_test.dart`:

```dart
  test('user DataType -> ImportedType with array + BIT-overlay members', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <DataTypes>
    <DataType Name="MyUdt" Class="User">
      <Members>
        <Member Name="Count" DataType="DINT" Dimension="0" Radix="Decimal"/>
        <Member Name="Buf" DataType="INT" Dimension="4" Radix="Decimal"/>
        <Member Name="Flags" DataType="DINT" Dimension="0" Radix="Hex">
          <DefaultData Format="Decorated"><DataValue Value="255"/></DefaultData>
        </Member>
        <Member Name="Bit0" DataType="BIT" Dimension="0" Target="Flags" BitNumber="0"/>
      </Members>
    </DataType>
    <DataType Name="Builtin" Class="ProductDefined"><Members/></DataType>
  </DataTypes>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    expect(ir.types.map((t) => t.name), ['MyUdt']); // ProductDefined skipped
    final udt = ir.types.single;
    final byName = {for (final f in udt.fields) f.name: f};
    expect(byName['Count']!.baseType, 'DINT');
    expect(byName['Buf']!.arrayLength, 4);
    expect(byName['Flags']!.initialValue, 255);
    expect(byName['Bit0']!.baseType, 'BOOL'); // BIT overlay -> BOOL
    expect(ir.warnings.any((w) => w.message.contains('bit overlay')), isTrue);
  });

  test('_l5xScalar parses radices', () {
    // Exercised indirectly here via a hex member default.
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <DataTypes><DataType Name="U" Class="User"><Members>
    <Member Name="M" DataType="DINT" Dimension="0" Radix="Hex">
      <DefaultData Format="Decorated"><DataValue Value="16#0000_ffff" Radix="Hex"/></DefaultData>
    </Member>
  </Members></DataType></DataTypes>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    expect(ir.types.single.fields.single.initialValue, 0xffff);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: the two new tests FAIL (`ir.types` empty — `_l5xTypes` not wired).

- [ ] **Step 3: Implement `_l5xScalar` + `_l5xTypes` and wire them**

In `mobile/lib/import/l5x_parser.dart`, replace the `final types = <ImportedType>[];` line in `parseL5x` with a call:

```dart
  final types = _l5xTypes(controller, warnings);
```

Add the functions (below `parseL5x`):

```dart
/// Parses an L5X scalar literal honoring [radix]. Handles a radix-prefixed form
/// (`16#ffff_0000`, `2#1010`, `8#17`) and the `Radix` attribute (Hex/Binary/
/// Octal/Decimal/Float). Underscores in digit groups are ignored. Returns an
/// `int` or `double`, or null if unparseable. (BOOL "1"/"0" come through as
/// int 1/0; the mapper coerces to bool by the field/var type.)
dynamic _l5xScalar(String raw, String? radix) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  // Radix-prefixed literal: <base>#<digits>.
  final hash = t.indexOf('#');
  if (hash > 0) {
    final base = int.tryParse(t.substring(0, hash));
    final digits = t.substring(hash + 1).replaceAll('_', '');
    if (base != null) {
      final v = int.tryParse(digits, radix: base);
      if (v != null) return v;
    }
  }
  switch (radix) {
    case 'Hex':
      return int.tryParse(t.replaceAll('_', ''), radix: 16);
    case 'Binary':
      return int.tryParse(t.replaceAll('_', ''), radix: 2);
    case 'Octal':
      return int.tryParse(t.replaceAll('_', ''), radix: 8);
    case 'Float':
    case 'Exponential':
      return double.tryParse(t);
    default:
      final i = int.tryParse(t.replaceAll('_', ''));
      return i ?? double.tryParse(t);
  }
}

/// Scalar `initialValue` from an element's `<DefaultData Format="Decorated">
/// <DataValue Value= Radix=/>`, or null.
dynamic _defaultDataScalar(XmlElement owner) {
  for (final dd in _children(owner, 'DefaultData')) {
    final dv = _firstChild(dd, 'DataValue');
    if (dv != null) {
      final v = dv.getAttribute('Value');
      if (v != null) return _l5xScalar(v, dv.getAttribute('Radix'));
    }
  }
  return null;
}

/// Maps user `<DataType>`s under the controller to `ImportedType`s.
List<ImportedType> _l5xTypes(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedType>[];
  if (controller == null) return out;
  for (final dts in _children(controller, 'DataTypes')) {
    for (final dt in _children(dts, 'DataType')) {
      if ((dt.getAttribute('Class') ?? 'User') != 'User') continue;
      final tname = dt.getAttribute('Name') ?? '';
      if (tname.isEmpty) continue;
      final fields = <ImportedField>[];
      for (final members in _children(dt, 'Members')) {
        for (final m in _children(members, 'Member')) {
          if (m.getAttribute('Hidden') == 'true') continue; // internal host member
          final mn = m.getAttribute('Name') ?? '';
          if (mn.isEmpty) continue;
          if (m.getAttribute('Target') != null && m.getAttribute('BitNumber') != null) {
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'DataType "$tname" member "$mn" is a bit overlay of '
                    '"${m.getAttribute('Target')}.${m.getAttribute('BitNumber')}" '
                    '— imported as a plain BOOL (no bit aliasing).'));
            fields.add(ImportedField(name: mn, baseType: 'BOOL', arrayLength: 0));
            continue;
          }
          fields.add(ImportedField(
            name: mn,
            baseType: m.getAttribute('DataType') ?? 'DINT',
            arrayLength: int.tryParse(m.getAttribute('Dimension') ?? '0') ?? 0,
            initialValue: _defaultDataScalar(m),
          ));
        }
      }
      out.add(ImportedType(name: tname, fields: fields));
    }
  }
  return out;
}
```

- [ ] **Step 4: Run to verify passing**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: PASS (all tests).

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/l5x_parser.dart mobile/test/import/l5x_parser_test.dart
git commit -m "feat(import): L5X DataTypes -> structs + scalar-value helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: AOIs → function-block POUs

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` (add `_l5xAois`)
- Test: `mobile/test/import/l5x_parser_test.dart`

**Interfaces:**
- Consumes: `_firstChild`/`_children`/`_defaultDataScalar` (Tasks 1–2); `ImportedPou`/`PouKind`/`PouLanguage`/`ImportedVar`/`VarScope`/`TextBody` (`import_ir.dart`).
- Produces: `List<ImportedPou> _l5xAois(XmlElement? controller, List<ImportWarning> warnings)` — each `<AddOnInstructionDefinition>` → an `ImportedPou(kind: PouKind.functionBlock, lang: PouLanguage.st, localVars: <params + local tags>, body: TextBody(<ST logic or ''>))`. `EnableIn`/`EnableOut` skipped; `Usage` Input/Output/InOut → `VarScope.input/output/inOut`; `<LocalTags>` → `VarScope.local`. ST Logic routine inlined; non-ST logic → empty body + warning.

- [ ] **Step 1: Write the failing test**

Add to `mobile/test/import/l5x_parser_test.dart`:

```dart
  test('AOI -> functionBlock POU with params, skipped EnableIn/Out, ST body', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Scaler">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="REAL" Usage="Input" Visible="true"/>
        <Parameter Name="Gain" DataType="REAL" Usage="Input" Visible="true">
          <DefaultData Format="Decorated"><DataValue Value="2.0" Radix="Float"/></DefaultData>
        </Parameter>
        <Parameter Name="Out" DataType="REAL" Usage="Output" Visible="true"/>
      </Parameters>
      <LocalTags><LocalTag Name="Tmp" DataType="REAL"/></LocalTags>
      <Routines>
        <Routine Name="Logic" Type="ST"><STContent>
          <Line Number="0"><![CDATA[Out := In * Gain;]]></Line>
        </STContent></Routine>
      </Routines>
    </AddOnInstructionDefinition>
    <AddOnInstructionDefinition Name="LadderAoi">
      <Parameters><Parameter Name="X" DataType="BOOL" Usage="Input" Visible="true"/></Parameters>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent><Rung Number="0"><Text><![CDATA[NOP();]]></Text></Rung></RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final scaler = ir.pous.firstWhere((p) => p.name == 'Scaler');
    expect(scaler.kind, PouKind.functionBlock);
    expect(scaler.lang, PouLanguage.st);
    expect(scaler.localVars.map((v) => v.name), ['In', 'Gain', 'Out', 'Tmp']); // EnableIn/Out skipped
    expect(scaler.localVars.firstWhere((v) => v.name == 'In').scope, VarScope.input);
    expect(scaler.localVars.firstWhere((v) => v.name == 'Out').scope, VarScope.output);
    expect(scaler.localVars.firstWhere((v) => v.name == 'Tmp').scope, VarScope.local);
    expect(scaler.localVars.firstWhere((v) => v.name == 'Gain').initialValue, 2.0);
    expect((scaler.body as TextBody).source, 'Out := In * Gain;');

    // RLL-bodied AOI: interface imported, empty body + warning.
    final ladder = ir.pous.firstWhere((p) => p.name == 'LadderAoi');
    expect((ladder.body as TextBody).source, '');
    expect(ir.warnings.any((w) => w.message.contains('LadderAoi') && w.message.contains('logic')), isTrue);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: the new test FAILS (`ir.pous` empty).

- [ ] **Step 3: Implement `_l5xAois` and wire it**

In `parseL5x`, after `final pous = <ImportedPou>[];`, add:

```dart
  pous.addAll(_l5xAois(controller, warnings));
```

Add the functions:

```dart
/// Concatenated CDATA of a routine's `<STContent><Line>`s (in document order).
String _stLines(XmlElement routine) {
  final lines = <String>[];
  for (final st in _children(routine, 'STContent')) {
    for (final ln in _children(st, 'Line')) {
      lines.add(ln.innerText.trim());
    }
  }
  return lines.join('\n');
}

VarScope _usageScope(String? usage) => switch (usage) {
      'Input' => VarScope.input,
      'Output' => VarScope.output,
      'InOut' => VarScope.inOut,
      _ => VarScope.local,
    };

/// Maps `<AddOnInstructionDefinition>`s to functionBlock POUs. The existing
/// `mapImportedFbs` turns these into FbDefinitions (AOI-typed tags then resolve).
List<ImportedPou> _l5xAois(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedPou>[];
  if (controller == null) return out;
  for (final defs in _children(controller, 'AddOnInstructionDefinitions')) {
    for (final aoi in _children(defs, 'AddOnInstructionDefinition')) {
      final name = aoi.getAttribute('Name') ?? '';
      if (name.isEmpty) continue;
      final vars = <ImportedVar>[];
      for (final params in _children(aoi, 'Parameters')) {
        for (final p in _children(params, 'Parameter')) {
          final pn = p.getAttribute('Name') ?? '';
          if (pn.isEmpty || pn == 'EnableIn' || pn == 'EnableOut') continue;
          vars.add(ImportedVar(
            name: pn,
            baseType: p.getAttribute('DataType') ?? 'DINT',
            arrayLength: int.tryParse(p.getAttribute('Dimensions') ?? '0') ?? 0,
            scope: _usageScope(p.getAttribute('Usage')),
            initialValue: _defaultDataScalar(p),
          ));
        }
      }
      for (final lts in _children(aoi, 'LocalTags')) {
        for (final lt in _children(lts, 'LocalTag')) {
          final ln = lt.getAttribute('Name') ?? '';
          if (ln.isEmpty) continue;
          vars.add(ImportedVar(
            name: ln,
            baseType: lt.getAttribute('DataType') ?? 'DINT',
            arrayLength: int.tryParse(lt.getAttribute('Dimensions') ?? '0') ?? 0,
            scope: VarScope.local,
            initialValue: _defaultDataScalar(lt),
          ));
        }
      }
      // Logic routine: named "Logic" else the first routine.
      XmlElement? logic;
      for (final rs in _children(aoi, 'Routines')) {
        for (final r in _children(rs, 'Routine')) {
          logic ??= r;
          if (r.getAttribute('Name') == 'Logic') logic = r;
        }
      }
      String body = '';
      if (logic != null) {
        final type = logic.getAttribute('Type');
        if (type == 'ST') {
          body = _stLines(logic);
        } else {
          warnings.add(ImportWarning(severity: WarningSeverity.info,
              message: 'AOI "$name" logic is ${type ?? '?'} — interface '
                  'imported, logic not yet translated.'));
        }
      }
      out.add(ImportedPou(name: name, kind: PouKind.functionBlock,
          lang: PouLanguage.st, localVars: vars, body: TextBody(body)));
    }
  }
  return out;
}
```

- [ ] **Step 4: Run to verify passing**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/l5x_parser.dart mobile/test/import/l5x_parser_test.dart
git commit -m "feat(import): L5X AOIs -> function-block POUs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Tags → `ImportedVar`

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` (add `_l5xTags`)
- Test: `mobile/test/import/l5x_parser_test.dart`

**Interfaces:**
- Consumes: `_firstChild`/`_children`/`_l5xScalar` (Tasks 1–2); `ImportedVar`/`VarScope` (`import_ir.dart`).
- Produces: `List<ImportedVar> _l5xTags(XmlElement? controller, List<ImportWarning> warnings)` — controller-scoped `<Tags>` and every `<Program><Tags>` → `ImportedVar(scope: global)`. Scalar tags hydrate `initialValue` from Decorated `<DataValue>` (radix-aware); composite/array tags → null (type default); array length from `Dimensions` (first dim, multi-dim warns).

- [ ] **Step 1: Write the failing test**

Add to `mobile/test/import/l5x_parser_test.dart`:

```dart
  test('controller + program tags -> ImportedVar with scalar values', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Tags>
    <Tag Name="Speed" DataType="DINT" Usage="Public">
      <Data Format="Decorated"><DataValue DataType="DINT" Radix="Decimal" Value="42"/></Data></Tag>
    <Tag Name="Mask" DataType="DINT">
      <Data Format="Decorated"><DataValue Radix="Hex" Value="16#0000_ffff"/></Data></Tag>
    <Tag Name="Inst" DataType="Scaler">
      <Data Format="Decorated"><Structure DataType="Scaler"><DataValueMember Name="Gain" Value="2.0"/></Structure></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags><Tag Name="Local1" DataType="INT"><Data Format="Decorated"><DataValue Value="7"/></Data></Tag></Tags>
    <Routines/></Program></Programs>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final byName = {for (final v in ir.globalVars) v.name: v};
    expect(byName.keys, containsAll(['Speed', 'Mask', 'Inst', 'Local1']));
    expect(byName['Speed']!.initialValue, 42);
    expect(byName['Mask']!.initialValue, 0xffff);
    expect(byName['Inst']!.baseType, 'Scaler');     // composite
    expect(byName['Inst']!.initialValue, isNull);   // type default used
    expect(byName['Local1']!.initialValue, 7);      // program-scoped -> flat global
    expect(byName['Speed']!.scope, VarScope.global);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: the new test FAILS (`ir.globalVars` empty).

- [ ] **Step 3: Implement `_l5xTags` and wire it**

In `parseL5x`, replace `final globalVars = <ImportedVar>[];` with:

```dart
  final globalVars = _l5xTags(controller, warnings);
```

Add the function:

```dart
/// Maps controller-scoped and program-scoped `<Tag>`s to global `ImportedVar`s.
/// Scalar tags hydrate their value from Decorated `<DataValue>`; composite/array
/// tags default to the type default (initialValue null). The mapper's existing
/// sanitize+dedup handles cross-program name collisions.
List<ImportedVar> _l5xTags(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedVar>[];
  if (controller == null) return out;

  ImportedVar? tagToVar(XmlElement tag) {
    final tn = tag.getAttribute('Name') ?? '';
    if (tn.isEmpty) return null;
    final dims = tag.getAttribute('Dimensions') ?? '';
    final firstDim = dims.trim().isEmpty
        ? 0
        : (int.tryParse(dims.trim().split(RegExp(r'\s+')).first) ?? 0);
    if (dims.trim().split(RegExp(r'\s+')).length > 1) {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Tag "$tn": multi-dimensional array flattened to $firstDim.'));
    }
    // Scalar value from a Decorated <DataValue> directly under <Data>.
    dynamic initial;
    for (final data in _children(tag, 'Data')) {
      if (data.getAttribute('Format') != 'Decorated') continue;
      final dv = _firstChild(data, 'DataValue');
      if (dv != null && dv.getAttribute('Value') != null) {
        initial = _l5xScalar(dv.getAttribute('Value')!, dv.getAttribute('Radix'));
      }
      // A <Structure>/<ArrayMember> tag stays null -> type default (foundation).
    }
    return ImportedVar(
      name: tn,
      baseType: tag.getAttribute('DataType') ?? 'DINT',
      arrayLength: firstDim,
      scope: VarScope.global,
      initialValue: initial,
    );
  }

  // Controller-scoped tags.
  for (final tags in _children(controller, 'Tags')) {
    for (final tag in _children(tags, 'Tag')) {
      final v = tagToVar(tag);
      if (v != null) out.add(v);
    }
  }
  // Program-scoped tags (flat).
  for (final progs in _children(controller, 'Programs')) {
    for (final prog in _children(progs, 'Program')) {
      for (final tags in _children(prog, 'Tags')) {
        for (final tag in _children(tags, 'Tag')) {
          final v = tagToVar(tag);
          if (v != null) out.add(v);
        }
      }
    }
  }
  return out;
}
```

- [ ] **Step 4: Run to verify passing**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/l5x_parser.dart mobile/test/import/l5x_parser_test.dart
git commit -m "feat(import): L5X tags -> ImportedVar (scalar values, flat namespace)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Routines → program POUs

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` (add `_l5xRoutines`)
- Test: `mobile/test/import/l5x_parser_test.dart`

**Interfaces:**
- Consumes: `_firstChild`/`_children`/`_stLines` (Tasks 1/3); `ImportedPou`/`PouKind`/`PouLanguage`/`TextBody`/`GraphBody`/`SfcBody` (`import_ir.dart`).
- Produces: `List<ImportedPou> _l5xRoutines(XmlElement? controller, List<ImportWarning> warnings)` — each `<Routine>` in each `<Program>` → `ImportedPou(name: 'Program_Routine', kind: program)`: ST → `TextBody`; RLL → `lang: ld` empty `GraphBody` + rung-count warning; FBD → `lang: fbd` empty `GraphBody` + warning; SFC → `lang: sfc` empty `SfcBody` + warning.

- [ ] **Step 1: Write the failing test**

Add to `mobile/test/import/l5x_parser_test.dart`:

```dart
  test('routines -> program POUs (ST body; RLL/FBD/SFC stubbed)', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Calc" Type="ST"><STContent>
        <Line Number="0"><![CDATA[X := 1;]]></Line>
        <Line Number="1"><![CDATA[Y := 2;]]></Line></STContent></Routine>
      <Routine Name="Ladder" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[XIC(A)OTE(B);]]></Text></Rung>
        <Rung Number="1"><Text><![CDATA[NOP();]]></Text></Rung></RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final calc = ir.pous.firstWhere((p) => p.name == 'Main_Calc');
    expect(calc.kind, PouKind.program);
    expect(calc.lang, PouLanguage.st);
    expect((calc.body as TextBody).source, 'X := 1;\nY := 2;');

    final ladder = ir.pous.firstWhere((p) => p.name == 'Main_Ladder');
    expect(ladder.lang, PouLanguage.ld);
    expect((ladder.body as GraphBody).nodes, isEmpty); // stubbed
    expect(ir.warnings.any((w) => w.message.contains('Main_Ladder') && w.message.contains('2 rungs')), isTrue);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: the new test FAILS (`Main_Calc` not found — routines not wired).

- [ ] **Step 3: Implement `_l5xRoutines` and wire it**

In `parseL5x`, after the `pous.addAll(_l5xAois(...))` line, add:

```dart
  pous.addAll(_l5xRoutines(controller, warnings));
```

Add the function:

```dart
/// Maps each `<Routine>` in each `<Program>` to a program POU named
/// `Program_Routine`. ST inlines its lines; RLL/FBD/SFC become empty graphical
/// bodies (the mapper's existing whole-POU stub) + a count-carrying warning.
List<ImportedPou> _l5xRoutines(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedPou>[];
  if (controller == null) return out;
  for (final progs in _children(controller, 'Programs')) {
    for (final prog in _children(progs, 'Program')) {
      final progName = prog.getAttribute('Name') ?? 'Program';
      for (final rs in _children(prog, 'Routines')) {
        for (final r in _children(rs, 'Routine')) {
          final rName = r.getAttribute('Name') ?? 'Routine';
          final name = '${progName}_$rName';
          final type = r.getAttribute('Type');
          switch (type) {
            case 'ST':
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.st, localVars: const [],
                  body: TextBody(_stLines(r))));
              break;
            case 'RLL':
              final rungs = _children(r, 'RLLContent')
                  .expand((e) => _children(e, 'Rung')).length;
              warnings.add(ImportWarning(severity: WarningSeverity.warning,
                  message: 'Routine "$name" (Ladder): $rungs rungs not yet '
                      'translated — neutral-text ladder import ships in a later '
                      'update.'));
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.ld, localVars: const [],
                  body: GraphBody(nodes: const [], connections: const [])));
              break;
            case 'FBD':
              warnings.add(ImportWarning(severity: WarningSeverity.warning,
                  message: 'Routine "$name" (FBD): graphical body not yet '
                      'translated.'));
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.fbd, localVars: const [],
                  body: GraphBody(nodes: const [], connections: const [])));
              break;
            case 'SFC':
              warnings.add(ImportWarning(severity: WarningSeverity.warning,
                  message: 'Routine "$name" (SFC): graphical body not yet '
                      'translated.'));
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.sfc, localVars: const [],
                  body: SfcBody(nodes: const [], edges: const [], actions: const [])));
              break;
            default:
              warnings.add(ImportWarning(severity: WarningSeverity.info,
                  message: 'Routine "$name": unsupported type "${type ?? '?'}" — skipped.'));
          }
        }
      }
    }
  }
  return out;
}
```

- [ ] **Step 4: Run to verify passing + full import suite**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: PASS.

Run: `cd mobile && /c/flutter/bin/flutter test test/import/`
Expected: PASS (no regression; note `corpus_import_test` may now FAIL on L5X files because they detect as `l5x` instead of null — that is fixed in Task 6; if it fails here for that reason only, proceed to Task 6, which updates it).

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/l5x_parser.dart mobile/test/import/l5x_parser_test.dart
git commit -m "feat(import): L5X routines -> program POUs (ST inlined, graphical stubbed)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Corpus test update + end-to-end + docs + full validation

**Files:**
- Modify: `mobile/test/import/corpus_import_test.dart` (L5X now detects + imports)
- Create: `mobile/test/import/import_l5x_e2e_test.dart`
- Modify: `docs/import/` (new) or `docs/iec61131/`, `docs/DEFERRED.md`

**Interfaces:**
- Consumes: the full pipeline — `detectDialect`, `parseL5x`, `mapImportedProject`; the corpus loader (`_findCorpus`/`_filesIn`) already in `corpus_import_test.dart`; `executeFbInstance`/`readPath`/`writePath` (`tag_resolver.dart`/`fb_exec.dart`) or `executeFbdPrograms`/`executeLdPrograms` for the run check.
- Produces: an executable end-to-end proof against real samples, an updated corpus contract, and docs.

- [ ] **Step 1: Update the corpus test — L5X now imports, others still rejected**

In `mobile/test/import/corpus_import_test.dart`, the `others` list currently lumps Rockwell-L5X with the still-unsupported vendors and asserts `detectDialect == null` for all. Split it. Replace the `final others = <File>[ … ];` block and the trailing `for (final f in others) { … }` loop with:

```dart
    final l5x = _filesIn(corpus, 'Rockwell-L5X');
    final unsupported = <File>[
      ..._filesIn(corpus, 'Beckhoff-TwinCAT'),
      ..._filesIn(corpus, 'CODESYS'),
      ..._filesIn(corpus, 'Siemens-TIA'),
    ];
```

(add `import 'package:soft_plc_mobile/import/l5x_parser.dart';` at the top), and after the PLCopen loop:

```dart
    for (final f in l5x) {
      final name = f.uri.pathSegments.last;
      test('L5X import: $name', () {
        final xml = f.readAsStringSync();
        expect(detectDialect(xml), ImportDialect.l5x,
            reason: '$name should be detected as Rockwell L5X');
        final ir = parseL5x(xml);
        final result = mapImportedProject(ir,
            projectName: ir.name.isEmpty ? 'Imported' : ir.name,
            projectId: 'corpus_test');
        expect(result.project, isNotNull);
      });
    }

    for (final f in unsupported) {
      final name = f.uri.pathSegments.last;
      test('unsupported vendor rejected: $name', () {
        final text = f.readAsStringSync();
        expect(detectDialect(text), isNull,
            reason: '$name is not yet supported and must route to the '
                '"unrecognized format" path');
      });
    }
```

- [ ] **Step 2: Write the end-to-end test against a real sample**

Create `mobile/test/import/import_l5x_e2e_test.dart`:

```dart
// End-to-end proof against REAL Rockwell L5X exports in
// `Resources/Project Exports/Rockwell-L5X/` (gitignored corpus — skips when
// absent). Proves parseL5x -> mapImportedProject produces a real project: UDTs,
// AOIs (as FbDefinitions), and tags import; an AOI-typed tag resolves to its
// composite type; an ST-bodied AOI executes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

File? _sample(String fileName) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/Resources/Project Exports/Rockwell-L5X/$fileName');
    if (f.existsSync()) return f;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  test('real Numeric_Program.L5X imports with UDTs/AOIs/tags', () {
    final f = _sample('logixlibraries_Numeric_Program.L5X');
    if (f == null) {
      markTestSkipped('Rockwell-L5X corpus absent — skipping.');
      return;
    }
    final ir = parseL5x(f.readAsStringSync());
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_e2e');
    final p = res.project;
    expect(p, isNotNull);
    // AOIs became function-block definitions.
    expect(p.fbDefinitions, isNotEmpty);
    expect(res.report.importedFbCount, greaterThan(0));
    // At least one controller tag is AOI-typed and resolves to a composite.
    final aoiNames = p.fbDefinitions.map((d) => d.name).toSet();
    final aoiTag = p.tags.where((t) => aoiNames.contains(t.dataType));
    expect(aoiTag, isNotEmpty, reason: 'expected an AOI-typed tag');
    expect(defaultValueFor(p, aoiTag.first.dataType, 0), isA<Map>());
  });

  test('real Op_PID_AOI.L5X imports without throwing', () {
    final f = _sample('logixlibraries_Op_PID_AOI.L5X');
    if (f == null) {
      markTestSkipped('Rockwell-L5X corpus absent — skipping.');
      return;
    }
    final ir = parseL5x(f.readAsStringSync());
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_e2e2');
    expect(res.project, isNotNull);
    expect(res.project.fbDefinitions, isNotEmpty);
  });
}
```

- [ ] **Step 3: Run the corpus + e2e tests**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/corpus_import_test.dart test/import/import_l5x_e2e_test.dart`
Expected: PASS (or the corpus/e2e tests SKIP gracefully if the gitignored `Resources/Project Exports/` is absent). If an assertion fails against a real file, diagnose and fix the underlying `l5x_parser.dart` (not the test) — real exports are the point of this test.

- [ ] **Step 4: Update docs**

Create `docs/import/L5X.md` (or add an SFC-matrix-style section under `docs/iec61131/`) with the L5X import support matrix:

```markdown
# L5X import (Rockwell Logix → app)

Foundation (sub-project 1). Supported: user DataTypes → structs; AOIs → function
blocks (interface + ST logic); controller + program tags → tags (flat namespace,
scalar values incl. Hex); ST routines → ST programs (named `Program_Routine`).

Stubbed / deferred: RLL (ladder) routines, FBD routines, SFC routines, non-ST
AOI logic (interface only), BIT-overlay members (→ plain BOOL), per-instance
composite tag values (type defaults used), predefined AB/CIP module datatypes,
multi-dimensional arrays (first dimension).
```

Update `docs/DEFERRED.md`: add an **L5X import** sub-program section — foundation delivered (with the e2e test path `mobile/test/import/import_l5x_e2e_test.dart`); queued sub-projects 2–5 (RLL ladder compiler; non-ST AOI logic; L5X FBD; L5X SFC); within-foundation deferrals (BIT-overlay aliasing; per-instance composite tag values; predefined AB module types; multi-dimensional arrays).

- [ ] **Step 5: Full validation — whole suite + analyze**

Run: `cd mobile && /c/flutter/bin/flutter test`
Expected: entire suite PASS (baseline was 2685 passing; this adds tests and must not regress any; the PLCopen import path is unchanged).

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add mobile/test/import/corpus_import_test.dart mobile/test/import/import_l5x_e2e_test.dart docs/import docs/DEFERRED.md
git commit -m "test(import): L5X corpus + e2e; docs; foundation complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- §2 `parseL5x` (root check, name, sections) → Task 1 (skeleton) + Tasks 2–5 (sections). ✅
- §3 DataTypes→structs (array, BIT-overlay, member default) → Task 2. ✅
- §4 AOIs→functionBlock POUs (params, EnableIn/Out skip, InOut, LocalTags, ST logic / non-ST warn) → Task 3. ✅
- §5 Tags→ImportedVar (controller + program, scalar values incl. Hex, composite default, array dims) → Task 4. ✅
- §5.1 value hydration (`_l5xScalar` radices) → Task 2 (helper) + Tasks 3/4 (use). ✅
- §6 Routines→program POUs (ST inline, RLL/FBD/SFC stub) → Task 5. ✅
- §7 dialect detect + enum + routing → Task 1. ✅
- §8 reporting (reuse existing counts; importedFbCount) → verified in Task 6 e2e. ✅
- §9 error handling (BIT overlay, unresolved type, non-ST AOI logic, stubs, dedup, radix, unparseable, multi-dim, unknown) → Tasks 2–5 + mapper. ✅
- §10 testing (detect, parser unit, mapping integration, e2e corpus, backward-compat) → Tasks 1–6. ✅
- §11 docs → Task 6. ✅
- §12 deferred → Task 6 Step 4. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output. The Task 5 Step 4 note (corpus may fail until Task 6) states an exact, expected condition with its resolution, not an open placeholder.

**3. Type consistency:**
- `parseL5x(String) -> ImportedProject`; helpers `_firstChild(XmlElement,String)->XmlElement?`, `_children(XmlElement,String)->Iterable<XmlElement>`, `_l5xScalar(String,String?)->dynamic`, `_defaultDataScalar(XmlElement)->dynamic`, `_stLines(XmlElement)->String`, `_usageScope(String?)->VarScope`, `_l5xTypes`/`_l5xAois`/`_l5xTags`/`_l5xRoutines(XmlElement?,List<ImportWarning>)->List<...>` — consistent across the task that defines each and the tasks that consume it. ✅
- IR constructors used verbatim: `ImportedField(name, baseType, arrayLength, initialValue)`, `ImportedType(name, fields)`, `ImportedVar(name, baseType, arrayLength, scope, initialValue)`, `ImportedPou(name, kind, lang, localVars, body)`, `ImportedProject(name, types, globalVars, pous, warnings)`, `TextBody`/`GraphBody(nodes, connections)`/`SfcBody(nodes, edges, actions)`, `ImportWarning(severity, message)`, `PouKind.functionBlock/program`, `PouLanguage.st/ld/fbd/sfc`, `VarScope.input/output/inOut/local/global`, `ImportDialect.l5x`. ✅
- `enum ImportDialect { plcOpen, l5x }` defined Task 1, used in detect + routing + corpus test. ✅

All consistent. Plan ready.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-07-26-l5x-import-foundation.md`. Six tasks: Task 1 wires the seam end-to-end (an L5X file imports as an empty project through the real routing); Tasks 2–5 each add one `parseL5x` section with its own unit tests; Task 6 flips the corpus contract, proves it against real samples, and validates the whole suite.
