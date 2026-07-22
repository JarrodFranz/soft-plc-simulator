// Task 5 of the PLCopen-XML program import feature: the thin UI wiring
// (menu action, autodetect + friendly-error snackbar, preview screen,
// create-new-project) over the pure Tasks 1-4 core (IR, dialect detection,
// PLCopen parser, IR→PlcProject mapper).
//
// The file_picker platform channel can't be faithfully mocked in a widget
// test (see `debugImportProject`'s doc comment in workspace_shell.dart), so
// these tests drive `WorkspaceShellState`'s test-only hooks that pick up
// right where the file picker leaves off:
//  - `debugImportXml` — parse+map+apply directly (bypasses picker AND the
//    preview screen) — used to assert the mapped project actually lands.
//  - `debugImportXmlFlow` — autodetect→parse/map→preview-or-error-snackbar
//    (bypasses only the picker) — used to exercise the friendly-error path.
// The preview widget (`ImportXmlPreview`) itself is also tested standalone.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/import_xml_preview.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

import '../support/responsive_test_utils.dart';

/// Well-formed PLCopen-flagged XML but with an unclosed tag: `detectDialect`
/// recognizes the `plcopen`-namespaced `<project>` root (so this reaches
/// `parsePlcOpen`), but the document itself doesn't parse — this is the
/// "malformed" case that must surface a friendly snackbar, never a crash.
const String _malformedButRecognizedXml =
    '<project xmlns="http://www.plcopen.org/xml/tc6_0201"><contentHeader name="Broken"><unclosed></project>';

/// Not PLCopen at all (no `<project` root, no plcopen/tc6 marker) — the
/// "unrecognized dialect" case, handled before `parsePlcOpen` is ever called.
const String _unrecognizedXml = '<RSLogix5000Content><Controller/></RSLogix5000Content>';

ImportResult _fakeResult({
  List<ImportWarning>? warnings,
  int stubbedRungCount = 0,
  Set<String> unsupportedLdBlockTypes = const {},
}) {
  final project = PlcProject(
    id: 'proj_new_test',
    name: 'Imported Demo',
    controllerName: 'Imported Demo',
    tags: [
      PlcTag(name: 'Temp_PV', path: 'Temp_PV', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
    ],
    structDefs: [],
    programs: [PlcProgram(name: 'Main', language: 'StructuredText', stSource: 'Count := Count + 1;')],
    tasks: [],
    hmis: [],
  );
  return ImportResult(
    project: project,
    report: ImportReport(
      tagCount: 1,
      structCount: 0,
      stProgramCount: 1,
      graphicalStubCount: 1,
      warnings: warnings ??
          [
            ImportWarning(
                severity: WarningSeverity.warning,
                message: 'POU "Rung1" (LadderLogic): graphical body not yet translated.'),
          ],
      stubbedRungCount: stubbedRungCount,
      unsupportedLdBlockTypes: unsupportedLdBlockTypes,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('debugImportXml (parse+map+apply, bypassing the picker and preview)', () {
    testWidgets('creates a new project from basic.xml with the real mapped counts',
        (tester) async {
      final basicXml = File('test/fixtures/plcopen/basic.xml').readAsStringSync();

      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      final previousActiveId = state.debugActiveProject.id;
      final countBefore = state.debugAllProjects.length;

      await state.debugImportXml(basicXml);
      await tester.pump();

      expect(state.debugAllProjects.length, countBefore + 1,
          reason: 'importing must add a new project, never replace one');
      expect(state.debugActiveProject.name, 'DemoProject',
          reason: "basic.xml's <contentHeader name=\"DemoProject\"/> supplies the project name");

      // basic.xml: 3 globalVars -> 3 tags, 1 DUT -> 1 struct, 2 POUs (Main:ST,
      // Rung1:LD) -> 1 ST program + 1 LadderLogic program = 2 programs total.
      // Rung1's contact->coil wiring in the fixture has no explicit power-rail
      // nodes (see plcopen_parser_test.dart's "lossless GraphBody" test), so
      // translateLdBody's edge-coverage faithfulness gate stubs it (Task 5:
      // LD is now translated per-rung by the mapper, not skipped wholesale —
      // this fixture just happens to still fully stub).
      final imported = state.debugAllProjects.firstWhere((p) => p.name == 'DemoProject');
      expect(imported.tags, hasLength(3));
      expect(imported.structDefs, hasLength(1));
      expect(imported.programs, hasLength(2));
      final rung1 = imported.programs.singleWhere((p) => p.name == 'Rung1');
      expect(rung1.language, 'LadderLogic');
      expect(rung1.rungs, isEmpty);
      expect(rung1.description, contains('not yet translated'));
      expect(imported.id, isNot(previousActiveId));

      final previous = state.debugAllProjects.firstWhere((p) => p.id == previousActiveId);
      expect(previous.name, isNot('DemoProject'),
          reason: 'the previously-active project must be unchanged, not overwritten');
    });
  });

  group('ImportXmlPreview (standalone)', () {
    testWidgets('renders the counts line and at least one warning', (tester) async {
      final result = _fakeResult();
      await tester.pumpWidget(MaterialApp(
        home: ImportXmlPreview(result: result, onCreate: (_) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('import_xml_preview')), findsOneWidget);
      expect(find.textContaining('1 tags'), findsOneWidget);
      expect(find.textContaining('0 structs'), findsOneWidget);
      expect(find.textContaining('2 programs'), findsOneWidget);
      expect(find.textContaining('1 graphical stubs'), findsOneWidget);
      expect(find.textContaining('graphical body not yet translated'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'shows the untranslated-rung note with unsupported blocks when stubbedRungCount > 0',
        (tester) async {
      final result =
          _fakeResult(stubbedRungCount: 2, unsupportedLdBlockTypes: {'FANCYFB'});
      await tester.pumpWidget(MaterialApp(
        home: ImportXmlPreview(result: result, onCreate: (_) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 rung(s) not translated'), findsOneWidget);
      expect(find.textContaining('FANCYFB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not show the untranslated-rung note when stubbedRungCount is 0',
        (tester) async {
      final result = _fakeResult();
      await tester.pumpWidget(MaterialApp(
        home: ImportXmlPreview(result: result, onCreate: (_) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('rung(s) not translated'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing the name field and tapping Create invokes onCreate with the edited name',
        (tester) async {
      final result = _fakeResult();
      String? created;
      await tester.pumpWidget(MaterialApp(
        home: ImportXmlPreview(result: result, onCreate: (name) => created = name),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('import_xml_name_field')), 'Renamed Import');
      await tester.pump();
      await tester.tap(find.byKey(const Key('import_xml_create_button')));
      await tester.pump();

      expect(created, 'Renamed Import');
      expect(tester.takeException(), isNull);
    });

    for (final entry in {
      'small phone (320)': smallPhoneSize,
      'phone (360)': phoneSize,
      'desktop (1400)': desktopSize,
    }.entries) {
      testWidgets('no overflow at ${entry.key}', (tester) async {
        await setSurface(tester, entry.value);
        final manyWarnings = [
          for (var i = 0; i < 15; i++)
            ImportWarning(
                severity: i.isEven ? WarningSeverity.warning : WarningSeverity.info,
                message: 'Warning number $i describing a mapping caveat in some detail.'),
        ];
        await tester.pumpWidget(MaterialApp(
          home: ImportXmlPreview(result: _fakeResult(warnings: manyWarnings), onCreate: (_) {}),
        ));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('debugImportXmlFlow (autodetect + friendly-error, bypassing only the picker)', () {
    testWidgets('an unrecognized dialect shows the not-recognized snackbar and creates no project',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      final countBefore = state.debugAllProjects.length;

      await state.debugImportXmlFlow(_unrecognizedXml);
      await tester.pump();

      expect(find.textContaining("Couldn't recognize this as a supported PLC export"),
          findsOneWidget);
      expect(state.debugAllProjects.length, countBefore,
          reason: 'an unrecognized dialect must not create a project');
      expect(tester.takeException(), isNull);
    });

    testWidgets('malformed-but-recognized XML shows a friendly error and creates no project, no crash',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      final countBefore = state.debugAllProjects.length;

      await state.debugImportXmlFlow(_malformedButRecognizedXml);
      await tester.pump();

      expect(find.textContaining("Couldn't import: not a valid PLCopen document"), findsOneWidget);
      expect(state.debugAllProjects.length, countBefore,
          reason: 'a malformed document must not create a project');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a recognized, well-formed document pushes the preview screen', (tester) async {
      final basicXml = File('test/fixtures/plcopen/basic.xml').readAsStringSync();

      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      unawaited(state.debugImportXmlFlow(basicXml));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('import_xml_preview')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
