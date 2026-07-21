# PLCopen-XML Program Import (foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import a PLCopen TC6 XML program export into the soft PLC as a new project — mapping variables→tags, DUTs→structs, and ST/IL bodies→ST programs, while capturing graphical (LD/FBD/SFC) bodies losslessly into a vendor-neutral IR for later translators.

**Architecture:** A pure-Dart pipeline `detectDialect → parsePlcOpen → ImportedProject (IR) → mapImportedProject → (PlcProject, ImportReport)`, with a thin Flutter wrapper (file pick + preview) in the shell. The IR is vendor-neutral and language-complete, so future L5X/Siemens parsers and future LD/FBD/SFC translators plug into the same spine.

**Tech Stack:** Flutter/Dart + the pure-Dart `xml` package (one new dependency). `flutter test`, `flutter analyze`, `flutter build web --release`.

**Spec:** `docs/superpowers/specs/2026-07-21-plcopen-xml-import-design.md`.

## Global Constraints

- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/import/`; only file-pick + navigation live in `workspace_shell.dart`. `xml` is confined to `plcopen_parser.dart`.
- **Additive / non-destructive**: import creates a NEW project; nothing in the current project, existing serialization, or scan behavior changes. Lossless round-trip + default-projects suites stay green.
- **Never crash on hostile/partial input**: the parser throws `FormatException` (clear message) ONLY on structurally-invalid XML or a non-PLCopen document; valid-but-unexpected content → an `ImportWarning`, never a throw. `detectDialect` and the mappers never throw.
- Deterministic: no clock/RNG in the IR, parser, normalizer, or mappers (stable IDs, document-order emission). The project `id` is supplied by the UI caller, not generated in the mapper.
- Dark theme; `withValues(alpha:)` not `withOpacity`; braces on all control flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- Identifier hygiene: imported names sanitized to the app's rules (see Task 4's `_sanitizeIdentifier`); every rename recorded as a warning; the reserved `System` name is never produced (a colliding name is suffixed).
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. No push.

## Key facts (verified on-branch — do not re-derive)

- **Target model** (`mobile/lib/models/project_model.dart`): `PlcProject` ctor requires `id, name, controllerName, tags, structDefs, programs, tasks, hmis` (others optional: `version`, `description`, `scanPeriodMs`, `simRules`, `signalGens`, `trends`, `protocols`). `PlcTag(name, path, dataType, value, ioType, {arrayLength, defaultValue, access, retentive, engineeringUnits, description, folder, …})`. `PlcStructDef(name, fields)` + `StructFieldDef(name, dataType, arrayLength, defaultValue)`. `PlcProgram(name, language, {description, stSource, rungs, fbdBlocks, fbdWires, sfcSteps, sfcTransitions, enabled})`; `language` ∈ `'StructuredText'`/`'LadderLogic'`/`'FunctionBlockDiagram'`/`'SequentialFunctionChart'`.
- **Helpers** (`mobile/lib/models/tag_resolver.dart`): `dynamic defaultValueFor(PlcProject p, String base, int arrayLength)` (`:133`) — BOOL→false, FLOAT64→0.0, STRING→'', TIMER/composite→Map, else int→0; `dynamic coerceScalarValue(String dataType, String input)` (`:175`) — BOOL from true/1/on, INT* via int.tryParse??0, FLOAT64 via double.tryParse??0.0, STRING verbatim.
- **`kSystemTagName = 'System'`** (`models/system_tags.dart:4`).
- **Import wrapper to mirror** (`mobile/lib/screens/workspace_shell.dart`): `_importProject()` (`:1317`) uses `FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], withData: true)`, decodes `file.bytes` via `utf8.decode`, catches picker/read/FormatException with a `ScaffoldMessenger` snackbar + `_logger.log(kLogSourceProject, …)`, then `_applyImportedProject(imported)` (`:1393`) which stops hosts + `repo.saveProject` + swaps active. `debugImportProject(PlcProject)` (`:595`) is a test hook bypassing the picker. `ProjectTransfer.reassignIdIfColliding(project, existingIds)` handles id collisions; `_allProjects` is the project list. New-project id convention: `'proj_new_${DateTime.now().millisecondsSinceEpoch}'`.
- **Pure-core precedent**: `data/project_transfer.dart` — pure, plugin-free, decode ALWAYS throws `FormatException` (never an obscure type) on a non-project document; UI wrappers separate.
- **Baseline**: `flutter test` green (2400 as of the tag-value merge; re-confirm at Task 1); `flutter analyze` clean.

---

### Task 1: IR data classes + dialect detection

**Files:** Create `mobile/lib/import/import_ir.dart`, `mobile/lib/import/dialect_detect.dart`; test `mobile/test/import/import_ir_test.dart`, `mobile/test/import/dialect_detect_test.dart`.

**Interfaces (Produces):** the IR classes/enums below; `ImportDialect? detectDialect(String xml)` and `enum ImportDialect { plcOpen }`.

- [ ] **Step 1: Write the failing tests.**

`mobile/test/import/dialect_detect_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/dialect_detect.dart';

void main() {
  test('recognizes a PLCopen TC6 project root', () {
    const xml = '<?xml version="1.0"?>\n'
        '<project xmlns="http://www.plcopen.org/xml/tc6_0201"><contentHeader/></project>';
    expect(detectDialect(xml), ImportDialect.plcOpen);
  });
  test('null for a non-PLCopen XML document', () {
    expect(detectDialect('<RSLogix5000Content/>'), isNull);
  });
  test('null for junk / malformed, never throws', () {
    expect(() => detectDialect('not xml at all'), returnsNormally);
    expect(detectDialect('not xml at all'), isNull);
    expect(detectDialect(''), isNull);
  });
}
```

`mobile/test/import/import_ir_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';

void main() {
  test('IR classes construct and hold their fields', () {
    final v = ImportedVar(name: 'Speed', baseType: 'INT', arrayLength: 0,
        initialValue: '10', scope: VarScope.global, retain: false);
    expect(v.name, 'Speed');
    final body = GraphBody(
      nodes: [IrGraphNode(localId: 1, elementType: 'contact', x: 0, y: 0, attributes: {'negated': 'false'})],
      connections: [IrConnection(toLocalId: 2, toPort: 0, fromLocalId: 1, fromPort: 0)],
    );
    final pou = ImportedPou(name: 'Main', kind: PouKind.program,
        lang: PouLanguage.ld, localVars: const [], body: body);
    expect(pou.body, isA<GraphBody>());
    final proj = ImportedProject(name: 'P', types: const [], globalVars: [v],
        pous: [pou], warnings: [ImportWarning(severity: WarningSeverity.info, message: 'hi')]);
    expect(proj.globalVars.single.name, 'Speed');
    expect((proj.pous.single.body as GraphBody).nodes.single.elementType, 'contact');
  });
}
```

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/import/`
- [ ] **Step 3: Implement `import_ir.dart`** (pure `dart:core` only):
```dart
/// Vendor-neutral intermediate representation for program import. Every
/// vendor parser (PLCopen now; L5X/Siemens later) emits this shape; every
/// language mapper consumes it. Pure data — no Flutter, no interpretation of
/// graphical bodies (a GraphBody is captured losslessly for later
/// per-language translators). See the design spec.
library import_ir;

enum VarScope { global, input, output, inOut, local, temp, external }
enum PouKind { program, functionBlock, function }
enum PouLanguage { st, il, ld, fbd, sfc }
enum WarningSeverity { info, warning }
enum ImportDialect { plcOpen }

class ImportWarning {
  final WarningSeverity severity;
  final String message;
  ImportWarning({required this.severity, required this.message});
}

class ImportedField {
  final String name;
  final String baseType;
  final int arrayLength;
  final dynamic initialValue;
  ImportedField({required this.name, required this.baseType,
      this.arrayLength = 0, this.initialValue});
}

class ImportedType {
  final String name;
  final List<ImportedField> fields;
  ImportedType({required this.name, required this.fields});
}

class ImportedVar {
  final String name;
  final String baseType;
  final int arrayLength;
  final dynamic initialValue;
  final VarScope scope;
  final bool retain;
  ImportedVar({required this.name, required this.baseType,
      this.arrayLength = 0, this.initialValue, required this.scope,
      this.retain = false});
}

sealed class PouBody {}

class TextBody extends PouBody {
  final String source;
  TextBody(this.source);
}

class IrGraphNode {
  final int localId;
  final String elementType;
  final double x;
  final double y;
  final Map<String, String> attributes;
  IrGraphNode({required this.localId, required this.elementType,
      this.x = 0, this.y = 0, Map<String, String>? attributes})
      : attributes = attributes ?? const {};
}

class IrConnection {
  final int toLocalId;
  final int toPort;
  final int fromLocalId;
  final int fromPort;
  IrConnection({required this.toLocalId, this.toPort = 0,
      required this.fromLocalId, this.fromPort = 0});
}

class GraphBody extends PouBody {
  final List<IrGraphNode> nodes;
  final List<IrConnection> connections;
  GraphBody({required this.nodes, required this.connections});
}

class ImportedPou {
  final String name;
  final PouKind kind;
  final PouLanguage lang;
  final List<ImportedVar> localVars;
  final PouBody body;
  ImportedPou({required this.name, required this.kind, required this.lang,
      required this.localVars, required this.body});
}

class ImportedProject {
  final String name;
  final List<ImportedType> types;
  final List<ImportedVar> globalVars;
  final List<ImportedPou> pous;
  final List<ImportWarning> warnings;
  ImportedProject({required this.name, required this.types,
      required this.globalVars, required this.pous, required this.warnings});
}
```
- [ ] **Step 4: Implement `dialect_detect.dart`**:
```dart
import 'import_ir.dart';
export 'import_ir.dart' show ImportDialect;

/// Cheap sniff of the leading markup (no full parse) to recognize the vendor
/// dialect. PLCopen TC6 documents have a `<project>` root and a namespace
/// containing `plcopen` (e.g. http://www.plcopen.org/xml/tc6_0201). Returns
/// null for anything not yet recognized. Never throws.
ImportDialect? detectDialect(String xml) {
  final head = xml.length > 4096 ? xml.substring(0, 4096) : xml;
  final lower = head.toLowerCase();
  final rootIdx = lower.indexOf('<project');
  if (rootIdx < 0) {
    return null;
  }
  // A real root, and its markup mentions the PLCopen namespace.
  if (lower.contains('plcopen') || lower.contains('tc6')) {
    return ImportDialect.plcOpen;
  }
  return null;
}
```
- [ ] **Step 5: Run — expect PASS**, then full suite (`cd mobile && flutter test`) — report the count.
- [ ] **Step 6: analyze + commit**
```bash
cd mobile && flutter analyze
git add mobile/lib/import/import_ir.dart mobile/lib/import/dialect_detect.dart mobile/test/import/
git commit -m "feat(import): vendor-neutral IR + PLCopen dialect detection"
```

---

### Task 2: Type normalization + initial-value coercion

**Files:** Create `mobile/lib/import/type_normalize.dart`; test `mobile/test/import/type_normalize_test.dart`.

**Interfaces:**
- Consumes: `defaultValueFor`, `coerceScalarValue` (`tag_resolver.dart`); `ImportWarning`, `WarningSeverity` (Task 1).
- Produces: `String normalizeType(String iecType, {required Set<String> knownDutNames})`; `dynamic coerceInitialValue(PlcProject p, String appType, int arrayLength, String? rawText, List<ImportWarning> sink)`.

- [ ] **Step 1: Write the failing tests** (`mobile/test/import/type_normalize_test.dart`):
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/type_normalize.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

PlcProject _p() => PlcProject(id: 'p', name: 'P', controllerName: 'PLC',
    programs: [], tasks: [], hmis: [], structDefs: [], tags: []);

void main() {
  group('normalizeType', () {
    test('elementary IEC types map to app types', () {
      final k = <String>{};
      expect(normalizeType('BOOL', knownDutNames: k), 'BOOL');
      expect(normalizeType('INT', knownDutNames: k), 'INT16');
      expect(normalizeType('UINT', knownDutNames: k), 'INT16');
      expect(normalizeType('DINT', knownDutNames: k), 'INT32');
      expect(normalizeType('LINT', knownDutNames: k), 'INT64');
      expect(normalizeType('REAL', knownDutNames: k), 'FLOAT64');
      expect(normalizeType('LREAL', knownDutNames: k), 'FLOAT64');
      expect(normalizeType('STRING', knownDutNames: k), 'STRING');
      expect(normalizeType('TIME', knownDutNames: k), 'TIMER');
    });
    test('case-insensitive', () {
      expect(normalizeType('bool', knownDutNames: {}), 'BOOL');
    });
    test('a known DUT name maps to itself', () {
      expect(normalizeType('MotorType', knownDutNames: {'MotorType'}), 'MotorType');
    });
    test('unknown type falls back to INT16', () {
      expect(normalizeType('WEIRD_T', knownDutNames: {}), 'INT16');
    });
  });

  group('coerceInitialValue', () {
    test('coerces a scalar text value per app type', () {
      final w = <ImportWarning>[];
      expect(coerceInitialValue(_p(), 'INT16', 0, '42', w), 42);
      expect(coerceInitialValue(_p(), 'FLOAT64', 0, '12.5', w), 12.5);
      expect(coerceInitialValue(_p(), 'BOOL', 0, 'TRUE', w), true);
      expect(w, isEmpty);
    });
    test('null raw -> type default, no warning', () {
      final w = <ImportWarning>[];
      expect(coerceInitialValue(_p(), 'INT16', 0, null, w), 0);
      expect(w, isEmpty);
    });
    test('an array or composite initial -> type default + info warning', () {
      final w = <ImportWarning>[];
      final v = coerceInitialValue(_p(), 'FLOAT64', 2, '1.0', w);
      expect(v, isA<List<dynamic>>());
      expect(w.length, 1);
      expect(w.single.severity, WarningSeverity.info);
    });
  });
}
```
- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement** `type_normalize.dart`:
```dart
import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import 'import_ir.dart';

const Map<String, String> _elementary = {
  'BOOL': 'BOOL',
  'SINT': 'INT16', 'INT': 'INT16', 'USINT': 'INT16', 'UINT': 'INT16',
  'BYTE': 'INT16', 'WORD': 'INT16',
  'DINT': 'INT32', 'UDINT': 'INT32', 'DWORD': 'INT32',
  'LINT': 'INT64', 'ULINT': 'INT64', 'LWORD': 'INT64',
  'REAL': 'FLOAT64', 'LREAL': 'FLOAT64',
  'STRING': 'STRING', 'WSTRING': 'STRING', 'CHAR': 'STRING', 'WCHAR': 'STRING',
  'TIME': 'TIMER', 'TON': 'TIMER', 'TOF': 'TIMER', 'TP': 'TIMER',
};

/// Maps an IEC/PLCopen type name to the app's data-type set. A name in
/// [knownDutNames] maps to itself (a struct reference); an unrecognized name
/// falls back to `INT16`. Case-insensitive.
String normalizeType(String iecType, {required Set<String> knownDutNames}) {
  final upper = iecType.trim().toUpperCase();
  final mapped = _elementary[upper];
  if (mapped != null) {
    return mapped;
  }
  if (knownDutNames.contains(iecType.trim())) {
    return iecType.trim();
  }
  return 'INT16';
}

/// Coerces a PLCopen `<initialValue>` raw scalar text into the runtime value
/// for an app tag/field of [appType]. Scalar only: an array/composite target
/// (arrayLength > 0 or a composite type) yields the structural default via
/// [defaultValueFor] and appends an info warning to [sink]. A null [rawText]
/// yields the type default silently. Never throws.
dynamic coerceInitialValue(PlcProject p, String appType, int arrayLength,
    String? rawText, List<ImportWarning> sink) {
  if (arrayLength > 0 || defaultValueFor(p, appType, 0) is Map) {
    if (rawText != null) {
      sink.add(ImportWarning(
          severity: WarningSeverity.info,
          message: 'Initial value for a $appType'
              '${arrayLength > 0 ? '[$arrayLength]' : ''} was not imported '
              '(only scalar initial values are supported).'));
    }
    return defaultValueFor(p, appType, arrayLength);
  }
  if (rawText == null) {
    return defaultValueFor(p, appType, 0);
  }
  return coerceScalarValue(appType, rawText);
}
```
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: analyze + commit**
```bash
git add mobile/lib/import/type_normalize.dart mobile/test/import/type_normalize_test.dart
git commit -m "feat(import): IEC type normalization + initial-value coercion"
```

---

### Task 3: PLCopen TC6 parser → IR (lossless graphical capture)

**Files:** Modify `mobile/pubspec.yaml` (add `xml`); create `mobile/lib/import/plcopen_parser.dart`, fixtures `mobile/test/fixtures/plcopen/*.xml`; test `mobile/test/import/plcopen_parser_test.dart`.

**Interfaces:**
- Consumes: the IR (Task 1), `normalizeType`/`coerceInitialValue` (Task 2).
- Produces: `ImportedProject parsePlcOpen(String xml)` — throws `FormatException` (clear message) on invalid XML or a non-PLCopen `<project>` document.

**Context:** Confine ALL `xml` package use to this file. Parse defensively — an unknown element inside a POU body is captured as a generic `IrGraphNode` + an info warning (never dropped, never a throw). Only structurally-invalid XML or a missing/renamed `<project>` root throws.

- [ ] **Step 1: Add the dependency.** In `mobile/pubspec.yaml` under `dependencies:` add `  xml: ^6.5.0` (after `path_provider`), then `cd mobile && flutter pub get`.
- [ ] **Step 2: Create fixtures.** `mobile/test/fixtures/plcopen/basic.xml` — a valid TC6 document with a DUT, globals of several types with initial values + a retain var, an ST POU, and an LD POU with two elements + a connection:
```xml
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="DemoProject"/>
  <types>
    <dataTypes>
      <dataType name="MotorType">
        <baseType><struct>
          <variable name="Running"><type><BOOL/></type></variable>
          <variable name="Rpm"><type><INT/></type><initialValue><simpleValue value="1500"/></initialValue></variable>
        </struct></baseType>
      </dataType>
    </dataTypes>
    <pous>
      <pou name="Main" pouType="program">
        <interface>
          <localVars>
            <variable name="Count"><type><DINT/></type><initialValue><simpleValue value="7"/></initialValue></variable>
          </localVars>
        </interface>
        <body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Count := Count + 1;</xhtml></ST></body>
      </pou>
      <pou name="Rung1" pouType="program">
        <interface><localVars/></interface>
        <body><LD>
          <contact localId="1"><position x="10" y="20"/><variable>Start</variable>
            <connectionPointIn/><connectionPointOut/></contact>
          <coil localId="2"><position x="90" y="20"/><variable>Motor</variable>
            <connectionPointIn><connection refLocalId="1"/></connectionPointIn></coil>
        </LD></body>
      </pou>
    </pous>
  </types>
  <instances>
    <configurations>
      <configuration name="Config">
        <resource name="Res">
          <globalVars>
            <variable name="Temp_PV"><type><REAL/></type><initialValue><simpleValue value="20.0"/></initialValue></variable>
            <variable name="Enable"><type><BOOL/></type><initialValue><simpleValue value="TRUE"/></initialValue></variable>
            <variable name="Retained" retain="true"><type><LREAL/></type></variable>
          </globalVars>
        </resource>
      </configuration>
    </configurations>
  </instances>
</project>
```
  `mobile/test/fixtures/plcopen/malformed.xml` = `<project><unclosed>`; `mobile/test/fixtures/plcopen/not_plcopen.xml` = `<RSLogix5000Content><Controller/></RSLogix5000Content>`.
- [ ] **Step 3: Write the failing tests** (`mobile/test/import/plcopen_parser_test.dart`). Load a fixture with `File('test/fixtures/plcopen/basic.xml').readAsStringSync()` (add `import 'dart:io';`). Assert:
  - project name == `DemoProject` (from `<contentHeader name>`, else fall back to a default).
  - one `ImportedType` `MotorType` with 2 fields (`Running` BOOL, `Rpm` INT with initialValue `'1500'`).
  - three global vars: `Temp_PV` (REAL, init `'20.0'`), `Enable` (BOOL, init `'TRUE'`), `Retained` (LREAL, `retain==true`, scope global).
  - two POUs: `Main` (ST, body is `TextBody` whose source contains `Count := Count + 1;`, one local var `Count` DINT init `'7'`), `Rung1` (LD, body is `GraphBody` with 2 nodes — `contact` localId 1 with attribute `variable`==`Start` at x=10,y=20; `coil` localId 2 — and 1 connection `to=2 from=1`).
  - `parsePlcOpen(File('…/malformed.xml'))` throws `FormatException`.
  - `parsePlcOpen(File('…/not_plcopen.xml'))` throws `FormatException` (root isn't `<project>`).
- [ ] **Step 4: Run — expect FAIL.** `cd mobile && flutter test test/import/plcopen_parser_test.dart`
- [ ] **Step 5: Implement `plcopen_parser.dart`.** Use `package:xml`. Structure (fill the element walk to satisfy the fixtures + the general rules):
```dart
import 'package:xml/xml.dart';
import 'import_ir.dart';
import 'type_normalize.dart';

/// Parses a PLCopen TC6 XML document into the vendor-neutral IR. Throws
/// [FormatException] (with a clear message) ONLY when [xml] is not
/// well-formed or its root is not a PLCopen `<project>`. Valid-but-unexpected
/// content becomes an [ImportWarning] on the returned project — never a throw.
/// The `xml` package is confined to this file.
ImportedProject parsePlcOpen(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException catch (e) {
    throw FormatException('Not well-formed XML: ${e.message}');
  }
  final root = doc.rootElement;
  if (root.name.local != 'project') {
    throw FormatException(
        'Not a PLCopen document: root element is <${root.name.local}>, expected <project>.');
  }
  final warnings = <ImportWarning>[];

  final projectName = _findElement(root, 'contentHeader')?.getAttribute('name') ?? 'Imported Project';

  // DUTs first (so var/field type normalization can recognize them).
  final types = <ImportedType>[];
  for (final dt in _descendants(root, 'dataType')) {
    final name = dt.getAttribute('name') ?? '';
    final struct = _findElement(dt, 'struct');
    final fields = <ImportedField>[];
    if (struct != null) {
      for (final v in struct.childElements.where((e) => e.name.local == 'variable')) {
        fields.add(_field(v));
      }
    }
    types.add(ImportedType(name: name, fields: fields));
  }
  final dutNames = types.map((t) => t.name).toSet();

  // Global vars (resource/config globalVars).
  final globals = <ImportedVar>[];
  for (final gv in _descendants(root, 'globalVars')) {
    for (final v in gv.childElements.where((e) => e.name.local == 'variable')) {
      globals.add(_var(v, VarScope.global, dutNames));
    }
  }

  // POUs.
  final pous = <ImportedPou>[];
  for (final p in _descendants(root, 'pou')) {
    pous.add(_pou(p, dutNames, warnings));
  }

  return ImportedProject(
      name: projectName, types: types, globalVars: globals, pous: pous, warnings: warnings);
}

ImportedField _field(XmlElement v) {
  final typeEl = _findElement(v, 'type');
  final baseName = _baseTypeName(typeEl);
  return ImportedField(
    name: v.getAttribute('name') ?? '',
    baseType: baseName,
    arrayLength: _arrayLen(typeEl),
    initialValue: _initialText(v),
  );
}

ImportedVar _var(XmlElement v, VarScope scope, Set<String> dutNames) {
  final typeEl = _findElement(v, 'type');
  return ImportedVar(
    name: v.getAttribute('name') ?? '',
    baseType: _baseTypeName(typeEl),
    arrayLength: _arrayLen(typeEl),
    initialValue: _initialText(v),
    scope: scope,
    retain: (v.getAttribute('retain') ?? 'false').toLowerCase() == 'true',
  );
}

ImportedPou _pou(XmlElement p, Set<String> dutNames, List<ImportWarning> warnings) {
  final name = p.getAttribute('name') ?? '';
  final kind = switch ((p.getAttribute('pouType') ?? 'program')) {
    'functionBlock' => PouKind.functionBlock,
    'function' => PouKind.function,
    _ => PouKind.program,
  };
  final locals = <ImportedVar>[];
  final iface = _findElement(p, 'interface');
  if (iface != null) {
    for (final section in iface.childElements) {
      final scope = switch (section.name.local) {
        'inputVars' => VarScope.input,
        'outputVars' => VarScope.output,
        'inOutVars' => VarScope.inOut,
        'tempVars' => VarScope.temp,
        'externalVars' => VarScope.external,
        _ => VarScope.local,
      };
      for (final v in section.childElements.where((e) => e.name.local == 'variable')) {
        locals.add(_var(v, scope, dutNames));
      }
    }
  }
  final body = _findElement(p, 'body');
  final langEl = body?.childElements.firstWhere(
      (e) => const {'ST', 'IL', 'LD', 'FBD', 'SFC'}.contains(e.name.local),
      orElse: () => XmlElement(XmlName('ST')));
  final lang = switch (langEl?.name.local) {
    'IL' => PouLanguage.il,
    'LD' => PouLanguage.ld,
    'FBD' => PouLanguage.fbd,
    'SFC' => PouLanguage.sfc,
    _ => PouLanguage.st,
  };
  final PouBody pouBody;
  if (lang == PouLanguage.st || lang == PouLanguage.il) {
    pouBody = TextBody((langEl?.innerText ?? '').trim());
  } else {
    pouBody = _graphBody(langEl, warnings, name);
  }
  return ImportedPou(name: name, kind: kind, lang: lang, localVars: locals, body: pouBody);
}

GraphBody _graphBody(XmlElement? langEl, List<ImportWarning> warnings, String pouName) {
  final nodes = <IrGraphNode>[];
  final conns = <IrConnection>[];
  if (langEl == null) {
    return GraphBody(nodes: nodes, connections: conns);
  }
  for (final el in langEl.childElements) {
    final localIdStr = el.getAttribute('localId');
    if (localIdStr == null) {
      continue; // non-element children without a localId aren't graph nodes
    }
    final localId = int.tryParse(localIdStr) ?? -1;
    final pos = _findElement(el, 'position');
    final attrs = <String, String>{};
    for (final a in el.attributes) {
      attrs[a.name.local] = a.value;
    }
    final varEl = _findElement(el, 'variable');
    if (varEl != null) {
      attrs['variable'] = varEl.innerText.trim();
    }
    nodes.add(IrGraphNode(
      localId: localId,
      elementType: el.name.local,
      x: double.tryParse(pos?.getAttribute('x') ?? '') ?? 0,
      y: double.tryParse(pos?.getAttribute('y') ?? '') ?? 0,
      attributes: attrs,
    ));
    // Each <connectionPointIn><connection refLocalId=…/> is an edge into this node.
    for (final cpi in el.findElements('connectionPointIn')) {
      for (final c in cpi.findElements('connection')) {
        final from = int.tryParse(c.getAttribute('refLocalId') ?? '') ?? -1;
        conns.add(IrConnection(toLocalId: localId, toPort: 0, fromLocalId: from, fromPort: 0));
      }
    }
  }
  if (nodes.isEmpty) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: 'POU "$pouName": graphical body had no recognizable elements.'));
  }
  return GraphBody(nodes: nodes, connections: conns);
}

// --- small helpers ---
XmlElement? _findElement(XmlElement e, String local) {
  for (final d in e.descendantElements) {
    if (d.name.local == local) {
      return d;
    }
  }
  return null;
}
Iterable<XmlElement> _descendants(XmlElement e, String local) =>
    e.descendantElements.where((d) => d.name.local == local);
String _baseTypeName(XmlElement? typeEl) {
  if (typeEl == null) {
    return 'INT16';
  }
  final derived = _findElement(typeEl, 'derived');
  if (derived != null) {
    return derived.getAttribute('name') ?? 'INT16';
  }
  final arr = _findElement(typeEl, 'array');
  final scope = arr ?? typeEl;
  for (final c in scope.descendantElements) {
    if (c.name.local != 'position' && c.name.local != 'dimension' &&
        c.name.local != 'baseType' && c.name.local != 'array') {
      return c.name.local; // e.g. BOOL/INT/REAL, or 'derived' handled above
    }
  }
  return 'INT16';
}
int _arrayLen(XmlElement? typeEl) {
  if (typeEl == null) {
    return 0;
  }
  final dim = _findElement(typeEl, 'dimension');
  if (dim == null) {
    return 0;
  }
  final lo = int.tryParse(dim.getAttribute('lower') ?? '0') ?? 0;
  final hi = int.tryParse(dim.getAttribute('upper') ?? '0') ?? 0;
  final n = hi - lo + 1;
  return n > 0 ? n : 0;
}
String? _initialText(XmlElement v) {
  final iv = _findElement(v, 'initialValue');
  if (iv == null) {
    return null;
  }
  final sv = _findElement(iv, 'simpleValue');
  return sv?.getAttribute('value');
}
```
  Note `_baseTypeName`: for the fixtures, `<type><BOOL/></type>` etc. give the element name; a `<derived name="MotorType"/>` gives the DUT name. If the general element-walk proves brittle against the fixtures, adjust it — the fixture tests define correctness.
- [ ] **Step 6: Run — expect PASS**, then full suite — report the count.
- [ ] **Step 7: analyze + commit**
```bash
cd mobile && flutter analyze
git add mobile/pubspec.yaml mobile/pubspec.lock mobile/lib/import/plcopen_parser.dart mobile/test/fixtures/plcopen/ mobile/test/import/plcopen_parser_test.dart
git commit -m "feat(import): PLCopen TC6 parser -> IR with lossless graphical capture"
```

---

### Task 4: IR → PlcProject mappers + ImportReport

**Files:** Create `mobile/lib/import/ir_to_project.dart`; test `mobile/test/import/ir_to_project_test.dart`.

**Interfaces:**
- Consumes: the IR (Task 1); `defaultValueFor` (`tag_resolver.dart`); `PlcProject`/`PlcTag`/`PlcStructDef`/`StructFieldDef`/`PlcProgram` (`project_model.dart`); `kSystemTagName` (`system_tags.dart`).
- Produces: `class ImportResult { final PlcProject project; final ImportReport report; }`; `class ImportReport { final int tagCount; final int structCount; final int stProgramCount; final int graphicalStubCount; final List<ImportWarning> warnings; }`; `ImportResult mapImportedProject(ImportedProject ir, {required String projectName, required String projectId})`.

**Context:** Pure, never throws. `projectId`/`projectName` are supplied by the caller (the UI generates the id) so this stays deterministic. Names sanitized via `_sanitizeIdentifier`.

- [ ] **Step 1: Write the failing tests** (`mobile/test/import/ir_to_project_test.dart`). Build an `ImportedProject` in-code (or parse `basic.xml`) and assert:
  - `structCount == 1`; the `MotorType` struct has fields `Running` BOOL, `Rpm` INT16 defaultValue `1500`.
  - global vars → tags: `Temp_PV` FLOAT64 `defaultValue == 20.0` ioType `Internal`; `Enable` BOOL `defaultValue == true`; `Retained` INT64 `retentive == true`; each tag's `value == defaultValue`.
  - a var scope `input`→ioType `SimulatedInput`, `output`→`SimulatedOutput` (construct two IR vars to assert).
  - ST POU `Main` → a `PlcProgram` language `StructuredText`, `stSource` contains `Count := Count + 1;`.
  - LD POU `Rung1` → a `PlcProgram` language `LadderLogic`, empty `rungs`, a `description` containing `not yet translated`; a `warning` present; `graphicalStubCount == 1`.
  - `report.tagCount == 3`, `report.structCount == 1`, `report.stProgramCount == 1`.
  - a var named `System` → sanitized to `System_1` (or similar) + a warning; a name with a space/hyphen → sanitized (e.g. `My Tag` → `My_Tag`) + a warning; duplicate names within the import → second suffixed.
  - the returned project has the supplied `id`/`name`.
- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement** `ir_to_project.dart`:
```dart
import '../models/project_model.dart';
import '../models/system_tags.dart';
import '../models/tag_resolver.dart';
import 'import_ir.dart';

class ImportReport {
  final int tagCount;
  final int structCount;
  final int stProgramCount;
  final int graphicalStubCount;
  final List<ImportWarning> warnings;
  ImportReport({required this.tagCount, required this.structCount,
      required this.stProgramCount, required this.graphicalStubCount,
      required this.warnings});
}

class ImportResult {
  final PlcProject project;
  final ImportReport report;
  ImportResult({required this.project, required this.report});
}

/// Sanitizes an imported identifier to the app's rules: keep [A-Za-z0-9_],
/// replace every other char with '_', prefix '_' if it starts with a digit,
/// fall back to 'Tag' if empty. Never yields the reserved [kSystemTagName].
String _sanitizeIdentifier(String raw) {
  var s = raw.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (s.isEmpty) {
    s = 'Tag';
  }
  if (RegExp(r'^[0-9]').hasMatch(s)) {
    s = '_$s';
  }
  return s;
}

/// Maps the vendor-neutral IR into a new [PlcProject]. Pure and never-throws.
/// [projectId]/[projectName] are supplied by the caller (keeps this
/// deterministic). Graphical POUs become language-tagged stubs (empty body +
/// a note) with a warning; the raw graph lives only in [ir] — a future
/// per-language translator re-imports to produce a real body.
ImportResult mapImportedProject(ImportedProject ir,
    {required String projectName, required String projectId}) {
  final warnings = <ImportWarning>[...ir.warnings];
  // A throwaway project only used to resolve type defaults during mapping.
  final scratch = PlcProject(id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: [], tags: []);
  final dutNames = ir.types.map((t) => t.name).toSet();

  // Structs (dependency order: a struct referencing another comes after it).
  final structs = _orderTypes(ir.types).map((t) => PlcStructDef(
        name: t.name,
        fields: t.fields.map((f) {
          final appType = _norm(f.baseType, dutNames);
          return StructFieldDef(
            name: f.name,
            dataType: appType,
            arrayLength: f.arrayLength,
            defaultValue: _fieldDefault(scratch, appType, f.arrayLength, f.initialValue, warnings, t.name, f.name),
          );
        }).toList(),
      )).toList();

  // Now scratch knows the structs, so composite-typed vars resolve.
  final scratch2 = PlcProject(id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: structs, tags: []);

  // Vars -> tags (with name sanitization + within-import dedup).
  final used = <String>{};
  final tags = <PlcTag>[];
  for (final v in ir.globalVars) {
    final appType = _norm(v.baseType, dutNames);
    var name = _sanitizeIdentifier(v.name);
    if (name != v.name) {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Variable "${v.name}" renamed to "$name" (identifier rules).'));
    }
    if (name == kSystemTagName || used.contains(name)) {
      var n = 1;
      while (used.contains('${name}_$n') || '${name}_$n' == kSystemTagName) {
        n++;
      }
      final renamed = '${name}_$n';
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Variable "$name" renamed to "$renamed" (name collision${name == kSystemTagName ? '/reserved' : ''}).'));
      name = renamed;
    }
    used.add(name);
    final def = v.arrayLength > 0 || defaultValueFor(scratch2, appType, 0) is Map
        ? defaultValueFor(scratch2, appType, v.arrayLength)
        : (v.initialValue == null
            ? defaultValueFor(scratch2, appType, 0)
            : coerceScalarValue(appType, '${v.initialValue}'));
    tags.add(PlcTag(
      name: name,
      path: name,
      dataType: appType,
      arrayLength: v.arrayLength,
      value: def,
      defaultValue: (v.arrayLength == 0 && defaultValueFor(scratch2, appType, 0) is! Map) ? def : null,
      ioType: switch (v.scope) {
        VarScope.input => 'SimulatedInput',
        VarScope.output => 'SimulatedOutput',
        _ => 'Internal',
      },
      retentive: v.retain,
    ));
  }

  // POUs -> programs.
  var stCount = 0;
  var stubCount = 0;
  final programs = <PlcProgram>[];
  for (final pou in ir.pous) {
    final body = pou.body;
    if (body is TextBody) {
      if (pou.lang == PouLanguage.il) {
        warnings.add(ImportWarning(severity: WarningSeverity.info,
            message: 'POU "${pou.name}" imported from IL as Structured Text — verify against the app\'s ST subset.'));
      }
      programs.add(PlcProgram(name: pou.name, language: 'StructuredText', stSource: body.source));
      stCount++;
    } else if (body is GraphBody) {
      final lang = switch (pou.lang) {
        PouLanguage.ld => 'LadderLogic',
        PouLanguage.fbd => 'FunctionBlockDiagram',
        PouLanguage.sfc => 'SequentialFunctionChart',
        _ => 'StructuredText',
      };
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'POU "${pou.name}" ($lang): graphical body not yet translated (${body.nodes.length} elements captured) — re-import once graphical translation ships.'));
      programs.add(PlcProgram(name: pou.name, language: lang,
          description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
      stubCount++;
    }
  }

  final project = PlcProject(
    id: projectId, name: projectName, controllerName: projectName,
    tags: tags, structDefs: structs, programs: programs, tasks: [], hmis: [],
  );
  return ImportResult(
    project: project,
    report: ImportReport(tagCount: tags.length, structCount: structs.length,
        stProgramCount: stCount, graphicalStubCount: stubCount, warnings: warnings),
  );
}

String _norm(String iec, Set<String> duts) {
  // Re-uses type_normalize's table; imported here to keep one source of truth.
  return normalizeTypePublic(iec, duts);
}

dynamic _fieldDefault(PlcProject scratch, String appType, int arrayLength,
    dynamic initial, List<ImportWarning> warnings, String typeName, String fieldName) {
  if (arrayLength > 0 || defaultValueFor(scratch, appType, 0) is Map) {
    return defaultValueFor(scratch, appType, arrayLength);
  }
  if (initial == null) {
    return defaultValueFor(scratch, appType, 0);
  }
  return coerceScalarValue(appType, '$initial');
}

/// Topologically orders [types] so a struct referencing another DUT is
/// emitted after it. A cycle (or an unresolved ref) is broken by emitting the
/// remaining types in input order.
List<ImportedType> _orderTypes(List<ImportedType> types) {
  final byName = {for (final t in types) t.name: t};
  final out = <ImportedType>[];
  final done = <String>{};
  void visit(ImportedType t, Set<String> stack) {
    if (done.contains(t.name) || stack.contains(t.name)) {
      return;
    }
    stack.add(t.name);
    for (final f in t.fields) {
      final dep = byName[f.baseType];
      if (dep != null) {
        visit(dep, stack);
      }
    }
    stack.remove(t.name);
    if (!done.contains(t.name)) {
      done.add(t.name);
      out.add(t);
    }
  }
  for (final t in types) {
    visit(t, {});
  }
  return out;
}
```
  Add to `type_normalize.dart` a thin public alias so the mapper and parser share the table without a circular import surprise: `String normalizeTypePublic(String iec, Set<String> duts) => normalizeType(iec, knownDutNames: duts);` (or simply call `normalizeType` directly and delete `_norm`/`normalizeTypePublic` — pick one and keep it consistent; the tests only care about behavior).
- [ ] **Step 4: Run — expect PASS**, then full suite — report the count.
- [ ] **Step 5: analyze + commit**
```bash
cd mobile && flutter analyze
git add mobile/lib/import/ir_to_project.dart mobile/lib/import/type_normalize.dart mobile/test/import/ir_to_project_test.dart
git commit -m "feat(import): IR -> PlcProject mappers + ImportReport"
```

---

### Task 5: Import UI (menu + dialect dropdown + preview) + docs + validation

**Files:** Modify `mobile/lib/screens/workspace_shell.dart`; create `mobile/lib/screens/import_xml_preview.dart`, `docs/import/plcopen.md`; test `mobile/test/import/import_xml_flow_test.dart`.

**Interfaces:** Consumes `detectDialect`, `parsePlcOpen`, `mapImportedProject`/`ImportResult`/`ImportReport` (Tasks 1-4), and the existing `_applyImportedProject`/`ProjectTransfer.reassignIdIfColliding`/`debugImportProject` pattern (`workspace_shell.dart`).

**Context:** Mirror `_importProject` (`:1317`) for the file pick + error snackbars + `_applyImportedProject`, but route through detect→parse→map→preview. Add a `debugImportXml(String xml)` test hook (parse+map+apply, bypassing the picker) mirroring `debugImportProject` (`:595`), so the flow is testable without a mocked platform channel.

- [ ] **Step 1: Write the failing tests** (`mobile/test/import/import_xml_flow_test.dart`). Pump `WorkspaceShell` with a fixture project (mirror an existing `workspace_*_test.dart` harness). Tests:
  - `detectDialect` on `basic.xml` → PLCopen (already unit-tested — here assert the flow); calling the new `debugImportXml(basicXml)` creates a NEW project (project count increases by 1) whose name is `DemoProject`, with 3 tags + 1 struct + 2 programs, and the previously-active project is unchanged.
  - the preview widget (`ImportXmlPreview`, keyed `Key('import_xml_preview')`) renders the counts and at least one warning line; editing the name field (`Key('import_xml_name_field')`) and tapping Create (`Key('import_xml_create_button')`) applies with the edited name.
  - a malformed XML string routed through the flow surfaces the friendly error (no crash / no new project).
  - no overflow at 320/360/1400 with the preview open.
- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement.**
  - `import_xml_preview.dart`: a screen/dialog taking `ImportResult` + an `onCreate(String finalName)` callback; shows an editable name `TextField(Key('import_xml_name_field'))` (default `result.project.name`), the counts (`N tags · M structs · K programs (J graphical stubs)`), a scrollable warning list (info = white70, warning = amber), and `Create`/`Cancel` buttons (`Key('import_xml_create_button')`). Dark theme; wrap content in a scroll view so it never overflows at 320.
  - In `workspace_shell.dart`, add `_importProgramXml()` mirroring `_importProject` (`:1317`) but: `allowedExtensions: ['xml']`; after reading text, `final dialect = detectDialect(text);` — if null, snackbar "Couldn't recognize this as a supported PLC export (only PLCopen TC6 XML is supported so far)"; else `try { final ir = parsePlcOpen(text); final id = 'proj_new_${DateTime.now().millisecondsSinceEpoch}'; final result = mapImportedProject(ir, projectName: ir.name, projectId: id); }` — on `FormatException` show a snackbar (mirror the existing catch). Push `ImportXmlPreview(result: result, onCreate: (name) async { final proj = result.project..name = name; final withId = ProjectTransfer.reassignIdIfColliding(proj, _allProjects.map((p)=>p.id).toSet()); await _applyImportedProject(withId); })`. Add the menu entry `_ProjectMenuEntry(icon: Icons.upload_file, label: 'Import PLC Program (XML)')` next to `'Import Project'` (`:2189`), wired to `_importProgramXml`.
  - Add the `debugImportXml(String xml)` hook: `final ir = parsePlcOpen(xml); final result = mapImportedProject(ir, projectName: ir.name, projectId: 'proj_new_test'); final withId = ProjectTransfer.reassignIdIfColliding(result.project, _allProjects.map((p)=>p.id).toSet()); return _applyImportedProject(withId);`.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Full validation**
```bash
cd mobile && flutter analyze           # zero warnings
cd mobile && flutter test              # ALL pass — record the count
cd mobile && flutter build web --release
```
- [ ] **Step 6: Docs + commit.** `docs/import/plcopen.md`: what's supported (vars→tags, DUTs→structs, ST/IL→ST programs), what's captured-but-stubbed (LD/FBD/SFC — re-import when translation ships), autodetect+override, the new-project behavior, how to run the import, and the deferred list (graphical translators, L5X/Siemens, merge, export). No competitor branding beyond the neutral vendor/format names (PLCopen, CODESYS, Beckhoff, Schneider, Rockwell, Siemens are format/vendor names, used factually like the protocol docs use Ignition).
```bash
git add mobile/lib/screens/workspace_shell.dart mobile/lib/screens/import_xml_preview.dart mobile/test/import/import_xml_flow_test.dart docs/import/plcopen.md
git commit -m "feat(import): Import PLC Program (XML) menu, dialect dropdown, preview + create-new-project"
```

---

## Self-Review

**Spec coverage:** Component 1 (IR) → Task 1 ✓; dialect detect → Task 1 ✓; Component 3 (PLCopen parser incl. lossless GraphBody) → Task 3 ✓; Component 4 (type normalization) → Task 2 ✓; Component 5 (mappers + ImportReport) → Task 4 ✓; Component 6 (UI: menu, autodetect+override dropdown, preview, create-new-project) → Task 5 ✓; testing folded per task; docs → Task 5. All five approved decisions bound: PLCopen-first (Task 3), vendor-neutral IR (Task 1, consumed by 3-4), foundation-now/graphical-stubbed (Task 4's stub branch + Task 1's GraphBody), new-project target (Task 5), autodetect+override (Task 5 dropdown + Task 1 detect).

**Placeholder scan:** No TBDs. The two "adjust if brittle against the fixtures" notes (parser `_baseTypeName`, and the `_norm`/`normalizeTypePublic` one-source-of-truth choice) are explicit, bounded instructions with the tests as the correctness oracle — not vague hand-waving. The `xml` version `^6.5.0` is pinned.

**Type consistency:** `ImportedProject`/`ImportedVar`/`ImportedType`/`ImportedField`/`ImportedPou`/`PouBody`(`TextBody`/`GraphBody`)/`IrGraphNode`/`IrConnection`/`ImportWarning` + the enums (Task 1) are used unchanged in Tasks 3-4. `normalizeType(String, {required Set<String> knownDutNames})` and `coerceInitialValue(PlcProject, String, int, String?, List<ImportWarning>)` (Task 2) match their Task 3-4 call sites. `parsePlcOpen(String) → ImportedProject` (Task 3) and `mapImportedProject(ImportedProject, {required String projectName, required String projectId}) → ImportResult` with `ImportResult{project, report}` / `ImportReport{tagCount, structCount, stProgramCount, graphicalStubCount, warnings}` (Task 4) match Task 5's flow. The UI reuses the real `_applyImportedProject`/`ProjectTransfer.reassignIdIfColliding`/`debugImport*` shapes.

**Note for the executor:** binding properties — (a) the pure core never crashes: `parsePlcOpen` throws `FormatException` ONLY on malformed/non-PLCopen XML, everything else is a warning; detect + mappers never throw; (b) import is purely additive — a NEW project, current project untouched, existing suites green; (c) graphical bodies are captured losslessly to `GraphBody` but mapped to stubs in v1 (a later sub-project adds the translators + a re-import); (d) determinism — no clock/RNG in the core, the project id is supplied by the UI; (e) identifier hygiene — sanitize + dedupe + never emit `System`, each rename a warning; (f) `xml` use confined to `plcopen_parser.dart`; (g) zero analyze warnings, no overflow at 320/360/1400. Tasks 1-4 are pure and independently testable; Task 5 is thin UI over them mirroring the existing `_importProject` flow.
